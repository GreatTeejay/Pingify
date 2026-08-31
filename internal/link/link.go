package link

import (
	"fmt"
	"os"
	"sync"
	"sync/atomic"

	"pingify/internal/buf"
	"pingify/internal/carrier"
	"pingify/internal/config"
	"pingify/internal/logging"
)

// The private link: a layer-3 interface on each server, and one datagram on
// the carrier for each IP packet that crosses it.
//
// There is nothing under it. No ordering, no windows, no retransmission, no
// acknowledgements - and that is not a shortcut, it is the point. Everything
// that travels through this link is already TCP or QUIC, which have spent
// thirty years learning to recover from exactly the losses a second layer
// underneath would be hiding. Hiding them does not make them stop happening;
// it makes them arrive late instead of not at all, and late is worse, because
// the sender inside has already sent another copy.
//
// The old core got this backwards: the link was built on a stream multiplexer
// with per-stream credit windows, and the direct path had to be added beside
// it later. Here the direct path is the only path.
type Link struct {
	cfg *config.Config
	car carrier.Carrier

	dev  []*os.File
	name string

	closing chan struct{}
	once    sync.Once
	wg      sync.WaitGroup

	toWire, toDevice uint64
	dropped          uint64
	short            uint64

	burst int // how many packets may go on the wire in one crossing
}

func New(cfg *config.Config, car carrier.Carrier) (*Link, error) {
	l := &Link{cfg: cfg, car: car, name: cfg.TUN.Name, closing: make(chan struct{}),
		burst: car.Burst()}

	n := cfg.TUN.Queues
	if n == 0 {
		n = defaultQueues()
	}

	for i := 0; i < n; i++ {
		f, err := openTUN(l.name, n > 1)
		if err != nil {
			l.closeDevices()
			return nil, err
		}
		l.dev = append(l.dev, f)
	}

	mine, _ := cfg.Mine()
	if err := configureDevice(l.name, mine, cfg.TUN.MTU); err != nil {
		l.closeDevices()
		return nil, err
	}
	logging.Info("private link %s up: %s, mtu %d, %d queues", l.name, mine, cfg.TUN.MTU, n)
	return l, nil
}

// start puts the link to work: one reader per queue taking packets to the
// wire, and the carrier bringing them back the other way.
func (l *Link) Start() {
	l.car.OnPacket(l.fromWire)
	for i := range l.dev {
		l.wg.Add(1)
		go func(f *os.File, q int) {
			defer l.wg.Done()
			l.readQueue(f, q)
		}(l.dev[i], i)
	}
}

// readQueue takes packets off one device queue and puts them on the wire.
//
// It blocks for the first packet, then takes whatever else is already waiting
// behind it - without waiting for it - and hands the lot to the carrier as one
// batch. A link with one packet on it therefore sends one packet immediately,
// and a link with a hundred sends them in one crossing into the kernel.
//
// The goroutine that read the packets is the one that sends them. Batching
// behind a channel with a single draining goroutine was tried first, and it is
// the obvious design: it cost a single stream 245 Mbit/s down to 164, because
// one flow is read by one device queue, so every one of its packets crossed
// the channel and waited to be scheduled on the far side. Sixteen streams
// never noticed - there was always something to batch - which is exactly how a
// design like that survives a benchmark.
//
// Each packet is read straight into a buffer that already has the carrier's
// headroom in front of it, so nothing is copied and nothing is shifted along
// afterwards to make room for a header that was known about before the read.
func (l *Link) readQueue(f *os.File, q int) {
	head, max := l.car.Headroom(), l.car.MaxPayload()
	sender := l.car.NewSender()
	rc := rawOf(f)
	held := make([]*[]byte, 0, l.burst)

	for {
		bp := buf.Take(head, max)
		n, err := f.Read((*bp)[head:])
		if n > 0 {
			*bp = (*bp)[:head+n]
			held = append(held, bp)
		} else {
			buf.Put(bp)
		}

		// Whatever else is already there comes along for the same crossing.
		for rc != nil && len(held) > 0 && len(held) < l.burst {
			nb := buf.Take(head, max)
			m, ok := readNow(rc, (*nb)[head:])
			if !ok {
				buf.Put(nb)
				break
			}
			*nb = (*nb)[:head+m]
			held = append(held, nb)
		}

		if len(held) > 0 {
			atomic.AddUint64(&l.toWire, uint64(len(held)))
			sender.Send(held)
			held = held[:0]
		}

		if err != nil {
			select {
			case <-l.closing:
			default:
				logging.Warn("device queue %d: %v", q, err)
			}
			return
		}
	}
}

// fromWire writes one packet that arrived on the carrier to the device.
//
// It runs on the goroutine that read the datagram off the socket, and writes
// from there. See udpCarrier.run for why there is nothing in between.
func (l *Link) fromWire(b []byte) {
	if len(b) < 20 {
		atomic.AddUint64(&l.short, 1)
		return
	}
	f := l.dev[flowHash(b)%uint32(len(l.dev))]
	if _, err := f.Write(b); err != nil {
		select {
		case <-l.closing:
		default:
			logging.Debug("device write: %v", err)
		}
		return
	}
	atomic.AddUint64(&l.toDevice, 1)
}

// flowHash picks a device queue from the packet's addresses and ports, so that
// every packet of one connection lands on the same queue and the receiver
// inside is not handed its own stream out of order.
//
// Round robin was tried and is wrong for exactly that reason: it spreads one
// connection across every queue, and the reordering it causes looks to the TCP
// inside like loss.
func flowHash(p []byte) uint32 {
	if len(p) < 20 || p[0]>>4 != 4 {
		return 0
	}
	ihl := int(p[0]&0x0f) * 4
	h := uint32(2166136261)
	for _, c := range p[12:20] { // source and destination address
		h = (h ^ uint32(c)) * 16777619
	}
	h = (h ^ uint32(p[9])) * 16777619 // protocol
	if (p[9] == 6 || p[9] == 17) && len(p) >= ihl+4 {
		for _, c := range p[ihl : ihl+4] { // source and destination port
			h = (h ^ uint32(c)) * 16777619
		}
	}
	// A last mix, because the low bits of an FNV hash of four bytes are not
	// well spread on their own and the low bits are the ones a modulo takes.
	h ^= h >> 16
	h *= 2246822507
	h ^= h >> 13
	return h
}

// defaultQueues is how many device queues to open when the config does not
// say. See the note on reordering in readQueue for why more is not better.
func defaultQueues() int { return 1 }

// Dropped is how many packets the link could not put on the wire. It is the
// one number above that main has any business seeing.
func (l *Link) Dropped() uint64 { return atomic.LoadUint64(&l.dropped) }

func (l *Link) closeDevices() {
	for _, f := range l.dev {
		f.Close()
	}
}

func (l *Link) Close() error {
	l.once.Do(func() {
		close(l.closing)
		l.closeDevices()
	})
	return nil
}

func (l *Link) String() string {
	return fmt.Sprintf("%s: %d packets to the wire, %d to the device, %d dropped",
		l.name, atomic.LoadUint64(&l.toWire), atomic.LoadUint64(&l.toDevice),
		atomic.LoadUint64(&l.dropped))
}
