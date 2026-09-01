package carrier

import (
	"encoding/binary"
	"fmt"
	"net"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"pingify/internal/buf"
	"pingify/internal/config"
	"pingify/internal/logging"
)

// GRE: our own framed datagram inside a real GRE packet, on a raw socket.
//
// The kernel has a GRE tunnel of its own and this is deliberately not it. A
// kernel tunnel is a device the kernel fills and empties, so nothing this core
// does reaches it: not the queue depth a profile sets, not the socket buffers,
// not the pacing, not the counters every screen in the manager reads, and not
// the health port the far end is asked on. It would be a transport that looked
// like the others in the menu and behaved like none of them.
//
// So the packets on the wire are ordinary GRE - IP protocol 47, the header
// from RFC 2890 with a key - and the thing moving them is this core, the same
// way the ICMP carrier moves echo requests. Everything above the carrier is
// unchanged and every number the manager shows is real.
//
// What GRE buys over UDP is that it is not UDP: no ports to block, and a
// protocol carriers route rather than shape.
//
// The tag and the sequence number are GRE's own fields rather than this
// core's twelve bytes in front of the payload, and that is not a detail of
// style. Written the other way it did not work at all, and the measurement
// that found out why is worth keeping:
//
//	keyed GRE, a real IP packet inside      10 of 10 arrived
//	plain GRE, a real IP packet inside      10 of 10
//	keyed GRE, twelve bytes then a packet    0 of 30
//	plain GRE, junk inside                   0 of 30
//
// Something on this path parses the inner packet, and a GRE packet whose
// payload is not a well-formed IP packet does not cross it. Our framing was
// what made it malformed. RFC 2890 has somewhere to put both things: a
// 32-bit key and a 32-bit sequence number, in the header, where they belong -
// so the payload is the bare IP packet, the packet is one any middlebox
// parses happily, and it costs eight bytes fewer than the framing did.
//
// The key is derived from the token. It rides in the clear and protects
// nothing; what it does is keep two tunnels between the same pair of servers
// from reading each other's packets, which is the whole job GRE gives it -
// and it is the reason this transport is the plainly visible one.
const (
	// flags and version, protocol type, key, sequence.
	greHdrLen     = 12
	greFlagKeySeq = 0x3000
	greProtoIPv4  = 0x0800

	greMaxPacket = 1500
	greReadBuf   = 2048
)

type greCarrier struct {
	pc *net.IPConn

	// No framer. Its two jobs - say a packet is ours, and number it so loss
	// can be counted - are the key and the sequence in GRE's own header.
	key  uint32
	seq  atomic.Uint32
	seen *buf.ReplayWindow

	burst int

	peer     atomic.Pointer[net.IPAddr]
	peer4    atomic.Uint32
	onPacket atomic.Pointer[func([]byte)]

	rc      syscall.RawConn
	batched bool

	sawIPHeader sync.Once
	done        chan struct{}
	once        sync.Once

	rxBytes, txBytes uint64
	sendErrs         uint64
	notOurs          uint64
	replayed         uint64
}

func newGRECarrier(cfg *config.Config) (*greCarrier, error) {
	c := &greCarrier{
		key:   greKeyFrom(cfg.Token),
		seen:  buf.NewReplayWindow(),
		done:  make(chan struct{}),
		burst: cfg.Tuning.SendBatch,
	}
	if c.burst <= 0 {
		c.burst = defaultSendBatch
	}

	pc, err := net.ListenIP("ip4:47", &net.IPAddr{IP: net.IPv4zero})
	if err != nil {
		return nil, fmt.Errorf("open raw gre socket: %v (this needs root)", err)
	}
	c.pc = pc

	if cfg.Dials() {
		addr, err := net.ResolveIPAddr("ip4", cfg.DialHost())
		if err != nil {
			pc.Close()
			return nil, fmt.Errorf("resolve %s: %v", cfg.DialHost(), err)
		}
		c.setPeer(addr.IP)
		logging.Info("carrier: gre to %s, key %d", addr.IP, c.key)
	} else {
		logging.Info("carrier: waiting for gre, key %d", c.key)
	}

	tuneSocket(pc, cfg)
	smoothTheWire(cfg)
	pace(pc, cfg, c.done, func() uint64 { return atomic.LoadUint64(&c.txBytes) })

	if canBatch {
		if rc, err := pc.SyscallConn(); err == nil {
			c.rc, c.batched = rc, true
			logging.Info("packet i/o: up to %d in and %d out per crossing into the kernel",
				recvBatch, sendBatch)
		}
	}
	return c, nil
}

func (c *greCarrier) setPeer(ip net.IP) {
	v4 := ip.To4()
	if v4 == nil {
		return
	}
	c.peer.Store(&net.IPAddr{IP: append(net.IP(nil), v4...)})
	c.peer4.Store(binary.BigEndian.Uint32(v4))
}

func (c *greCarrier) Burst() int      { return c.burst }
func (c *greCarrier) Headroom() int   { return greHdrLen }
func (c *greCarrier) MaxPayload() int { return greMaxPacket - greHdrLen }
func (c *greCarrier) Up() bool        { return c.peer.Load() != nil }

func (c *greCarrier) OnPacket(f func([]byte)) { c.onPacket.Store(&f) }

// stamp writes the GRE header over the headroom the layer above left for it.
// The protocol type says IPv4 and means it: what follows this header is the
// packet itself and nothing else.
func (c *greCarrier) stamp(b []byte) {
	binary.BigEndian.PutUint16(b[0:2], greFlagKeySeq)
	binary.BigEndian.PutUint16(b[2:4], greProtoIPv4)
	binary.BigEndian.PutUint32(b[4:8], c.key)
	binary.BigEndian.PutUint32(b[8:12], c.seq.Add(1))
}

func (c *greCarrier) Send(bp *[]byte) error {
	peer := c.peer.Load()
	b := *bp
	if peer == nil || len(b) < c.Headroom() {
		buf.Put(bp)
		if peer == nil {
			return ErrNoPeer
		}
		return nil
	}
	c.stamp(b)

	n, err := c.pc.WriteToIP(b, peer)
	buf.Put(bp)
	if err != nil {
		atomic.AddUint64(&c.sendErrs, 1)
		return err
	}
	atomic.AddUint64(&c.txBytes, uint64(n))
	return nil
}

// greSender sends a batch in one crossing into the kernel where the platform
// allows it, and one at a time where it does not. It is the ICMP carrier's
// arrangement and for the same reason: on a raw socket the syscall is most of
// the cost of a small packet.
type greSender struct {
	c    *greCarrier
	w    *batchWriter
	bufs [][]byte
}

func (c *greCarrier) NewSender() Sender {
	if !c.batched {
		return &grePlainSender{c: c}
	}
	return &greSender{c: c, w: newBatchWriter(), bufs: make([][]byte, 0, sendBatch)}
}

func (s *greSender) Send(bps []*[]byte) {
	c := s.c
	peer := c.peer.Load()
	if peer == nil {
		for _, bp := range bps {
			buf.Put(bp)
		}
		return
	}
	var to [4]byte
	copy(to[:], peer.IP.To4())

	s.bufs = s.bufs[:0]
	for _, bp := range bps {
		b := *bp
		if len(b) < c.Headroom() {
			continue
		}
		c.stamp(b)
		s.bufs = append(s.bufs, b)
	}

	// sendmmsg may take fewer than it was offered. What it did not take has
	// not been sent, so it goes round again rather than being let go quietly.
	out := s.bufs
	for len(out) > 0 {
		n, err := s.w.write(c.rc, out, to)
		if err != nil {
			atomic.AddUint64(&c.sendErrs, 1)
			logging.Debug("gre send batch: %v", err)
			break
		}
		if n <= 0 {
			break
		}
		for i := 0; i < n; i++ {
			atomic.AddUint64(&c.txBytes, uint64(len(out[i])))
		}
		out = out[n:]
	}
	for _, bp := range bps {
		buf.Put(bp)
	}
}

type grePlainSender struct{ c *greCarrier }

func (s *grePlainSender) Send(bps []*[]byte) {
	for _, bp := range bps {
		_ = s.c.Send(bp)
	}
}

func (c *greCarrier) Run() {
	buf := make([]byte, greReadBuf)
	for {
		n, from, err := c.pc.ReadFromIP(buf)
		if n > 0 {
			var a [4]byte
			if v4 := from.IP.To4(); v4 != nil {
				copy(a[:], v4)
			}
			c.handle(buf[:n], a)
		}
		if err != nil {
			select {
			case <-c.done:
			default:
				logging.Warn("gre read: %v", err)
			}
			return
		}
	}
}

func (c *greCarrier) handle(b []byte, from [4]byte) {
	// A raw socket is given the IP header by the kernel. Whether the net
	// package has already taken it off depends on which call read the packet,
	// so it is looked for rather than assumed.
	if len(b) >= 20 && b[0]>>4 == 4 {
		ihl := int(b[0]&0x0f) * 4
		if ihl < 20 || len(b) <= ihl {
			return
		}
		b = b[ihl:]
		c.sawIPHeader.Do(func() {
			logging.Debug("the ip header arrives with each gre packet; stepping over it")
		})
	}
	if len(b) < greHdrLen {
		return
	}
	// Ours is the only shape we answer to: the key and sequence flags set,
	// no others, and our key in it. A kernel GRE tunnel on the same host
	// carries a different key or none, and either way its packets are not
	// read as ours.
	if binary.BigEndian.Uint16(b[0:2]) != greFlagKeySeq ||
		binary.BigEndian.Uint32(b[4:8]) != c.key {
		atomic.AddUint64(&c.notOurs, 1)
		return
	}
	if !c.seen.Fresh(binary.BigEndian.Uint32(b[8:12])) {
		atomic.AddUint64(&c.replayed, 1)
		return
	}
	body := b[greHdrLen:]

	// The tag was right, so this is the far end, wherever it is speaking from.
	// The side that waits learns the address here and nowhere else.
	v := binary.BigEndian.Uint32(from[:])
	if v != 0 && c.peer4.Load() != v {
		c.setPeer(net.IPv4(from[0], from[1], from[2], from[3]))
		logging.Info("carrier: the far end is at %d.%d.%d.%d", from[0], from[1], from[2], from[3])
	}

	atomic.AddUint64(&c.rxBytes, uint64(len(b)))
	if len(body) == 0 {
		return // a keepalive, which has done its whole job by arriving
	}
	if f := c.onPacket.Load(); f != nil {
		(*f)(body)
	}
}

func (c *greCarrier) Keepalive(every time.Duration) {
	keepaliveLoop(c, c.done, every)
}

func (c *greCarrier) Close() error {
	c.once.Do(func() { close(c.done) })
	return c.pc.Close()
}

func (c *greCarrier) Lost() (missing, late, gaps uint64) { return c.seen.Lost() }

func (c *greCarrier) Counters() (rx, tx, bad, replay, errs uint64) {
	return atomic.LoadUint64(&c.rxBytes), atomic.LoadUint64(&c.txBytes),
		atomic.LoadUint64(&c.notOurs), atomic.LoadUint64(&c.replayed),
		atomic.LoadUint64(&c.sendErrs)
}

// greKeyFrom turns the token into the key both ends put in every packet.
//
// Never zero: zero is what a tunnel built without a key would carry, and a
// tunnel that answers to it would answer to anybody's.
func greKeyFrom(token string) uint32 {
	h := uint32(2166136261)
	for i := 0; i < len(token); i++ {
		h ^= uint32(token[i])
		h *= 16777619
	}
	if h == 0 {
		h = 1
	}
	return h
}
