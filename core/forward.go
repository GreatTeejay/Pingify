package main

import (
	"fmt"
	"net"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

// ==========================================================================
// 6. forward mode - TCP/UDP port forwarding
// ==========================================================================

// forward mode: the edge owns the user-facing ports and the origin owns the
// real services. Everything in between rides the carrier pool.

const (
	udpIDBit    = 0x80000000
	udpIdleSec  = 90
	udpReadSize = 64 * 1024
)

type sessKey struct {
	l  *link
	id uint32
}

type udpSess struct {
	l   *link
	id  uint32
	pc  net.PacketConn
	cli net.Addr // edge side: where the client's datagrams came from
	key string   // edge side: map key

	// The origin dials the real service off the carrier's read loop, so that
	// a slow DNS lookup cannot stall every other stream on that carrier.
	// Datagrams that arrive while the dial is in flight wait here instead of
	// being dropped - losing the first packet of a UDP exchange would often
	// mean losing the whole exchange.
	mu      sync.Mutex
	uc      *net.UDPConn
	pending [][]byte
	dialed  bool

	last int64
}

const udpPendingMax = 8

// deliver hands one datagram to the real service, queueing it if the socket is
// not ready yet.
func (s *udpSess) deliver(b []byte) {
	s.mu.Lock()
	if s.uc != nil {
		uc := s.uc
		s.mu.Unlock()
		uc.Write(b)
		return
	}
	if !s.dialed && len(s.pending) < udpPendingMax {
		s.pending = append(s.pending, append([]byte(nil), b...))
	}
	s.mu.Unlock()
}

// ready installs the dialled socket and flushes whatever queued up.
func (s *udpSess) ready(uc *net.UDPConn) {
	s.mu.Lock()
	s.uc = uc
	s.dialed = true
	q := s.pending
	s.pending = nil
	s.mu.Unlock()
	for _, b := range q {
		uc.Write(b)
	}
}

func (s *udpSess) socket() *net.UDPConn {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.uc
}

type forwarder struct {
	cfg *Config
	p   *pool

	listeners []net.Listener
	packets   []net.PacketConn

	mu    sync.Mutex
	edge  map[string]*udpSess  // edge: "lport|clientaddr" -> session
	byID  map[sessKey]*udpSess // both sides: (carrier, id) -> session
	udpSq uint32

	allow  map[string]bool
	closed chan struct{}
	once   sync.Once

	// Refused streams, and how many of those the log had reported the last
	// time it said anything. See noteRefusal.
	refused     uint64
	refusedSaid uint64

	// The same, for connections dropped because nothing was up to carry
	// them. See noteNoCarrier.
	dropped     uint64
	droppedSaid uint64
}

func startForward(cfg *Config, p *pool) (*forwarder, error) {
	f := &forwarder{
		cfg:    cfg,
		p:      p,
		edge:   make(map[string]*udpSess),
		byID:   make(map[sessKey]*udpSess),
		closed: make(chan struct{}),
	}
	if len(cfg.Allow) > 0 {
		f.allow = make(map[string]bool, len(cfg.Allow))
		for _, a := range cfg.Allow {
			f.allow[a] = true
		}
	}
	p.setHandler(f)

	if cfg.Role == "server" {
		for _, spec := range cfg.Forwards {
			rules, err := parseForward(spec)
			if err != nil {
				f.Close()
				return nil, err
			}
			for _, r := range rules {
				if err := f.bind(r); err != nil {
					f.Close()
					return nil, err
				}
			}
		}
	}
	go f.reapUDP()
	return f, nil
}

func (f *forwarder) bind(r fwdRule) error {
	addr := net.JoinHostPort(f.cfg.BindAddr, strconv.Itoa(r.lport))
	if r.proto == "udp" {
		pc, err := net.ListenPacket("udp", addr)
		if err != nil {
			return fmt.Errorf("listen udp %s: %v", addr, err)
		}
		f.packets = append(f.packets, pc)
		go f.serveUDP(pc, r)
		logInfo("forward udp %s -> %s", addr, r.target)
		return nil
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("listen tcp %s: %v", addr, err)
	}
	f.listeners = append(f.listeners, ln)
	go f.serveTCP(ln, r)
	logInfo("forward tcp %s -> %s", addr, r.target)
	return nil
}

// ---------------------------------------------------------------------------
// edge: TCP
// ---------------------------------------------------------------------------

func (f *forwarder) serveTCP(ln net.Listener, r fwdRule) {
	for {
		c, err := ln.Accept()
		if err != nil {
			select {
			case <-f.closed:
				return
			default:
			}
			logWarn("accept :%d: %v", r.lport, err)
			time.Sleep(100 * time.Millisecond)
			continue
		}
		go f.openStream(c, r)
	}
}

// openStream carries one user connection across the braid.
//
// If the carrier it picked cannot take the opening record, another is tried.
// It used to give up there and close the user's connection, which is the one
// thing a braid exists to avoid: a carrier can die between being chosen and
// being written to, and one dead carrier out of eight was taking a share of
// everybody's connections down with it rather than being routed around.
func (f *forwarder) openStream(c net.Conn, r fwdRule) {
	tuneSocket(c, f.cfg)
	// As many attempts as there are carriers, so a connection is only given up
	// on when the braid as a whole has nothing to offer.
	for try := 0; try < maxCarriers; try++ {
		l := f.p.pick()
		if l == nil {
			break
		}
		s := l.newStream(c)
		if l.send(ctrlRec(cmdSYN, s.id, []byte(r.target))) {
			go s.pumpIn(c)
			s.pumpOut(c)
			return
		}
		// That carrier is gone. Take the stream off it and ask the pool for
		// another - reset() would close the user's connection, which is the
		// thing being rescued.
		l.removeStream(s.id)
	}
	f.noteNoCarrier(r.lport)
	c.Close()
}

// ---------------------------------------------------------------------------
// edge: UDP
// ---------------------------------------------------------------------------

func (f *forwarder) serveUDP(pc net.PacketConn, r fwdRule) {
	buf := make([]byte, udpReadSize)
	for {
		n, addr, err := pc.ReadFrom(buf)
		if err != nil {
			select {
			case <-f.closed:
				return
			default:
			}
			logWarn("udp read :%d: %v", r.lport, err)
			return
		}
		if n > maxRecord {
			continue
		}
		key := strconv.Itoa(r.lport) + "|" + addr.String()
		f.mu.Lock()
		s := f.edge[key]
		if s == nil {
			l := f.p.pickHash(hash5([]byte(key)))
			if l == nil {
				f.mu.Unlock()
				continue
			}
			id := (atomic.AddUint32(&f.udpSq, 1) & 0x7fffffff) | udpIDBit
			s = &udpSess{l: l, id: id, pc: pc, cli: addr, key: key}
			f.edge[key] = s
			f.byID[sessKey{l, id}] = s
			f.mu.Unlock()
			l.send(ctrlRec(cmdUSYN, id, []byte(r.target)))
		} else {
			f.mu.Unlock()
		}
		atomic.StoreInt64(&s.last, time.Now().UnixNano())
		if !s.l.alive() {
			f.dropUDP(s)
			continue
		}
		atomic.AddUint64(&s.l.txBytes, uint64(n))
		s.l.send(ctrlRec(cmdUDP, s.id, buf[:n]))
	}
}

// ---------------------------------------------------------------------------
// origin: incoming records
// ---------------------------------------------------------------------------

func (f *forwarder) onRecord(l *link, cmd byte, id uint32, body []byte) {
	switch cmd {
	case cmdSYN:
		// Register before dialling: the data records for this stream are
		// usually already in flight behind the SYN.
		s := l.acceptStream(id, nil)
		if s == nil {
			return
		}
		go f.dialTCP(s, string(body))
	case cmdUSYN:
		f.openUDP(l, id, string(body))
	case cmdUDP:
		f.mu.Lock()
		s := f.byID[sessKey{l, id}]
		f.mu.Unlock()
		if s == nil {
			return
		}
		atomic.StoreInt64(&s.last, time.Now().UnixNano())
		atomic.AddUint64(&l.rxBytes, uint64(len(body)))
		if s.pc != nil {
			s.pc.WriteTo(body, s.cli) // edge -> the user
		} else {
			s.deliver(body) // origin -> the real service
		}
	case cmdUFIN:
		f.mu.Lock()
		s := f.byID[sessKey{l, id}]
		f.mu.Unlock()
		if s != nil {
			f.dropUDP(s)
		}
	}
}

// noteRefusal says a stream could not be made, at most once a minute, with a
// count of the ones it stood for.
//
// The reason still travels back to the other server on every single one -
// that is what tells an operator over there that the service is down rather
// than the tunnel. What is rationed is this server's own log, because a
// target that is down refuses every connection there is, and a line per
// connection is thousands a minute into a journal that then stops keeping up
// with anything else.
// noteNoCarrier says the tunnel is down and connections are being dropped, at
// most once a minute, with a count of the ones it stood for.
//
// A tunnel that is down is precisely the state a client retries hardest in, so
// the line that appears thousands of times a minute is the one that says
// nothing - and it lands on top of the handful that say WHY it went down,
// which are the only ones worth reading when it is down. Field logs came back
// as page after page of this with the reason nowhere in them. The volume has
// to follow the clock, which is the rule the carrier count and the refusals
// below already keep.
func (f *forwarder) noteNoCarrier(lport int) {
	if f.p == nil {
		logWarn("no carrier up, dropping connection to :%d", lport)
		return
	}
	n := atomic.AddUint64(&f.dropped, 1)
	if !f.p.firstIn("no-carrier", time.Minute) {
		return
	}
	quiet := n - atomic.SwapUint64(&f.droppedSaid, n)
	if quiet > 1 {
		logWarn("no carrier up, dropping connection to :%d (and %d more since the last time this said so)",
			lport, quiet-1)
		return
	}
	logWarn("no carrier up, dropping connection to :%d", lport)
}

func (f *forwarder) noteRefusal(target, why string) {
	if f.p == nil {
		logWarn("stream to %s: %s", target, why)
		return
	}
	n := atomic.AddUint64(&f.refused, 1)
	if !f.p.firstIn("stream-refused", time.Minute) {
		return
	}
	quiet := n - atomic.SwapUint64(&f.refusedSaid, n)
	if quiet > 1 {
		logWarn("stream to %s: %s (and %d more since the last time this said so)", target, why, quiet-1)
		return
	}
	logWarn("stream to %s: %s", target, why)
}

func (f *forwarder) targetAllowed(target string) bool {
	if f.allow == nil {
		return true
	}
	return f.allow[target]
}

func (f *forwarder) dialTCP(s *stream, target string) {
	// The reason travels back with the reset. Without it the other server
	// closes the user's connection with nothing to say, and "the tunnel does
	// not work" is indistinguishable from "the service is not running here".
	refuse := func(why string) {
		f.noteRefusal(target, why)
		s.l.send(ctrlRec(cmdRST, s.id, []byte(target+": "+why)))
		s.reset()
	}
	if !f.targetAllowed(target) {
		refuse("not in allow list")
		return
	}
	c, err := net.DialTimeout("tcp", target, time.Duration(f.cfg.DialTimeout)*time.Second)
	if err != nil {
		refuse(err.Error())
		return
	}
	tuneSocket(c, f.cfg)
	if !s.attach(c) {
		c.Close()
		return
	}
	go s.pumpIn(c)
	s.pumpOut(c)
}

// openUDP registers the session immediately - so datagrams following the USYN
// find it - and dials in the background.
func (f *forwarder) openUDP(l *link, id uint32, target string) {
	if !f.targetAllowed(target) {
		l.send(ctrlRec(cmdUFIN, id, nil))
		return
	}
	s := &udpSess{l: l, id: id}
	atomic.StoreInt64(&s.last, time.Now().UnixNano())
	f.mu.Lock()
	if old := f.byID[sessKey{l, id}]; old != nil {
		f.mu.Unlock()
		return
	}
	f.byID[sessKey{l, id}] = s
	f.mu.Unlock()

	go func() {
		ua, err := net.ResolveUDPAddr("udp", target)
		if err != nil {
			logWarn("resolve udp %s: %v", target, err)
			f.dropUDP(s)
			return
		}
		uc, err := net.DialUDP("udp", nil, ua)
		if err != nil {
			logWarn("dial udp %s: %v", target, err)
			f.dropUDP(s)
			return
		}
		s.ready(uc)

		buf := make([]byte, udpReadSize)
		for {
			uc.SetReadDeadline(time.Now().Add(udpIdleSec * time.Second))
			n, err := uc.Read(buf)
			if n > 0 && n <= maxRecord {
				atomic.StoreInt64(&s.last, time.Now().UnixNano())
				atomic.AddUint64(&l.txBytes, uint64(n))
				if !l.send(ctrlRec(cmdUDP, id, buf[:n])) {
					break
				}
			}
			if err != nil {
				break
			}
		}
		f.dropUDP(s)
	}()
}

func (f *forwarder) dropUDP(s *udpSess) {
	f.mu.Lock()
	if f.byID[sessKey{s.l, s.id}] != s {
		f.mu.Unlock()
		return
	}
	delete(f.byID, sessKey{s.l, s.id})
	if s.key != "" {
		delete(f.edge, s.key)
	}
	f.mu.Unlock()
	if uc := s.socket(); uc != nil {
		uc.Close()
	}
	if s.l.alive() {
		s.l.send(ctrlRec(cmdUFIN, s.id, nil))
	}
}

func (f *forwarder) reapUDP() {
	t := time.NewTicker(30 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-t.C:
		case <-f.closed:
			return
		}
		cut := time.Now().Add(-udpIdleSec * time.Second).UnixNano()
		var dead []*udpSess
		f.mu.Lock()
		for _, s := range f.byID {
			if atomic.LoadInt64(&s.last) < cut || !s.l.alive() {
				dead = append(dead, s)
			}
		}
		f.mu.Unlock()
		for _, s := range dead {
			f.dropUDP(s)
		}
	}
}

func (f *forwarder) onLinkDown(l *link) {
	var dead []*udpSess
	f.mu.Lock()
	for k, s := range f.byID {
		if k.l == l {
			dead = append(dead, s)
		}
	}
	f.mu.Unlock()
	for _, s := range dead {
		f.dropUDP(s)
	}
}

func (f *forwarder) Close() error {
	f.once.Do(func() {
		close(f.closed)
		for _, ln := range f.listeners {
			ln.Close()
		}
		for _, pc := range f.packets {
			pc.Close()
		}
	})
	return nil
}
