package carrier

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"pingify/internal/buf"
	"pingify/internal/config"
	"pingify/internal/logging"
)

// The carrier every stream transport is built out of: TCP, WebSocket, and
// WebSocket inside TLS. They differ in how a connection is opened and how a
// datagram is marked out on it, and in nothing else, so those two things are
// arguments here and the rest of the file is shared.
//
// Several connections, and that is the whole design. Written with one it
// carried 6 Mbit/s on a path that carries seven hundred. iperf3 between the
// same two servers, with no tunnel anywhere near it:
//
//	one TCP connection      0.39 Mbit/s
//	sixteen connections     743 Mbit/s
//
// A single flow is shaped to nothing on this path and sixteen together are
// not shaped at all. Nothing inside a carrier could have fixed that; only
// more flows fixes it. This is what the old core called "carriers".
//
// The other cost, said once: TCP inside TCP. The tunnel's own retransmit
// timer and the timer of every connection running through it are two control
// loops on one wire, and when the path drops a packet they both react - the
// inner one to a loss the outer one is already repairing. That is why UDP and
// ICMP come first. A stream is for the path that carries nothing else.
const (
	streamMaxFrame = 2048 // an IP packet, the tun's headroom and ours

	streamRedialMin = 500 * time.Millisecond
	streamRedialMax = 8 * time.Second
	streamDialWait  = 15 * time.Second
)

// framing is how whole datagrams are marked out on a stream. One per
// connection, because a WebSocket client keeps a mask key per connection.
type framing interface {
	// headroom is how many bytes it needs in front of a payload.
	headroom() int

	// wrap is handed the whole buffer - headroom and payload - and returns
	// the bytes to write, which is the header it just built followed by the
	// payload. The header ends where the payload begins, so nothing is
	// copied and nothing is shifted along.
	wrap(b []byte) []byte

	// next takes the next whole datagram off the reader into dst, and
	// returns how much of dst it filled. A datagram of zero length is
	// possible and is not the end of anything.
	next(r *bufio.Reader, dst []byte) (int, error)
}

// One connection, its framing, and the lock that keeps two writers from
// interleaving frames on it. Interleaved halves are not a frame either end
// can read.
type streamLink struct {
	c   net.Conn
	fm  framing
	mu  sync.Mutex
	seq uint64 // when it was accepted, so the oldest can be found
}

type streamCarrier struct {
	cfg  *config.Config
	fr   *framer
	kind string // for log lines: tcp, ws, wss

	// dial opens one connection from the side that dials, already upgraded
	// and ready to carry frames. accept does the same to a connection that
	// arrived. Either may be nil, which means a plain TCP connection.
	dial   func() (net.Conn, framing, error)
	accept func(net.Conn) (net.Conn, framing, error)

	ln net.Listener

	// A fixed set of slots rather than a growing slice: the size is decided
	// once from the config, both ends open the same number, and an empty slot
	// is a connection being redialled rather than a hole to grow around.
	links []atomic.Pointer[streamLink]
	spare atomic.Uint32 // round robin, for when the chosen slot is down

	head     int // the largest headroom any framing here will need
	onPacket atomic.Pointer[func([]byte)]

	done chan struct{}
	once sync.Once

	rxBytes, txBytes uint64
	sendErrs         uint64
}

// listenAddr is where the side that waits binds. It is not always the port a
// tunnel names: behind a CDN the dialling side asks for a port on the CDN's
// edge, and the edge connects to this origin on a port of its own choosing.
func newStreamCarrier(cfg *config.Config, kind string, head int) (*streamCarrier, error) {
	n := cfg.Transport.Connections
	c := &streamCarrier{
		cfg:   cfg,
		fr:    newStreamFramer(cfg.Token, "pingify "+kind+" v1"),
		kind:  kind,
		links: make([]atomic.Pointer[streamLink], n),
		head:  head,
		done:  make(chan struct{}),
	}
	if cfg.Dials() {
		smoothTheWire(cfg)
		return c, nil
	}
	ln, err := net.Listen("tcp4", fmt.Sprintf(":%d", cfg.ListenPort()))
	if err != nil {
		return nil, fmt.Errorf("listen on tcp/%d: %v", cfg.ListenPort(), err)
	}
	c.ln = ln
	smoothTheWire(cfg)
	logging.Info("carrier: waiting on %s/%d, up to %d connections",
		kind, cfg.ListenPort(), n)
	return c, nil
}

// prep sets the two things that matter on the socket, and deliberately does
// not set a third.
//
// Nagle has to go: it holds a small write back for up to forty milliseconds
// hoping for company, and every write here is already a whole packet that
// somebody is waiting for at the other end.
//
// What is not set is the socket buffers. Every datagram carrier here sets them
// by hand, and on TCP that is the wrong move - naming a size turns off the
// kernel's receive window auto-tuning, and this path needs a window of about
// four megabytes to fill four hundred megabits at eighty milliseconds. The
// auto-tuned maximum covers that; a hand-set buffer would cap it.
func prepStream(c net.Conn) {
	tc, ok := c.(*net.TCPConn)
	if !ok {
		return
	}
	_ = tc.SetNoDelay(true)
	_ = tc.SetKeepAlive(true)
	_ = tc.SetKeepAlivePeriod(30 * time.Second)
}

func (c *streamCarrier) Headroom() int   { return c.head + c.fr.headroom() }
func (c *streamCarrier) MaxPayload() int { return streamMaxFrame - c.Headroom() }
func (c *streamCarrier) Burst() int      { return 1 }

// Up is stronger here than on a datagram carrier. A connection exists only
// because something at the other end accepted it, so even on the side that
// dials this is not "we know where to send" but "somebody was there".
func (c *streamCarrier) Up() bool { return c.pick(0) != nil }

func (c *streamCarrier) OnPacket(f func([]byte)) { c.onPacket.Store(&f) }

type streamSender struct{ c *streamCarrier }

func (c *streamCarrier) NewSender() Sender { return &streamSender{c: c} }

func (s *streamSender) Send(bps []*[]byte) {
	for _, bp := range bps {
		_ = s.c.Send(bp)
	}
}

// flowOf picks the connection a packet belongs on, from the packet itself.
//
// Every packet of one conversation goes down the same connection, so nothing
// inside the tunnel ever sees its own packets arrive out of order. Spraying
// them round-robin instead would be faster to write and would make every TCP
// connection inside the tunnel think the path was reordering - which they
// answer with duplicate acknowledgements and a needless retransmit.
//
// Addresses and ports, and nothing cleverer: this is IPv4 out of a tun device,
// so the source and destination are at a fixed offset, and the ports follow
// the header when the protocol has them.
func flowOf(p []byte) uint32 {
	if len(p) < 20 || p[0]>>4 != 4 {
		return 0
	}
	h := uint32(2166136261)
	mix := func(b []byte) {
		for _, x := range b {
			h ^= uint32(x)
			h *= 16777619
		}
	}
	mix(p[12:20]) // source and destination address
	mix(p[9:10])  // protocol
	ihl := int(p[0]&0x0f) * 4
	if (p[9] == 6 || p[9] == 17) && len(p) >= ihl+4 {
		mix(p[ihl : ihl+4]) // both ports
	}
	return h
}

// pick returns the connection for a flow, or any live one if that slot is
// down. A packet on the wrong connection is better than a packet dropped:
// what it costs is being out of order with the rest of its flow, once, while
// a slot redials.
func (c *streamCarrier) pick(flow uint32) *streamLink {
	n := uint32(len(c.links))
	if n == 0 {
		return nil
	}
	if l := c.links[flow%n].Load(); l != nil {
		return l
	}
	start := c.spare.Add(1)
	for i := uint32(0); i < n; i++ {
		if l := c.links[(start+i)%n].Load(); l != nil {
			return l
		}
	}
	return nil
}

func (c *streamCarrier) Send(bp *[]byte) error {
	b := *bp
	if len(b) < c.Headroom() {
		buf.Put(bp)
		return nil
	}
	l := c.pick(flowOf(b[c.Headroom():]))
	if l == nil {
		buf.Put(bp)
		return ErrNoPeer
	}
	return c.sendOn(l, bp)
}

func (c *streamCarrier) sendOn(l *streamLink, bp *[]byte) error {
	b := *bp
	// The framing owns the bytes in front of the tag, and the tag covers
	// everything from there to the end. Seal first, then let the framing
	// build its header up against it.
	c.fr.seal(b[c.head:])

	l.mu.Lock()
	n, err := l.c.Write(l.fm.wrap(b))
	l.mu.Unlock()

	buf.Put(bp)
	if err != nil {
		atomic.AddUint64(&c.sendErrs, 1)
		// Not logged and not retried. The reader on this connection is about
		// to see the same failure, and it is the one that redials.
		return err
	}
	atomic.AddUint64(&c.txBytes, uint64(n))
	return nil
}

func (c *streamCarrier) Run() {
	if c.cfg.Dials() {
		for i := range c.links {
			go c.dialForever(i)
		}
		<-c.done
		return
	}
	c.acceptForever()
}

// dialForever keeps one slot filled. It dials, reads until the connection
// ends, and dials again - backing off so that a server that is down does not
// get eight connection attempts every half second all night, and resetting
// the backoff the moment one succeeds.
//
// Only the first slot says anything about a failure. Eight slots failing the
// same way is one fact, and printing it eight times buries the next one.
func (c *streamCarrier) dialForever(slot int) {
	wait := streamRedialMin
	for {
		select {
		case <-c.done:
			return
		default:
		}

		nc, fm, err := c.dial()
		if err != nil {
			select {
			case <-c.done:
				return
			default:
			}
			if slot == 0 {
				logging.Warn("carrier: %v - again in %s", err, wait)
			}
			select {
			case <-c.done:
				return
			case <-time.After(wait):
			}
			if wait *= 2; wait > streamRedialMax {
				wait = streamRedialMax
			}
			continue
		}
		wait = streamRedialMin

		l := &streamLink{c: nc, fm: fm, seq: uint64(slot)}
		c.links[slot].Store(l)
		if slot == 0 {
			logging.Info("carrier: connected over %s", c.kind)
		}
		logging.Debug("carrier: connection %d up", slot)

		c.read(l)
		c.links[slot].CompareAndSwap(l, nil)
		_ = nc.Close()
		logging.Debug("carrier: connection %d dropped", slot)
	}
}

// acceptForever is the side that waits. It fills empty slots first, and when
// they are all full the oldest is replaced - because a full slot may hold a
// socket nobody has noticed is dead yet, and the connection being offered now
// is one the other end has just decided it needs.
func (c *streamCarrier) acceptForever() {
	var seq uint64
	for {
		nc, err := c.ln.Accept()
		if err != nil {
			select {
			case <-c.done:
			default:
				logging.Warn("%s accept: %v", c.kind, err)
			}
			return
		}
		go c.take(nc, atomic.AddUint64(&seq, 1))
	}
}

// take upgrades one accepted connection and puts it in a slot.
//
// On its own goroutine, because the upgrade reads from the connection - a
// WebSocket handshake, a TLS handshake - and one silent client would
// otherwise hold up every connection behind it.
func (c *streamCarrier) take(nc net.Conn, seq uint64) {
	prepStream(nc)
	_ = nc.SetDeadline(time.Now().Add(streamDialWait))
	up, fm, err := c.accept(nc)
	if err != nil {
		logging.Debug("carrier: refused a connection from %s: %v", nc.RemoteAddr(), err)
		_ = nc.Close()
		return
	}
	_ = nc.SetDeadline(time.Time{})

	l := &streamLink{c: up, fm: fm, seq: seq}
	slot := -1
	for i := range c.links {
		if c.links[i].Load() == nil {
			slot = i
			break
		}
	}
	if slot < 0 {
		oldest := ^uint64(0)
		slot = 0
		for i := range c.links {
			if p := c.links[i].Load(); p != nil && p.seq < oldest {
				oldest, slot = p.seq, i
			}
		}
	}
	if old := c.links[slot].Swap(l); old != nil {
		_ = old.c.Close()
	}
	if seq == 1 {
		logging.Info("carrier: the far end is at %s", nc.RemoteAddr())
	}
	logging.Debug("carrier: connection %d from %s", slot, nc.RemoteAddr())

	c.read(l)
	c.links[slot].CompareAndSwap(l, nil)
	_ = up.Close()
}

// read takes whole datagrams off one connection until it ends.
//
// The buffer under the reader is what makes this cheap: without it every
// length would be its own read syscall, which on a four hundred megabit
// stream is a syscall for every eight hundred bytes carried.
func (c *streamCarrier) read(l *streamLink) {
	r := bufio.NewReaderSize(l.c, 256*1024)
	body := make([]byte, streamMaxFrame)

	for {
		n, err := l.fm.next(r, body)
		if err != nil {
			c.readEnded(err)
			return
		}
		c.handle(body[:n])
	}
}

func (c *streamCarrier) readEnded(err error) {
	select {
	case <-c.done:
		return
	default:
	}
	if err == io.EOF {
		logging.Debug("carrier: a connection was closed by the far end")
		return
	}
	logging.Debug("%s read: %v", c.kind, err)
}

func (c *streamCarrier) handle(b []byte) {
	body, ok := c.fr.open(b)
	if !ok {
		return
	}
	atomic.AddUint64(&c.rxBytes, uint64(len(b)))
	if len(body) == 0 {
		return // a keepalive, which has done its whole job by arriving
	}
	if f := c.onPacket.Load(); f != nil {
		(*f)(body)
	}
}

// Keepalive touches every connection, not one of them.
//
// An idle connection is one some middlebox on the way has quietly forgotten,
// and neither end finds out until the next packet disappears into it. With
// eight of them, seven can be forgotten while the eighth carries all the
// traffic and looks perfectly healthy.
func (c *streamCarrier) Keepalive(every time.Duration) {
	tk := time.NewTicker(every)
	defer tk.Stop()
	for {
		select {
		case <-c.done:
			return
		case <-tk.C:
			for i := range c.links {
				l := c.links[i].Load()
				if l == nil {
					continue
				}
				bp := buf.Take(c.Headroom(), 0)
				if err := c.sendOn(l, bp); err != nil {
					logging.Debug("keepalive on connection %d: %v", i, err)
				}
			}
		}
	}
}

func (c *streamCarrier) Close() error {
	c.once.Do(func() { close(c.done) })
	if c.ln != nil {
		_ = c.ln.Close()
	}
	for i := range c.links {
		if l := c.links[i].Swap(nil); l != nil {
			_ = l.c.Close()
		}
	}
	return nil
}

func (c *streamCarrier) Lost() (missing, late, gaps uint64) { return c.fr.lost() }

func (c *streamCarrier) Counters() (rx, tx, bad, replay, errs uint64) {
	bad, replay = c.fr.counted()
	return atomic.LoadUint64(&c.rxBytes), atomic.LoadUint64(&c.txBytes),
		bad, replay, atomic.LoadUint64(&c.sendErrs)
}
