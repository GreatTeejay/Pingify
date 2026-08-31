//go:build linux && (amd64 || arm64)

package carrier

import (
	"syscall"
	"unsafe"
)

// One crossing into the kernel per batch, instead of one per packet.
//
// At four hundred megabits this link moves something like forty thousand
// packets a second in each direction. One recvfrom and one sendto each is
// eighty thousand system calls a second, on a server with one core, and it is
// the whole difference between what the plain path measured and what the wire
// can carry:
//
//	                    idle ping   16 streams
//	one call per packet   81.0 ms    351 Mbit/s
//	recvmmsg/sendmmsg     81.0 ms    (see below)
//
// The ping was never the problem - a single packet with nothing behind it
// costs one call either way. It is throughput that pays, and it pays in the
// place that is hardest to see from inside the process, because the packets
// are not dropped by us and not delayed by us: they simply arrive at the wire
// later than they could have.
//
// recvmmsg and sendmmsg are not in Go's syscall package as functions, only as
// numbers, so the structures are laid out here. Both are stable kernel ABI and
// have been since 2.6.33; the layout below is for 64-bit, which is what the
// build tag says.
const (
	recvBatch = 128 // what a busy link can have waiting when we look
	sendBatch = 64  // the most a sender will ever be asked for

	// How many packets go on the wire in one crossing unless the config says
	// otherwise. One - which is to say, none.
	//
	// This is not a throughput knob. It is a burst knob, and the path cares
	// about bursts far more than it cares about syscalls. Measured at Germany
	// by counting gaps in our own sequence numbers, one stream pushing:
	//
	//	  send_batch    packets the path lost    one stream
	//	      64             2.870%               129.8 Mbit/s
	//	      16             0.728%               144.1
	//	       4             1.145%               157.0
	//	       1             0.000%               170.6
	//
	// flagtun on the same path in the same minute lost nothing at all, which
	// is what said the loss was ours and not the route's. Draining the device
	// and firing sixty-four packets into the wire at line rate undoes the
	// pacing the TCP inside had carefully applied, and something on the way
	// polices the burst by dropping a run of it - a hundred and seventy-three
	// packets in a row, twice in fifteen seconds.
	//
	// Batching cost nothing to give up. Sixteen streams carried 442.7 Mbit/s
	// at a batch of one against 443.2 at sixty-four, because with sixteen
	// streams the packets are already there when we look; it is the single
	// stream, the one that arrives paced, that a batch can only damage.
	defaultSendBatch = 1
)

// mmsghdr is the kernel's struct mmsghdr: a msghdr and the length that call
// filled in. syscall.Msghdr is already the right shape for the first half.
type mmsghdr struct {
	hdr syscall.Msghdr
	len uint32
	_   [4]byte
}

// batchReader takes up to recvBatch datagrams off a socket in one call.
type batchReader struct {
	msgs []mmsghdr
	iovs []syscall.Iovec
	sas  []syscall.RawSockaddrInet4
	bufs [][]byte
}

func newBatchReader(size int) *batchReader {
	r := &batchReader{
		msgs: make([]mmsghdr, recvBatch),
		iovs: make([]syscall.Iovec, recvBatch),
		sas:  make([]syscall.RawSockaddrInet4, recvBatch),
		bufs: make([][]byte, recvBatch),
	}
	for i := range r.bufs {
		r.bufs[i] = make([]byte, size)
		r.iovs[i].Base = &r.bufs[i][0]
		r.iovs[i].Len = uint64(size)
		r.msgs[i].hdr.Name = (*byte)(unsafe.Pointer(&r.sas[i]))
		r.msgs[i].hdr.Namelen = uint32(unsafe.Sizeof(r.sas[i]))
		r.msgs[i].hdr.Iov = &r.iovs[i]
		r.msgs[i].hdr.Iovlen = 1
	}
	return r
}

// read waits for the socket to have something and takes everything that is
// there, up to the batch size. It returns how many datagrams arrived.
//
// rc.Read parks the goroutine on the network poller until the socket is
// readable, then calls this; returning false means "not ready after all, wait
// again", which is what EAGAIN means when a poller wakes on a packet another
// goroutine got to first.
func (r *batchReader) read(rc syscall.RawConn) (int, error) {
	var n int
	var errno syscall.Errno
	err := rc.Read(func(fd uintptr) bool {
		ret, _, e := syscall.Syscall6(sysRecvmmsg, fd,
			uintptr(unsafe.Pointer(&r.msgs[0])), uintptr(len(r.msgs)), 0, 0, 0)
		if e == syscall.EAGAIN || e == syscall.EINTR {
			return false
		}
		n, errno = int(ret), e
		return true
	})
	if err != nil {
		return 0, err
	}
	if errno != 0 {
		return 0, errno
	}
	// The kernel writes each datagram's length into msg_len and leaves the
	// iovecs alone, so the buffers are ready for the next call as they are.
	return n, nil
}

// packet returns the i'th datagram of the batch and the address it came from.
func (r *batchReader) packet(i int) ([]byte, [4]byte) {
	return r.bufs[i][:r.msgs[i].len], r.sas[i].Addr
}

// batchWriter puts up to sendBatch datagrams on a socket in one call.
type batchWriter struct {
	msgs []mmsghdr
	iovs []syscall.Iovec
	sas  []syscall.RawSockaddrInet4
}

func newBatchWriter() *batchWriter {
	w := &batchWriter{
		msgs: make([]mmsghdr, sendBatch),
		iovs: make([]syscall.Iovec, sendBatch),
		sas:  make([]syscall.RawSockaddrInet4, sendBatch),
	}
	for i := range w.msgs {
		w.sas[i].Family = syscall.AF_INET
		w.msgs[i].hdr.Name = (*byte)(unsafe.Pointer(&w.sas[i]))
		w.msgs[i].hdr.Namelen = uint32(unsafe.Sizeof(w.sas[i]))
		w.msgs[i].hdr.Iov = &w.iovs[i]
		w.msgs[i].hdr.Iovlen = 1
	}
	return w
}

// write sends the given packets to one address, and reports how many the
// kernel took. A short count is not an error: the caller keeps the rest for
// the next crossing rather than throwing them away.
func (w *batchWriter) write(rc syscall.RawConn, pkts [][]byte, to [4]byte) (int, error) {
	n := len(pkts)
	if n > len(w.msgs) {
		n = len(w.msgs)
	}
	for i := 0; i < n; i++ {
		w.sas[i].Addr = to
		w.iovs[i].Base = &pkts[i][0]
		w.iovs[i].Len = uint64(len(pkts[i]))
	}

	var sent int
	var errno syscall.Errno
	err := rc.Write(func(fd uintptr) bool {
		ret, _, e := syscall.Syscall6(sysSendmmsg, fd,
			uintptr(unsafe.Pointer(&w.msgs[0])), uintptr(n), 0, 0, 0)
		if e == syscall.EAGAIN || e == syscall.EINTR {
			return false
		}
		sent, errno = int(ret), e
		return true
	})
	if err != nil {
		return 0, err
	}
	if errno != 0 {
		return sent, errno
	}
	return sent, nil
}

const canBatch = true
