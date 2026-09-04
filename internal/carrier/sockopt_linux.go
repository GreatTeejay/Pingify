//go:build linux

package carrier

import (
	"net"
	"syscall"
	"time"

	"pingify/internal/config"
	"pingify/internal/logging"
)

// Asking for a socket buffer the kernel will actually give.
//
// SetReadBuffer asks for SO_RCVBUF, and the kernel silently clamps that to
// net.core.rmem_max - which on an ordinary server is 212992 bytes. It does not
// fail, it does not warn, and nothing above ever learns that the buffer it
// asked for is not the buffer it has.
//
// On a raw socket carrying a private link that is the whole ballgame. The old
// core's own counters said it was dropping nothing, and they were right: the
// kernel was dropping them, before the process ever saw them. Read straight
// off the socket on a real server while the tunnel ran:
//
//	skmem:(r0,rb425984,t0,tb425984,f0,w0,o464,bl0,d925)
//	                                                ^^^^ dropped
//
// Nine hundred and twenty-five packets thrown away for want of room, every one
// of them read by the TCP inside the tunnel as congestion. That is what held a
// single stream to a quarter of what the pair could carry.
//
// That was true when one goroutine took one packet off the socket at a time.
// It is not true now: the socket is read by recvmmsg, a hundred and twenty
// eight datagrams to the call, by one goroutine per core - so the queue is
// drained faster than it fills, and its depth stopped being the difference
// between carrying a stream and not. What its depth still decides is how long
// a packet waits when the link is busy, and three megabytes at four hundred
// and fifty megabits is fifty milliseconds of waiting. The profile now sets
// it, and sets it shallow unless the profile is the one about aggregate
// throughput; see Config.profile for the measurement.
//
// So the drop counter below no longer reads the way it did. A socket that
// drops nothing is a socket deep enough to hide the congestion rather than
// report it, and the loss it hides costs more than the loss it prevents.
//
// SO_RCVBUFFORCE and SO_SNDBUFFORCE are the same request without the clamp,
// and a process with CAP_NET_ADMIN may make it - which this one has, because a
// raw socket needs the same privilege. Where it is refused the ordinary call
// still applies, so an unprivileged build keeps the old behaviour rather than
// no buffer at all.
const (
	soSndBufForce = 32
	soRcvBufForce = 33
	soPriority    = 12
)

// tuneSocket gives the carrier's socket the buffers it was configured with,
// then reads back what it got and says so if the kernel cut it anyway.
//
// Never call this on a TCP socket. Setting SO_RCVBUF at all switches off
// tcp_rmem autotuning for that socket and pins the window wherever it was put,
// which is worse than any number you might choose.
func tuneSocket(pc net.PacketConn, cfg *config.Config) {
	sc, ok := pc.(syscall.Conn)
	if !ok {
		return
	}
	raw, err := sc.SyscallConn()
	if err != nil {
		return
	}
	rcv, snd := cfg.Tuning.RcvBufKB*1024, cfg.Tuning.SndBufKB*1024
	var gotRcv, gotSnd int

	_ = raw.Control(func(fd uintptr) {
		f := int(fd)
		if rcv > 0 {
			if syscall.SetsockoptInt(f, syscall.SOL_SOCKET, soRcvBufForce, rcv) != nil {
				_ = syscall.SetsockoptInt(f, syscall.SOL_SOCKET, syscall.SO_RCVBUF, rcv)
			}
		}
		if snd > 0 {
			if syscall.SetsockoptInt(f, syscall.SOL_SOCKET, soSndBufForce, snd) != nil {
				_ = syscall.SetsockoptInt(f, syscall.SOL_SOCKET, syscall.SO_SNDBUF, snd)
			}
		}
		// Interactive class. This queue holds one user's latency, and it should
		// leave the machine ahead of a backup or an apt update.
		_ = syscall.SetsockoptInt(f, syscall.SOL_SOCKET, soPriority, 6)

		// The kernel reports double what it gave, by long-standing convention.
		if v, e := syscall.GetsockoptInt(f, syscall.SOL_SOCKET, syscall.SO_RCVBUF); e == nil {
			gotRcv = v / 2
		}
		if v, e := syscall.GetsockoptInt(f, syscall.SOL_SOCKET, syscall.SO_SNDBUF); e == nil {
			gotSnd = v / 2
		}
	})

	logging.Info("socket buffers: %d KB in, %d KB out", gotRcv/1024, gotSnd/1024)
	if rcv > 0 && gotRcv < rcv*9/10 {
		logging.Warn("asked the kernel for %d KB of receive buffer and got %d KB -"+
			" raise net.core.rmem_max, or packets will be dropped before we see them",
			rcv/1024, gotRcv/1024)
	}
}

// setUserTimeout is TCP_USER_TIMEOUT: how long transmitted data may go
// unacknowledged before the kernel gives the connection up with an error,
// instead of retransmitting into a route that has stopped answering for as
// long as it otherwise would - which is about fifteen minutes.
func setUserTimeout(tc *net.TCPConn, d time.Duration) {
	raw, err := tc.SyscallConn()
	if err != nil {
		return
	}
	const tcpUserTimeout = 18 // TCP_USER_TIMEOUT, in milliseconds
	_ = raw.Control(func(fd uintptr) {
		_ = syscall.SetsockoptInt(int(fd), syscall.IPPROTO_TCP, tcpUserTimeout,
			int(d/time.Millisecond))
	})
}
