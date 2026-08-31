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
// Both ends send echo *requests* (type 8), and both accept either type.
//
// This used to send replies in both directions, on the reasoning that the
// kernel answers a request by itself and would double every packet we send.
// The reasoning is sound and the arrangement still could not carry a tunnel,
// because it never asked what the path would carry. Measured between a real
// Iranian server and two abroad, 50 packets at each of six sizes up to 1400:
//
//	                    echo reply (0)    echo request (8)
//	Iran -> Germany     nothing           300 of 300
//	Germany -> Iran     nothing           50,50,44,41,39,42
//	Iran -> Turkey      300 of 300        300 of 300
//
// An unsolicited echo reply is not part of any conversation and that route
// drops it in both directions. A request is the start of one, and passes. So
// the type that always works is the request, and that is what both ends send.
//
// Being strict about what we send and liberal about what we accept costs
// nothing here and means a peer configured either way still connects.
//
// The doubling problem is real and is handled where it belongs, in the kernel:
// net.ipv4.icmp_echo_ignore_all stops it answering pings nobody asked it
// about. The manager sets it on both servers, and without it every packet this
// transport receives is answered a second time by the machine underneath it.
//
// One thing this cannot fix: whether the route carries ICMP at all. Turkey to
// Iran allowed six packets and then nothing, on the same day the Germany route
// carried everything. That is the path, not the packet.
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

	// How many packets one crossing into the kernel may carry, where the
	// kernel offers that. See icmpsend_linux.go.
	icmpSendBatch = 64
)

var errICMPClosed = errors.New("icmp: transport closed")

// A bare packet needs somewhere to go, and the accepting end has nowhere to
// send one until it has heard from the other server at least once.
var errICMPNoPeer = errors.New("icmp: no peer to send a packet to yet")

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

	// Packets from the private link on their way out. A device reader hands
	// one over and goes straight back to the device; one sender takes
	// whatever has arrived and puts it on the wire in a single crossing.
	// See icmpsend_linux.go for why that is worth a queue.
	outQ chan outPkt

	// Packets the sender could not take because it was behind.
	sendDropped uint64

	// What this end puts on the wire. What it accepts is either type - see
	// the note at the top of this file.
	sendType byte

	// Whether this end dials. The end that dials never accepts, so an
	// unknown session arriving there cannot be a carrier - see dispatch.
	dials bool

	// Where a bare packet goes when one arrives, and who to send one to.
	//
	// The peer is learned rather than configured: the accepting end has no
	// address until somebody talks to it, and by the time a private link is
	// carrying anything the braid's handshake has already been through here.
	// Only a datagram that carried a valid tag can set it.
	pktMu  sync.Mutex
	pktTo  *net.IPAddr
	onPkt  func([]byte)
	pktSeq uint32

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
		sendType: icmpEchoRequest,
		outQ:     make(chan outPkt, 512),
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
	go t.sendPacketLoop()
	go t.watchSendDrops()
	workers, batch := startPacketReaders(pc, t.done, cfg.Profile, cfg.carriesPackets(), icmpMaxPacket,
		t.handlePacket,
		func(err error) { logDebug("icmp read: %v", err) })
	logInfo("ICMP packet I/O: %d receive workers, batches up to %d packets, %d-byte payload",
		workers, batch, icmpMaxPayload)
	return t, nil
}

// Two kinds of thing travel on this socket: a datagram belonging to an ARQ
// session, and a bare packet from the private link, which has no session under
// it at all. They are told apart by which key the tag was made with, so
// neither needs a byte on the wire to say which it is, and neither can be
// mistaken for the other by anything that does not hold the token.
const (
	icmpTagARQ    = "pingify/v3 icmp tag"
	icmpTagDirect = "pingify/v3 icmp packet"
)

func (t *icmpTransport) putTagFor(label string, dst, hdr []byte) {
	m := t.tagHash.Get().(hash.Hash)
	m.Reset()
	m.Write([]byte(label))
	m.Write(hdr)
	var sum [sha256.Size]byte
	out := m.Sum(sum[:0])
	copy(dst, out[:icmpTagLen])
	t.tagHash.Put(m)
}

func (t *icmpTransport) putTag(dst, hdr []byte) { t.putTagFor(icmpTagARQ, dst, hdr) }

func (t *icmpTransport) validTagFor(label string, want, hdr []byte) bool {
	var got [icmpTagLen]byte
	t.putTagFor(label, got[:], hdr)
	return hmac.Equal(want, got[:])
}

func (t *icmpTransport) validTag(want, hdr []byte) bool {
	return t.validTagFor(icmpTagARQ, want, hdr)
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
		pkt[0] = t.sendType
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
	head := datagram[:min(len(datagram), arqOver)]
	direct := false

	// Which tag to try first is worth getting right, because the one that
	// fails costs exactly as much as the one that succeeds - each is an
	// HMAC over the header - and on a tunnel carrying a private link almost
	// every packet is a private-link packet.
	//
	// The session tag used to be tried first, so every one of those paid for
	// two hashes: one that could never match and one that did. On the server
	// abroad the reader could not drain the socket fast enough because of it,
	// and the kernel's receive buffer stood at seven to eight megabytes -
	// a hundred and fifty milliseconds of packets waiting their turn, which
	// is what a user feels as lag while something downloads.
	//
	// So when there is a private link, its tag is tried first. A carrier's
	// datagram then pays for two hashes instead, and there are a handful of
	// those a second against tens of thousands of the other.
	h := t.packetHandler()
	if h != nil && t.validTagFor(icmpTagDirect, body[:icmpTagLen], head) {
		direct = true
	} else if !t.validTag(body[:icmpTagLen], head) {
		if h == nil || !t.validTagFor(icmpTagDirect, body[:icmpTagLen], head) {
			return
		}
		direct = true
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
	if direct {
		t.rememberPeer(ip)
		if h := t.packetHandler(); h != nil {
			h(datagram)
		}
		return
	}
	// A session datagram tells us who to answer as well.
	t.rememberPeer(ip)
	t.dispatch(ip, datagram)
}

func (t *icmpTransport) packetHandler() func([]byte) {
	t.pktMu.Lock()
	defer t.pktMu.Unlock()
	return t.onPkt
}

func (t *icmpTransport) rememberPeer(ip *net.IPAddr) {
	t.pktMu.Lock()
	if t.pktTo == nil || t.pktTo.IP.String() != ip.IP.String() {
		t.pktTo = ip
	}
	t.pktMu.Unlock()
}

// SetPacketHandler installs where a bare packet goes, and names the peer to
// send to when this end is the one that dials.
func (t *icmpTransport) SetPacketHandler(h func([]byte), peer *net.IPAddr) {
	t.pktMu.Lock()
	t.onPkt = h
	if peer != nil {
		t.pktTo = peer
	}
	t.pktMu.Unlock()
}

// SendPacket puts one whole packet on the wire, with no session under it.
// Headroom is the ICMP header and the tag that follows it.
func (t *icmpTransport) Headroom() int { return icmpHdrLen + icmpTagLen }

// SendPacket puts one packet from the private link on the wire. The first
// Headroom() bytes are ours to fill; the rest is already built, and is not
// copied anywhere. The buffer comes with the packet and goes back to the pool
// when the wire is done with it.
func (t *icmpTransport) SendPacket(bp *[]byte) error {
	t.pktMu.Lock()
	peer := t.pktTo
	t.pktMu.Unlock()
	if peer == nil {
		tunBufs.Put(bp)
		return errICMPNoPeer
	}
	pkt := *bp
	if len(pkt) < icmpHdrLen+icmpTagLen {
		tunBufs.Put(bp)
		return nil
	}
	for i := range pkt[:icmpHdrLen] {
		pkt[i] = 0
	}
	pkt[0] = t.sendType
	binary.BigEndian.PutUint16(pkt[4:6], t.id)
	binary.BigEndian.PutUint16(pkt[6:8], uint16(atomic.AddUint32(&t.pktSeq, 1)))
	body := pkt[icmpHdrLen+icmpTagLen:]
	t.putTagFor(icmpTagDirect, pkt[icmpHdrLen:icmpHdrLen+icmpTagLen],
		body[:min(len(body), arqOver)])
	binary.BigEndian.PutUint16(pkt[2:4], icmpChecksum(pkt))

	select {
	case t.outQ <- outPkt{bp: bp, at: time.Now().UnixNano()}:
		return nil
	default:
		// The sender is behind, which on a link carrying IP means the wire is
		// behind. Dropping here is what a router does, and it is the signal
		// the sender inside needs; queueing it deeper would only add delay to
		// a packet that is already late. Counted, because a drop here looks
		// exactly like a drop on the path to everything above.
		*bp = pkt[:0]
		tunBufs.Put(bp)
		atomic.AddUint64(&t.sendDropped, 1)
		return nil
	}
}

// watchSendDrops says so when the sender cannot keep up, because a packet
// dropped here is indistinguishable from one lost on the path to everything
// above, and only this end knows which it was.
func (t *icmpTransport) watchSendDrops() {
	tk := time.NewTicker(15 * time.Second)
	defer tk.Stop()
	var last uint64
	for {
		select {
		case <-t.done:
			return
		case <-tk.C:
			n := atomic.LoadUint64(&t.sendDropped)
			if n == last {
				continue
			}
			logWarn("the private link dropped %d packets on the way out in the "+
				"last 15s (%d in all) - the sender is behind", n-last, n)
			last = n
		}
	}
}

// sendPacketLoop puts the private link's packets on the wire, as many per
// crossing into the kernel as have arrived by the time it looks.
// outPkt is one packet waiting for the wire, and when it started waiting.
type outPkt struct {
	bp *[]byte
	at int64
}

// sendPacketLoop puts the private link's packets on the wire, as many per
// crossing into the kernel as have arrived by the time it looks.
//
// A packet that has waited longer than it is worth is dropped rather than
// sent. On a link carrying IP that is not damage: the TCP inside has already
// counted it lost and sent another, so putting this one on the wire adds
// delay for a copy nobody wants, and the drop is the congestion signal that
// tells the sender to slow down - the signal a queue hides.
//
// Without it the queue is bounded only by its length, and length is not what
// a user feels. Five hundred packets is fourteen milliseconds at four hundred
// megabits and two hundred at twenty, and the same number cannot be right for
// both. Time is the same at any rate.
func (t *icmpTransport) sendPacketLoop() {
	w := newICMPBatchWriter(t.pc)
	held := make([]*[]byte, 0, icmpSendBatch)
	bufs := make([][]byte, 0, icmpSendBatch)

	release := func() {
		for _, bp := range held {
			*bp = (*bp)[:0]
			tunBufs.Put(bp)
		}
		held = held[:0]
		bufs = bufs[:0]
	}

	// A deadline was tried here: drop a packet that has waited longer than
	// tunMaxSojourn rather than send it, on the reasoning that the TCP inside
	// has already given up on it. The reasoning holds and the number does not.
	// At six milliseconds it dropped so much that throughput fell from 440
	// Mbit/s to 158, then to 294, and the third run did not carry anything at
	// all - a sender that is mid-syscall is not a sender that is behind, and
	// six milliseconds cannot tell them apart. The queue is bounded by its
	// length, which is what a queue that empties in one crossing needs.
	take := func(o outPkt, _ int64) {
		held = append(held, o.bp)
	}

	for {
		var first outPkt
		select {
		case first = <-t.outQ:
		case <-t.done:
			return
		}
		now := time.Now().UnixNano()
		take(first, now)
		// Whatever else is already waiting comes along for the same crossing.
		// Nothing is waited for: a link with one packet on it sends one.
	drain:
		for len(held) < icmpSendBatch {
			select {
			case o := <-t.outQ:
				take(o, now)
			default:
				break drain
			}
		}
		if len(held) == 0 {
			continue
		}
		t.pktMu.Lock()
		peer := t.pktTo
		t.pktMu.Unlock()
		if peer == nil {
			release()
			continue
		}
		for _, bp := range held {
			bufs = append(bufs, *bp)
		}
		if _, err := w.write(bufs, peer); err != nil {
			logDebug("icmp send batch: %v", err)
		}
		release()
	}
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
