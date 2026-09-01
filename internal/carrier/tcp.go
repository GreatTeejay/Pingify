package carrier

import (
	"bufio"
	"encoding/binary"
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

// TCP: the same framed datagram as every other carrier here, with two bytes
// of length in front of it, spread over several connections that come back
// when they drop.
//
// Several, and that is the whole design. One connection was the obvious way
// to write this and it carried 6 Mbit/s on a path that carries seven hundred.
// iperf3 between the same two servers, with no tunnel anywhere near it:
//
//	one TCP connection      0.39 Mbit/s
//	sixteen connections     743 Mbit/s
//
// A single flow is shaped to nothing on this path and sixteen together are
// not shaped at all. Nothing in the carrier could have fixed that; only more
// flows fixes it. This is what the old core called "carriers" and it is the
// reason a stream transport is worth having here at all.
//
// The other cost, said once: TCP inside TCP. The tunnel's own retransmit
// timer and the timer of every connection running through it are two control
// loops on one wire, and when the path drops a packet they both react - the
// inner one to a loss the outer one is already repairing. That is why UDP and
// ICMP come first. TCP is for the path that carries nothing else.
//
// Two bytes of length, not a delimiter and not a fixed size. What comes off a
// stream is whatever the kernel had when it was asked, and a carrier that
// hands whole datagrams upward has to know where each one ends. A length this
// side did not write is a stream that cannot be resynchronised, so the
// connection goes rather than the frame.
const (
	tcpLenLen   = 2
	tcpMaxFrame = 2048 // an IP packet, the tun's headroom and ours

	tcpRedialMin = 500 * time.Millisecond
	tcpRedialMax = 8 * time.Second
	tcpDialWait  = 10 * time.Second
)

// One connection and the lock that keeps two writers from interleaving frames
// on it. Interleaved halves are not a frame either end can read.
type tcpLink struct {
	tc  *net.TCPConn
	mu  sync.Mutex
	seq uint64 // which slot it was accepted into, for the log line
}

type tcpCarrier struct {
	cfg *config.Config
	fr  *framer

	ln net.Listener

	// A fixed set of slots rather than a growing slice: the size is decided
	// once from the config, both ends open the same number, and a slot that
	// is empty is a connection being redialled rather than a hole to grow
	// around.
	links []atomic.Pointer[tcpLink]
	spare atomic.Uint32 // round robin, for when the chosen slot is down

	onPacket atomic.Pointer[func([]byte)]

	done chan struct{}
	once sync.Once

	rxBytes, txBytes uint64
	sendErrs         uint64
}

func newTCPCarrier(cfg *config.Config) (*tcpCarrier, error) {
	n := cfg.Transport.Connections
	c := &tcpCarrier{
		cfg:   cfg,
		fr:    newStreamFramer(cfg.Token, "pingify tcp v1"),
		links: make([]atomic.Pointer[tcpLink], n),
		done:  make(chan struct{}),
	}

	// Iran dials out, so there is nothing to open here: Run does the dialling,
	// once per slot, and does it again every time one drops.
	if cfg.Dials() {
		smoothTheWire(cfg)
		logging.Info("carrier: dialling %s:%d over tcp, %d connections",
			cfg.Transport.Kharej, cfg.Transport.Port, n)
		return c, nil
	}

	ln, err := net.Listen("tcp4", fmt.Sprintf(":%d", cfg.Transport.Port))
	if err != nil {
		return nil, fmt.Errorf("listen on tcp/%d: %v", cfg.Transport.Port, err)
	}
	c.ln = ln
	smoothTheWire(cfg)
	logging.Info("carrier: waiting on tcp/%d, up to %d connections",
		cfg.Transport.Port, n)
	return c, nil
}

// prep sets the two things that matter on the socket, and deliberately does
// not set a third.
//
// Nagle has to go: it holds a small write back for up to forty milliseconds
// hoping for company, and every write here is already a whole packet that
// somebody is waiting for at the other end.
//
// What is not set is the socket buffers. Every other carrier here sets them by
// hand, and on TCP that is the wrong move - naming a size turns off the
// kernel's receive window auto-tuning, and this path needs a window of about
// four megabytes to fill four hundred megabits at eighty milliseconds. The
// auto-tuned maximum covers that; a hand-set buffer would cap it.
func (c *tcpCarrier) prep(tc *net.TCPConn) {
	_ = tc.SetNoDelay(true)
	_ = tc.SetKeepAlive(true)
	_ = tc.SetKeepAlivePeriod(30 * time.Second)
}

// Headroom covers the length as well as the frame, so that a packet is built
// once and written once: no second write for the length, and no copy to make
// room for it.
func (c *tcpCarrier) Headroom() int   { return tcpLenLen + c.fr.headroom() }
func (c *tcpCarrier) MaxPayload() int { return tcpMaxFrame - c.Headroom() }
func (c *tcpCarrier) Burst() int      { return 1 }

// Up is stronger here than on a datagram carrier. A TCP connection exists only
// because something at the other end accepted it, so even on the side that
// dials this is not "we know where to send" but "somebody was there".
func (c *tcpCarrier) Up() bool { return c.pick(0) != nil }

func (c *tcpCarrier) OnPacket(f func([]byte)) { c.onPacket.Store(&f) }

type tcpSender struct{ c *tcpCarrier }

func (c *tcpCarrier) NewSender() Sender { return &tcpSender{c: c} }

func (s *tcpSender) Send(bps []*[]byte) {
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
func (c *tcpCarrier) pick(flow uint32) *tcpLink {
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

func (c *tcpCarrier) Send(bp *[]byte) error {
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

func (c *tcpCarrier) sendOn(l *tcpLink, bp *[]byte) error {
	b := *bp
	body := b[tcpLenLen:]
	c.fr.seal(body)
	binary.BigEndian.PutUint16(b[:tcpLenLen], uint16(len(body)))

	l.mu.Lock()
	n, err := l.tc.Write(b)
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

func (c *tcpCarrier) Run() {
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
func (c *tcpCarrier) dialForever(slot int) {
	addr := net.JoinHostPort(c.cfg.Transport.Kharej, fmt.Sprint(c.cfg.Transport.Port))
	wait := tcpRedialMin
	for {
		select {
		case <-c.done:
			return
		default:
		}

		nc, err := net.DialTimeout("tcp4", addr, tcpDialWait)
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
			if wait *= 2; wait > tcpRedialMax {
				wait = tcpRedialMax
			}
			continue
		}
		wait = tcpRedialMin

		tc := nc.(*net.TCPConn)
		c.prep(tc)
		l := &tcpLink{tc: tc, seq: uint64(slot)}
		c.links[slot].Store(l)
		if slot == 0 {
			logging.Info("carrier: connected to %s over tcp", addr)
		}
		logging.Debug("carrier: connection %d up", slot)

		c.read(tc)
		c.links[slot].CompareAndSwap(l, nil)
		_ = tc.Close()
		logging.Debug("carrier: connection %d dropped", slot)
	}
}

// acceptForever is the Kharej side. It fills empty slots first, and when they
// are all full the oldest is replaced - because a slot that is full may hold
// a socket nobody has noticed is dead yet, and the connection being offered
// now is one Iran has just decided it needs.
func (c *tcpCarrier) acceptForever() {
	var seq uint64
	for {
		nc, err := c.ln.Accept()
		if err != nil {
			select {
			case <-c.done:
			default:
				logging.Warn("tcp accept: %v", err)
			}
			return
		}
		tc := nc.(*net.TCPConn)
		c.prep(tc)
		seq++
		l := &tcpLink{tc: tc, seq: seq}

		slot := -1
		for i := range c.links {
			if c.links[i].Load() == nil {
				slot = i
				break
			}
		}
		if slot < 0 {
			oldest := c.links[0].Load().seq
			slot = 0
			for i := range c.links {
				if p := c.links[i].Load(); p != nil && p.seq < oldest {
					oldest, slot = p.seq, i
				}
			}
		}
		if old := c.links[slot].Swap(l); old != nil {
			_ = old.tc.Close()
		}
		if seq == 1 {
			logging.Info("carrier: the far end is at %s", tc.RemoteAddr())
		}
		logging.Debug("carrier: connection %d from %s", slot, tc.RemoteAddr())

		go func(slot int, l *tcpLink) {
			c.read(l.tc)
			c.links[slot].CompareAndSwap(l, nil)
			_ = l.tc.Close()
		}(slot, l)
	}
}

// read takes whole frames off one connection until it ends.
//
// The buffer under the reader is what makes this cheap: without it every
// two-byte length would be its own read syscall, which on a four hundred
// megabit stream is a syscall for every eight hundred bytes carried.
func (c *tcpCarrier) read(tc *net.TCPConn) {
	r := bufio.NewReaderSize(tc, 256*1024)
	hdr := make([]byte, tcpLenLen)
	body := make([]byte, tcpMaxFrame)

	for {
		if _, err := io.ReadFull(r, hdr); err != nil {
			c.readEnded(err)
			return
		}
		n := int(binary.BigEndian.Uint16(hdr))
		if n < frameLen || n > tcpMaxFrame {
			// A length this side did not write. There is no way to find the
			// start of the next frame on a stream, so the connection goes and
			// a fresh one is dialled; both ends then start clean.
			logging.Warn("carrier: %d bytes announced on the stream, which is not one of ours", n)
			return
		}
		if _, err := io.ReadFull(r, body[:n]); err != nil {
			c.readEnded(err)
			return
		}
		c.handle(body[:n])
	}
}

func (c *tcpCarrier) readEnded(err error) {
	select {
	case <-c.done:
		return
	default:
	}
	if err == io.EOF {
		logging.Debug("carrier: a connection was closed by the far end")
		return
	}
	logging.Debug("tcp read: %v", err)
}

func (c *tcpCarrier) handle(b []byte) {
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
// An idle TCP connection is one some middlebox on the way has quietly
// forgotten, and neither end finds out until the next packet disappears into
// it. With eight of them, seven can be forgotten while the eighth carries all
// the traffic and looks perfectly healthy.
func (c *tcpCarrier) Keepalive(every time.Duration) {
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

func (c *tcpCarrier) Close() error {
	c.once.Do(func() { close(c.done) })
	if c.ln != nil {
		_ = c.ln.Close()
	}
	for i := range c.links {
		if l := c.links[i].Swap(nil); l != nil {
			_ = l.tc.Close()
		}
	}
	return nil
}

func (c *tcpCarrier) Lost() (missing, late, gaps uint64) { return c.fr.lost() }

func (c *tcpCarrier) Counters() (rx, tx, bad, replay, errs uint64) {
	bad, replay = c.fr.counted()
	return atomic.LoadUint64(&c.rxBytes), atomic.LoadUint64(&c.txBytes),
		bad, replay, atomic.LoadUint64(&c.sendErrs)
}
