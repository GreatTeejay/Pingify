package main

import (
	"bytes"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	mrand "math/rand"
	"net"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// ==========================================================================
// 5. framing, encryption and stream multiplexing
// ==========================================================================

// ---------------------------------------------------------------------------
// wire format
//
// Every carrier connection carries a stream of frames:
//
//	[4-byte big-endian ciphertext length][AES-256-GCM ciphertext]
//
// The plaintext of a frame is one or more back-to-back records:
//
//	[1-byte cmd][4-byte stream id][4-byte payload length][payload]
//
// The writer coalesces everything queued at that instant into a single frame,
// so a burst of small packets costs one seal and one write syscall instead of
// dozens. That batching is most of the throughput win over a naive tunnel.
// ---------------------------------------------------------------------------

const (
	recHdr    = 9
	maxRecord = 32 * 1024
	maxPlain  = 128 * 1024
	maxFrame  = maxPlain + 64

	// Control records - window credits, keepalives, opens and closes - are a
	// handful of bytes each and vastly outnumber data records. Giving them
	// their own small pool keeps a four-byte credit update from borrowing a
	// 32 KiB buffer, which is where most of the idle memory used to go.
	smallRecord = 512

	sendQueue      = 128 // records queued per carrier before the writer blocks
	earlyPadFrames = 8   // pad only the opening frames of a connection
	earlyPadMax    = 512
)

const (
	cmdData = 1  // stream payload
	cmdSYN  = 2  // open TCP stream; payload = target "host:port"
	cmdFIN  = 3  // half-close: no more data from this side
	cmdRST  = 4  // hard close
	cmdWND  = 5  // flow-control credit; payload = 4-byte byte count
	cmdPing = 6  // payload = 8-byte stamp
	cmdPong = 7  // echo of the ping payload
	cmdUSYN = 8  // open UDP session; payload = target "host:port"
	cmdUDP  = 9  // one UDP datagram
	cmdUFIN = 10 // UDP session gone
	cmdTUN  = 11 // one raw IP packet (tun mode)
	cmdPad  = 12 // random filler, discarded on arrival
	// cmdVer carries this end's version string, once, when a carrier comes up.
	//
	// It is a record rather than a handshake field on purpose. The handshake
	// is a fixed length that both ends agree on before they have exchanged
	// anything, so a field added there is a tunnel that will not come up
	// against a peer running yesterday's build. A record an older peer does
	// not know falls to the default arm of dispatch, which logs it at debug
	// and carries on - so this is invisible to one and useful to the other.
	cmdVer = 13
)

var errLinkClosed = errors.New("carrier closed")

// ---------------------------------------------------------------------------
// pooled records
// ---------------------------------------------------------------------------

type recBuf struct {
	a   []byte
	n   int
	big bool

	// When this was put on a carrier's queue, for records that are worth less
	// the longer they wait. Zero means it waits however long it takes: a
	// handshake, a window credit or a forwarded byte has to arrive.
	enq int64
}

func (r *recBuf) body() []byte  { return r.a[recHdr:] }
func (r *recBuf) bytes() []byte { return r.a[:r.n] }

func (r *recBuf) seal(cmd byte, id uint32, n int) {
	r.a[0] = cmd
	binary.BigEndian.PutUint32(r.a[1:5], id)
	binary.BigEndian.PutUint32(r.a[5:9], uint32(n))
	r.n = recHdr + n
}

var bigPool = sync.Pool{New: func() interface{} {
	return &recBuf{a: make([]byte, recHdr+maxRecord), big: true}
}}

var smallPool = sync.Pool{New: func() interface{} {
	return &recBuf{a: make([]byte, recHdr+smallRecord)}
}}

// getRec hands out a full-size buffer, for the data path.
func getRec() *recBuf { return bigPool.Get().(*recBuf) }

// getCtrl sizes the buffer to the payload, so a keepalive does not cost 32 KiB.
func getCtrl(payload int) *recBuf {
	if payload <= smallRecord {
		return smallPool.Get().(*recBuf)
	}
	return bigPool.Get().(*recBuf)
}

func putRec(r *recBuf) {
	r.enq = 0
	if r.big {
		bigPool.Put(r)
	} else {
		smallPool.Put(r)
	}
}

func ctrlRec(cmd byte, id uint32, payload []byte) *recBuf {
	r := getCtrl(len(payload))
	copy(r.a[recHdr:], payload)
	r.seal(cmd, id, len(payload))
	return r
}

// appendPad tacks a random-length filler record onto a frame.
func appendPad(frame []byte) []byte {
	n := mrand.Intn(earlyPadMax)
	if n == 0 {
		return frame
	}
	var hdr [recHdr]byte
	hdr[0] = cmdPad
	binary.BigEndian.PutUint32(hdr[5:9], uint32(n))
	frame = append(frame, hdr[:]...)
	start := len(frame)
	frame = append(frame, make([]byte, n)...)
	rand.Read(frame[start:])
	return frame
}

// ---------------------------------------------------------------------------
// receive buffer: byte-bounded, never blocks the carrier reader
// ---------------------------------------------------------------------------

type recvBuf struct {
	mu  sync.Mutex
	cv  *sync.Cond
	buf bytes.Buffer
	eof bool
	err error
}

func newRecvBuf() *recvBuf {
	r := &recvBuf{}
	r.cv = sync.NewCond(&r.mu)
	return r
}

func (r *recvBuf) push(p []byte) {
	r.mu.Lock()
	if r.err == nil && !r.eof {
		r.buf.Write(p)
	}
	r.cv.Broadcast()
	r.mu.Unlock()
}

func (r *recvBuf) Read(p []byte) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for r.buf.Len() == 0 {
		if r.err != nil {
			return 0, r.err
		}
		if r.eof {
			return 0, io.EOF
		}
		r.cv.Wait()
	}
	return r.buf.Read(p)
}

// buffered says how much is waiting, so a reader can tell whether its next
// call would block. See pumpIn: that is the moment credit has to go back.
func (r *recvBuf) buffered() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.buf.Len()
}

func (r *recvBuf) closeEOF() {
	r.mu.Lock()
	r.eof = true
	r.cv.Broadcast()
	r.mu.Unlock()
}

func (r *recvBuf) fail(err error) {
	r.mu.Lock()
	if r.err == nil {
		r.err = err
	}
	r.cv.Broadcast()
	r.mu.Unlock()
}

// ---------------------------------------------------------------------------
// stream
// ---------------------------------------------------------------------------

// stream is one multiplexed TCP connection riding a single carrier. It never
// migrates between carriers: a stream is pinned at open time so its bytes can
// never be reordered by uneven carrier latency, which is what would otherwise
// make the inner TCP connection collapse.
type stream struct {
	id     uint32
	l      *link
	rb     *recvBuf
	win    int32
	winCh  chan struct{}
	done   chan struct{}
	once   sync.Once
	halves int32

	lmu   sync.Mutex
	local net.Conn
	dead  bool
}

// attach hands the stream its local socket. A stream is registered the moment
// its SYN is parsed, before the dial finishes, so that data arriving right
// behind the SYN is buffered instead of dropped; attach closes that gap.
func (s *stream) attach(c net.Conn) bool {
	s.lmu.Lock()
	defer s.lmu.Unlock()
	if s.dead {
		return false
	}
	s.local = c
	return true
}

// halfDone retires the stream once both directions have finished. Without it
// a completed connection would sit in the carrier's stream table forever and
// its local socket would never be closed.
func (s *stream) halfDone() {
	if atomic.AddInt32(&s.halves, 1) == 2 {
		s.reset()
	}
}

func (s *stream) acquireUpTo(max int32) int32 {
	for {
		cur := atomic.LoadInt32(&s.win)
		if cur > 0 {
			n := cur
			if n > max {
				n = max
			}
			if atomic.CompareAndSwapInt32(&s.win, cur, cur-n) {
				return n
			}
			continue
		}
		select {
		case <-s.winCh:
		case <-s.done:
			return 0
		case <-s.l.closed:
			return 0
		}
	}
}

func (s *stream) addWin(n int32) {
	if n <= 0 {
		return
	}
	atomic.AddInt32(&s.win, n)
	select {
	case s.winCh <- struct{}{}:
	default:
	}
}

// pumpOut moves bytes from the local socket into the carrier, never sending
// more than the credit the far side has granted.
func (s *stream) pumpOut(local net.Conn) {
	defer s.halfDone()
	defer s.l.send(ctrlRec(cmdFIN, s.id, nil))
	for {
		credit := s.acquireUpTo(maxRecord)
		if credit == 0 {
			return
		}
		r := getRec()
		n, err := local.Read(r.body()[:credit])
		if n > 0 {
			r.seal(cmdData, s.id, n)
			atomic.AddUint64(&s.l.txBytes, uint64(n))
			if !s.l.send(r) {
				return
			}
		} else {
			putRec(r)
		}
		s.addWin(credit - int32(n)) // hand back the slice we did not use
		if err != nil {
			return
		}
	}
}

// pumpIn drains the receive buffer into the local socket and returns the
// consumed credit to the far side.
func (s *stream) pumpIn(local net.Conn) {
	defer s.halfDone()
	buf := make([]byte, 32*1024)

	// Credit goes back in as few records as the sender can afford to wait for.
	//
	// One record per read is one control record for every 32 KiB consumed -
	// hundreds a second on a busy stream, and dozens of streams do it at once.
	// Each one is a frame to seal, a wakeup for the writer, and a place in the
	// queue ahead of data that is actually going somewhere. Under load that is
	// where the jitter comes from: real traffic waiting behind bookkeeping.
	//
	// So it accumulates, and goes out when it is worth a record - or the
	// moment there is nothing left to read, because the next call blocks there
	// and credit held past that point is credit the sender is waiting on. An
	// idle stream therefore still returns its window immediately, and a busy
	// one returns it in one record instead of sixteen.
	flushAt := s.l.window() / 2
	if flushAt < int32(len(buf)) {
		flushAt = int32(len(buf))
	}
	var pending int32
	give := func() {
		if pending <= 0 {
			return
		}
		var c [4]byte
		binary.BigEndian.PutUint32(c[:], uint32(pending))
		s.l.send(ctrlRec(cmdWND, s.id, c[:]))
		pending = 0
	}

	for {
		n, err := s.rb.Read(buf)
		if n > 0 {
			if _, werr := local.Write(buf[:n]); werr != nil {
				// The client is gone. The far end is still reading the real
				// service for it and must be told, or it waits for credit
				// that is never coming.
				s.resetPeer()
				return
			}
			atomic.AddUint64(&s.l.rxBytes, uint64(n))
			pending += int32(n)
			if pending >= flushAt || s.rb.buffered() == 0 {
				give()
			}
		}
		if err != nil {
			give()
			// Far side stopped sending: half-close so the local peer sees EOF
			// but can still finish its own upload.
			if cw, ok := local.(interface{ CloseWrite() error }); ok {
				cw.CloseWrite()
			} else {
				s.resetPeer()
			}
			return
		}
	}
}

// reset tears the stream down at this end and says nothing.
//
// It is the ordinary end of a stream as well as an unhappy one - halfDone
// calls it when both directions have finished - so it must not tell the peer
// anything. A record sent from here would arrive after the data still in
// flight and cut it off. Where this end has genuinely failed and the peer
// needs to know, resetPeer is the one to call.
func (s *stream) reset() {
	s.once.Do(func() {
		close(s.done)
		s.rb.fail(errLinkClosed)
		s.lmu.Lock()
		s.dead = true
		c := s.local
		s.lmu.Unlock()
		if c != nil {
			c.Close()
		}
		s.l.removeStream(s.id)
	})
}

// resetPeer tears the stream down and tells the other end, for the cases where
// this end failed rather than finished.
//
// Saying so is not politeness. Without it, a client that vanishes at the edge
// leaves the far end reading from the real service and sending data for a
// stream id that no longer exists. Those records are dropped on arrival with
// no reply, so no window credit ever comes back, and after one window the far
// end's writer blocks for good - holding a goroutine, a connection to the real
// service, and a window's worth of memory, until the carrier itself dies. One
// browser closed the wrong way was enough.
//
// trySend, never send: this is reachable from the read loop, which is the one
// goroutine draining the peer's socket, and send() waits for room. On a
// carrier whose queue is full - which is exactly when this matters - waiting
// there would stop the reads that make room.
func (s *stream) resetPeer() {
	if s.l.alive() {
		s.l.trySend(ctrlRec(cmdRST, s.id, nil))
	}
	s.reset()
}

// ---------------------------------------------------------------------------
// link
// ---------------------------------------------------------------------------

type link struct {
	idx  int
	cfg  *Config
	conn net.Conn
	pool *pool

	keys  *sessionKeys
	txCtr uint64
	rxCtr uint64

	sendQ chan *recBuf
	// Control that must not queue behind bulk.
	//
	// sendQ holds up to 128 records of up to 32 KiB, so a keepalive handed to
	// it can sit behind four megabytes of somebody's download - a third of a
	// second on a hundred-megabit path, before the ARQ or the wire have seen
	// it at all. That is measured as round-trip time, and felt as a video
	// that stutters while a file copies.
	//
	// Only records that carry no stream position go here: a ping, a pong, a
	// window credit. Those mean the same thing whenever they arrive, so
	// letting them past the queue costs nothing. An open, a close or a byte
	// of data has a place in its stream and keeps it.
	priQ      chan *recBuf
	closed    chan struct{}
	closeOnce sync.Once

	mu      sync.Mutex
	streams map[uint32]*stream
	nextID  uint32

	obf     bool   // mask frame lengths and pad the opening frames
	plain   bool   // frames go out unsealed - see Config.Encrypt
	downWhy string // why the carrier died; read once, when it is logged

	txBytes uint64 // payload carried for streams, tun and UDP
	rxBytes uint64
	// Bytes actually written to and read from the socket, keepalives and all.
	// txBytes only counts payload, so an idle tunnel reports zero either way
	// and cannot answer the one question that matters when nothing works:
	// did our bytes leave this machine, and did any of theirs arrive?
	wireTx  uint64
	wireRx  uint64
	lastRx  int64 // unix nano
	rttUS   int64
	upSince int64
}

func newLink(idx int, cfg *Config, conn net.Conn, k *sessionKeys, p *pool) *link {
	l := &link{
		idx: idx, cfg: cfg, conn: conn, pool: p, obf: cfg.obfuscated(),
		plain:   !cfg.encrypted(),
		keys:    k,
		sendQ:   make(chan *recBuf, sendQueue),
		priQ:    make(chan *recBuf, sendQueue),
		closed:  make(chan struct{}),
		streams: make(map[uint32]*stream),
	}
	// Odd ids from the edge, even from the origin. Ids are per-carrier, so this
	// is only belt and braces against a future origin-initiated stream.
	if cfg.Role == "server" {
		l.nextID = 1
	} else {
		l.nextID = 2
	}
	now := time.Now().UnixNano()
	atomic.StoreInt64(&l.lastRx, now)
	atomic.StoreInt64(&l.upSince, now)
	return l
}

func (l *link) run() {
	go l.writeLoop()
	go l.keepaliveLoop()
	// Say which build this is, once. See cmdVer, and peerVersion below for
	// why the answer is worth having.
	l.trySend(ctrlRec(cmdVer, 0, []byte(version)))
	l.readLoop()
}

func (l *link) alive() bool {
	select {
	case <-l.closed:
		return false
	default:
		return true
	}
}

// died records why this carrier is going away and then closes it. The first
// reason wins: the read loop, the write loop and the keepalive all race to
// close a dying carrier, and the first one to notice knows the most.
func (l *link) died(format string, a ...interface{}) {
	l.mu.Lock()
	if l.downWhy == "" {
		l.downWhy = fmt.Sprintf(format, a...)
	}
	l.mu.Unlock()
	l.close()
}

// How long a private-link packet may wait before dropping it beats sending it.
//
// The queue is 128 records deep per carrier - at a carrier's share of a
// hundred megabits, about seventy milliseconds of packets. Idle, the link
// measures 40 ms. With sixteen streams pushing through it and no shedding at
// all, the same ping averaged 270 ms and peaked at 896, with 244 ms of
// jitter. The bytes were not lost, they were queued, and no sender inside
// could tell: a queue that deep hides the congestion signal that would have
// made them slow down.
//
// CoDel was tried here, properly - target 5 ms, interval 100 ms, drop rate
// rising with the square root of a persisting queue - and it lost on both
// counts: 191 ms under the same load against this rule's 63 ms, and 173
// Mbit/s against 202. Its interval is the reason. CoDel waits a hundred
// milliseconds to be sure a queue is standing rather than bursting, and on
// this path the queue is built and hurting long before that.
//
// So the rule is the plain one: a packet that has waited longer than this is
// one the TCP inside has already counted as lost and resent, and sending it
// now adds delay for a copy nobody wants. Dropping is not damage on a link
// that carries IP - it is the signal, and it is the signal that a deep queue
// was preventing. Shedding is also what makes it FASTER under load, because
// the retransmit storms that bufferbloat causes cost more than the drops do.
const tunMaxSojourn = 6 * time.Millisecond

// staleTUN reports a private-link packet the queue should shed, and returns
// its buffer. Records with no timestamp - handshakes, window credits,
// forwarded bytes - are never shed: those have to arrive.
func (l *link) staleTUN(r *recBuf) bool {
	if r.enq == 0 || time.Now().UnixNano()-r.enq <= int64(tunMaxSojourn) {
		return false
	}
	putRec(r)
	return true
}

// jumpsQueue is true for the records that carry no position in any stream, so
// nothing is reordered by letting them go first.
func jumpsQueue(cmd byte) bool {
	return cmd == cmdPing || cmd == cmdPong || cmd == cmdWND
}

func (l *link) queueFor(r *recBuf) chan *recBuf {
	// A link without the second queue - one built by hand in a test - still
	// has to send. A nil channel blocks for ever, which is not a failure any
	// caller here is prepared for.
	if l.priQ == nil {
		return l.sendQ
	}
	if b := r.bytes(); len(b) > 0 && jumpsQueue(b[0]) {
		return l.priQ
	}
	return l.sendQ
}

func (l *link) send(r *recBuf) bool {
	q := l.queueFor(r)
	select {
	case q <- r:
		return true
	case <-l.closed:
		putRec(r)
		return false
	}
}

func (l *link) trySend(r *recBuf) bool {
	q := l.queueFor(r)
	select {
	case q <- r:
		return true
	default:
		putRec(r)
		return false
	}
}

func nonceFor(ctr uint64) [12]byte {
	var n [12]byte
	binary.BigEndian.PutUint64(n[4:], ctr)
	return n
}

func (l *link) writeLoop() {
	defer l.close()
	frame := make([]byte, 0, maxPlain)
	out := make([]byte, 0, 4+maxPlain+32)
	for {
		var r *recBuf
		select {
		case r = <-l.priQ:
		case <-l.closed:
			return
		default:
			select {
			case r = <-l.priQ:
			case r = <-l.sendQ:
			case <-l.closed:
				return
			}
		}
		if l.staleTUN(r) {
			continue
		}
		frame = append(frame[:0], r.bytes()...)
		putRec(r)
	drain:
		for len(frame) <= maxPlain-recHdr-maxRecord {
			var r2 *recBuf
			select {
			case r2 = <-l.priQ:
			default:
				select {
				case r2 = <-l.sendQ:
				default:
					break drain
				}
			}
			if l.staleTUN(r2) {
				continue
			}
			frame = append(frame, r2.bytes()...)
			putRec(r2)
		}
		// Only the opening frames are padded. That is where a fingerprint
		// would be taken, and padding every frame would cost real bandwidth.
		if ctr := l.txCtr; l.obf && ctr < earlyPadFrames && len(frame) < maxPlain-recHdr-earlyPadMax {
			frame = appendPad(frame)
		}
		ctr := l.txCtr
		l.txCtr++
		n := nonceFor(ctr)
		out = out[:4]
		if l.plain {
			// Length-prefixed and nothing else. The nonce is still counted so
			// that length masking, which uses it, behaves the same either way.
			out = append(out, frame...)
		} else {
			out = l.keys.tx.Seal(out, n[:], frame, nil)
		}
		binary.BigEndian.PutUint32(out[:4], uint32(len(out)-4))
		if l.obf {
			maskLen(l.keys.maskTx, ctr, out[:4])
		}
		l.conn.SetWriteDeadline(time.Now().Add(60 * time.Second))
		if _, err := l.conn.Write(out); err != nil {
			l.died("write: %v", err)
			return
		}
		atomic.AddUint64(&l.wireTx, uint64(len(out)))
		logTrace("carrier %d tx frame %d: %d bytes on the wire, %d of records",
			l.idx, ctr, len(out), len(frame))
		out = out[:0]
	}
}

// readReason turns a socket error into something worth reading at 4am. A
// timeout means nothing arrived and the peer may be fine; a reset means
// something actively tore the connection down, which on this path is usually
// not the peer.
func readReason(err error, idle time.Duration) string {
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		return fmt.Sprintf("nothing received for %s - the peer stopped sending, or the path dropped it", idle)
	}
	if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
		return "peer closed the connection"
	}
	if errors.Is(err, syscall.ECONNRESET) {
		return "connection reset - something on the path killed it, not the peer"
	}
	return "read: " + err.Error()
}

func (l *link) readLoop() {
	defer l.close()
	var hdr [4]byte
	ct := make([]byte, 0, maxFrame)
	plain := make([]byte, 0, maxPlain)
	idle := l.idleLimit()
	for {
		l.conn.SetReadDeadline(time.Now().Add(idle))
		if _, err := io.ReadFull(l.conn, hdr[:]); err != nil {
			l.died("%s%s", readReason(err, idle), l.rxSummary())
			return
		}
		if l.obf {
			maskLen(l.keys.maskRx, l.rxCtr, hdr[:]) // XOR is its own inverse
		}
		n := int(binary.BigEndian.Uint32(hdr[:]))
		// A sealed frame always carries at least a sixteen-byte GCM tag, so
		// anything shorter was impossible and worth refusing. An unsealed one
		// has no tag: the smallest thing it can hold is a single record
		// header, and a keepalive is exactly that. Judging both by the sealed
		// minimum killed every carrier on its first ping.
		least := 16
		if l.plain {
			least = recHdr
		}
		if n < least || n > maxFrame {
			l.died("bad frame length %d - the two ends disagree or something rewrote the stream", n)
			return
		}
		if cap(ct) < n {
			ct = make([]byte, 0, n)
		}
		ct = ct[:n]
		if _, err := io.ReadFull(l.conn, ct); err != nil {
			l.died("%s%s", readReason(err, idle), l.rxSummary())
			return
		}
		atomic.AddUint64(&l.wireRx, uint64(len(hdr)+n))
		logTrace("carrier %d rx frame %d: %d bytes on the wire", l.idx, l.rxCtr, len(hdr)+n)
		nc := nonceFor(l.rxCtr)
		l.rxCtr++
		var p []byte
		if l.plain {
			p = ct
		} else {
			var err error
			p, err = l.keys.rx.Open(plain[:0], nc[:], ct, nil)
			if err != nil {
				// One end sealing and the other not looks exactly like this,
				// so the message has to name it: the tokens can be identical
				// and the tunnel still fail here.
				l.died("could not read a frame - the token does not match, one end " +
					"has encryption off while the other has it on, or a middlebox altered the stream")
				return
			}
			// Keep whatever capacity Open grew it to. Not in plain mode: p is
			// the frame buffer there, and pointing the cipher's scratch at it
			// would quietly make one buffer out of two.
			plain = p[:0]
		}
		atomic.StoreInt64(&l.lastRx, time.Now().UnixNano())
		if err := l.dispatch(p); err != nil {
			l.died("%v", err)
			return
		}
	}
}

func (l *link) dispatch(p []byte) error {
	for len(p) > 0 {
		if len(p) < recHdr {
			return fmt.Errorf("truncated record header")
		}
		cmd := p[0]
		id := binary.BigEndian.Uint32(p[1:5])
		n := int(binary.BigEndian.Uint32(p[5:9]))
		if n > maxRecord || len(p) < recHdr+n {
			return fmt.Errorf("truncated record body")
		}
		body := p[recHdr : recHdr+n]
		p = p[recHdr+n:]

		switch cmd {
		case cmdData:
			if s := l.getStream(id); s != nil {
				s.rb.push(body)
			}
		case cmdWND:
			if n == 4 {
				if s := l.getStream(id); s != nil {
					s.addWin(int32(binary.BigEndian.Uint32(body)))
				}
			}
		case cmdFIN:
			if s := l.getStream(id); s != nil {
				s.rb.closeEOF()
			}
		case cmdRST:
			if n > 0 {
				l.refused(string(body))
			}
			if s := l.getStream(id); s != nil {
				s.reset()
			}
		case cmdPad:
			logTrace("carrier %d rx pad %d bytes", l.idx, n)
		case cmdPing:
			logTrace("carrier %d rx ping, answering", l.idx)
			// Never block the read loop: if the send queue is momentarily
			// full, drop the pong rather than risk both ends stalling on
			// each other's socket buffers.
			l.trySend(ctrlRec(cmdPong, 0, body))
		case cmdPong:
			logTrace("carrier %d rx pong", l.idx)
			if n == 8 {
				sent := int64(binary.BigEndian.Uint64(body))
				atomic.StoreInt64(&l.rttUS, (time.Now().UnixNano()-sent)/1000)
			}
		case cmdVer:
			l.peerVersion(string(body))
		case cmdSYN, cmdUSYN, cmdUDP, cmdUFIN, cmdTUN:
			if h := l.pool.handler(); h != nil {
				h.onRecord(l, cmd, id, body)
			}
		default:
			logDebug("carrier %d: unknown cmd %d", l.idx, cmd)
		}
	}
	return nil
}

// idleLimit is how long a carrier waits before declaring the peer gone.
//
// It cannot simply be three of our own keepalives. Our keepalive says how
// often WE speak; what keeps this carrier alive is how often the PEER speaks,
// and the peer is configured separately, by hand, on another machine. A field
// tunnel built with "gaming" on one end and "balanced" on the other had one
// side hanging up every nine seconds while the other was still perfectly
// happy. The floor makes that impossible: however impatient this end is
// configured to be, it waits a full minute of real silence before giving up.
// rxSummary says whether this carrier ever heard anything and how long ago,
// which is the difference between "the peer went away" and "the peer was never
// able to reach us at all".
func (l *link) rxSummary() string {
	n := atomic.LoadUint64(&l.wireRx)
	if n == 0 {
		return " (nothing was EVER received on this carrier)"
	}
	last := time.Since(time.Unix(0, atomic.LoadInt64(&l.lastRx))).Round(time.Second)
	return fmt.Sprintf(" (received %s in all, last %s ago)", humanBytes(n), last)
}

// refused reports what the far end said about a connection it would not make.
//
// One line a minute, with a count of the ones it stood for. The far side
// sends one of these per refused connection, and a target that is down
// refuses every connection there is - so a dead port on one server used to
// write a line per record here, out of the carrier's read loop, on a socket
// that went unread for as long as the write took. Under systemd that write is
// to a pipe journald can stop draining, and the tunnel stopped with it.
//
// Both halves of that are fixed: the sink no longer waits for anybody, and
// this no longer speaks per record. The volume follows the clock, which is
// the rule the carrier count already keeps.
func (l *link) refused(why string) {
	p := l.pool
	if p == nil {
		logWarn("the other server refused a connection: %s", why)
		return
	}
	n := atomic.AddUint64(&p.refusals, 1)
	if !p.firstIn("refused", time.Minute) {
		return
	}
	// How many arrived since the last time this said anything - which is the
	// number an operator wants, and the one a per-record line never gave.
	quiet := n - atomic.SwapUint64(&p.refusalsSaid, n)
	if quiet > 1 {
		logWarn("the other server refused a connection: %s (and %d more since the last time this said so)",
			why, quiet-1)
		return
	}
	logWarn("the other server refused a connection: %s", why)
}

// peerVersion says so when the two servers are not running the same build.
//
// This is the single thing that has cost the most time in the field, and it is
// invisible from either end on its own. The presets, the token format and the
// wire records move together, so two builds disagree quietly: the far end
// dials the carrier count ITS table says, and this end reports "20 of 8
// carriers up" against a config that asked for eight. Nothing in that line
// says why, and both servers look healthy from where they are standing.
//
// A peer running a build older than this one never sends its version at all,
// which is itself the answer - so silence is reported too, once the carrier
// has been up long enough that the record would have arrived.
func (l *link) peerVersion(v string) {
	if v == "" || l.pool == nil {
		return
	}
	if prev := l.pool.peerVer.Swap(v); prev == v {
		return // already said, and nothing has changed
	}
	if v == version {
		logDebug("the other server runs %s, the same as this one", v)
		return
	}
	if !l.pool.firstIn("peer-version", 10*time.Minute) {
		return
	}
	logWarn("the other server runs %s and this one runs %s", v, version)
	logWarn("update both ends: presets, token format and wire records move together")
	logWarn("a mismatch shows up as the two ends disagreeing about how many carriers there are")
}

func (l *link) idleLimit() time.Duration {
	d := time.Duration(l.cfg.KeepaliveSec) * time.Second * 3
	if d < minIdle {
		return minIdle
	}
	return d
}

func (l *link) keepaliveLoop() {
	t := time.NewTicker(time.Duration(l.cfg.KeepaliveSec) * time.Second)
	defer t.Stop()
	idle := int64(l.idleLimit())
	for {
		select {
		case <-t.C:
			if time.Now().UnixNano()-atomic.LoadInt64(&l.lastRx) > idle {
				l.died("silent for %s - nothing came back from the peer%s",
					l.idleLimit(), l.rxSummary())
				return
			}
			var b [8]byte
			binary.BigEndian.PutUint64(b[:], uint64(time.Now().UnixNano()))
			logTrace("carrier %d tx ping (last heard %s ago)", l.idx,
				time.Since(time.Unix(0, atomic.LoadInt64(&l.lastRx))).Round(time.Millisecond))
			// Never wait for room. send() blocks until the queue drains or
			// the carrier closes, and on a carrier whose peer has gone the
			// queue never drains: the writer is stuck in a Write nobody is
			// acknowledging, so the queue fills, and the keepalive blocks in
			// send() and never reaches the idle check above again.
			//
			// That is the one check that would have noticed. A carrier could
			// therefore sit "up" forever with a dead peer on the other end -
			// on the accepting side, holding that peer's address and its slot
			// in the count, which is how one server came to report twenty
			// carriers up against a config that asked for eight.
			//
			// A ping that cannot be queued is not worth waiting for anyway: a
			// full queue already means the writer is behind, and the ping is
			// the least valuable thing in it. Drop it, and let the next tick
			// reach the idle check.
			l.trySend(ctrlRec(cmdPing, 0, b[:]))
		case <-l.closed:
			return
		}
	}
}

func (l *link) close() {
	l.closeOnce.Do(func() {
		close(l.closed)
		l.conn.Close()
		l.mu.Lock()
		streams := make([]*stream, 0, len(l.streams))
		for _, s := range l.streams {
			streams = append(streams, s)
		}
		l.streams = make(map[uint32]*stream)
		why := l.downWhy
		l.mu.Unlock()
		for _, s := range streams {
			s.reset()
		}
		if l.pool != nil {
			if h := l.pool.handler(); h != nil {
				h.onLinkDown(l)
			}
		}
		if why == "" {
			why = "closed locally"
		}
		// The reason belongs in the log every time - it is the only place
		// that says *why* - but at debug, because noteStrength below turns a
		// whole braid dropping at once into one line instead of twenty-four.
		logDebug("carrier %d down: %s (up %s)", l.idx, why,
			time.Since(time.Unix(0, atomic.LoadInt64(&l.upSince))).Round(time.Second))
		if l.pool != nil {
			l.pool.mu.Lock()
			l.pool.lastDown = why
			l.pool.mu.Unlock()
			l.pool.noteStrength()
		}
	})
}

// ---------------------------------------------------------------------------
// stream table
// ---------------------------------------------------------------------------

func (l *link) window() int32 { return int32(l.cfg.WindowKB) * 1024 }

func (l *link) newStream(local net.Conn) *stream {
	l.mu.Lock()
	id := l.nextID
	l.nextID += 2
	s := l.mkStream(id, local)
	l.streams[id] = s
	l.mu.Unlock()
	return s
}

func (l *link) acceptStream(id uint32, local net.Conn) *stream {
	l.mu.Lock()
	if _, dup := l.streams[id]; dup {
		l.mu.Unlock()
		return nil
	}
	s := l.mkStream(id, local)
	l.streams[id] = s
	l.mu.Unlock()
	return s
}

func (l *link) mkStream(id uint32, local net.Conn) *stream {
	return &stream{
		id:    id,
		l:     l,
		rb:    newRecvBuf(),
		win:   l.window(),
		winCh: make(chan struct{}, 1),
		done:  make(chan struct{}),
		local: local,
	}
}

func (l *link) getStream(id uint32) *stream {
	l.mu.Lock()
	s := l.streams[id]
	l.mu.Unlock()
	return s
}

func (l *link) removeStream(id uint32) {
	l.mu.Lock()
	delete(l.streams, id)
	l.mu.Unlock()
}

func (l *link) streamCount() int {
	l.mu.Lock()
	n := len(l.streams)
	l.mu.Unlock()
	return n
}
