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

// Raw TCP: our datagrams inside TCP segments the kernel never sees.
//
// The stream carrier gives a path that only carries TCP something it will
// carry, and pays for it in head-of-line blocking: one lost packet stops
// everything behind it while TCP repairs it, under connections that were
// repairing it themselves. This is the other way round the same problem.
// What goes on the wire is a TCP segment with a plausible sequence number,
// window and checksum - to a filter counting protocols, and to anything that
// does not keep state, this is a TCP conversation. What is inside is a
// datagram, and a lost one is lost, exactly as with UDP or ICMP. No stream, no
// retransmit, no head of line.
//
// The two things that make it work, and both are the kernel:
//
// It has to not answer. A segment arriving for a port with no socket on it
// gets an RST from the kernel, which would tear down a conversation it is not
// part of and tell anybody watching that nothing is listening here. The
// manager drops those in the firewall - see the PINGIFY_RAWTCP chain - and
// this carrier refuses to start if they are not being dropped, because a
// tunnel that resets itself every few seconds is worse than one that says why
// it will not start.
//
// It has to not be given every packet on the host. A raw TCP socket receives a
// copy of every segment the machine sees, so on anything busy most of the work
// would be throwing other people's traffic away in Go. The same socket filter
// the ICMP carrier uses does it in the kernel, on the two ports that are ours.
const (
	rawTCPHdrLen = 20 // no options: a plain header, which is what a data segment carries
	rawTCPMax    = 1500
	rawTCPRead   = 2048

	tcpFlagACK = 0x10
	tcpFlagPSH = 0x08
)

type rawTCPCarrier struct {
	pc *net.IPConn
	fr *framer

	myPort, peerPort uint16
	burst            int

	// Where our sequence number is up to. It is not TCP's - nothing acks it
	// and nothing retransmits - but it has to move the way TCP's does or the
	// segments do not look like a conversation.
	seq  atomic.Uint32
	ack  atomic.Uint32
	mine [4]byte

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
}

func newRawTCPCarrier(cfg *config.Config) (*rawTCPCarrier, error) {
	port := uint16(cfg.Transport.Port)
	c := &rawTCPCarrier{
		fr:    newFramer(cfg.Token, "pingify rawtcp v1"),
		done:  make(chan struct{}),
		burst: cfg.Tuning.SendBatch,
	}
	if c.burst <= 0 {
		c.burst = defaultSendBatch
	}

	// One port, both ends. There is no handshake to negotiate a second one
	// with, and a conversation between the same port on two machines is a
	// shape the internet is full of.
	c.myPort, c.peerPort = port, port
	c.seq.Store(uint32(time.Now().UnixNano()))

	pc, err := net.ListenIP("ip4:tcp", &net.IPAddr{IP: net.IPv4zero})
	if err != nil {
		return nil, fmt.Errorf("open raw tcp socket: %v (this needs root)", err)
	}
	c.pc = pc

	if cfg.Dials() {
		addr, err := net.ResolveIPAddr("ip4", cfg.DialHost())
		if err != nil {
			pc.Close()
			return nil, fmt.Errorf("resolve %s: %v", cfg.DialHost(), err)
		}
		c.setPeer(addr.IP)
		logging.Info("carrier: raw tcp to %s:%d", addr.IP, port)
	} else {
		logging.Info("carrier: waiting for raw tcp on %d", port)
	}
	if err := c.findLocalAddress(cfg); err != nil {
		logging.Warn("carrier: %v - the checksum will be wrong and the far end will drop us", err)
	}

	tuneSocket(pc, cfg)
	smoothTheWire(cfg)
	pace(pc, cfg, c.done, func() uint64 { return atomic.LoadUint64(&c.txBytes) })

	if err := attachPortFilter(pc, port); err != nil {
		logging.Debug("no socket filter (%v); every tcp segment this host sees is sorted here instead", err)
	} else {
		logging.Info("the kernel is filtering segments for us: only port %d arrives", port)
	}

	if canBatch {
		if rc, err := pc.SyscallConn(); err == nil {
			c.rc, c.batched = rc, true
		}
	}
	return c, nil
}

// findLocalAddress works out which address this host will send from, because
// a TCP checksum covers a header built from both ends and we are building it
// ourselves. It asks the routing table the only way a program can without
// parsing it: by opening a UDP socket to the far end and reading back the
// address the kernel chose. Nothing is sent.
func (c *rawTCPCarrier) findLocalAddress(cfg *config.Config) error {
	host := cfg.DialHost()
	if host == "" {
		host = cfg.Transport.Iran
	}
	if host == "" {
		return fmt.Errorf("no address to work out the local one from")
	}
	u, err := net.Dial("udp4", net.JoinHostPort(host, "9"))
	if err != nil {
		return fmt.Errorf("could not work out this host's address: %v", err)
	}
	defer u.Close()
	la, ok := u.LocalAddr().(*net.UDPAddr)
	if !ok || la.IP.To4() == nil {
		return fmt.Errorf("could not work out this host's address")
	}
	copy(c.mine[:], la.IP.To4())
	return nil
}

func (c *rawTCPCarrier) setPeer(ip net.IP) {
	v4 := ip.To4()
	if v4 == nil {
		return
	}
	c.peer.Store(&net.IPAddr{IP: append(net.IP(nil), v4...)})
	c.peer4.Store(binary.BigEndian.Uint32(v4))
}

func (c *rawTCPCarrier) Burst() int      { return c.burst }
func (c *rawTCPCarrier) Headroom() int   { return rawTCPHdrLen + c.fr.headroom() }
func (c *rawTCPCarrier) MaxPayload() int { return rawTCPMax - c.Headroom() }
func (c *rawTCPCarrier) Up() bool        { return c.peer.Load() != nil }

func (c *rawTCPCarrier) OnPacket(f func([]byte)) { c.onPacket.Store(&f) }

// stamp writes the TCP header over the headroom, and the checksum over the
// whole segment. The sequence number moves by the length of what is being
// sent, which is what makes a capture of this look like a conversation rather
// than a machine repeating itself.
func (c *rawTCPCarrier) stamp(b []byte, peer [4]byte) {
	n := len(b) - rawTCPHdrLen
	binary.BigEndian.PutUint16(b[0:2], c.myPort)
	binary.BigEndian.PutUint16(b[2:4], c.peerPort)
	binary.BigEndian.PutUint32(b[4:8], c.seq.Add(uint32(n))-uint32(n))
	binary.BigEndian.PutUint32(b[8:12], c.ack.Load())
	b[12] = 5 << 4 // data offset: five words, no options
	b[13] = tcpFlagACK | tcpFlagPSH
	binary.BigEndian.PutUint16(b[14:16], 64240) // a window somebody could believe
	b[16], b[17] = 0, 0                         // checksum, filled in below
	b[18], b[19] = 0, 0                         // urgent pointer

	binary.BigEndian.PutUint16(b[16:18], tcpChecksum(c.mine, peer, b))
}

// tcpChecksum is the ordinary one's complement sum over a pseudo header and
// the segment. It is not optional: a segment with a wrong checksum is dropped
// by the far kernel before any raw socket sees it, which is a tunnel that
// sends perfectly and receives nothing.
func tcpChecksum(src, dst [4]byte, seg []byte) uint16 {
	var sum uint32
	add := func(b []byte) {
		for i := 0; i+1 < len(b); i += 2 {
			sum += uint32(b[i])<<8 | uint32(b[i+1])
		}
		if len(b)%2 == 1 {
			sum += uint32(b[len(b)-1]) << 8
		}
	}
	add(src[:])
	add(dst[:])
	sum += uint32(syscall.IPPROTO_TCP)
	sum += uint32(len(seg))
	add(seg)
	for sum>>16 != 0 {
		sum = (sum & 0xffff) + (sum >> 16)
	}
	return ^uint16(sum)
}

func (c *rawTCPCarrier) Send(bp *[]byte) error {
	peer := c.peer.Load()
	b := *bp
	if peer == nil || len(b) < c.Headroom() {
		buf.Put(bp)
		if peer == nil {
			return ErrNoPeer
		}
		return nil
	}
	var to [4]byte
	copy(to[:], peer.IP.To4())
	c.fr.seal(b[rawTCPHdrLen:])
	c.stamp(b, to)

	n, err := c.pc.WriteToIP(b, peer)
	buf.Put(bp)
	if err != nil {
		atomic.AddUint64(&c.sendErrs, 1)
		return err
	}
	atomic.AddUint64(&c.txBytes, uint64(n))
	return nil
}

type rawTCPSender struct {
	c    *rawTCPCarrier
	w    *batchWriter
	bufs [][]byte
}

func (c *rawTCPCarrier) NewSender() Sender {
	if !c.batched {
		return &rawTCPPlain{c: c}
	}
	return &rawTCPSender{c: c, w: newBatchWriter(), bufs: make([][]byte, 0, sendBatch)}
}

func (s *rawTCPSender) Send(bps []*[]byte) {
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
		c.fr.seal(b[rawTCPHdrLen:])
		c.stamp(b, to)
		s.bufs = append(s.bufs, b)
	}
	out := s.bufs
	for len(out) > 0 {
		n, err := s.w.write(c.rc, out, to)
		if err != nil {
			atomic.AddUint64(&c.sendErrs, 1)
			logging.Debug("raw tcp send batch: %v", err)
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

type rawTCPPlain struct{ c *rawTCPCarrier }

func (s *rawTCPPlain) Send(bps []*[]byte) {
	for _, bp := range bps {
		_ = s.c.Send(bp)
	}
}

func (c *rawTCPCarrier) Run() {
	b := make([]byte, rawTCPRead)
	for {
		n, from, err := c.pc.ReadFromIP(b)
		if n > 0 {
			var a [4]byte
			if v4 := from.IP.To4(); v4 != nil {
				copy(a[:], v4)
			}
			c.handle(b[:n], a)
		}
		if err != nil {
			select {
			case <-c.done:
			default:
				logging.Warn("raw tcp read: %v", err)
			}
			return
		}
	}
}

func (c *rawTCPCarrier) handle(b []byte, from [4]byte) {
	if len(b) >= 20 && b[0]>>4 == 4 {
		ihl := int(b[0]&0x0f) * 4
		if ihl < 20 || len(b) <= ihl {
			return
		}
		b = b[ihl:]
		c.sawIPHeader.Do(func() {
			logging.Debug("the ip header arrives with each segment; stepping over it")
		})
	}
	if len(b) < rawTCPHdrLen {
		return
	}
	if binary.BigEndian.Uint16(b[0:2]) != c.peerPort ||
		binary.BigEndian.Uint16(b[2:4]) != c.myPort {
		atomic.AddUint64(&c.notOurs, 1)
		return
	}
	off := int(b[12]>>4) * 4
	if off < rawTCPHdrLen || len(b) < off+frameLen {
		return
	}

	// Their sequence plus what they sent is what we acknowledge next, which
	// keeps the numbers in a capture consistent with each other.
	their := binary.BigEndian.Uint32(b[4:8])
	c.ack.Store(their + uint32(len(b)-off))

	body, ok := c.fr.open(b[off:])
	if !ok {
		return
	}
	v := binary.BigEndian.Uint32(from[:])
	if v != 0 && c.peer4.Load() != v {
		c.setPeer(net.IPv4(from[0], from[1], from[2], from[3]))
		logging.Info("carrier: the far end is at %d.%d.%d.%d", from[0], from[1], from[2], from[3])
	}

	atomic.AddUint64(&c.rxBytes, uint64(len(b)))
	if len(body) == 0 {
		return
	}
	if f := c.onPacket.Load(); f != nil {
		(*f)(body)
	}
}

func (c *rawTCPCarrier) Keepalive(every time.Duration) {
	keepaliveLoop(c, c.done, every)
}

func (c *rawTCPCarrier) Close() error {
	c.once.Do(func() { close(c.done) })
	return c.pc.Close()
}

func (c *rawTCPCarrier) Lost() (missing, late, gaps uint64) { return c.fr.lost() }

func (c *rawTCPCarrier) Counters() (rx, tx, bad, replay, errs uint64) {
	bad, replay = c.fr.counted()
	return atomic.LoadUint64(&c.rxBytes), atomic.LoadUint64(&c.txBytes),
		bad + atomic.LoadUint64(&c.notOurs), replay,
		atomic.LoadUint64(&c.sendErrs)
}
