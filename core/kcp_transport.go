package main

import (
	"fmt"
	"net"

	kcp "github.com/xtaci/kcp-go/v5"
)

// KCP sits directly on UDP and repairs loss before the multiplexed Pingify
// streams see it. Reed-Solomon FEC repairs short loss bursts without waiting
// for a retransmission; KCP remains responsible for anything FEC cannot fix.
// The outer Pingify record layer still authenticates every byte, while this
// packet-layer cipher also hides KCP's otherwise recognisable headers.
type kcpTransport struct {
	cfg   *Config
	block kcp.BlockCrypt
	ln    *kcp.Listener
}

func newKCPTransport(cfg *Config) (*kcpTransport, error) {
	packetKey := hkdfExpand(hkdfExtract([]byte("pingify/v4 kcp"), cfg.key()),
		[]byte("packet header key"), 32)
	block, err := kcp.NewAESBlockCrypt(packetKey)
	if err != nil {
		return nil, fmt.Errorf("kcp packet cipher: %v", err)
	}
	t := &kcpTransport{cfg: cfg, block: block}
	if cfg.Connect == "" {
		ln, err := kcp.ListenWithOptions(cfg.Listen, block, cfg.FECData, cfg.FECParity)
		if err != nil {
			return nil, fmt.Errorf("kcp listen on %s: %v", cfg.Listen, err)
		}
		t.ln = ln
		// These apply to the shared UDP socket. A large userspace KCP window is
		// useless if the kernel drops the burst before KCP can read it.
		// Guarded, the way tunePacketSocket guards it: unset means "leave the
		// kernel default alone", not "ask for a buffer of nothing".
		if cfg.RcvBufKB > 0 {
			_ = ln.SetReadBuffer(cfg.RcvBufKB * 1024)
		}
		if cfg.SndBufKB > 0 {
			_ = ln.SetWriteBuffer(cfg.SndBufKB * 1024)
		}
	}
	return t, nil
}

func tuneKCPSession(s *kcp.UDPSession, cfg *Config) {
	// Fast mode from the original KCP design: 10 ms clock, fast resend after
	// two duplicate ACKs, and no conservative TCP-style congestion window.
	// Pingify's bounded per-stream credit window is still the memory/backlog
	// limit, while FEC absorbs the common one-or-two packet loss burst.
	s.SetNoDelay(1, cfg.KCPInterval, 2, 1)
	s.SetStreamMode(true)
	s.SetACKNoDelay(true)
	s.SetWriteDelay(false)
	_ = s.SetMtu(cfg.PacketMTU)

	mss := cfg.PacketMTU - 64 // KCP + FEC + packet crypto overhead, conservatively.
	if mss < 256 {
		mss = 256
	}
	wnd := cfg.WindowKB * 1024 / mss
	if wnd < 128 {
		wnd = 128
	}
	if wnd > 4096 {
		wnd = 4096
	}
	s.SetWindowSize(wnd, wnd)
	// Guarded, the way tunePacketSocket guards it: unset means "leave the
	// kernel default alone", not "ask for a buffer of nothing".
	if cfg.RcvBufKB > 0 {
		_ = s.SetReadBuffer(cfg.RcvBufKB * 1024)
	}
	if cfg.SndBufKB > 0 {
		_ = s.SetWriteBuffer(cfg.SndBufKB * 1024)
	}
}

func (t *kcpTransport) Dial(idx int) (net.Conn, error) {
	s, err := kcp.DialWithOptions(t.cfg.Connect, t.block, t.cfg.FECData, t.cfg.FECParity)
	if err != nil {
		return nil, err
	}
	tuneKCPSession(s, t.cfg)
	return s, nil
}

func (t *kcpTransport) Accept() (net.Conn, error) {
	if t.ln == nil {
		return nil, fmt.Errorf("kcp: this end dials, it does not accept")
	}
	s, err := t.ln.AcceptKCP()
	if err != nil {
		return nil, err
	}
	tuneKCPSession(s, t.cfg)
	return s, nil
}

func (t *kcpTransport) Close() error {
	if t.ln != nil {
		return t.ln.Close()
	}
	return nil
}

func (t *kcpTransport) Name() string { return "kcp+fec" }
