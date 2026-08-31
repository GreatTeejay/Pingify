//go:build linux

package main

import (
	"net"
	"syscall"

	"golang.org/x/sys/unix"
)

// ---------------------------------------------------------------------------
// asking for a socket buffer the kernel will actually give
//
// SetReadBuffer asks for SO_RCVBUF, and the kernel silently clamps that to
// net.core.rmem_max - which on an ordinary server is 212992 bytes. It does not
// fail, it does not warn, and nothing above ever learns that the buffer it
// asked for is not the buffer it has.
//
// On a raw socket carrying a private link that is the whole ballgame. The
// tunnel's own counters said it was dropping nothing, and it was not: the
// kernel was, before we ever saw the packets. Read straight off the socket on
// a real server while a tunnel ran on it:
//
//	skmem:(r0,rb425984,t0,tb425984,f0,w0,o464,bl0,d925)
//	                                                ^^^^ dropped
//
// Nine hundred and twenty-five packets thrown away for want of room, and every
// one of them read by the TCP inside the tunnel as congestion. That is what
// held a single stream to a quarter of what the pair could carry.
//
// SO_RCVBUFFORCE and SO_SNDBUFFORCE are the same request without the clamp,
// and a process with CAP_NET_ADMIN may make it - which this one has, because a
// raw socket needs the same privilege. Where it is refused the ordinary call
// still applies, so an unprivileged build keeps the old behaviour rather than
// no buffer at all.
// ---------------------------------------------------------------------------

// forceSocketBuffer sets the receive and send buffers past net.core.*_max
// where the kernel allows it, and reports what the socket ended up with.
func forceSocketBuffer(pc net.PacketConn, rcv, snd int) (gotRcv, gotSnd int) {
	sc, ok := pc.(syscall.Conn)
	if !ok {
		return 0, 0
	}
	raw, err := sc.SyscallConn()
	if err != nil {
		return 0, 0
	}
	_ = raw.Control(func(fd uintptr) {
		f := int(fd)
		if rcv > 0 {
			// Try the privileged one first; fall back to the ordinary request,
			// which the kernel will clamp but not refuse.
			if unix.SetsockoptInt(f, unix.SOL_SOCKET, unix.SO_RCVBUFFORCE, rcv) != nil {
				_ = unix.SetsockoptInt(f, unix.SOL_SOCKET, unix.SO_RCVBUF, rcv)
			}
		}
		if snd > 0 {
			if unix.SetsockoptInt(f, unix.SOL_SOCKET, unix.SO_SNDBUFFORCE, snd) != nil {
				_ = unix.SetsockoptInt(f, unix.SOL_SOCKET, unix.SO_SNDBUF, snd)
			}
		}
		// Ahead of ordinary traffic in the qdisc, behind anything the kernel
		// considers control. What this carries is somebody's call or game, and
		// on a server that is also doing other things it should not wait
		// behind a backup.
		_ = unix.SetsockoptInt(f, unix.SOL_SOCKET, unix.SO_PRIORITY, 6)
		// What the kernel reports back is doubled: it counts its own
		// bookkeeping in the figure. Halving it gives the usable bytes, which
		// is what was asked for and what belongs in the log.
		if v, e := unix.GetsockoptInt(f, unix.SOL_SOCKET, unix.SO_RCVBUF); e == nil {
			gotRcv = v / 2
		}
		if v, e := unix.GetsockoptInt(f, unix.SOL_SOCKET, unix.SO_SNDBUF); e == nil {
			gotSnd = v / 2
		}
	})
	return gotRcv, gotSnd
}
