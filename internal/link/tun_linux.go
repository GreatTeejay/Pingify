//go:build linux

package link

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"unsafe"
)

// The device, opened the only way Linux offers: /dev/net/tun and one ioctl.
const (
	tunsetiff       = 0x400454ca
	iffTun          = 0x0001
	iffNoPI         = 0x1000
	iffMultiQueue   = 0x0100
	ifNameSize      = 16
	ifreqSize       = 40
	deviceQueuesMin = 2
	deviceQueuesMax = 8
)

// openTUN attaches one queue to the named device, creating it if this is the
// first. Every queue after the first must ask for multi-queue too, and so must
// the first, which is why the flag is not conditional on the count here.
//
// The descriptor is put in non-blocking mode and handed to os.NewFile, which
// gives it to Go's poller. Two things depend on that. An ordinary Read still
// blocks the goroutine and not the thread, as it would either way; and a read
// that goes straight to the descriptor - see readNow - returns at once when
// there is nothing there, instead of waiting for the next packet.
//
// That second one is not a nicety. With a blocking descriptor, a reader that
// had one packet and looked for a second would wait for it, and the first
// packet would sit built and unsent until more traffic happened to arrive.
// A lone SYN never gets sent at all, and the tunnel comes up carrying nothing.
func openTUN(name string, multi bool) (*os.File, error) {
	if len(name) >= ifNameSize {
		return nil, fmt.Errorf("device name %q is too long", name)
	}
	fd, err := syscall.Open("/dev/net/tun", syscall.O_RDWR|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, fmt.Errorf("open /dev/net/tun: %v (is the tun module loaded?)", err)
	}

	var req [ifreqSize]byte
	copy(req[:ifNameSize-1], name)
	flags := uint16(iffTun | iffNoPI)
	if multi {
		flags |= iffMultiQueue
	}
	*(*uint16)(unsafe.Pointer(&req[ifNameSize])) = flags

	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), tunsetiff,
		uintptr(unsafe.Pointer(&req[0]))); e != 0 {
		syscall.Close(fd)
		return nil, fmt.Errorf("attach to %s: %v", name, e)
	}
	if err := syscall.SetNonblock(fd, true); err != nil {
		syscall.Close(fd)
		return nil, fmt.Errorf("%s: could not be made non-blocking: %v", name, err)
	}
	return os.NewFile(uintptr(fd), "/dev/net/tun"), nil
}

// configureDevice gives the interface its address and brings it up, by asking
// iproute2 rather than by opening a netlink socket. It runs once at startup,
// where a fork costs nothing and a hand-rolled netlink implementation would
// cost several hundred lines that only ever run once.
func configureDevice(name, addr string, mtu, txqueuelen int) error {
	run := func(args ...string) error {
		out, err := exec.Command("ip", args...).CombinedOutput()
		if err != nil {
			return fmt.Errorf("ip %s: %v: %s",
				strings.Join(args, " "), err, strings.TrimSpace(string(out)))
		}
		return nil
	}
	// The queue is set with the address because the default is far too short
	// for this. A tun device holds txqueuelen packets between the kernel
	// putting them there and us reading them, and the default is 500 - while
	// one TCP stream through an eighty millisecond path runs a window of eight
	// hundred and more. A burst does not fit, and the device throws away the
	// remainder.
	//
	// Those drops are invisible from inside this process: they happen before
	// the read, so the carrier's counters show nothing lost, and ss shows the
	// consequence instead - retransmissions, and a congestion window that
	// never grows. Counted over eighteen seconds of one stream:
	//
	//	  txqueuelen    dropped by the device    one stream
	//	     500          47, 1167, 2320         116, 116, 98 Mbit/s
	//	   10000              0, 0, 0            117, 140, 137 Mbit/s
	//
	// So it was ten thousand, with a note saying that was "about thirty
	// milliseconds" at four hundred megabits. The arithmetic was wrong: ten
	// thousand packets of 1320 bytes is 105 megabits, which at four hundred
	// megabits a second is 264 milliseconds, and it was not a burst that
	// drained - it was a standing backlog with every reply queued behind it.
	// It was the whole of this tunnel's latency under load. Measured on the
	// Tehran to Frankfurt pair, eight streams downloading, the round trip
	// taken through the tunnel while it ran:
	//
	//	  txqueuelen    download        p50 / p90
	//	   10000        409 Mbit/s      75 / 234 ms
	//	    2000        357             76 / 119
	//	    1000        409             75 / 109
	//	     500        378             75 /  84
	//
	// A thousand carries exactly what ten thousand carried and answers in
	// less than half the time; one stream on its own went up rather than
	// down, 381 to 432. The device drops more - that is the point of a queue
	// with an end to it, and the TCP inside reads a drop as the signal it is
	// for, which is what keeps the queue short. tun.txqueuelen moves it, for
	// a path that measures differently.
	if err := run("link", "set", "dev", name, "mtu", fmt.Sprint(mtu),
		"txqueuelen", fmt.Sprint(txqueuelen), "up"); err != nil {
		return err
	}
	return run("addr", "add", addr, "dev", name)
}
