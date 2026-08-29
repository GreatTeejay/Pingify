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
	"sync/atomic"
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

	// The longest a segment waits before going again. Twelve retries with a
	// doubling back-off up to this is about forty-seven seconds, which is
	// inside the minute the braid gives a carrier before declaring the peer
	// gone - so the ARQ, which knows more, is the one that decides.
	arqMaxRTO = 5 * time.Second

	// How long the best round trip is trusted before it is measured again.
	// Long enough to ride out a burst, short enough to follow a path that has
	// really changed.
	minRTTWindow = 10 * time.Second

	// How long a packet-transport session may hear nothing before it is
	// let go of. Longer than the ARQ's own forty-seven seconds of retries
	// and far longer than a ten-second keepalive, so nothing live is ever
	// swept up by it.
	arqSessionIdle = 90 * time.Second

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
	packetBuf sync.Pool // one datagram scratch buffer; returned after send

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

	// The best round trip seen lately, and when that measurement started.
	//
	// A window only helps up to the bandwidth-delay product: enough segments
	// in flight to keep the path full for one round trip. Past that the extra
	// ones are not in flight at all, they are in a queue - and a queue is
	// latency for everything behind it, including the small interactive
	// packets that share the carrier.
	//
	// The round trip is what tells the two apart. While it stays near the
	// best we have seen, the path is carrying what we send. When it climbs
	// well above it, we are filling a buffer, and sending more will not make
	// anything arrive sooner.
	minRTT      time.Duration
	minRTTSince time.Time

	lastAck  uint32
	dupAcks  int
	needAck  bool
	peerFin  bool
	sentFin  bool
	closed   bool
	err      error
	done     chan struct{}
	deadline time.Time
	dlTimer  *time.Timer

	// When something last arrived, so a session that turns out to be nobody
	// can be told from one that is simply quiet. Written without the lock -
	// the reaper reads it from another goroutine.
	lastRx int64

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

// arqLabel is the domain separator the header mask key is derived from. Each
// transport passes its own, so two transports carrying the same tunnel never
// mask with the same key - and so the derivation is not a constant buried in
// here that a new transport has to know to copy.
func arqMaskKey(label string, psk []byte) []byte {
	return hkdfExpand(hkdfExtract([]byte(label), psk), []byte("arq header"), 32)
}

func newARQ(session uint32, carrier uint8, psk []byte, label string, maxPayload, window int, send func([]byte) error) *arqConn {
	k := arqMaskKey(label, psk)
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
		lastRx:     time.Now().UnixNano(),
		done:       make(chan struct{}),
		maxRetries: 12,
	}
	c.packetBuf.New = func() interface{} {
		return make([]byte, arqOver+maxPayload)
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
		if c.expired() {
			return 0, arqTimeout{}
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
			if c.expired() {
				c.mu.Unlock()
				return total, arqTimeout{}
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
	if c.dlTimer != nil {
		c.dlTimer.Stop()
		c.dlTimer = nil
	}
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

// Deadlines.
//
// These used to be accepted and ignored, on the grounds that the keepalive and
// the retransmit counter already noticed a wedged carrier. That was one
// mechanism where every other transport has two, and the day the keepalive
// itself got stuck behind a full send queue there was nothing else watching:
// the reader sat in cond.Wait forever, the carrier stayed "up" with a peer
// that had gone, and a server reported twenty carriers against a config asking
// for eight.
//
// The braid sets a read deadline before every frame, exactly as it does for
// TCP. Honouring it costs a timer and gives ICMP and UDP the same second
// opinion TCP has always had.
func (c *arqConn) SetDeadline(t time.Time) error {
	c.setDeadline(t)
	return nil
}

func (c *arqConn) SetReadDeadline(t time.Time) error {
	c.setDeadline(t)
	return nil
}

// The writer has its own wait - on window space rather than on data - and the
// same deadline covers it, because a peer that acknowledges nothing wedges
// that side first.
func (c *arqConn) SetWriteDeadline(t time.Time) error {
	c.setDeadline(t)
	return nil
}

func (c *arqConn) setDeadline(t time.Time) {
	c.mu.Lock()
	c.deadline = t
	if c.dlTimer != nil {
		c.dlTimer.Stop()
		c.dlTimer = nil
	}
	if !t.IsZero() {
		// Wake whoever is waiting when the moment arrives. cond.Wait has no
		// timeout of its own, so the timer is the only thing that can.
		if d := time.Until(t); d > 0 {
			c.dlTimer = time.AfterFunc(d, func() { c.cond.Broadcast() })
		} else {
			c.cond.Broadcast()
		}
	}
	c.mu.Unlock()
}

// expired reports whether the deadline has passed. The caller holds mu.
func (c *arqConn) expired() bool {
	return !c.deadline.IsZero() && !time.Now().Before(c.deadline)
}

// errARQTimeout is a net.Error that says Timeout, because that is what the
// layer above checks to tell "nothing arrived" from "the peer went away".
type arqTimeout struct{}

func (arqTimeout) Error() string   { return "arq: i/o timeout" }
func (arqTimeout) Timeout() bool   { return true }
func (arqTimeout) Temporary() bool { return true }

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
	raw := c.packetBuf.Get().([]byte)
	need := arqOver + len(payload)
	if cap(raw) < need {
		raw = make([]byte, need)
	}
	buf := raw[:need]
	defer c.packetBuf.Put(raw[:cap(raw)])
	if _, err := rand.Read(buf[:arqNonce]); err != nil {
		c.fail(err)
		return
	}
	h.put(buf[arqNonce:arqOver])
	maskHeader(c.mask, buf[:arqNonce], buf[arqNonce:arqOver])
	copy(buf[arqOver:], payload)
	c.needAck = false
	if err := c.send(buf); err != nil {
		c.fail(err)
	}
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
	atomic.StoreInt64(&c.lastRx, time.Now().UnixNano())
	var hdr [arqHdr]byte
	copy(hdr[:], buf[arqNonce:arqOver])
	maskHeader(c.mask, buf[:arqNonce], hdr[:])
	var h arqHeader
	h.get(hdr[:])
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

// grow widens the window by one segment for each newly acknowledged segment,
// up to what the tunnel was configured for. That is slow start on clean RTTs;
// loss still halves it so a saturated path sheds its queue quickly.
// grow widens the window by one segment for each newly acknowledged segment -
// but only while the path is still carrying what it is given.
//
// Growing on acknowledgement alone fills the window to whatever ceiling the
// config named and then keeps it there, which is why a bigger window_kb used
// to buy latency and nothing else: measured over a real tunnel, going from
// 128 KiB to 4 MiB left throughput where it was and took the round trip from
// 3 ms to 8. The extra segments were never in flight. They were queued.
//
// So the round trip decides. While it sits near the best seen, there is room
// and the window opens. Once it has climbed a quarter above that, the path is
// buffering rather than carrying, and the window stays where it is until it
// drains. That is what keeps a small packet quick while a large transfer is
// running - the thing a tunnel is actually judged on.
func (c *arqConn) grow() {
	if c.window >= c.maxWindow {
		return
	}
	if c.minRTT > 0 && c.srtt > c.minRTT+c.minRTT/4 {
		return
	}
	c.window++
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
	// An authenticated peer should never acknowledge data we have not sent.
	// Refusing it also bounds the retirement/growth loops below.
	if ack > c.sndNext {
		return
	}
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
		advanced := int(ack - c.sndUna)
		c.sndUna = ack
		// Grow for the amount of fresh ground acknowledged, not merely once
		// for the cumulative ACK packet. ICMP coalesces many segment ACKs into
		// one response every timer tick; counting that response as one made a
		// 1 MB window take tens of seconds to open. This is ordinary slow start:
		// roughly double once per clean RTT, while shrink still halves on loss.
		for i := 0; i < advanced; i++ {
			c.grow()
		}
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
	// The common case is in order. Put it straight into the byte stream: the
	// old map-first path allocated and copied once into the map and then again
	// into inbox for every packet, even when there was no reordering at all.
	if seq == c.rcvNext {
		c.inbox = append(c.inbox, payload...)
		c.rcvNext++
	} else {
		c.rcvBuf[seq] = append([]byte(nil), payload...)
	}
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
	// Re-learn the floor now and then, so a path that genuinely got slower is
	// not measured for ever against a number it can no longer reach.
	if c.minRTT == 0 || m < c.minRTT || time.Since(c.minRTTSince) > minRTTWindow {
		c.minRTT = m
		c.minRTTSince = time.Now()
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
	// Ten milliseconds halves the acknowledgement delay for games and small
	// web requests. ACKs are cumulative, so a fast transfer still sends at
	// most one small control datagram per tick rather than one per packet.
	t := time.NewTicker(10 * time.Millisecond)
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
			// Anything past its timeout goes again. Both the back-off and
			// the window cut happen ONCE for the pass, not once per segment:
			// a full window timing out together is one event - the path
			// stopped carrying - and treating it as sixty-four drove the
			// timeout from 500ms to its five-second ceiling on the first
			// pass, and halved the window past its floor in the same instant.
			// Twelve retries at five seconds is exactly the sixty seconds a
			// carrier is given before it is declared dead, so every carrier
			// died together on the first real stall rather than riding it out.
			lost := false
			for _, seg := range c.sndBuf {
				if now.Sub(seg.sentAt) >= c.rto {
					seg.retries++
					lost = true
					if seg.retries > c.maxRetries {
						c.fail(errARQClosed)
						c.mu.Unlock()
						return
					}
					c.emit(seg, flagData)
				}
			}
			if lost {
				c.shrink()
				// Clamped after doubling, not before. Testing first let it
				// pass the ceiling on the way through - four seconds is under
				// five, so it doubled to eight.
				c.rto *= 2
				if c.rto > arqMaxRTO {
					c.rto = arqMaxRTO
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
