//go:build linux

package main

import (
	"net"
	"time"

	"golang.org/x/sys/unix"
)

// ---------------------------------------------------------------------------
// telling the kernel how long to keep trying
//
// The measured failure on this path is not a reset and not an error. A
// connection into Iran completes, carries a few exchanges, and is then
// blackholed: nothing comes back and nothing says so. TCP does what TCP does -
// it retransmits, backs off, and keeps the socket open. Captured on the wire,
// one carrier retransmitted the same 37 bytes at 0.25s, 0.5s, 1s, 2s, 4s, 8s
// and was still trying when we stopped watching, while the far end had long
// since stopped answering.
//
// Everything above it believed the carrier was fine, because from its side
// nothing had failed. Streams pinned there hung, new ones kept being handed to
// it, and the tunnel went on reporting every carrier up.
//
// TCP_USER_TIMEOUT is the kernel's own answer: it bounds how long data may go
// unacknowledged before the socket gives up and returns ETIMEDOUT. It needs no
// protocol change, no cooperation from the peer, and no keepalive to notice -
// the kernel already knows, and this is how it is asked to say so.
// ---------------------------------------------------------------------------

// How long unacknowledged data may sit before the kernel gives up on the
// socket. Comfortably above any real round trip on this route - Germany is
// 80 ms - and far below the minute the silence check needs.
const userTimeout = 4 * time.Second

func setUserTimeout(c net.Conn) {
	tc := baseTCP(c)
	if tc == nil {
		return
	}
	raw, err := tc.SyscallConn()
	if err != nil {
		return
	}
	// Best effort: an old kernel that does not know the option is not a
	// reason to refuse the carrier, it just keeps the old behaviour.
	_ = raw.Control(func(fd uintptr) {
		_ = unix.SetsockoptInt(int(fd), unix.IPPROTO_TCP,
			unix.TCP_USER_TIMEOUT, int(userTimeout/time.Millisecond))
	})
}
