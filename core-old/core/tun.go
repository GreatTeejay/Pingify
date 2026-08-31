package main

import (
	"crypto/cipher"
	"fmt"
	"net"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// ==========================================================================
// 7. tun mode - layer 3
// ==========================================================================

// tun mode carries whole IP packets instead of individual TCP connections.
// It is the right choice when the far side must be reachable as a machine
// (routing, ICMP, any protocol) rather than as a list of ports.

type tunnel struct {
	cfg    *Config
	p      *pool
	queues []*os.File
	closed chan struct{}
	once   sync.Once

	// When the transport can carry a whole packet with no session under it,
	// this is how the private link travels: one packet, one datagram, no
	// reliability layer. See tunfast.go for why that is the right shape for
	// something carrying IP.
	fast *tunFast
}

// packetCarrier is a transport that can put one whole packet on the wire
// without a session underneath it.
type packetCarrier interface {
	// Headroom is how many bytes the transport needs in front of the payload
	// for its own header. The private link leaves that much room when it
	// builds a packet, so the transport fills it in place instead of taking a
	// second buffer and copying the payload into it - which is what it used
	// to do, once per packet, for every packet.
	Headroom() int

	// SendPacket puts one packet on the wire. (*buf)[:Headroom()] belongs to
	// the transport to fill; the rest is the payload, already built and not
	// copied anywhere. The buffer goes with it: the wire may be written from
	// another thread, so the transport is what returns it to the pool.
	SendPacket(buf *[]byte) error

	SetPacketHandler(func([]byte), *net.IPAddr)
}

func startTUN(cfg *Config, p *pool) (*tunnel, error) {
	t := &tunnel{cfg: cfg, p: p, closed: make(chan struct{})}
	// How many device queues, and so how many threads read the device.
	//
	// This used to be the carrier count, which has nothing to do with it. A
	// carrier is a path across the wire; a queue is a thread competing for
	// this machine's processors, and eight of them on a server with one
	// processor do not read the device eight times faster - they take turns,
	// and everything else on that processor takes its turn behind them.
	//
	// Measured on a one-processor server abroad, a single stream through an
	// ICMP tunnel:
	//
	//	one queue      213 Mbit/s
	//	two queues     270 Mbit/s, and the sender dropped nothing
	//	four queues    262 Mbit/s, sender dropped 227 packets
	//	eight queues   216 Mbit/s
	//
	// At eight the threads reading the device starved the one putting packets
	// on the wire, its queue filled, and it threw away three thousand packets
	// - which the TCP inside read as congestion and answered by halving its
	// window. The machine was not short of work to do. It was short of turns.
	//
	// So the count follows the processors, with two as a floor because one
	// queue cannot overlap a read with anything, and eight as a ceiling
	// because past that the descriptors cost more than the parallelism pays.
	n := runtime.GOMAXPROCS(0)
	if n < 2 {
		n = 2
	}
	if n > 8 {
		n = 8
	}
	if cfg.Carriers > 0 && n > cfg.Carriers {
		n = cfg.Carriers
	}
	for i := 0; i < n; i++ {
		f, err := openTUN(cfg.TUN.Name, n > 1)
		if err != nil {
			t.Close()
			return nil, fmt.Errorf("open %s queue %d: %v", cfg.TUN.Name, i, err)
		}
		t.queues = append(t.queues, f)
	}
	if err := configureTUN(cfg.TUN); err != nil {
		t.Close()
		return nil, err
	}
	p.setHandler(t)

	// One writer per device queue: the queues are what make parallel writes
	// worth anything, and a writer with no queue of its own would only queue
	// behind another.
	t.startFast()
	for i := range t.queues {
		go t.readQueue(t.queues[i])
	}
	logInfo("tun %s up: %s peer %s mtu %d, %d queues",
		cfg.TUN.Name, cfg.TUN.Local, cfg.TUN.Peer, cfg.TUN.MTU, len(t.queues))
	return t, nil
}

func configureTUN(c TUNConfig) error {
	run := func(args ...string) error {
		out, err := exec.Command("ip", args...).CombinedOutput()
		if err != nil {
			msg := strings.TrimSpace(string(out))
			// Re-adding an address after a restart is expected, not an error.
			if strings.Contains(msg, "File exists") {
				return nil
			}
			return fmt.Errorf("ip %s: %v: %s", strings.Join(args, " "), err, msg)
		}
		return nil
	}
	if err := run("link", "set", "dev", c.Name, "mtu", fmt.Sprint(c.MTU), "up"); err != nil {
		return err
	}
	if c.Local != "" {
		// The "peer" form is right for a point-to-point /30 or /32. On a
		// wider prefix both addresses live in the same subnet and a plain
		// address is what gives the kernel the route it needs.
		pfx := ""
		if i := strings.LastIndex(c.Local, "/"); i >= 0 {
			pfx = c.Local[i+1:]
		}
		ptp := c.Peer != "" && (pfx == "30" || pfx == "31" || pfx == "32")
		if ptp {
			peer := c.Peer
			if i := strings.Index(peer, "/"); i >= 0 {
				peer = peer[:i]
			}
			if err := run("addr", "add", c.Local, "peer", peer, "dev", c.Name); err != nil {
				return err
			}
		} else if err := run("addr", "add", c.Local, "dev", c.Name); err != nil {
			return err
		}
	}
	return nil
}

func (t *tunnel) readQueue(f *os.File) {
	for {
		r := getRec()
		n, err := f.Read(r.body())
		if n > 0 {
			if t.fast != nil {
				// Straight onto the wire. No braid, no window, no ordering -
				// the packet is its own datagram and arrives or does not,
				// which is what IP has always promised the layers above it.
				if e := t.fast.Send(r.body()[:n]); e != nil {
					logDebug("tun send: %v", e)
				}
				putRec(r)
			} else {
				r.seal(cmdTUN, 0, n)
				r.enq = time.Now().UnixNano()
				l := t.p.pickHash(flowHash(r.body()[:n]))
				if l == nil {
					putRec(r)
				} else {
					atomic.AddUint64(&l.txBytes, uint64(n))
					l.send(r)
				}
			}
		} else {
			putRec(r)
		}
		if err != nil {
			select {
			case <-t.closed:
			default:
				logWarn("tun read: %v", err)
			}
			return
		}
	}
}

func (t *tunnel) onRecord(l *link, cmd byte, id uint32, body []byte) {
	if cmd != cmdTUN || len(t.queues) == 0 {
		return
	}
	atomic.AddUint64(&l.rxBytes, uint64(len(body)))
	t.toDevice(body)
}

// startFast puts the private link on the direct path when the transport can
// carry a whole packet on its own.
//
// Only the packet transports can: a stream transport has no packet boundaries
// to put one in, and TCP is already reliable and ordered whatever we do, so
// there is nothing to gain there anyway.
func (t *tunnel) startFast() {
	pc, ok := t.p.tr.(packetCarrier)
	if !ok {
		return
	}

	// Its own keys, and a different label from anything the braid derives, so
	// the two paths cannot be confused for one another even in principle.
	var tx, rx cipher.AEAD
	if t.cfg.encrypted() {
		prk := hkdfExtract([]byte("pingify/v3 tun packets"), t.cfg.key())
		out := hkdfExpand(prk, []byte("iran to kharej"), 32)
		in := hkdfExpand(prk, []byte("kharej to iran"), 32)
		if t.cfg.Role != "server" {
			out, in = in, out
		}
		tx, rx = aeadFrom(out), aeadFrom(in)
	}

	var peer *net.IPAddr
	if host := t.cfg.Connect; host != "" {
		if h, _, err := net.SplitHostPort(host); err == nil {
			host = h
		}
		if ip, err := net.ResolveIPAddr("ip4", host); err == nil {
			peer = ip
		}
	}

	t.fast = newTunFast(tx, rx, pc.Headroom(), pc.SendPacket, t.toDevice)
	pc.SetPacketHandler(t.fast.Deliver, peer)

	how := "encrypted"
	if !t.cfg.encrypted() {
		how = "in the clear"
	}
	logInfo("private link goes straight onto the wire, %s: one packet per datagram,"+
		" nothing ordering or resending them", how)
}

// toDevice writes one IP packet to the interface, whichever path brought it.
// toDevice writes one received packet to the device.
//
// The reader that took it off the socket writes it, here, with nothing in
// between. That is worth saying because it was not always so: a layer of
// per-flow writers and batched handovers sat here for a while, on the
// reasoning that one thread doing every write would serialise them.
//
// It did, and it was still faster. Measured once the kernel's receive buffer
// was no longer being silently clamped - which was the real reason the reader
// could not keep up - with sixteen streams pushing through the link:
//
//	               p50      p90      p99    throughput
//	batched      160 ms   179 ms   561 ms   427 Mbit/s
//	written here 113 ms   133 ms   146 ms   444 Mbit/s
//
// Better on every one of them. The handovers cost more in wakeups than the
// writes cost in waiting, and the queue in front of them was one more place
// for delay to hide. What made the batching look necessary was a bug
// somewhere else.
func (t *tunnel) toDevice(pkt []byte) {
	if len(t.queues) == 0 {
		return
	}
	// The queue is chosen by the flow, never round-robin.
	//
	// Round-robin here quietly destroyed the thing the send side had been
	// careful to preserve. A flow is pinned to one carrier so its packets stay
	// in order on the wire, and then every packet that arrived was handed to
	// the next device queue in turn. Several queues drain at once, so one
	// flow's packets reached the kernel in whatever order the queues happened
	// to run, and the TCP inside saw its own segments shuffled.
	//
	// Measured on a real 37 ms path: the inner connection reported 1071
	// reordering events, retransmitted 400 KB it had never lost, and its round
	// trip rose from 37 ms to 187 ms. Hashing the flow to a queue costs one
	// pass over the header and keeps every flow on one queue, in order.
	q := t.queues[flowHash(pkt)%uint32(len(t.queues))]
	if _, err := q.Write(pkt); err != nil {
		logDebug("tun write: %v", err)
	}
}

func (t *tunnel) onLinkDown(*link) {}

// bothHandler runs a private layer-3 link and port forwarding over the same
// carriers. Raw IP packets go to the tun device, everything else to the
// forwarder, so one tunnel can give you a private network between the two
// servers and forwarded ports at the same time.
type bothHandler struct {
	f *forwarder
	t *tunnel
}

func (b *bothHandler) onRecord(l *link, cmd byte, id uint32, body []byte) {
	if cmd == cmdTUN {
		b.t.onRecord(l, cmd, id, body)
		return
	}
	b.f.onRecord(l, cmd, id, body)
}

func (b *bothHandler) onLinkDown(l *link) {
	b.f.onLinkDown(l)
	b.t.onLinkDown(l)
}

func (b *bothHandler) Close() error {
	b.f.Close()
	b.t.Close()
	return nil
}

func (t *tunnel) Close() error {
	t.once.Do(func() {
		close(t.closed)
		for _, f := range t.queues {
			f.Close()
		}
	})
	return nil
}

// flowHash folds the 5-tuple of an IP packet into one number. Every packet of
// a given inner connection lands on the same carrier, so the inner TCP never
// sees the reordering that unequal carrier latency would otherwise create.
func flowHash(pkt []byte) uint32 {
	h := uint32(2166136261)
	mix := func(b []byte) {
		for _, c := range b {
			h ^= uint32(c)
			h *= 16777619
		}
	}
	if len(pkt) < 20 {
		return 0
	}
	switch pkt[0] >> 4 {
	case 4:
		ihl := int(pkt[0]&0x0f) * 4
		if ihl < 20 || len(pkt) < ihl {
			return 0
		}
		mix(pkt[12:20]) // src + dst
		proto := pkt[9]
		mix([]byte{proto})
		if (proto == 6 || proto == 17) && len(pkt) >= ihl+4 {
			mix(pkt[ihl : ihl+4]) // src + dst port
		}
	case 6:
		if len(pkt) < 40 {
			return 0
		}
		mix(pkt[8:40])
		nh := pkt[6]
		mix([]byte{nh})
		if (nh == 6 || nh == 17) && len(pkt) >= 44 {
			mix(pkt[40:44])
		}
	}
	// FNV leaves its weakest bits at the bottom, and a modulus takes exactly
	// those. It happens to spread runs of ephemeral source ports well enough,
	// but only by luck of the multiplier - the guarantee is worth having when
	// the cost is four instructions once per flow, and it is what keeps the
	// carrier and the device queue from ever agreeing to cluster.
	h ^= h >> 16
	h *= 0x85ebca6b
	h ^= h >> 13
	h *= 0xc2b2ae35
	h ^= h >> 16
	return h
}
