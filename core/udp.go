package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"hash"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

// UDP, the first carrier, and the shape every other packet carrier follows.
//
// On the wire a datagram is:
//
//	0                 8                12
//	+-----------------+----------------+-----------------------------+
//	|  tag (8)        |  seq (4)       |  the IP packet              |
//	+-----------------+----------------+-----------------------------+
//
// The tag is what says a datagram is ours. Anyone can send to an open UDP
// port, and without it the first thing a scanner sends would be handed
// straight to the kernel as an IP packet.
//
// It is one hash over the sequence number and the first bytes of the packet -
// not the whole packet, which at four hundred megabits would mean hashing
// fifty megabytes a second to learn what the first thirty-two bytes already
// say. One hash per packet, not two: the old core built a second tag it then
// checked in a different order, and that was pure cost.
//
// There is no encryption here and none is wanted. What travels through this
// tunnel is already TLS, and what is asked of the tunnel is speed, ping and
// stability.
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
// Six, and only ever six. A fresh destination port gets six, a fresh source
// port gets six, waiting a minute gets six, forty packets fired back to back
// get six. Captures on both ends at the same time say which direction: Germany
// received every packet and answered every one, and six of the answers reached
// Iran.
//
// So UDP is not a slow transport on this path. It is an unusable one, and no
// amount of tuning here changes that - which is the whole reason ICMP is the
// transport worth making good rather than the fallback.
//
// This carrier stays anyway. It is the same code an ICMP carrier needs minus
// the raw socket, so it is the cheapest place to get the shape right, and this
// is one path on one ISP on one day. Somebody else's will carry UDP happily.
const (
	udpTagLen   = 8
	udpSeqLen   = 4
	udpHeadroom = udpTagLen + udpSeqLen
	udpTagOver  = 32 // how many bytes of the payload the tag covers
	udpMaxDgram = 1500
)

var errNoPeer = errors.New("no peer yet")

type udpCarrier struct {
	pc  *net.UDPConn
	key []byte
	hp  sync.Pool // hash.Hash, kept rather than made per packet

	seq  uint32
	peer atomic.Pointer[net.UDPAddr]

	onPacket atomic.Pointer[func([]byte)]

	done chan struct{}
	once sync.Once

	rxBytes, txBytes   uint64
	rxPackets          uint64
	badTag, replayed   uint64
	sendErrs, noPeerTx uint64

	seen *replayWindow
}

func newUDPCarrier(cfg *Config) (*udpCarrier, error) {
	c := &udpCarrier{
		key:  carrierKey(cfg.Token, "pingify udp v1"),
		done: make(chan struct{}),
		seen: newReplayWindow(),
	}
	c.hp.New = func() any { return hmac.New(sha256.New, c.key) }

	if cfg.dials() {
		// Iran dials out. The socket stays unconnected and the peer is
		// remembered instead, because the abroad side may answer from a
		// different source port when anything on the way rewrites addresses.
		raddr, err := net.ResolveUDPAddr("udp4",
			net.JoinHostPort(cfg.Transport.Kharej, fmt.Sprint(cfg.Transport.Port)))
		if err != nil {
			return nil, fmt.Errorf("resolve %s: %v", cfg.Transport.Kharej, err)
		}
		pc, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: 0})
		if err != nil {
			return nil, fmt.Errorf("open udp socket: %v", err)
		}
		c.pc = pc
		c.peer.Store(raddr)
		logInfo("carrier: dialling %s over udp", raddr)
		return c, nil
	}

	pc, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: cfg.Transport.Port})
	if err != nil {
		return nil, fmt.Errorf("listen on udp/%d: %v", cfg.Transport.Port, err)
	}
	c.pc = pc
	logInfo("carrier: waiting on udp/%d", cfg.Transport.Port)
	return c, nil
}

func (c *udpCarrier) Headroom() int   { return udpHeadroom }
func (c *udpCarrier) MaxPayload() int { return udpMaxDgram - udpHeadroom }
func (c *udpCarrier) Up() bool        { return c.peer.Load() != nil }

func (c *udpCarrier) OnPacket(f func([]byte)) { c.onPacket.Store(&f) }

// tag writes the eight bytes that say a datagram is ours.
func (c *udpCarrier) tag(dst, seqAndBody []byte) {
	m := c.hp.Get().(hash.Hash)
	m.Reset()
	m.Write(seqAndBody)
	var sum [sha256.Size]byte
	copy(dst, m.Sum(sum[:0])[:udpTagLen])
	c.hp.Put(m)
}

// covered is how much of a datagram the tag is computed over.
func covered(b []byte) []byte {
	if len(b) > udpHeadroom+udpTagOver {
		return b[udpTagLen : udpHeadroom+udpTagOver]
	}
	return b[udpTagLen:]
}

func (c *udpCarrier) Send(bp *[]byte) error {
	peer := c.peer.Load()
	if peer == nil {
		bufPool.Put(bp)
		atomic.AddUint64(&c.noPeerTx, 1)
		return errNoPeer
	}
	b := *bp
	if len(b) < udpHeadroom {
		bufPool.Put(bp)
		return nil
	}
	binary.BigEndian.PutUint32(b[udpTagLen:udpHeadroom], atomic.AddUint32(&c.seq, 1))
	c.tag(b[:udpTagLen], covered(b))

	n, err := c.pc.WriteToUDP(b, peer)
	bufPool.Put(bp)
	if err != nil {
		atomic.AddUint64(&c.sendErrs, 1)
		return err
	}
	atomic.AddUint64(&c.txBytes, uint64(n))
	return nil
}

// run reads datagrams until the socket closes, handing each one that carries
// the right tag to the layer above - on this goroutine, with nothing in
// between.
//
// The reader that took the packet off the socket is the one that writes it to
// the device. A layer of per-flow writers and batched handovers was tried
// there, on the reasoning that one thread doing every write would serialise
// them. It did, and it was still faster: p50 113 ms and 444 Mbit/s written
// here, against 160 ms and 427 Mbit/s handed over.
func (c *udpCarrier) run() {
	buf := make([]byte, udpMaxDgram)
	for {
		n, from, err := c.pc.ReadFromUDP(buf)
		if n >= udpHeadroom {
			c.handle(buf[:n], from)
		}
		if err != nil {
			select {
			case <-c.done:
			default:
				logWarn("udp read: %v", err)
			}
			return
		}
	}
}

func (c *udpCarrier) handle(b []byte, from *net.UDPAddr) {
	var want [udpTagLen]byte
	c.tag(want[:], covered(b))
	if !hmac.Equal(want[:], b[:udpTagLen]) {
		atomic.AddUint64(&c.badTag, 1)
		return
	}

	seq := binary.BigEndian.Uint32(b[udpTagLen:udpHeadroom])
	if !c.seen.fresh(seq) {
		atomic.AddUint64(&c.replayed, 1)
		return
	}

	// The tag was right, so this is the far end, wherever it is speaking from.
	// The side that waits learns the address here and nowhere else.
	if p := c.peer.Load(); p == nil || p.Port != from.Port || !p.IP.Equal(from.IP) {
		cp := *from
		c.peer.Store(&cp)
		logInfo("carrier: the far end is at %s", from)
	}

	atomic.AddUint64(&c.rxBytes, uint64(len(b)))
	atomic.AddUint64(&c.rxPackets, 1)

	body := b[udpHeadroom:]
	if len(body) == 0 {
		return // a keepalive, which has done its whole job by arriving
	}
	if f := c.onPacket.Load(); f != nil {
		(*f)(body)
	}
}

// keepalive holds the path open, and on the side that waits it is the only
// thing that says where the far end is. The side that dials sends it, because
// before a datagram arrives the other side knows nothing to send to.
func (c *udpCarrier) keepalive(every time.Duration) {
	tk := time.NewTicker(every)
	defer tk.Stop()
	for {
		select {
		case <-c.done:
			return
		case <-tk.C:
			bp := takeBuf(udpHeadroom, 0)
			if err := c.Send(bp); err != nil && !errors.Is(err, errNoPeer) {
				logDebug("keepalive: %v", err)
			}
		}
	}
}

func (c *udpCarrier) Close() error {
	c.once.Do(func() { close(c.done) })
	return c.pc.Close()
}

// carrierKey turns the token the user typed into the key a carrier tags with.
// Each carrier has its own label, so a datagram built for one can never be
// mistaken for a datagram built for another - which matters the moment two
// tunnels between the same pair of servers share a token.
func carrierKey(token, label string) []byte {
	m := hmac.New(sha256.New, []byte(label))
	m.Write([]byte(token))
	return m.Sum(nil)
}
