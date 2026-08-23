package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

// ---------------------------------------------------------------------------
// the echo transport
//
// Carries the same braid stream inside ICMP echo packets, for a path where
// TCP is simply not allowed out. It is the fallback, not the fast option:
// every datagram is about 1.4 KB and has to be acknowledged, so expect a
// fraction of what braid does over TCP.
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
	icmpMaxPayload  = 1200 // conservative: fits inside a 1400-byte path MTU
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

func buildEcho(typ byte, id, seq uint16, payload []byte) []byte {
	b := make([]byte, icmpHdrLen+len(payload))
	b[0] = typ
	b[1] = 0
	binary.BigEndian.PutUint16(b[4:6], id)
	binary.BigEndian.PutUint16(b[6:8], seq)
	copy(b[icmpHdrLen:], payload)
	binary.BigEndian.PutUint16(b[2:4], icmpChecksum(b))
	return b
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
	pc  net.PacketConn
	psk []byte
	// Segments in flight per ARQ connection, from the tunnel's window_kb.
	window int

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
func newICMPTransport(psk []byte, bind string, windowKB int) (*icmpTransport, error) {
	if bind == "" || bind == "0.0.0.0" {
		bind = "0.0.0.0"
	}
	pc, err := net.ListenPacket("ip4:icmp", bind)
	if err != nil {
		return nil, fmt.Errorf("raw ICMP socket on %s: %v (needs CAP_NET_RAW; are you root?)", bind, err)
	}
	t := &icmpTransport{
		pc:       pc,
		psk:      psk,
		window:   arqWindowFor(windowKB, icmpMaxPayload),
		sessions: make(map[sessionKey]*arqConn),
		inbound:  make(chan net.Conn, 16),
		done:     make(chan struct{}),
	}
	go t.readLoop()
	return t, nil
}

func (t *icmpTransport) tag(hdr []byte) []byte {
	m := hmac.New(sha256.New, t.psk)
	m.Write([]byte("pingify/v3 icmp tag"))
	m.Write(hdr)
	return m.Sum(nil)[:icmpTagLen]
}

// sender returns the function one ARQ connection uses to put a datagram on
// the wire, addressed to its peer.
func (t *icmpTransport) sender(peer *net.IPAddr, id uint16) func([]byte) error {
	var seq uint32
	return func(datagram []byte) error {
		body := make([]byte, icmpTagLen+len(datagram))
		copy(body[:icmpTagLen], t.tag(datagram[:min(len(datagram), arqOver)]))
		copy(body[icmpTagLen:], datagram)
		s := uint16(atomic.AddUint32(&seq, 1))
		_, err := t.pc.WriteTo(buildEcho(icmpEchoReply, id, s, body), peer)
		return err
	}
}

func (t *icmpTransport) readLoop() {
	buf := make([]byte, 65535)
	for {
		n, addr, err := t.pc.ReadFrom(buf)
		if err != nil {
			select {
			case <-t.done:
				return
			default:
			}
			logDebug("icmp read: %v", err)
			continue
		}
		msg := stripIP(buf[:n])
		if len(msg) < icmpHdrLen+icmpTagLen+arqOver {
			continue
		}
		if msg[0] != icmpEchoReply && msg[0] != icmpEchoRequest {
			continue
		}
		body := msg[icmpHdrLen:]
		datagram := body[icmpTagLen:]

		// Reject the ordinary pings a public address collects before doing
		// any real work on them.
		if !hmac.Equal(body[:icmpTagLen], t.tag(datagram[:min(len(datagram), arqOver)])) {
			continue
		}

		ip, _ := addr.(*net.IPAddr)
		if ip == nil {
			continue
		}
		t.dispatch(ip, binary.BigEndian.Uint16(msg[4:6]), append([]byte(nil), datagram...))
	}
}

// dispatch hands the datagram to its connection, creating one if this is a
// session the listening side has not seen before.
func (t *icmpTransport) dispatch(peer *net.IPAddr, id uint16, datagram []byte) {
	// The header is masked with a key both ends derive from the PSK, so the
	// session and carrier can be read out before any connection exists.
	hdr := make([]byte, arqHdr)
	copy(hdr, datagram[arqNonce:arqOver])
	k := hkdfExpand(hkdfExtract([]byte("pingify/v3 icmp"), t.psk), []byte("arq header"), 32)
	maskHeader(blockFrom(k), datagram[:arqNonce], hdr)
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
		conn = newARQ(h.session, h.carrier, t.psk, icmpMaxPayload, t.window, t.sender(peer, id))
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
	id := uint16(session)

	conn := newARQ(session, uint8(carrier), t.psk, icmpMaxPayload, t.window, t.sender(ip, id))
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

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
