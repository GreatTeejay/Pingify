package main

import (
	"fmt"
	"net"
	"time"
)

// ---------------------------------------------------------------------------
// what a transport has to be
//
// Everything above this line is the same whatever carries it: the handshake,
// the AES-GCM framing, the credit windows, the stream multiplexing, the
// keepalive, the status endpoint. All of it takes a net.Conn and does not care
// where the bytes go. That is not an accident - it is the only reason a second
// transport was ever cheap to add.
//
// What it did care about was one if/else in dialCarrier and another in start,
// which is fine for two and a mess for five. A transport now answers three
// questions and nothing else:
//
//	dial a carrier          the end that opens the connection
//	accept carriers         the end that waits for one
//	shut down               release whatever it holds
//
// Adding one means writing those three and nothing above them changes.
// ---------------------------------------------------------------------------

type carrierTransport interface {
	// Dial opens carrier idx towards the configured peer. The index matters:
	// the far end reads it out of the handshake and installs the carrier in
	// the same slot, so a carrier that dies is replaced rather than duplicated.
	Dial(idx int) (net.Conn, error)

	// Accept blocks until a carrier arrives. Returning an error ends the
	// accept loop, so a closed transport must return one.
	Accept() (net.Conn, error)

	// Close releases the listener or the raw socket. Carriers already open are
	// closed by the pool, not here.
	Close() error

	// Name is what the log calls this, in the one line that says the tunnel is
	// starting.
	Name() string
}

// ---------------------------------------------------------------------------
// TCP
//
// The plain case: one socket per carrier, and the kernel does the rest.
// ---------------------------------------------------------------------------

type tcpTransport struct {
	cfg *Config
	ln  net.Listener
}

func newTCPTransport(cfg *Config) (*tcpTransport, error) {
	t := &tcpTransport{cfg: cfg}
	// Only the accepting end binds. The dialling end has nothing to listen on
	// and must not take a port it will never use.
	if cfg.Connect == "" {
		ln, err := net.Listen("tcp", cfg.Listen)
		if err != nil {
			return nil, err
		}
		t.ln = ln
	}
	return t, nil
}

func (t *tcpTransport) Dial(idx int) (net.Conn, error) {
	return net.DialTimeout("tcp", t.cfg.Connect,
		time.Duration(t.cfg.DialTimeout)*time.Second)
}

func (t *tcpTransport) Accept() (net.Conn, error) {
	if t.ln == nil {
		return nil, fmt.Errorf("tcp: this end dials, it does not accept")
	}
	return t.ln.Accept()
}

func (t *tcpTransport) Close() error {
	if t.ln != nil {
		return t.ln.Close()
	}
	return nil
}

func (t *tcpTransport) Name() string { return "tcp" }

// ---------------------------------------------------------------------------
// ICMP
//
// One raw socket for every carrier, so the transport is what holds it and the
// carriers are sessions demultiplexed out of it. The wrapper is thin: it only
// gives the existing transport the shape the interface asks for, and strips
// the port off the peer address, which ICMP does not have.
// ---------------------------------------------------------------------------

type icmpCarrier struct {
	t   *icmpTransport
	cfg *Config
}

func newICMPCarrier(cfg *Config) (*icmpCarrier, error) {
	// The listening side stores the address to answer from; the dialling side
	// has none and takes the default.
	t, err := newICMPTransport(cfg)
	if err != nil {
		return nil, err
	}
	go t.reap()
	return &icmpCarrier{t: t, cfg: cfg}, nil
}

func (c *icmpCarrier) Dial(idx int) (net.Conn, error) {
	host := c.cfg.Connect
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	return c.t.Dial(host, idx)
}

func (c *icmpCarrier) Accept() (net.Conn, error) { return c.t.Accept() }

// The private link's packets go straight to the transport underneath. Without
// these two the wrapper hid them: the pool holds this, not the transport, so
// the check for "can this carry a bare packet" looked at the wrapper, found
// nothing, and the direct path silently never turned on. Every test had
// exercised the transport directly and so every test passed.
func (c *icmpCarrier) SendPacket(b []byte) error { return c.t.SendPacket(b) }
func (c *icmpCarrier) SetPacketHandler(h func([]byte), peer *net.IPAddr) {
	c.t.SetPacketHandler(h, peer)
}
func (c *icmpCarrier) Close() error { return c.t.Close() }
func (c *icmpCarrier) Name() string { return "echo" }

// ---------------------------------------------------------------------------
// choosing one
// ---------------------------------------------------------------------------

// newTransport builds the transport this config asks for. A name it does not
// know is a configuration error rather than a silent fall back to TCP, because
// falling back would build a tunnel that cannot possibly reach the other end
// and then look healthy doing it.
func newTransport(cfg *Config) (carrierTransport, error) {
	switch cfg.Transport {
	case "icmp", "echo":
		return newICMPCarrier(cfg)
	case "udp":
		return newUDPCarrier(cfg)
	case "kcp":
		return newKCPTransport(cfg)
	case "pck":
		return newPCKTransport(cfg)
	case "ws":
		return newWSTransport(cfg)
	case "wss":
		return newWSSTransport(cfg)
	case "mirage":
		return newMirageTransport(cfg)
	case "tcp", "":
		return newTCPTransport(cfg)
	}
	return nil, fmt.Errorf("unknown transport %q", cfg.Transport)
}
