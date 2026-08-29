package main

import (
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"hash"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

// ---------------------------------------------------------------------------
// the echo transport
//
// Carries the same braid stream inside ICMP echo packets. Some Iran routes
// carry ICMP more cleanly than TCP or UDP, so this is a first-class transport,
// not merely an emergency fallback. Its packet path is batch-read and its ARQ
// window is shared across several lightweight sessions to fill a fast link.
//
// Data travels in Echo *Reply* packets (type 0) in both directions rather
// than requests. Two reasons: the kernel answers an echo request by itself,
// which would double every packet we send, and a reply needs no matching
// request to exist on our side. Raw sockets receive both regardless.
//
//	ICMP data = [4] tag  [24] arq datagram ...
//
// The tag is the first four bytes of HMAC(psk, header), which is what lets
// the listener tell our traffic apart from the ordinary pings a public server
// receives all day, before it spends anything on them.
// ---------------------------------------------------------------------------

const (
	icmpEchoReply   = 0
	icmpEchoRequest = 8
	icmpTagLen      = 4
	icmpHdrLen      = 8
	// 1320 bytes of ARQ payload produces a 1372-byte IPv4 packet after the
	// ICMP, tag and ARQ headers. It stays below the 1400-byte paths this
	// transport targets while carrying ten percent more useful data.
	icmpMaxPayload = 1320
	icmpMaxPacket  = 2048 // our packet is < 1400; larger traffic is not ours

	// what this transport's header mask key is derived from
	icmpARQLabel = "pingify/v3 icmp"
)

var errICMPClosed = errors.New("icmp: transport closed")

// icmpChecksum is the standard one's-complement sum from RFC 1071.
func icmpChecksum(b []byte) uint16 {
	var sum uint32
	for i := 0; i+1 < len(b); i += 2 {
		sum += uint32(b[i])<<8 | uint32(b[i+1])
	}
	if len(b)%2 == 1 {
		sum += uint32(b[len(b)-1]) << 8
	}
	for sum>>16 != 0 {
		sum = (sum & 0xffff) + (sum >> 16)
	}
	return ^uint16(sum)
}

// stripIP removes an IPv4 header if the kernel handed us one. Raw sockets do
// this inconsistently across platforms, so look rather than assume.
func stripIP(b []byte) []byte {
	if len(b) >= 20 && b[0]>>4 == 4 {
		ihl := int(b[0]&0x0f) * 4
		if ihl >= 20 && ihl <= len(b) {
			return b[ihl:]
		}
	}
	return b
}

type sessionKey struct {
	peer    string
	session uint32
	carrier uint8
}

// icmpTransport owns the one raw socket and fans packets out to the ARQ
// connection they belong to.
type icmpTransport struct {
	pc       net.PacketConn
	psk      []byte
	mask     cipher.Block // header key is constant for the transport
	maskOnce sync.Once
	tagHash  sync.Pool // keyed HMAC states reused on the packet hot path
	// Segments in flight per ARQ connection, from the tunnel's window_kb.
	window int

	// The identifier every echo of this tunnel carries. Both ends derive the
	// same one from the token, which is what lets the kernel keep our packets
	// and drop every other echo this host sees before it is ever queued.
	id uint16

	// Whether this end dials. The end that dials never accepts, so an
	// unknown session arriving there cannot be a carrier - see dispatch.
	dials bool

	mu       sync.Mutex
	sessions map[sessionKey]*arqConn
	inbound  chan net.Conn
	closed   bool
	done     chan struct{}
}

// newICMPTransport opens the one raw socket every carrier shares.
//
// bind is the local address to answer from. Empty means every address, which
// is right on a server with one. On a server with several the kernel picks
// the source itself, and a reply that leaves from an address the far end is
// not expecting is a reply the far end throws away - so the wizard asks.
func newICMPTransport(cfg *Config) (*icmpTransport, error) {
	bind := cfg.Listen
	if bind == "" || bind == "0.0.0.0" {
		bind = "0.0.0.0"
	}
	pc, err := net.ListenPacket("ip4:icmp", bind)
	if err != nil {
		return nil, fmt.Errorf("raw ICMP socket on %s: %v (needs CAP_NET_RAW; are you root?)", bind, err)
	}
	t := &icmpTransport{
		pc:       pc,
		psk:      cfg.key(),
		mask:     blockFrom(arqMaskKey(icmpARQLabel, cfg.key())),
		window:   arqWindowFor(cfg.WindowKB, icmpMaxPayload),
		id:       icmpIDFor(cfg.key()),
		dials:    cfg.Connect != "",
		sessions: make(map[sessionKey]*arqConn),
		// Deep enough that a listening end with a busy acceptor does not drop
		// a carrier it wanted; the reader never waits on it either way.
		inbound: make(chan net.Conn, 64),
		done:    make(chan struct{}),
	}
	t.tagHash.New = func() interface{} { return hmac.New(sha256.New, t.psk) }
	tunePacketSocket(pc, cfg)
	// Best effort. Everything this filters is still checked in Go afterwards,
	// so a kernel that will not take it costs speed and nothing else.
	if err := attachICMPFilter(pc, t.id); err != nil {
		logDebug("icmp: no kernel filter (%v) - every echo this host sees will be sorted in Go", err)
	}
	workers, batch := startPacketReaders(pc, t.done, cfg.Profile, icmpMaxPacket,
		t.handlePacket, func(err error) { logDebug("icmp read: %v", err) })
	logInfo("ICMP packet I/O: %d receive workers, batches up to %d packets, %d-byte payload",
		workers, batch, icmpMaxPayload)
	return t, nil
}

func (t *icmpTransport) putTag(dst, hdr []byte) {
	m := t.tagHash.Get().(hash.Hash)
	m.Reset()
	m.Write([]byte("pingify/v3 icmp tag"))
	m.Write(hdr)
	var sum [sha256.Size]byte
	out := m.Sum(sum[:0])
	copy(dst, out[:icmpTagLen])
	t.tagHash.Put(m)
}

func (t *icmpTransport) validTag(want, hdr []byte) bool {
	var got [icmpTagLen]byte
	t.putTag(got[:], hdr)
	return hmac.Equal(want, got[:])
}

func (t *icmpTransport) headerMask() cipher.Block {
	t.maskOnce.Do(func() {
		if t.mask == nil {
			t.mask = blockFrom(arqMaskKey(icmpARQLabel, t.psk))
		}
	})
	return t.mask
}

// sender returns the function one ARQ connection uses to put a datagram on
// the wire, addressed to its peer.
func (t *icmpTransport) sender(peer *net.IPAddr) func([]byte) error {
	var seq uint32
	return func(datagram []byte) error {
		// Header, tag and payload are built in one buffer. This used to create a
		// tagged body and then copy it into a second allocation in buildEcho for
		// every packet on the path.
		pkt := make([]byte, icmpHdrLen+icmpTagLen+len(datagram))
		pkt[0] = icmpEchoReply
		binary.BigEndian.PutUint16(pkt[4:6], t.id)
		s := uint16(atomic.AddUint32(&seq, 1))
		binary.BigEndian.PutUint16(pkt[6:8], s)
		body := pkt[icmpHdrLen:]
		t.putTag(body[:icmpTagLen], datagram[:min(len(datagram), arqOver)])
		copy(body[icmpTagLen:], datagram)
		binary.BigEndian.PutUint16(pkt[2:4], icmpChecksum(pkt))
		_, err := t.pc.WriteTo(pkt, peer)
		return err
	}
}

// addrIP pulls the peer out of whatever the reader handed back. ReadFrom on a
// raw socket gives a *net.IPAddr; a batched read need not, and the transport
// only ever wants the address itself.
func addrIP(a net.Addr) *net.IPAddr {
	switch v := a.(type) {
	case nil:
		return nil
	case *net.IPAddr:
		return v
	case *net.UDPAddr:
		return &net.IPAddr{IP: v.IP, Zone: v.Zone}
	case *net.TCPAddr:
		return &net.IPAddr{IP: v.IP, Zone: v.Zone}
	}
	str := a.String()
	if ip := net.ParseIP(str); ip != nil {
		return &net.IPAddr{IP: ip}
	}
	if host, _, err := net.SplitHostPort(str); err == nil {
		if ip := net.ParseIP(host); ip != nil {
			return &net.IPAddr{IP: ip}
		}
	}
	return nil
}

var icmpAddrOnce sync.Once

func (t *icmpTransport) handlePacket(pkt []byte, addr net.Addr) {
	msg := stripIP(pkt)
	if len(msg) < icmpHdrLen+icmpTagLen+arqOver {
		return
	}
	if msg[0] != icmpEchoReply && msg[0] != icmpEchoRequest {
		return
	}
	body := msg[icmpHdrLen:]
	datagram := body[icmpTagLen:]

	// handlePacket and onDatagram finish synchronously, so the batch buffer
	// can be used in place. Copying every received packet here only fed the GC.
	if !t.validTag(body[:icmpTagLen], datagram[:min(len(datagram), arqOver)]) {
		return
	}
	ip := addrIP(addr)
	if ip == nil {
		// Said once rather than never. A packet dropped because its address
		// was not the shape we expected looks, from every other vantage
		// point, exactly like a peer that has gone quiet.
		icmpAddrOnce.Do(func() {
			logWarn("icmp: cannot read a peer address out of %T - packets are being dropped", addr)
		})
		return
	}
	t.dispatch(ip, datagram)
}

// dispatch hands the datagram to its connection, creating one if this is a
// session the listening side has not seen before.
func (t *icmpTransport) dispatch(peer *net.IPAddr, datagram []byte) {
	// The header is masked with a key both ends derive from the PSK, so the
	// session and carrier can be read out before any connection exists.
	var hdr [arqHdr]byte
	copy(hdr[:], datagram[arqNonce:arqOver])
	maskHeader(t.headerMask(), datagram[:arqNonce], hdr[:])
	var h arqHeader
	h.get(hdr[:])

	key := sessionKey{peer: peer.String(), session: h.session, carrier: h.carrier}

	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return
	}
	conn, known := t.sessions[key]
	if !known {
		// A session this end has never seen before is only ever real on the
		// end that accepts. The end that dials never calls Accept at all, so
		// anything arriving there for an unknown session is a stray: a peer
		// still retransmitting to a session already torn down, or noise on a
		// raw socket that sees every echo the host does.
		//
		// Building an ARQ connection for one is not free. It is a map entry, a
		// channel slot nobody will ever take, and a goroutine with a ten
		// millisecond ticker - and none of the three is ever released, because
		// the reaper only removes what has closed or failed and a session
		// nobody accepts does neither. Days of that is what "Consumed 32min
		// CPU, 194.8M memory peak" looks like.
		if t.dials {
			t.mu.Unlock()
			logDebug("icmp: ignoring unknown session %08x carrier %d from %s - this end only dials",
				h.session, h.carrier, peer)
			return
		}
		// Is there anywhere for it to go? Checked before anything is built,
		// because a connection nobody accepts is a goroutine and a timer for
		// a session that does not exist - and closing one sends a datagram
		// back to a stray we have decided to ignore.
		//
		// The length test is under t.mu, so parallel receive workers cannot
		// overbook the channel.
		if len(t.inbound) == cap(t.inbound) {
			t.mu.Unlock()
			logDebug("icmp: no room to accept session %08x carrier %d from %s, ignored",
				h.session, h.carrier, peer)
			return
		}
		conn = newARQ(h.session, h.carrier, t.psk, icmpARQLabel, icmpMaxPayload, t.window, t.sender(peer))
		conn.remote = peer
		t.sessions[key] = conn
		t.mu.Unlock()

		// Never block here. This is the one read loop, shared by every live
		// carrier on this transport, and it was waiting for somebody to
		// accept a session nobody had asked for.
		//
		// The dialling end never calls Accept at all - it only dials - so the
		// first sixteen strays filled this channel and the reader stopped
		// dead. Every carrier then went silent, and sixty seconds later the
		// braid declared the peer gone and took all of them down together.
		// Restart, and the same thing a minute later. A raw ICMP socket
		// receives every echo reply the host sees, so strays are not an edge
		// case: a peer retransmitting to a session this end has already torn
		// down is enough.
		//
		// If there is no room, the session is not wanted. Drop it - the peer
		// retries, and a listening end with a live acceptor has room.
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
func (t *icmpTransport) Dial(peer string, carrier int) (net.Conn, error) {
	ip, err := net.ResolveIPAddr("ip4", peer)
	if err != nil {
		return nil, err
	}
	var b [4]byte
	if _, err := rand.Read(b[:]); err != nil {
		return nil, err
	}
	session := binary.BigEndian.Uint32(b[:])

	conn := newARQ(session, uint8(carrier), t.psk, icmpARQLabel, icmpMaxPayload, t.window, t.sender(ip))
	conn.remote = ip

	key := sessionKey{peer: ip.String(), session: session, carrier: uint8(carrier)}
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return nil, errICMPClosed
	}
	t.sessions[key] = conn
	t.mu.Unlock()

	// Nudge the peer so it creates its side before the handshake starts.
	conn.mu.Lock()
	conn.ackOnly()
	conn.mu.Unlock()
	return conn, nil
}

func (t *icmpTransport) Accept() (net.Conn, error) {
	select {
	case c := <-t.inbound:
		return c, nil
	case <-t.done:
		return nil, errICMPClosed
	}
}

func (t *icmpTransport) Close() error {
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
func (t *icmpTransport) reap() {
	tick := time.NewTicker(30 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-t.done:
			return
		case <-tick.C:
			t.mu.Lock()
			var closing []*arqConn
			now := time.Now().UnixNano()
			for k, c := range t.sessions {
				c.mu.Lock()
				dead := c.err != nil || c.closed
				c.mu.Unlock()
				// A session that has heard nothing for this long is finished
				// whatever it once was. The ARQ gives up on its own after
				// about forty-seven seconds and a carrier the braid still
				// wants exchanges keepalives every ten, so anything quieter
				// than this is a stray or already dead - and either way it is
				// holding a goroutine and a ticker for nothing.
				if !dead && now-atomic.LoadInt64(&c.lastRx) > int64(arqSessionIdle) {
					dead = true
					closing = append(closing, c)
				}
				if dead {
					delete(t.sessions, k)
				}
			}
			t.mu.Unlock()
			// Closed after the lock is let go. Close sends a final datagram,
			// and a socket write can block - holding the transport through one
			// would stop dispatch, which is on the read path, and take every
			// carrier with it.
			for _, c := range closing {
				c.Close()
			}
		}
	}
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
