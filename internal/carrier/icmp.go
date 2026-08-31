package carrier

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"pingify/internal/buf"
	"pingify/internal/config"
	"pingify/internal/logging"
)

// ICMP: the transport that works on the path this tunnel was built for.
//
// Not the fallback. On the route between the Iran server and Frankfurt, UDP
// gets six packets back and then nothing - on every port, from every source
// port, for ever. ICMP gets all of them. That is the whole reason this exists
// and the reason it is worth being careful with.
//
// Both ends send echo *requests*, type 8, and both accept either type. This is
// the single fact that took longest to find, and it is worth writing down
// plainly because every textbook says the opposite: client asks, server
// answers. Counted on the real path, out of 300:
//
//	                    echo reply (0)    echo request (8)
//	  Iran -> Germany    nothing           300 of 300
//	  Germany -> Iran    nothing           most
//	  Iran -> Turkey     300 of 300        300 of 300
//
// An unsolicited echo reply is not part of any conversation, and the route
// drops it in both directions. A request is the start of one, and passes. So a
// tunnel built the textbook way does not come up on this path at all, which is
// exactly what "ICMP does not work" looked like for weeks.
//
// Because both ends send requests, both kernels would answer them by
// themselves and double every packet on the wire. net.ipv4.icmp_echo_ignore_all
// stops that, and this carrier sets it rather than leaving it to a document
// nobody reads.
//
// On the wire:
//
//	 0     1     2           4         6         8              20
//	 +-----+-----+-----------+---------+---------+--------------+-------------+
//	 |type |code | checksum  |   id    |  seq    | tag + count  | the packet  |
//	 +-----+-----+-----------+---------+---------+--------------+-------------+
//	 |<---------- ICMP's own header ------------>|<--- ours --->|

// errNoFilter means the kernel would not sort our echoes for us, so Go has to.
// Not an error anybody needs to act on - see attachICMPFilter.
var errNoFilter = errors.New("icmp: no socket filter on this platform")

const (
	icmpHdrLen     = 8
	icmpEchoReply  = 0
	icmpEchoReq    = 8
	icmpMaxPayload = 1460 // 1500 on the path, less 20 of IP and 8 of ICMP
	icmpReadBuf    = 1600
)

type icmpCarrier struct {
	pc *net.IPConn
	rc syscall.RawConn
	fr *framer
	id uint16

	seq   uint32 // the ICMP header's own sequence, which nothing reads
	peer  atomic.Pointer[net.IPAddr]
	peer4 atomic.Uint32 // the same address as a number, to compare per packet

	onPacket atomic.Pointer[func([]byte)]

	batched bool
	burst   int

	// Whether the kernel handed us the IP header. It does on a raw socket, and
	// Go takes it off again in ReadFromIP but not in recvmmsg - so it is looked
	// for rather than assumed, and said once.
	sawIPHeader sync.Once

	done chan struct{}
	once sync.Once

	rxBytes, txBytes  uint64
	sendErrs, wrongID uint64
	notEcho, dropped  uint64
}

func newICMPCarrier(cfg *config.Config) (*icmpCarrier, error) {
	c := &icmpCarrier{
		fr:    newFramer(cfg.Token, "pingify icmp v1"),
		id:    icmpIDFrom(cfg.Token),
		done:  make(chan struct{}),
		burst: cfg.Tuning.SendBatch,
	}
	if c.burst <= 0 {
		c.burst = defaultSendBatch
	}

	pc, err := net.ListenIP("ip4:icmp", &net.IPAddr{IP: net.IPv4zero})
	if err != nil {
		return nil, fmt.Errorf("open raw icmp socket: %v (this needs root)", err)
	}
	c.pc = pc

	if cfg.Dials() {
		addr, err := net.ResolveIPAddr("ip4", cfg.Transport.Kharej)
		if err != nil {
			pc.Close()
			return nil, fmt.Errorf("resolve %s: %v", cfg.Transport.Kharej, err)
		}
		c.setPeer(addr.IP)
		logging.Info("carrier: echoing to %s, id %d", addr.IP, c.id)
	} else {
		logging.Info("carrier: listening for echoes, id %d", c.id)
	}

	silenceKernelPings()
	tuneSocket(pc, cfg)
	smoothTheWire(cfg)
	pace(pc, cfg, c.done, func() uint64 { return atomic.LoadUint64(&c.txBytes) })

	// The kernel can sort our echoes from everybody else's for nothing, before
	// a packet is queued or a goroutine woken. Without it, every monitoring
	// ping and every scanner on a public address arrives here and is thrown
	// out in Go, one hash at a time - which on a busy address is most of the
	// work the transport does.
	if err := attachICMPFilter(pc, c.id); err != nil {
		logging.Debug("no socket filter (%v); every echo the host sees is sorted here instead", err)
	} else {
		logging.Info("the kernel is filtering echoes for us: only id %d arrives", c.id)
	}

	if canBatch {
		if rc, err := pc.SyscallConn(); err == nil {
			c.rc, c.batched = rc, true
			logging.Info("packet i/o: up to %d in and %d out per crossing into the kernel",
				recvBatch, sendBatch)
		} else {
			logging.Warn("no raw access to the socket (%v): one call per packet", err)
		}
	} else {
		logging.Info("packet i/o: one call per packet on this platform")
	}
	return c, nil
}

func (c *icmpCarrier) setPeer(ip net.IP) {
	v4 := ip.To4()
	if v4 == nil {
		return
	}
	c.peer.Store(&net.IPAddr{IP: append(net.IP(nil), v4...)})
	c.peer4.Store(uint32(v4[0])<<24 | uint32(v4[1])<<16 | uint32(v4[2])<<8 | uint32(v4[3]))
}

func (c *icmpCarrier) Burst() int      { return c.burst }
func (c *icmpCarrier) Headroom() int   { return icmpHdrLen + c.fr.headroom() }
func (c *icmpCarrier) MaxPayload() int { return icmpMaxPayload - c.fr.headroom() }
func (c *icmpCarrier) Up() bool        { return c.peer.Load() != nil }

func (c *icmpCarrier) OnPacket(f func([]byte)) { c.onPacket.Store(&f) }

// stamp fills in the ICMP header, the tag and the checksum. After it, the
// buffer is a whole packet and nothing else needs to touch it.
func (c *icmpCarrier) stamp(b []byte) {
	b[0] = icmpEchoReq
	b[1] = 0
	b[2], b[3] = 0, 0
	binary.BigEndian.PutUint16(b[4:6], c.id)
	binary.BigEndian.PutUint16(b[6:8], uint16(atomic.AddUint32(&c.seq, 1)))
	c.fr.seal(b[icmpHdrLen:])
	binary.BigEndian.PutUint16(b[2:4], icmpChecksum(b))
}

// Send puts one packet on the wire on its own. Only keepalives come this way,
// once every ten seconds, so it does not batch and does not need to.
func (c *icmpCarrier) Send(bp *[]byte) error {
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

// icmpSender belongs to one goroutine reading one device queue, and puts that
// queue's packets on the wire in as few crossings into the kernel as it can.
type icmpSender struct {
	c    *icmpCarrier
	w    *batchWriter
	bufs [][]byte
}

func (c *icmpCarrier) NewSender() Sender {
	if !c.batched {
		return &plainSender{c: c}
	}
	return &icmpSender{c: c, w: newBatchWriter(), bufs: make([][]byte, 0, sendBatch)}
}

func (s *icmpSender) Send(bps []*[]byte) {
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
		c.stamp(*bp)
		s.bufs = append(s.bufs, *bp)
	}

	// sendmmsg may take fewer than it was offered. What it did not take has
	// not been sent, so it goes round again rather than being let go quietly.
	out := s.bufs
	for len(out) > 0 {
		n, err := s.w.write(c.rc, out, to)
		if err != nil {
			atomic.AddUint64(&c.sendErrs, 1)
			logging.Debug("icmp send batch: %v", err)
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

// plainSender is what a platform without the batched calls gets: one packet,
// one call, which is what every carrier did before.
type plainSender struct{ c *icmpCarrier }

func (s *plainSender) Send(bps []*[]byte) {
	for _, bp := range bps {
		_ = s.c.Send(bp)
	}
}

func (c *icmpCarrier) Run() {
	if c.batched {
		c.runBatched()
		return
	}
	c.runPlain()
}

func (c *icmpCarrier) runBatched() {
	r := newBatchReader(icmpReadBuf)
	for {
		n, err := r.read(c.rc)
		for i := 0; i < n; i++ {
			b, from := r.packet(i)
			c.handle(b, from)
		}
		if err != nil {
			select {
			case <-c.done:
			default:
				logging.Warn("icmp read: %v", err)
			}
			return
		}
	}
}

func (c *icmpCarrier) runPlain() {
	buf := make([]byte, icmpReadBuf)
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
				logging.Warn("icmp read: %v", err)
			}
			return
		}
	}
}

// handle sorts one arrival. It runs on the goroutine that took the packet off
// the socket and hands it to the private link from there - see link.fromWire
// for why there is nothing in between.
func (c *icmpCarrier) handle(b []byte, from [4]byte) {
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
			logging.Debug("the ip header arrives with each echo; stepping over it")
		})
	}
	if len(b) < icmpHdrLen+frameLen {
		return
	}
	if b[0] != icmpEchoReq && b[0] != icmpEchoReply {
		atomic.AddUint64(&c.notEcho, 1)
		return
	}
	if binary.BigEndian.Uint16(b[4:6]) != c.id {
		atomic.AddUint64(&c.wrongID, 1)
		return
	}

	body, ok := c.fr.open(b[icmpHdrLen:])
	if !ok {
		return
	}

	// The tag was right, so this is the far end, wherever it is speaking from.
	// The side that waits learns the address here and nowhere else.
	v := uint32(from[0])<<24 | uint32(from[1])<<16 | uint32(from[2])<<8 | uint32(from[3])
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

func (c *icmpCarrier) Keepalive(every time.Duration) {
	keepaliveLoop(c, c.done, every)
}

func (c *icmpCarrier) Close() error {
	c.once.Do(func() { close(c.done) })
	return c.pc.Close()
}

func (c *icmpCarrier) Lost() (missing, late, gaps uint64) { return c.fr.lost() }

func (c *icmpCarrier) Counters() (rx, tx, bad, replay, errs uint64) {
	return atomic.LoadUint64(&c.rxBytes), atomic.LoadUint64(&c.txBytes),
		c.fr.badTag, c.fr.replayed,
		atomic.LoadUint64(&c.sendErrs) + atomic.LoadUint64(&c.dropped)
}

// icmpIDFrom is the identifier both ends put in every echo they send.
//
// Derived from the token, so it is the same on both servers and different on
// every tunnel: the kernel can then be told exactly what to keep, and two
// tunnels between the same pair of servers do not collect each other's
// packets. Zero is stepped over, because plenty of tools ping with an
// identifier of zero and matching all of them would defeat the point.
func icmpIDFrom(token string) uint16 {
	m := hmac.New(sha256.New, []byte("pingify icmp id v1"))
	m.Write([]byte(token))
	id := binary.BigEndian.Uint16(m.Sum(nil))
	if id == 0 {
		id = 1
	}
	return id
}

// icmpChecksum is the ones-complement sum the header carries, over the whole
// message with the checksum field held at zero.
func icmpChecksum(b []byte) uint16 {
	var sum uint32
	for i := 0; i+1 < len(b); i += 2 {
		sum += uint32(b[i])<<8 | uint32(b[i+1])
	}
	if len(b)%2 == 1 {
		sum += uint32(b[len(b)-1]) << 8
	}
	for sum>>16 != 0 {
		sum = sum&0xffff + sum>>16
	}
	return ^uint16(sum)
}

// silenceKernelPings stops this host answering echo requests on its own.
//
// Both ends of this tunnel send requests, so without it every packet we send
// is answered twice: once by the tunnel at the far end, and once by the far
// end's kernel, which has no idea it is in the middle of anything. That
// doubles the traffic on the path and hands the sender a reply nobody asked
// for.
//
// It is a system-wide setting, which is worth being honest about in the log:
// ordinary pings to this server stop being answered for as long as this runs.
func silenceKernelPings() {
	const path = "/proc/sys/net/ipv4/icmp_echo_ignore_all"
	was, err := os.ReadFile(path)
	if err != nil {
		return // not Linux, or not permitted; the tunnel still works
	}
	if len(was) > 0 && was[0] == '1' {
		return
	}
	if err := os.WriteFile(path, []byte("1\n"), 0o644); err != nil {
		logging.Warn("could not stop the kernel answering pings (%v) - it will answer"+
			" every echo this tunnel sends, and double the traffic", err)
		return
	}
	logging.Info("the kernel will stop answering pings while this runs" +
		" (icmp_echo_ignore_all), because both ends of this tunnel send requests")
}
