//go:build linux

package main

import (
	"os"
	"syscall"
)

// Taking whatever else is already there, without waiting for it.
//
// The device is read by a goroutine that blocks for the first packet. Once it
// has one, anything already queued behind it can be collected for the same
// crossing into the kernel - but only what is already there. Waiting even
// briefly for a batch to fill would put the delay back that batching was
// supposed to remove, and a link with one packet on it must send one packet.
//
// rc.Control runs on the descriptor without asking the poller to wait, which
// is exactly the difference between this and an ordinary Read.
func rawOf(f *os.File) syscall.RawConn {
	rc, err := f.SyscallConn()
	if err != nil {
		return nil
	}
	return rc
}

// readNow returns a packet if one is waiting, and false if none is.
func readNow(rc syscall.RawConn, b []byte) (int, bool) {
	var n int
	var ok bool
	_ = rc.Control(func(fd uintptr) {
		m, err := syscall.Read(int(fd), b)
		if err == nil && m > 0 {
			n, ok = m, true
		}
	})
	return n, ok
}
