package carrier

import (
	"errors"
	"fmt"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"pingify/internal/buf"
	"pingify/internal/config"
	"pingify/internal/logging"
)

// UDP: a framed datagram in a UDP datagram, and nothing else.
//
// What happened when this was first run between Tehran and Frankfurt: the
// tunnel came up, carried exactly one round trip at 81.0 ms, and went silent.
// It was not this code. A plain python socket on the same pair of servers,
// with no tunnel anywhere near it, gets the same answer:
//
//	udp/8444    6 of 30 back   111111........................
//	udp/8445    6 of 15 back   111111.........
//	udp/8446    6 of 15 back   111111.........
//
// Six, and only ever six. Measured again, with an echo server on the far end
// so that it is a conversation this side starts rather than an arrival nobody
// asked for, and with the harness checked against itself first:
//
//	turkey to germany, no Iran in it     15 of 15
//	iran to germany                       6 of 40
//	iran to turkey                        6 of 40
//	iran to germany, one packet per 2s    111111......
//	three fresh flows, one after another  6, 6, 6
//
// So it is a counter on the flow and not a rate: the seventh packet of a flow
// is dropped whether it comes a fifth of a second or two seconds after the
// sixth, the destination makes no difference, and a new source port starts
// the count again. That last part is why eight TCP connections carry what one
// cannot, and why anything built on a single long-lived UDP flow - a
// WireGuard, an AmneziaWG, this carrier - gets its handshake through and then
// stops.
//
// So UDP is not a slow transport on this path. It is an unusable one, and no
// amount of tuning here changes that - which is why ICMP is the transport
// worth making good rather than the fallback.
//
// This carrier stays anyway. It is what proved the shape the framer and the
// private link now share, it is the one place to test a carrier without a raw
// socket, and this is one path on one ISP on one day. Somebody else's will
// carry UDP happily.
const udpMaxDgram = 1500

var ErrNoPeer = errors.New("no peer yet")

type udpCarrier struct {
	pc *net.UDPConn
	fr *framer

	peer     atomic.Pointer[net.UDPAddr]
	onPacket atomic.Pointer[func([]byte)]

	done chan struct{}
	once sync.Once

	rxBytes, txBytes uint64
	sendErrs         uint64
}

func newUDPCarrier(cfg *config.Config) (*udpCarrier, error) {
	c := &udpCarrier{
		fr:   newFramer(cfg.Token, "pingify udp v1"),
		done: make(chan struct{}),
	}

	if cfg.Dials() {
		// Iran dials out. The socket stays unconnected and the peer is
		// remembered instead, because the abroad side may answer from a
		// different source port when anything on the way rewrites addresses.
		raddr, err := net.ResolveUDPAddr("udp4",
			net.JoinHostPort(cfg.DialHost(), fmt.Sprint(cfg.Transport.Port)))
		if err != nil {
			return nil, fmt.Errorf("resolve %s: %v", cfg.DialHost(), err)
		}
		pc, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: 0})
		if err != nil {
			return nil, fmt.Errorf("open udp socket: %v", err)
		}
		c.pc = pc
		c.peer.Store(raddr)
		tuneSocket(pc, cfg)
		smoothTheWire(cfg)
		pace(pc, cfg, c.done, func() uint64 { return atomic.LoadUint64(&c.txBytes) })
		logging.Info("carrier: dialling %s over udp", raddr)
		return c, nil
	}

	pc, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: cfg.Transport.Port})
	if err != nil {
		return nil, fmt.Errorf("listen on udp/%d: %v", cfg.Transport.Port, err)
	}
	c.pc = pc
	tuneSocket(pc, cfg)
	smoothTheWire(cfg)
	pace(pc, cfg, c.done, func() uint64 { return atomic.LoadUint64(&c.txBytes) })
	logging.Info("carrier: waiting on udp/%d", cfg.Transport.Port)
	return c, nil
}

// Burst is one: this carrier sends a packet per call, so there is nothing to
// be gained by collecting them first.
func (c *udpCarrier) Burst() int      { return 1 }
func (c *udpCarrier) Headroom() int   { return c.fr.headroom() }
func (c *udpCarrier) MaxPayload() int { return udpMaxDgram - c.fr.headroom() }
func (c *udpCarrier) Up() bool        { return c.peer.Load() != nil }

func (c *udpCarrier) OnPacket(f func([]byte)) { c.onPacket.Store(&f) }

// udpSender sends a batch one packet at a time. There is no sendmmsg here
// because there is no point: this carrier is for paths where UDP works, and
// those are not the paths where the last ten percent is being fought over.
type udpSender struct{ c *udpCarrier }

func (c *udpCarrier) NewSender() Sender { return &udpSender{c: c} }

func (s *udpSender) Send(bps []*[]byte) {
	for _, bp := range bps {
		_ = s.c.Send(bp)
	}
}

func (c *udpCarrier) Send(bp *[]byte) error {
	peer := c.peer.Load()
	b := *bp
	if peer == nil || len(b) < c.fr.headroom() {
		buf.Put(bp)
		if peer == nil {
			return ErrNoPeer
		}
		return nil
	}
	c.fr.seal(b)
	n, err := c.pc.WriteToUDP(b, peer)
	buf.Put(bp)
	if err != nil {
		atomic.AddUint64(&c.sendErrs, 1)
		return err
	}
	atomic.AddUint64(&c.txBytes, uint64(n))
	return nil
}

// run reads datagrams until the socket closes, handing each one that carries
// the right tag to the layer above - on this goroutine, with nothing in
// between. See link.fromWire for why there is nothing in between.
func (c *udpCarrier) Run() {
	buf := make([]byte, udpMaxDgram)
	for {
		n, from, err := c.pc.ReadFromUDP(buf)
		if n > 0 {
			c.handle(buf[:n], from)
		}
		if err != nil {
			select {
			case <-c.done:
			default:
				logging.Warn("udp read: %v", err)
			}
			return
		}
	}
}

func (c *udpCarrier) handle(b []byte, from *net.UDPAddr) {
	body, ok := c.fr.open(b)
	if !ok {
		return
	}

	// The tag was right, so this is the far end, wherever it is speaking from.
	// The side that waits learns the address here and nowhere else.
	if p := c.peer.Load(); p == nil || p.Port != from.Port || !p.IP.Equal(from.IP) {
		cp := *from
		c.peer.Store(&cp)
		logging.Info("carrier: the far end is at %s", from)
	}

	atomic.AddUint64(&c.rxBytes, uint64(len(b)))
	if len(body) == 0 {
		return // a keepalive, which has done its whole job by arriving
	}
	if f := c.onPacket.Load(); f != nil {
		(*f)(body)
	}
}

func (c *udpCarrier) Keepalive(every time.Duration) {
	keepaliveLoop(c, c.done, every)
}

func (c *udpCarrier) Close() error {
	c.once.Do(func() { close(c.done) })
	return c.pc.Close()
}

func (c *udpCarrier) Lost() (missing, late, gaps uint64) { return c.fr.lost() }

func (c *udpCarrier) Counters() (rx, tx, bad, replay, errs uint64) {
	bad, replay = c.fr.counted()
	return atomic.LoadUint64(&c.rxBytes), atomic.LoadUint64(&c.txBytes),
		bad, replay, atomic.LoadUint64(&c.sendErrs)
}

// keepaliveLoop holds the path open, and on the side that waits it is the only
// thing that says where the far end is. The side that dials sends it, because
// before a datagram arrives the other side has nothing to send to.
func keepaliveLoop(c Carrier, done <-chan struct{}, every time.Duration) {
	tk := time.NewTicker(every)
	defer tk.Stop()
	for {
		select {
		case <-done:
			return
		case <-tk.C:
			bp := buf.Take(c.Headroom(), 0)
			if err := c.Send(bp); err != nil && !errors.Is(err, ErrNoPeer) {
				logging.Debug("keepalive: %v", err)
			}
		}
	}
}
