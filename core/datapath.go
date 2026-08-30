package main

import (
	"os"
	"sync"
	"sync/atomic"
	"time"
)

// ---------------------------------------------------------------------------
// the private link's datapath
//
// This is the part that decides what the tunnel feels like. Everything else -
// the handshake, the token, the wizard - happens once. This runs for every
// packet, tens of thousands of times a second, and what it costs per packet is
// what the link costs.
//
// It was rebuilt around one measurement. Profiled on a real server abroad
// carrying this tunnel with the cipher out of the way, so nothing else could
// be blamed:
//
//	9.85%  finish_task_switch
//	8.64%  _raw_spin_unlock_irqrestore
//	2.30%  do_syscall_64
//
// Nothing of ours was hot. No cipher, no hash, no parsing - the processor was
// going into the kernel and coming back, and switching threads while it did.
// The work was not the problem. Getting to the work was.
//
// So the shape here follows one rule: cross a boundary once for many packets,
// never once per packet. There are three boundaries and each one is crossed in
// batches now.
//
//	the socket        recvmmsg already read a batch; the batch is kept whole
//	                  through the whole path instead of being taken apart at
//	                  the first hop
//
//	the writers       a batch is handed to a device writer in one send, not
//	                  one send per packet. At a hundred and twenty-eight
//	                  packets a batch that is one wakeup instead of a hundred
//	                  and twenty-eight
//
//	the device        one write per packet, which is all a TUN device offers -
//	                  but the writes for a batch happen back to back on one
//	                  thread that is already running, not on a thread that had
//	                  to be woken for each
//
// Ordering survives all of it, and that is not incidental. A packet is placed
// by its flow: every packet of a flow goes to the same writer, and a writer
// writes what it is given in the order it was given. Different flows are
// written at the same time by different threads. Order is a property of a
// flow, not of a device, and this is the only place it has to be paid for.
//
// The alternative - one reader doing all the writing - keeps order too, and
// was measured: it held the link to a third of what the pair could carry,
// because every write into the kernel queued behind the one before it.
// ---------------------------------------------------------------------------

const (
	// How many packets a device writer takes in one handover. Sized to the
	// receive batch so a full socket read becomes one wakeup per writer.
	deviceBatch = 128

	// How many batches may be waiting for a writer before the path sheds.
	// Short on purpose: a writer that is behind means the device is behind,
	// and a queue in front of it only adds delay to packets that are already
	// late. Dropping is what a router does and it is the signal the sender
	// inside is waiting for.
	deviceQueueDepth = 8
)

// pktBuf is one packet on its way to the device. The path owns it from the
// moment it is filled to the moment it has been written.
type pktBuf struct {
	b []byte
}

var pktBufPool = sync.Pool{New: func() interface{} {
	return &pktBuf{b: make([]byte, 0, 2048)}
}}

func getPktBuf(src []byte) *pktBuf {
	p := pktBufPool.Get().(*pktBuf)
	if cap(p.b) < len(src) {
		p.b = make([]byte, len(src))
	}
	p.b = p.b[:len(src)]
	copy(p.b, src)
	return p
}

func putPktBuf(p *pktBuf) {
	p.b = p.b[:0]
	pktBufPool.Put(p)
}

// deviceWriter owns one device queue and writes what it is handed, in order.
type deviceWriter struct {
	q    *os.File
	in   chan []*pktBuf
	done <-chan struct{}

	dropped uint64 // batches shed because this writer was behind
}

func (w *deviceWriter) run() {
	for {
		select {
		case <-w.done:
			return
		case batch := <-w.in:
			for _, p := range batch {
				if _, err := w.q.Write(p.b); err != nil {
					logDebug("tun write: %v", err)
				}
				putPktBuf(p)
			}
			batchPool.Put(batch[:0])
		}
	}
}

var batchPool = sync.Pool{New: func() interface{} {
	return make([]*pktBuf, 0, deviceBatch)
}}

// deviceFan places packets on writers by flow and hands them over in batches.
//
// One of these belongs to the goroutine draining the socket, and only that
// goroutine touches it, so it needs no lock of its own.
type deviceFan struct {
	writers []*deviceWriter
	pending [][]*pktBuf // one accumulating batch per writer
}

func newDeviceFan(queues []*os.File, done <-chan struct{}) *deviceFan {
	f := &deviceFan{
		writers: make([]*deviceWriter, len(queues)),
		pending: make([][]*pktBuf, len(queues)),
	}
	for i, q := range queues {
		w := &deviceWriter{
			q:    q,
			in:   make(chan []*pktBuf, deviceQueueDepth),
			done: done,
		}
		f.writers[i] = w
		f.pending[i] = batchPool.Get().([]*pktBuf)
		go w.run()
	}
	return f
}

// add takes one packet. The bytes are copied: they belong to the socket's
// receive batch and will be overwritten as soon as this returns.
func (f *deviceFan) add(pkt []byte) {
	if len(f.writers) == 0 || len(pkt) == 0 {
		return
	}
	i := int(flowHash(pkt) % uint32(len(f.writers)))
	f.pending[i] = append(f.pending[i], getPktBuf(pkt))
	if len(f.pending[i]) >= deviceBatch {
		f.flushOne(i)
	}
}

// flush hands over everything accumulated. Called once at the end of a socket
// batch, so a batch of any size costs one wakeup per writer that has work.
func (f *deviceFan) flush() {
	for i := range f.pending {
		if len(f.pending[i]) > 0 {
			f.flushOne(i)
		}
	}
}

func (f *deviceFan) flushOne(i int) {
	batch := f.pending[i]
	w := f.writers[i]
	select {
	case w.in <- batch:
	default:
		// The writer is behind, which means the device is behind. Shed it.
		for _, p := range batch {
			putPktBuf(p)
		}
		atomic.AddUint64(&w.dropped, uint64(len(batch)))
		batchPool.Put(batch[:0])
	}
	f.pending[i] = batchPool.Get().([]*pktBuf)
}

// shed reports how many packets every writer has had to drop, which is the
// only honest measure of whether this side is keeping up.
func (f *deviceFan) shed() uint64 {
	var n uint64
	for _, w := range f.writers {
		n += atomic.LoadUint64(&w.dropped)
	}
	return n
}

// watchShedding says so when this side starts dropping, because a drop here
// is indistinguishable from a drop on the path to everything above - the TCP
// inside halves its window either way - and only this end knows which it was.
func (f *deviceFan) watchShedding(done <-chan struct{}) {
	t := time.NewTicker(15 * time.Second)
	defer t.Stop()
	var last uint64
	for {
		select {
		case <-done:
			return
		case <-t.C:
			n := f.shed()
			if n == last {
				continue
			}
			logWarn("the private link dropped %d packets writing to the device "+
				"in the last 15s (%d in all) - this end is not keeping up, and "+
				"the sender inside will read it as congestion", n-last, n)
			last = n
		}
	}
}
