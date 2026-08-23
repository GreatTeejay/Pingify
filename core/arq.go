package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"sync"
	"time"
)

// ---------------------------------------------------------------------------
// ARQ - a reliable ordered stream over an unreliable datagram carrier
//
// The braid layer above needs what TCP gives it: bytes arriving once, in
// order. ICMP echo gives none of that, so this sits in between and supplies
// it - sequence numbers, cumulative acknowledgements, retransmission on a
// measured timeout, fast retransmit on duplicate acks, and a send window.
//
// It deliberately knows nothing about ICMP. It takes a function that puts one
// datagram on the wire and a stream of datagrams coming back, which is what
// makes it testable against a link that loses, reorders and duplicates on
// purpose rather than only against a real network on a good day.
//
// Wire layout of one datagram:
//
//	[4]  nonce      random, in the clear, keys the mask below
//	[16] header     masked with AES(k, nonce)
//	     [4] session
//	     [1] carrier
//	     [1] flags
//	     [4] seq
//	     [4] ack
//	     [2] length
//	[n]  payload    already encrypted by the layer above
//
// Masking the header costs one AES block per datagram and leaves nothing
// constant for a filter to match on.
// ---------------------------------------------------------------------------

const (
	arqNonce = 4
	arqHdr   = 16
	arqOver  = arqNonce + arqHdr
	// The floor and the ceiling on segments in flight. The window itself is
	// per connection now, sized from the tunnel's own window_kb - it used to
	// be this constant, 64, and nothing could reach it.
	//
	// 64 segments of 1200 bytes is 76.8 KB in flight, and a stream is pinned
	// to one carrier for its life. At 75 ms that is 8 Mbit/s for a single
	// download, whatever the carrier count says - which is why an ICMP tunnel
	// measured a fraction of what the same servers did over TCP, and why one
	// video stalled while the tunnel looked idle.
	arqWinMin = 32
	arqWinMax = 4096
	// Where every version before this one sat, and so the only width an
	// un-updated peer is known to accept.
	arqWinStart = 64

	flagData = 1 << 0
	flagFin  = 1 << 1
	flagRst  = 1 << 2
)

var (
	errARQClosed = errors.New("arq: connection closed")
	errARQReset  = errors.New("arq: reset by peer")
)

type arqHeader struct {
	session uint32
	carrier uint8
	flags   uint8
	seq     uint32
	ack     uint32
	length  uint16
}

func (h *arqHeader) put(dst []byte) {
	binary.BigEndian.PutUint32(dst[0:4], h.session)
	dst[4] = h.carrier
	dst[5] = h.flags
	binary.BigEndian.PutUint32(dst[6:10], h.seq)
	binary.BigEndian.PutUint32(dst[10:14], h.ack)
	binary.BigEndian.PutUint16(dst[14:16], h.length)
}

func (h *arqHeader) get(src []byte) {
	h.session = binary.BigEndian.Uint32(src[0:4])
	h.carrier = src[4]
	h.flags = src[5]
	h.seq = binary.BigEndian.Uint32(src[6:10])
	h.ack = binary.BigEndian.Uint32(src[10:14])
	h.length = binary.BigEndian.Uint16(src[14:16])
}

// maskHeader XORs the 16 header bytes with an AES block keyed by the nonce.
func maskHeader(blk cipher.Block, nonce, hdr []byte) {
	var in, ks [16]byte
	copy(in[:], nonce)
	blk.Encrypt(ks[:], in[:])
	for i := 0; i < arqHdr; i++ {
		hdr[i] ^= ks[i]
	}
}

// segment is one unacknowledged piece of the outgoing stream.
type segment struct {
	seq     uint32
	data    []byte
	sentAt  time.Time
	retries int
}

// arqConn presents a net.Conn over datagrams.
type arqConn struct {
	session uint32
	carrier uint8
	mask    cipher.Block
	maxPay  int
	// Segments allowed in flight. A stream is pinned to one carrier, so this
	// alone decides how fast a single download can go: window * maxPay / RTT.
	//
	// It starts at arqWinStart and grows towards maxWindow while the peer
	// keeps acknowledging, and halves when a segment has to be sent twice.
	// Two reasons, and both matter:
	//
	//   A peer that has not been updated yet only accepts what the old fixed
	//   window allowed. Starting there means the tunnel comes up against any
	//   version, and widens only once this peer has shown it keeps up.
	//
	//   A window past what the path can carry does not go faster, it queues -
	//   and a queue is the stalling video and the swinging ping it was meant
	//   to cure. Backing off on loss is what holds it near the path's own
	//   capacity instead of above it.
	window    int
	maxWindow int
	send      func([]byte) error
	remote    net.Addr

	mu   sync.Mutex
	cond *sync.Cond

	// outbound
	sndNext uint32
	sndUna  uint32
	sndBuf  map[uint32]*segment
	pending []byte // bytes not yet cut into a segment

	// inbound
	rcvNext uint32
	rcvBuf  map[uint32][]byte
	inbox   []byte

	// round-trip estimate, Jacobson/Karels
	srtt, rttvar, rto time.Duration

	lastAck  uint32
	dupAcks  int
	needAck  bool
	peerFin  bool
	sentFin  bool
	closed   bool
	err      error
	done     chan struct{}
	deadline time.Time

	// How many times one segment is resent before the carrier is declared
	// dead. With the doubling backoff below, twelve works out at roughly
	// half a minute - long enough to ride out a blip, short enough that the
	// pool starts a fresh carrier while anyone is still watching.
	maxRetries int
}

// arqWindowFor turns the tunnel's window_kb into segments in flight, which is
// the unit the ARQ actually counts in. Sized the same way the TCP transport
// sizes its credit window, so the two answer to the same setting.
func arqWindowFor(windowKB, maxPayload int) int {
	if windowKB <= 0 || maxPayload <= 0 {
		return arqWinMin
	}
	n := windowKB * 1024 / maxPayload
	if n < arqWinMin {
		return arqWinMin
	}
	if n > arqWinMax {
		return arqWinMax
	}
	return n
}

func newARQ(session uint32, carrier uint8, psk []byte, maxPayload, window int, send func([]byte) error) *arqConn {
	k := hkdfExpand(hkdfExtract([]byte("pingify/v3 icmp"), psk), []byte("arq header"), 32)
	blk, err := aes.NewCipher(k)
	if err != nil {
		panic(err)
	}
	c := &arqConn{
		session:    session,
		carrier:    carrier,
		mask:       blk,
		maxPay:     maxPayload,
		window:     arqWinStart,
		maxWindow:  window,
		send:       send,
		sndBuf:     make(map[uint32]*segment),
		rcvBuf:     make(map[uint32][]byte),
		rto:        500 * time.Millisecond,
		done:       make(chan struct{}),
		maxRetries: 12,
	}
	c.cond = sync.NewCond(&c.mu)
	go c.timerLoop()
	return c
}

// ---------------------------------------------------------------------------
// net.Conn
// ---------------------------------------------------------------------------

func (c *arqConn) Read(p []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for len(c.inbox) == 0 {
		if c.err != nil {
			return 0, c.err
		}
		if c.peerFin {
			return 0, io.EOF
		}
		if c.closed {
			return 0, errARQClosed
		}
		c.cond.Wait()
	}
	n := copy(p, c.inbox)
	c.inbox = c.inbox[n:]
	return n, nil
}

func (c *arqConn) Write(p []byte) (int, error) {
	total := 0
	for len(p) > 0 {
		c.mu.Lock()
		for len(c.sndBuf) >= c.window {
			if c.closed || c.err != nil {
				e := c.err
				if e == nil {
					e = errARQClosed
				}
				c.mu.Unlock()
				return total, e
			}
			c.cond.Wait()
		}
		if c.closed || c.err != nil {
			e := c.err
			if e == nil {
				e = errARQClosed
			}
			c.mu.Unlock()
			return total, e
		}
		n := len(p)
		if n > c.maxPay {
			n = c.maxPay
		}
		seg := &segment{seq: c.sndNext, data: append([]byte(nil), p[:n]...)}
		c.sndBuf[seg.seq] = seg
		c.sndNext++
		c.emit(seg, flagData)
		c.mu.Unlock()
		p = p[n:]
		total += n
	}
	return total, nil
}

func (c *arqConn) Close() error {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return nil
	}
	c.closed = true
	if !c.sentFin {
		c.sentFin = true
		c.emit(nil, flagFin)
	}
	close(c.done)
	c.cond.Broadcast()
	c.mu.Unlock()
	return nil
}

func (c *arqConn) LocalAddr() net.Addr  { return c.remote }
func (c *arqConn) RemoteAddr() net.Addr { return c.remote }

// The braid layer sets deadlines to detect a wedged carrier. The keepalive and
// retransmit machinery already covers that, so these are accepted and ignored
// rather than pretended not to exist.
func (c *arqConn) SetDeadline(t time.Time) error      { return nil }
func (c *arqConn) SetReadDeadline(t time.Time) error  { return nil }
func (c *arqConn) SetWriteDeadline(t time.Time) error { return nil }

// ---------------------------------------------------------------------------
// sending
// ---------------------------------------------------------------------------

// emit builds and sends one datagram. Caller holds the lock, and the send
// callback runs under it - fine for a datagram socket, which does not block,
// but it means the callback must not reach back into this connection.
func (c *arqConn) emit(seg *segment, flags uint8) {
	var payload []byte
	h := arqHeader{session: c.session, carrier: c.carrier, flags: flags, ack: c.rcvNext}
	if seg != nil {
		h.seq = seg.seq
		h.length = uint16(len(seg.data))
		payload = seg.data
		seg.sentAt = time.Now()
	}
	buf := make([]byte, arqOver+len(payload))
	if _, err := rand.Read(buf[:arqNonce]); err != nil {
		return
	}
	h.put(buf[arqNonce:arqOver])
	maskHeader(c.mask, buf[:arqNonce], buf[arqNonce:arqOver])
	copy(buf[arqOver:], payload)
	c.needAck = false
	c.send(buf)
}

// ackOnly sends a bare acknowledgement. Caller holds the lock.
func (c *arqConn) ackOnly() { c.emit(nil, 0) }

// ---------------------------------------------------------------------------
// receiving
// ---------------------------------------------------------------------------

// onDatagram feeds one received datagram in. It never blocks, so the socket
// reader is never held up by a slow consumer.
func (c *arqConn) onDatagram(buf []byte) {
	if len(buf) < arqOver {
		return
	}
	hdr := make([]byte, arqHdr)
	copy(hdr, buf[arqNonce:arqOver])
	maskHeader(c.mask, buf[:arqNonce], hdr)
	var h arqHeader
	h.get(hdr)
	if h.session != c.session || h.carrier != c.carrier {
		return
	}
	if int(h.length) > len(buf)-arqOver {
		return
	}
	payload := buf[arqOver : arqOver+int(h.length)]

	c.mu.Lock()
	defer c.mu.Unlock()

	if h.flags&flagRst != 0 {
		c.fail(errARQReset)
		return
	}

	c.processAck(h.ack)

	if h.flags&flagData != 0 && h.length > 0 {
		c.deliver(h.seq, payload)
		c.needAck = true
	}
	if h.flags&flagFin != 0 {
		c.peerFin = true
		c.cond.Broadcast()
	}
}

// grow widens the window by one segment for each round of clean acks, up to
// what the tunnel was configured for. Additive on the way up, halved on the
// way down - the shape that settles near a path's capacity rather than
// oscillating around it.
func (c *arqConn) grow() {
	if c.window < c.maxWindow {
		c.window++
	}
}

// shrink halves the window when a segment had to be sent twice, which is the
// path saying it is carrying more than it can.
func (c *arqConn) shrink() {
	c.window /= 2
	if c.window < arqWinMin {
		c.window = arqWinMin
	}
	c.cond.Broadcast()
}

// processAck retires everything the peer has confirmed. Caller holds the lock.
func (c *arqConn) processAck(ack uint32) {
	if ack == c.lastAck {
		c.dupAcks++
		// Three duplicates mean the segment after the ack is almost certainly
		// gone; resend it now rather than waiting out the timer.
		if c.dupAcks == 3 {
			if seg, ok := c.sndBuf[ack]; ok {
				c.emit(seg, flagData)
				seg.retries++
				c.shrink()
			}
		}
		return
	}
	c.dupAcks = 0
	c.lastAck = ack

	for s := c.sndUna; s < ack; s++ {
		if seg, ok := c.sndBuf[s]; ok {
			// Karn's rule: a retransmitted segment says nothing about the RTT.
			if seg.retries == 0 {
				c.sampleRTT(time.Since(seg.sentAt))
			}
			delete(c.sndBuf, s)
		}
	}
	if ack > c.sndUna {
		c.sndUna = ack
		// Fresh ground acknowledged with nothing resent: the peer is keeping
		// up and is willing to take at least this much, so widen a little.
		c.grow()
	}
	c.cond.Broadcast()
}

// deliver puts a segment in order, buffering anything that arrives early.
// Caller holds the lock.
func (c *arqConn) deliver(seq uint32, payload []byte) {
	if seq < c.rcvNext {
		return // already had it; the ack was lost, not the data
	}
	// Bounded by what any peer is allowed to send, never by what this end
	// happens to be sending. Tying it to our own window made the receive
	// guard a wire parameter: an end with a wide window sent past what an end
	// with a narrow one would accept, every one of those segments was
	// dropped, the sender resent them until it gave up, and the carrier died.
	// Which is exactly what updating one server before the other did.
	if seq >= c.rcvNext+arqWinMax*2 {
		return // absurdly far ahead, drop rather than grow without bound
	}
	if _, dup := c.rcvBuf[seq]; dup {
		return
	}
	c.rcvBuf[seq] = append([]byte(nil), payload...)
	for {
		seg, ok := c.rcvBuf[c.rcvNext]
		if !ok {
			break
		}
		c.inbox = append(c.inbox, seg...)
		delete(c.rcvBuf, c.rcvNext)
		c.rcvNext++
	}
	c.cond.Broadcast()
}

func (c *arqConn) fail(err error) {
	if c.err == nil {
		c.err = err
	}
	c.cond.Broadcast()
}

// ---------------------------------------------------------------------------
// timers
// ---------------------------------------------------------------------------

// sampleRTT folds one measurement into the retransmit timeout, the way TCP
// does: smoothed average plus four mean deviations. Caller holds the lock.
func (c *arqConn) sampleRTT(m time.Duration) {
	if c.srtt == 0 {
		c.srtt = m
		c.rttvar = m / 2
	} else {
		d := c.srtt - m
		if d < 0 {
			d = -d
		}
		c.rttvar = (3*c.rttvar + d) / 4
		c.srtt = (7*c.srtt + m) / 8
	}
	c.rto = c.srtt + 4*c.rttvar
	if c.rto < 200*time.Millisecond {
		c.rto = 200 * time.Millisecond
	}
	if c.rto > 5*time.Second {
		c.rto = 5 * time.Second
	}
}

func (c *arqConn) timerLoop() {
	t := time.NewTicker(20 * time.Millisecond)
	defer t.Stop()
	idle := time.Now()
	for {
		select {
		case <-c.done:
			return
		case now := <-t.C:
			c.mu.Lock()
			if c.err != nil {
				c.mu.Unlock()
				return
			}
			// Anything past its timeout goes again, with the timeout doubled
			// so a dead path is not hammered.
			for _, seg := range c.sndBuf {
				if now.Sub(seg.sentAt) >= c.rto {
					seg.retries++
					c.shrink()
					if seg.retries > c.maxRetries {
						c.fail(errARQClosed)
						c.mu.Unlock()
						return
					}
					c.emit(seg, flagData)
					if c.rto < 5*time.Second {
						c.rto *= 2
					}
				}
			}
			if c.needAck {
				c.ackOnly()
			}
			// A quiet link still needs a heartbeat, both to keep any stateful
			// middlebox interested and to notice the peer going away.
			if len(c.sndBuf) == 0 && now.Sub(idle) > time.Second {
				c.ackOnly()
				idle = now
			}
			if len(c.sndBuf) > 0 {
				idle = now
			}
			c.mu.Unlock()
		}
	}
}
