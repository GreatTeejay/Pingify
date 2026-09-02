// Package forward is the tunnel without a private link: the IRAN server owns
// the user-facing ports, the KHAREJ server owns the real services, and every
// connection between them rides the carrier as a stream of its own.
//
// This is the kind of tunnel a port forwarder makes, and the kind the old
// core called TCP: there is no tun device, no address pair, no route and no
// NAT. A user connects to IRAN on 443, this end opens a stream to the far
// end naming 127.0.0.1:443, the far end dials it, and the bytes go across in
// records inside the carrier's datagrams. UDP goes the same way, one session
// per client address.
//
// It needs a carrier that cannot lose or reorder a datagram, which is every
// stream carrier - TCP, WS, WSS, TCP UTLS, TLS FALLBACK - and none of the
// datagram ones. Those keep the private link, which is what they need.
//
// On the wire, inside one carrier datagram:
//
//	0      1            5
//	+------+------------+-------------------------------+
//	| cmd  |  stream id |  body                         |
//	+------+------------+-------------------------------+
//
// A stream lives on one carrier connection from its first record to its
// last. The carrier picks the connection from the flow number, and the flow
// number is the stream id, so nothing arrives out of order.
package forward

import (
	"encoding/binary"
	"fmt"
	"net"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"pingify/internal/buf"
	"pingify/internal/carrier"
	"pingify/internal/config"
	"pingify/internal/logging"
)

const (
	cmdData = 1 // stream payload
	cmdSYN  = 2 // open a TCP stream; body is the target "host:port"
	cmdFIN  = 3 // no more data from this side
	cmdRST  = 4 // the stream is gone; body says why
	_       = 5 // was a credit record; flow control is the carrier's TCP now
	cmdPing = 6 // body is a stamp, echoed back as is
	cmdPong = 7
	cmdUSYN = 8  // open a UDP session; body is the target
	cmdUDP  = 9  // one datagram
	cmdUFIN = 10 // the session is gone

	hdrLen = 5

	udpIDBit  = 0x80000000
	udpIdle   = 90 * time.Second
	pingEvery = 10 * time.Second
	dialWait  = 10 * time.Second
)

// FlowSender is the one thing a carrier has to offer for this: sending a
// datagram on the connection its flow number picks, every time.
type FlowSender interface {
	SendFlow(flow uint32, bp *[]byte) error
}

type Forwarder struct {
	cfg  *config.Config
	car  carrier.Full
	send FlowSender
	edge bool // the IRAN side: binds the ports

	listeners []net.Listener
	packets   []net.PacketConn
	rules     []Rule
	allow     map[string]bool

	mu      sync.Mutex
	streams map[uint32]*stream
	udp     map[uint32]*udpSess
	udpEdge map[string]*udpSess // "port|client" -> session, on the edge
	nextID  uint32
	udpSeq  uint32

	toWire, fromWire, dropped, refused uint64
	farSeen                            int64 // unix nanos of the last record in
	rtt                                int64 // nanos, from the last pong

	// Records on their way out, one queue per carrier connection, each drained
	// by a goroutine of its own. The receive path never writes to the carrier
	// directly: it hands a pong or a refusal to these queues without blocking
	// (recordNB), so a read goroutine is never stuck in a write while the far
	// end waits to be read. Bulk data blocks here, and that block is the back
	// pressure a fast local end should feel.
	out []chan outRec

	closing chan struct{}
	once    sync.Once
}

type outRec struct {
	id uint32
	bp *[]byte
}

func New(cfg *config.Config, car carrier.Full) (*Forwarder, error) {
	fs, ok := car.(FlowSender)
	if !ok {
		return nil, fmt.Errorf("%s cannot carry streams; a forward tunnel needs tcp, ws, wss, utls or fallback",
			cfg.Transport.Type)
	}
	f := &Forwarder{
		cfg: cfg, car: car, send: fs,
		edge:    cfg.Side == config.SideIran,
		streams: map[uint32]*stream{},
		udp:     map[uint32]*udpSess{},
		udpEdge: map[string]*udpSess{},
		closing: make(chan struct{}),
	}
	if f.edge {
		rules, err := ParseAll(cfg.Forward.Ports)
		if err != nil {
			return nil, err
		}
		f.rules = rules
	}
	if len(cfg.Forward.Allow) > 0 {
		f.allow = map[string]bool{}
		for _, a := range cfg.Forward.Allow {
			f.allow[a] = true
		}
	}
	n := cfg.Transport.Connections
	if n < 1 {
		n = 1
	}
	f.out = make([]chan outRec, n)
	for i := range f.out {
		f.out[i] = make(chan outRec, 4096)
	}
	car.OnPacket(f.onRecord)
	return f, nil
}

// writer drains one outbound queue onto the carrier. One per connection,
// so a stream's records leave in the order they were queued.
func (f *Forwarder) writer(q chan outRec) {
	for {
		select {
		case <-f.closing:
			return
		case r := <-q:
			if err := f.send.SendFlow(r.id, r.bp); err != nil {
				atomic.AddUint64(&f.dropped, 1)
				continue
			}
			atomic.AddUint64(&f.toWire, 1)
		}
	}
}

// Start binds the ports on the edge and starts the pinger on both.
func (f *Forwarder) Start() error {
	if f.edge {
		for _, r := range f.rules {
			if err := f.bind(r); err != nil {
				f.Close()
				return err
			}
		}
		if len(f.rules) == 0 {
			logging.Warn("no ports to forward yet: add them on the Ports screen")
		}
	}
	for _, q := range f.out {
		go f.writer(q)
	}
	go f.pinger()
	go f.reapUDP()
	return nil
}

func (f *Forwarder) Close() error {
	f.once.Do(func() {
		close(f.closing)
		for _, ln := range f.listeners {
			_ = ln.Close()
		}
		for _, pc := range f.packets {
			_ = pc.Close()
		}
		// Collect first, kill outside the lock: kill -> forget wants this same
		// lock, so killing while holding it deadlocks the shutdown, and the
		// core hangs until systemd loses patience and sends SIGKILL.
		f.mu.Lock()
		streams := make([]*stream, 0, len(f.streams))
		for _, s := range f.streams {
			streams = append(streams, s)
		}
		f.mu.Unlock()
		for _, s := range streams {
			s.kill()
		}
	})
	return nil
}

// --- what the status server asks ------------------------------------------

func (f *Forwarder) Dropped() uint64 { return atomic.LoadUint64(&f.dropped) }
func (f *Forwarder) Packets() (toWire, toDevice uint64) {
	return atomic.LoadUint64(&f.toWire), atomic.LoadUint64(&f.fromWire)
}

// FarSeen is when the far end last said anything, and RTT the last measured
// round trip - the two things a forward tunnel can say about its health,
// having no address to be pinged on.
func (f *Forwarder) FarSeen() time.Time {
	n := atomic.LoadInt64(&f.farSeen)
	if n == 0 {
		return time.Time{}
	}
	return time.Unix(0, n)
}
func (f *Forwarder) RTT() time.Duration { return time.Duration(atomic.LoadInt64(&f.rtt)) }

func (f *Forwarder) String() string {
	return fmt.Sprintf("forward: %d records to the wire, %d from it, %d dropped, %d refused",
		atomic.LoadUint64(&f.toWire), atomic.LoadUint64(&f.fromWire),
		atomic.LoadUint64(&f.dropped), atomic.LoadUint64(&f.refused))
}

// --- records ----------------------------------------------------------------

func (f *Forwarder) maxBody() int { return f.car.MaxPayload() - hdrLen }

// record puts one record on the wire, on the connection the stream id picks.
func (f *Forwarder) record(cmd byte, id uint32, body []byte) bool {
	head := f.car.Headroom()
	bp := buf.Take(head, hdrLen+len(body))
	b := (*bp)[head:]
	b[0] = cmd
	binary.BigEndian.PutUint32(b[1:5], id)
	copy(b[hdrLen:], body)
	// Queued for the connection this id lives on, never written from here:
	// see the note on Forwarder.out. A pump goroutine blocking on a full
	// queue is the back pressure it should feel.
	select {
	case f.out[id%uint32(len(f.out))] <- outRec{id, bp}:
		return true
	case <-f.closing:
		buf.Put(bp)
		return false
	}
}

// recordNB is record for the one caller that must never block: the carrier's
// own read goroutine, in onRecord. If it blocked there - on a full out queue,
// which drains onto the very connection the peer is trying to read - both ends
// wedge, each read goroutine stuck sending while the other waits to be read.
// Measured before this: an upload stopped dead at 8088 bytes, every time.
//
// What it sends is a pong or a refusal, and both are safe to drop when the
// queue is full: a missed pong costs one round-trip sample, a missed refusal
// is a session the reaper collects anyway. Bulk data never comes this way.
func (f *Forwarder) recordNB(cmd byte, id uint32, body []byte) {
	head := f.car.Headroom()
	bp := buf.Take(head, hdrLen+len(body))
	b := (*bp)[head:]
	b[0] = cmd
	binary.BigEndian.PutUint32(b[1:5], id)
	copy(b[hdrLen:], body)
	select {
	case f.out[id%uint32(len(f.out))] <- outRec{id, bp}:
	default:
		buf.Put(bp)
	}
}

func (f *Forwarder) onRecord(b []byte) {
	if len(b) < hdrLen {
		return
	}
	atomic.AddUint64(&f.fromWire, 1)
	atomic.StoreInt64(&f.farSeen, time.Now().UnixNano())
	cmd, id, body := b[0], binary.BigEndian.Uint32(b[1:5]), b[hdrLen:]
	switch cmd {
	case cmdPing:
		f.recordNB(cmdPong, id, body)
	case cmdPong:
		if len(body) == 8 {
			sent := int64(binary.BigEndian.Uint64(body))
			atomic.StoreInt64(&f.rtt, time.Now().UnixNano()-sent)
		}
	case cmdSYN:
		if f.edge {
			return // the edge opens streams; it does not take them
		}
		f.accept(id, string(body))
	case cmdData:
		if s := f.stream(id); s != nil {
			s.deliver(body)
		}
	case cmdFIN:
		if s := f.stream(id); s != nil {
			s.deliverEOF()
		}
	case cmdRST:
		if s := f.stream(id); s != nil {
			s.kill()
		}
	case cmdUSYN:
		if !f.edge {
			f.openUDP(id, string(body))
		}
	case cmdUDP:
		f.mu.Lock()
		s := f.udp[id]
		f.mu.Unlock()
		if s != nil {
			s.deliver(body)
		}
	case cmdUFIN:
		f.mu.Lock()
		s := f.udp[id]
		f.mu.Unlock()
		if s != nil {
			f.dropUDP(s, false)
		}
	}
}

func (f *Forwarder) stream(id uint32) *stream {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.streams[id]
}

func (f *Forwarder) forget(id uint32) {
	f.mu.Lock()
	delete(f.streams, id)
	f.mu.Unlock()
}

func (f *Forwarder) pinger() {
	tk := time.NewTicker(pingEvery)
	defer tk.Stop()
	for {
		select {
		case <-f.closing:
			return
		case <-tk.C:
			if !f.car.Up() {
				continue
			}
			var stamp [8]byte
			binary.BigEndian.PutUint64(stamp[:], uint64(time.Now().UnixNano()))
			f.record(cmdPing, 0, stamp[:])
		}
	}
}

// --- TCP streams --------------------------------------------------------------

// A stream is one TCP connection carried across: the local socket at this
// end, the records to and from the other. Credit is what keeps a fast sender
// from burying a slow reader: this end may have `win` bytes in flight, and
// the far end hands bytes back as it writes them out.
type stream struct {
	id    uint32
	f     *Forwarder
	local net.Conn

	// Records from the wire, in order, waiting for the local socket to take
	// them. A bounded channel, and that bound is the whole of this stream's
	// flow control: when the local end cannot keep up, this fills, deliver
	// blocks the carrier's read goroutine, that goroutine stops reading its
	// connection, the connection's window closes, and the far end's write
	// blocks - end to end, over the carrier's own TCP, with no credit scheme
	// of our own on top of it.
	//
	// An earlier version did have one - a per-stream byte credit sent back as
	// records. It deadlocked over a real path every time: the sender filled
	// its window and waited for credit that was itself stuck behind the data
	// it was meant to clear. TCP already does this correctly; doing it again
	// above TCP only invents a way to get it wrong.
	in     chan []byte
	inEOF  chan struct{}
	inOnce sync.Once

	done     chan struct{}
	doneOnce sync.Once
}

// inDepth is how many records a stream may hold before the carrier read
// goroutine is made to wait on it. Deep enough that a stream on an idle path
// never stalls on it, shallow enough that a slow local end pushes back before
// megabytes pile up: a few hundred records is a few hundred kilobytes.
const inDepth = 256

func (f *Forwarder) newStream(id uint32, local net.Conn) *stream {
	s := &stream{
		id: id, f: f, local: local,
		in:    make(chan []byte, inDepth),
		inEOF: make(chan struct{}),
		done:  make(chan struct{}),
	}
	f.mu.Lock()
	f.streams[id] = s
	f.mu.Unlock()
	return s
}

// deliver is a record from the wire. The copy is not optional: the carrier
// owns the buffer it handed us and reuses it the moment this returns. The
// send blocks when the stream is backed up, which is the flow control - see
// the note on stream.in.
func (s *stream) deliver(b []byte) {
	c := make([]byte, len(b))
	copy(c, b)
	select {
	case s.in <- c:
	case <-s.done:
	case <-s.f.closing:
	}
}

func (s *stream) deliverEOF() { s.inOnce.Do(func() { close(s.inEOF) }) }

func (s *stream) kill() {
	s.doneOnce.Do(func() {
		close(s.done)
		if s.local != nil {
			_ = s.local.Close()
		}
		s.f.forget(s.id)
	})
}

// pumpOut reads the local socket and sends it across. record blocks when the
// carrier is backed up, so a fast local end cannot outrun the wire. It ends
// with a FIN, the local side having nothing more to say.
func (s *stream) pumpOut() {
	defer s.f.record(cmdFIN, s.id, nil)
	b := make([]byte, s.f.maxBody())
	for {
		n, err := s.local.Read(b)
		if n > 0 {
			if !s.f.record(cmdData, s.id, b[:n]) {
				s.kill()
				return
			}
		}
		if err != nil {
			return
		}
	}
}

// pumpIn writes what arrived into the local socket, in order, until the far
// end half-closes or the stream ends.
func (s *stream) pumpIn() {
	writeOne := func(b []byte) bool {
		if _, err := s.local.Write(b); err != nil {
			s.f.record(cmdRST, s.id, []byte("local write failed"))
			s.kill()
			return false
		}
		return true
	}
	for {
		select {
		case b := <-s.in:
			if !writeOne(b) {
				return
			}
		case <-s.inEOF:
			// Whatever is still queued is ordered before the FIN it follows.
			for {
				select {
				case b := <-s.in:
					if !writeOne(b) {
						return
					}
					continue
				default:
				}
				break
			}
			if cw, ok := s.local.(interface{ CloseWrite() error }); ok {
				_ = cw.CloseWrite()
			} else {
				s.kill()
			}
			return
		case <-s.done:
			return
		case <-s.f.closing:
			return
		}
	}
}

// run pumps both ways and takes the stream down when both are done.
func (s *stream) run() {
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); s.pumpOut() }()
	go func() { defer wg.Done(); s.pumpIn() }()
	wg.Wait()
	s.kill()
}

// bind takes one rule on the edge.
func (f *Forwarder) bind(r Rule) error {
	addr := net.JoinHostPort(f.cfg.Forward.BindAddr, strconv.Itoa(r.Port))
	if r.Proto == "udp" {
		pc, err := net.ListenPacket("udp", addr)
		if err != nil {
			return fmt.Errorf("udp/%d: %v", r.Port, err)
		}
		f.packets = append(f.packets, pc)
		go f.serveUDP(pc, r)
		logging.Info("forward udp/%d -> %s", r.Port, r.Target)
		return nil
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("tcp/%d: %v", r.Port, err)
	}
	f.listeners = append(f.listeners, ln)
	go f.serveTCP(ln, r)
	logging.Info("forward tcp/%d -> %s", r.Port, r.Target)
	return nil
}

func (f *Forwarder) serveTCP(ln net.Listener, r Rule) {
	for {
		c, err := ln.Accept()
		if err != nil {
			select {
			case <-f.closing:
			default:
				logging.Warn("tcp/%d: %v", r.Port, err)
			}
			return
		}
		go f.open(c, r)
	}
}

// open is a user's connection on the edge becoming a stream.
func (f *Forwarder) open(c net.Conn, r Rule) {
	if !f.car.Up() {
		atomic.AddUint64(&f.dropped, 1)
		_ = c.Close()
		return
	}
	if tc, ok := c.(*net.TCPConn); ok {
		_ = tc.SetNoDelay(true)
	}
	id := atomic.AddUint32(&f.nextID, 1) & 0x7fffffff
	s := f.newStream(id, c)
	if !f.record(cmdSYN, id, []byte(r.Target)) {
		s.kill()
		return
	}
	s.run()
}

// accept is a SYN arriving at the origin: dial the service it names.
func (f *Forwarder) accept(id uint32, target string) {
	if f.allow != nil && !f.allow[target] {
		atomic.AddUint64(&f.refused, 1)
		f.recordNB(cmdRST, id, []byte(target+": not in the allow list"))
		return
	}
	// The stream exists before the dial, not after it. The edge sends data
	// on the heels of its SYN, and anything that arrives while the service is
	// still being dialled has to queue on the stream - registered late, the
	// first fifty kilobytes of every connection were thrown away as records
	// for a stream nobody had heard of.
	s := f.newStream(id, nil)
	go func() {
		c, err := net.DialTimeout("tcp", target, dialWait)
		if err != nil {
			atomic.AddUint64(&f.refused, 1)
			f.record(cmdRST, id, []byte(target+": "+err.Error()))
			s.kill()
			return
		}
		select {
		case <-s.done:
			_ = c.Close()
			return
		default:
		}
		if tc, ok := c.(*net.TCPConn); ok {
			_ = tc.SetNoDelay(true)
		}
		s.local = c
		s.run()
	}()
}

// --- UDP sessions -------------------------------------------------------------

type udpSess struct {
	id  uint32
	f   *Forwarder
	pc  net.PacketConn // edge: the bound port, to answer the user on
	cli net.Addr       // edge: the user
	key string

	mu      sync.Mutex
	uc      *net.UDPConn // origin: the socket to the service
	pending [][]byte
	last    int64
}

func (f *Forwarder) serveUDP(pc net.PacketConn, r Rule) {
	b := make([]byte, 64*1024)
	for {
		n, addr, err := pc.ReadFrom(b)
		if err != nil {
			select {
			case <-f.closing:
			default:
				logging.Warn("udp/%d: %v", r.Port, err)
			}
			return
		}
		if n > f.maxBody() {
			atomic.AddUint64(&f.dropped, 1)
			continue
		}
		key := strconv.Itoa(r.Port) + "|" + addr.String()
		f.mu.Lock()
		s := f.udpEdge[key]
		if s == nil {
			id := (atomic.AddUint32(&f.udpSeq, 1) & 0x7fffffff) | udpIDBit
			s = &udpSess{id: id, f: f, pc: pc, cli: addr, key: key}
			f.udpEdge[key] = s
			f.udp[id] = s
			f.mu.Unlock()
			f.record(cmdUSYN, id, []byte(r.Target))
		} else {
			f.mu.Unlock()
		}
		atomic.StoreInt64(&s.last, time.Now().UnixNano())
		f.record(cmdUDP, s.id, b[:n])
	}
}

func (f *Forwarder) openUDP(id uint32, target string) {
	if f.allow != nil && !f.allow[target] {
		atomic.AddUint64(&f.refused, 1)
		f.recordNB(cmdUFIN, id, nil) // read path: must not block
		return
	}
	s := &udpSess{id: id, f: f}
	atomic.StoreInt64(&s.last, time.Now().UnixNano())
	f.mu.Lock()
	if f.udp[id] != nil {
		f.mu.Unlock()
		return
	}
	f.udp[id] = s
	f.mu.Unlock()
	go func() {
		ua, err := net.ResolveUDPAddr("udp", target)
		if err != nil {
			f.dropUDP(s, true)
			return
		}
		uc, err := net.DialUDP("udp", nil, ua)
		if err != nil {
			f.dropUDP(s, true)
			return
		}
		s.ready(uc)
		b := make([]byte, 64*1024)
		for {
			_ = uc.SetReadDeadline(time.Now().Add(udpIdle))
			n, err := uc.Read(b)
			if n > 0 && n <= f.maxBody() {
				atomic.StoreInt64(&s.last, time.Now().UnixNano())
				f.record(cmdUDP, id, b[:n])
			}
			if err != nil {
				f.dropUDP(s, true)
				return
			}
		}
	}()
}

// deliver is a datagram from the wire: to the user on the edge, to the
// service at the origin - queued, briefly, while the service is being dialled,
// because losing the first datagram of an exchange is usually losing the
// exchange.
func (s *udpSess) deliver(b []byte) {
	atomic.StoreInt64(&s.last, time.Now().UnixNano())
	if s.pc != nil {
		_, _ = s.pc.WriteTo(b, s.cli)
		return
	}
	s.mu.Lock()
	if s.uc == nil {
		if len(s.pending) < 8 {
			c := make([]byte, len(b))
			copy(c, b)
			s.pending = append(s.pending, c)
		}
		s.mu.Unlock()
		return
	}
	uc := s.uc
	s.mu.Unlock()
	_, _ = uc.Write(b)
}

func (s *udpSess) ready(uc *net.UDPConn) {
	s.mu.Lock()
	s.uc = uc
	p := s.pending
	s.pending = nil
	s.mu.Unlock()
	for _, b := range p {
		_, _ = uc.Write(b)
	}
}

func (f *Forwarder) dropUDP(s *udpSess, tell bool) {
	f.mu.Lock()
	delete(f.udp, s.id)
	if s.key != "" {
		delete(f.udpEdge, s.key)
	}
	f.mu.Unlock()
	s.mu.Lock()
	if s.uc != nil {
		_ = s.uc.Close()
	}
	s.mu.Unlock()
	if tell {
		f.record(cmdUFIN, s.id, nil)
	}
}

func (f *Forwarder) reapUDP() {
	tk := time.NewTicker(udpIdle / 3)
	defer tk.Stop()
	for {
		select {
		case <-f.closing:
			return
		case <-tk.C:
			cut := time.Now().Add(-udpIdle).UnixNano()
			var old []*udpSess
			f.mu.Lock()
			for _, s := range f.udp {
				if atomic.LoadInt64(&s.last) < cut {
					old = append(old, s)
				}
			}
			f.mu.Unlock()
			for _, s := range old {
				f.dropUDP(s, true)
			}
		}
	}
}
