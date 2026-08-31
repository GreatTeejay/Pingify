package main

import (
	"fmt"
	"net"
	"strconv"
	"strings"
)

// ==========================================================================
// 8. socket tuning and forward specs
// ==========================================================================

// tuneSocket applies the settings that actually move the needle on a
// long-haul, lossy Iran<->Kharej path: no Nagle delay on the carrier, and
// socket buffers big enough to hold a full bandwidth-delay product.
// baseTCP walks down to the socket under whatever is wrapping it.
//
// A carrier is not always a bare socket. A ws carrier is framing over a
// socket; a wss carrier is framing over TLS over a socket. A plain type
// assert saw neither, so every ws and wss carrier ran with Nagle on - up to
// forty milliseconds of hesitation before a small write leaves - with no
// keepalive and with the tuning's socket buffers silently ignored, while the
// tcp transport got all three.
func baseTCP(c net.Conn) *net.TCPConn {
	for i := 0; i < 4 && c != nil; i++ {
		if tc, ok := c.(*net.TCPConn); ok {
			return tc
		}
		switch v := c.(type) {
		case interface{ netConn() net.Conn }: // our own framing
			c = v.netConn()
		case interface{ NetConn() net.Conn }: // *tls.Conn
			c = v.NetConn()
		default:
			return nil
		}
	}
	return nil
}

func tuneSocket(c net.Conn, cfg *Config) {
	tc := baseTCP(c)
	if tc == nil {
		return
	}
	tc.SetNoDelay(true)
	tc.SetKeepAlive(true)
	tc.SetKeepAlivePeriod(30e9)
	// The one that matters on this route: bound how long the kernel will
	// retransmit into a blackhole before admitting the socket is gone.
	setUserTimeout(c)
	// The socket buffers are deliberately not set here.
	//
	// SetReadBuffer and SetWriteBuffer ask for SO_RCVBUF and SO_SNDBUF, and on
	// a TCP socket that does two things, both of them bad. The kernel clamps
	// the value to net.core.rmem_max - 212992 bytes on an ordinary server -
	// and asking at all switches off the receive-buffer autotuning that would
	// otherwise have grown the socket to net.ipv4.tcp_rmem's ceiling, six
	// megabytes on the same machine.
	//
	// So a carrier that was given "sixteen megabytes" in the config ran with
	// two hundred and eight kilobytes and no ability to grow. Over a 68 ms
	// path that is twenty-four megabits a carrier, and eight of them measured
	// 113 Mbit/s where the pair could carry far more.
	//
	// Autotuning is better than any number that could be written here: it
	// grows to what the path turns out to need and gives the memory back when
	// it does not. The packet transports still set theirs explicitly, because
	// a raw socket has no autotuning to leave alone - see sockbuf_linux.go.
}

// ---------------------------------------------------------------------------
// forward specs
//
//	443                      tcp :443        -> 127.0.0.1:443
//	443=8443                 tcp :443        -> 127.0.0.1:8443
//	443=10.0.0.5:8443        tcp :443        -> 10.0.0.5:8443
//	8000-8010                tcp :8000..8010 -> 127.0.0.1:same
//	8000-8010=9000           tcp :8000..8010 -> 127.0.0.1:9000..9010
//	udp:500=500              udp :500        -> 127.0.0.1:500
// ---------------------------------------------------------------------------

type fwdRule struct {
	proto  string // "tcp" or "udp"
	lport  int
	target string // "host:port"
}

func parseForward(spec string) ([]fwdRule, error) {
	s := strings.TrimSpace(spec)
	if s == "" {
		return nil, fmt.Errorf("empty forward")
	}
	proto := "tcp"
	if i := strings.Index(s, ":"); i >= 0 {
		switch strings.ToLower(s[:i]) {
		case "tcp":
			proto, s = "tcp", s[i+1:]
		case "udp":
			proto, s = "udp", s[i+1:]
		}
	}

	local, remote := s, ""
	if i := strings.Index(s, "="); i >= 0 {
		local, remote = s[:i], s[i+1:]
	}

	lo, hi, err := parsePortRange(local)
	if err != nil {
		return nil, fmt.Errorf("%q: %v", spec, err)
	}

	host := "127.0.0.1"
	rbase := 0
	if remote != "" {
		rp := remote
		if i := strings.LastIndex(remote, ":"); i >= 0 {
			host, rp = remote[:i], remote[i+1:]
			if host == "" {
				host = "127.0.0.1"
			}
		}
		if rp != "" {
			rbase, err = strconv.Atoi(rp)
			if err != nil || rbase < 1 || rbase > 65535 {
				return nil, fmt.Errorf("%q: bad target port %q", spec, rp)
			}
		}
	}

	out := make([]fwdRule, 0, hi-lo+1)
	for pt := lo; pt <= hi; pt++ {
		rp := pt
		if rbase > 0 {
			rp = rbase + (pt - lo)
			if rp > 65535 {
				return nil, fmt.Errorf("%q: target port range overflows", spec)
			}
		}
		out = append(out, fwdRule{
			proto:  proto,
			lport:  pt,
			target: net.JoinHostPort(host, strconv.Itoa(rp)),
		})
	}
	return out, nil
}

func parsePortRange(s string) (int, int, error) {
	if i := strings.Index(s, "-"); i >= 0 {
		lo, e1 := strconv.Atoi(strings.TrimSpace(s[:i]))
		hi, e2 := strconv.Atoi(strings.TrimSpace(s[i+1:]))
		if e1 != nil || e2 != nil || lo < 1 || hi > 65535 || lo > hi {
			return 0, 0, fmt.Errorf("bad port range %q", s)
		}
		if hi-lo > 512 {
			return 0, 0, fmt.Errorf("port range %q is wider than 512 ports", s)
		}
		return lo, hi, nil
	}
	p, err := strconv.Atoi(strings.TrimSpace(s))
	if err != nil || p < 1 || p > 65535 {
		return 0, 0, fmt.Errorf("bad port %q", s)
	}
	return p, p, nil
}

// hash5 is a FNV-1a over the fields that identify one inner flow. It is what
// keeps a flow glued to a single carrier.
func hash5(b []byte) uint32 {
	h := uint32(2166136261)
	for _, c := range b {
		h ^= uint32(c)
		h *= 16777619
	}
	return h
}
