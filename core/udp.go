package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"net"
	"sync"
	"time"
)

// ---------------------------------------------------------------------------
// the UDP transport
//
// The same reliable layer the echo transport uses, over an ordinary UDP socket
// instead of a raw ICMP one. That is the whole difference, and it is worth
// being precise about why it is worth having:
//
//	the braid over TCP carries TCP inside TCP. When a packet is lost both
//	layers retransmit - the outer one because it must, the inner one because
//	its own timer fired - and they fight. It is called TCP meltdown and it is
//	why a tunnel can be slower than the path it rides on.
//
//	over UDP there is one reliability layer: ours. A loss is repaired once,
//	by the layer that knows what the tunnel is doing, and the sender's own
//	congestion control never sees it.
//
// This is what a KCP tunnel is: a reliable ARQ over UDP with the timers tuned
// for latency rather than for throughput. We already had the ARQ - written,
// tested and carrying an ICMP tunnel - so what was missing was the socket.
//
// The session tag is kept even though UDP has ports to demultiplex with. A
// public port collects scans and strays the same way a raw socket does, and
// four bytes of HMAC is cheaper than building a connection for one.
// ---------------------------------------------------------------------------

const (
	udpTagLen = 4
	// One datagram, sized to fit inside a path that carries less than a full
	// packet - which most routes out of Iran do, being inside something else.
	udpMaxPayload = 1200

	// what this transport's header mask key is derived from
	udpARQLabel = "pingify/v3 udp"
)

type udpTransport struct {
	pc     net.PacketConn
	psk    []byte
	window int

	mu       sync.Mutex
	sessions map[sessionKey]*arqConn
	inbound  chan net.Conn
	closed   bool
	done     chan struct{}
}

func newUDPTransport(psk []byte, bind string, windowKB int) (*udpTransport, error) {
	// The accepting end binds the agreed port. The dialling end takes any
	// port the kernel offers: nothing ever connects to it, and taking a fixed
	// one would collide with a second tunnel on the same machine.
	if bind == "" {
		bind = ":0"
	}
	pc, err := net.ListenPacket("udp", bind)
	if err != nil {
		return nil, fmt.Errorf("udp socket on %s: %v", bind, err)
	}
	t := &udpTransport{
		pc:       pc,
		psk:      psk,
		window:   arqWindowFor(windowKB, udpMaxPayload),
		sessions: make(map[sessionKey]*arqConn),
		// Deep enough that a listening end with a busy acceptor does not drop
		// a carrier it wanted. The reader never waits on it either way - see
		// dispatch, and the fault that taught us to write it that way.
		inbound: make(chan net.Conn, 64),
		done:    make(chan struct{}),
	}
	go t.readLoop()
	go t.reap()
	return t, nil
}

// tag is the same cheap pre-filter the echo transport uses: enough to tell our
// traffic from the noise a public port collects, before anything is spent on it.
func (t *udpTransport) tag(hdr []byte) []byte {
	m := hmac.New(sha256.New, t.psk)
	m.Write([]byte("pingify/v3 udp tag"))
	m.Write(hdr)
	return m.Sum(nil)[:udpTagLen]
}

func (t *udpTransport) sender(peer net.Addr) func([]byte) error {
	return func(datagram []byte) error {
		body := make([]byte, udpTagLen+len(datagram))
		copy(body[:udpTagLen], t.tag(datagram[:min(len(datagram), arqOver)]))
		copy(body[udpTagLen:], datagram)
		_, err := t.pc.WriteTo(body, peer)
		return err
	}
}

func (t *udpTransport) readLoop() {
	buf := make([]byte, 65535)
	for {
		n, addr, err := t.pc.ReadFrom(buf)
		if err != nil {
			select {
			case <-t.done:
				return
			default:
			}
			// A datagram socket reports the odd transient error - an ICMP
			// port-unreachable coming back, most often - and reading on.
			continue
		}
		if n < udpTagLen+arqOver {
			continue
		}
		pkt := buf[:n]
		datagram := pkt[udpTagLen:]
		if !hmac.Equal(pkt[:udpTagLen], t.tag(datagram[:min(len(datagram), arqOver)])) {
			continue // not ours, and it cost one HMAC to find out
		}
		t.dispatch(addr, append([]byte(nil), datagram...))
	}
}

// dispatch hands the datagram to its session, creating one if this is a
// session the listening side has not seen before.
func (t *udpTransport) dispatch(peer net.Addr, datagram []byte) {
	hdr := make([]byte, arqHdr)
	copy(hdr, datagram[arqNonce:arqOver])
	maskHeader(blockFrom(arqMaskKey(udpARQLabel, t.psk)), datagram[:arqNonce], hdr)
	var h arqHeader
	h.get(hdr)

	key := sessionKey{peer: peer.String(), session: h.session, carrier: h.carrier}

	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return
	}
	conn, known := t.sessions[key]
	if !known {
		// Room first, before anything is built. This read loop is shared by
		// every carrier on the transport, and waiting here for an acceptor
		// that does not exist is what wedged the echo transport: the dialling
		// end never accepts, so strays filled the queue and the reader
		// stopped, taking every carrier with it sixty seconds later.
		if len(t.inbound) == cap(t.inbound) {
			t.mu.Unlock()
			logDebug("udp: no room to accept session %08x carrier %d from %s, ignored",
				h.session, h.carrier, peer)
			return
		}
		conn = newARQ(h.session, h.carrier, t.psk, udpARQLabel, udpMaxPayload, t.window, t.sender(peer))
		conn.remote = peer
		t.sessions[key] = conn
		t.mu.Unlock()
		select {
		case t.inbound <- conn:
		case <-t.done:
			return
		}
	} else {
		t.mu.Unlock()
	}
	conn.onDatagram(datagram)
}

// Dial opens one carrier towards the peer.
func (t *udpTransport) Dial(peer string, carrier int) (net.Conn, error) {
	addr, err := net.ResolveUDPAddr("udp", peer)
	if err != nil {
		return nil, err
	}
	var b [4]byte
	if _, err := rand.Read(b[:]); err != nil {
		return nil, err
	}
	session := binary.BigEndian.Uint32(b[:])

	conn := newARQ(session, uint8(carrier), t.psk, udpARQLabel, udpMaxPayload, t.window, t.sender(addr))
	conn.remote = addr

	key := sessionKey{peer: addr.String(), session: session, carrier: uint8(carrier)}
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		conn.Close()
		return nil, errICMPClosed
	}
	t.sessions[key] = conn
	t.mu.Unlock()
	return conn, nil
}

func (t *udpTransport) Accept() (net.Conn, error) {
	select {
	case c := <-t.inbound:
		return c, nil
	case <-t.done:
		return nil, errICMPClosed
	}
}

func (t *udpTransport) Close() error {
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return nil
	}
	t.closed = true
	close(t.done)
	conns := make([]*arqConn, 0, len(t.sessions))
	for _, c := range t.sessions {
		conns = append(conns, c)
	}
	t.sessions = make(map[sessionKey]*arqConn)
	t.mu.Unlock()
	for _, c := range conns {
		c.Close()
	}
	return t.pc.Close()
}

// reap drops sessions whose connection has failed, so a long-lived listener
// does not accumulate them.
func (t *udpTransport) reap() {
	tk := time.NewTicker(30 * time.Second)
	defer tk.Stop()
	for {
		select {
		case <-t.done:
			return
		case <-tk.C:
			t.mu.Lock()
			for k, c := range t.sessions {
				c.mu.Lock()
				dead := c.err != nil || c.closed
				c.mu.Unlock()
				if dead {
					delete(t.sessions, k)
				}
			}
			t.mu.Unlock()
		}
	}
}

// ---------------------------------------------------------------------------
// the seam
// ---------------------------------------------------------------------------

type udpCarrier struct {
	t   *udpTransport
	cfg *Config
}

func newUDPCarrier(cfg *Config) (*udpCarrier, error) {
	t, err := newUDPTransport(cfg.key(), cfg.Listen, cfg.WindowKB)
	if err != nil {
		return nil, err
	}
	return &udpCarrier{t: t, cfg: cfg}, nil
}

func (c *udpCarrier) Dial(idx int) (net.Conn, error) { return c.t.Dial(c.cfg.Connect, idx) }
func (c *udpCarrier) Accept() (net.Conn, error)      { return c.t.Accept() }
func (c *udpCarrier) Close() error                   { return c.t.Close() }
func (c *udpCarrier) Name() string                   { return "udp" }
