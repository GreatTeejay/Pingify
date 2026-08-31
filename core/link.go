package main

import (
	"fmt"
	"os"
	"runtime"
	"sync"
	"sync/atomic"
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
type link struct {
	cfg *Config
	car packetCarrier

	dev  []*os.File
	name string

	closing chan struct{}
	once    sync.Once
	wg      sync.WaitGroup

	toWire, toDevice uint64
	dropped          uint64
	short            uint64
}

func newLink(cfg *Config, car packetCarrier) (*link, error) {
	l := &link{cfg: cfg, car: car, name: cfg.TUN.Name, closing: make(chan struct{})}

	// The queue count follows the processors, with two as a floor because one
	// queue cannot overlap a read with anything, and eight as a ceiling
	// because past that the readers starve the sender: at eight the sender's
	// queue filled and it threw away three thousand packets, which the TCP
	// inside read as congestion and answered by halving its window. The
	// machine was not short of work to do. It was short of turns.
	n := runtime.GOMAXPROCS(0)
	if n < deviceQueuesMin {
		n = deviceQueuesMin
	}
	if n > deviceQueuesMax {
		n = deviceQueuesMax
	}

	for i := 0; i < n; i++ {
		f, err := openTUN(l.name, n > 1)
		if err != nil {
			l.closeDevices()
			return nil, err
		}
		l.dev = append(l.dev, f)
	}

	mine, _ := cfg.mine()
	if err := configureDevice(l.name, mine, cfg.TUN.MTU); err != nil {
		l.closeDevices()
		return nil, err
	}
	logInfo("private link %s up: %s, mtu %d, %d queues", l.name, mine, cfg.TUN.MTU, n)
	return l, nil
}

// start puts the link to work: one reader per queue taking packets to the
// wire, and the carrier bringing them back the other way.
func (l *link) start() {
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
// The packet is read straight into a buffer that already has the carrier's
// headroom in front of it, so nothing is copied and nothing is shifted along
// afterwards to make room for a header that was known about before the read.
func (l *link) readQueue(f *os.File, q int) {
	head := l.car.Headroom()
	max := l.car.MaxPayload()
	for {
		bp := takeBuf(head, max)
		b := *bp
		n, err := f.Read(b[head:])
		if n > 0 {
			*bp = b[:head+n]
			if e := l.car.Send(bp); e != nil {
				atomic.AddUint64(&l.dropped, 1)
			} else {
				atomic.AddUint64(&l.toWire, 1)
			}
		} else {
			bufPool.Put(bp)
		}
		if err != nil {
			select {
			case <-l.closing:
			default:
				logWarn("device queue %d: %v", q, err)
			}
			return
		}
	}
}

// fromWire writes one packet that arrived on the carrier to the device.
//
// It runs on the goroutine that read the datagram off the socket, and writes
// from there. See udpCarrier.run for why there is nothing in between.
func (l *link) fromWire(b []byte) {
	if len(b) < 20 {
		atomic.AddUint64(&l.short, 1)
		return
	}
	f := l.dev[flowHash(b)%uint32(len(l.dev))]
	if _, err := f.Write(b); err != nil {
		select {
		case <-l.closing:
		default:
			logDebug("device write: %v", err)
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

func (l *link) closeDevices() {
	for _, f := range l.dev {
		f.Close()
	}
}

func (l *link) Close() error {
	l.once.Do(func() {
		close(l.closing)
		l.closeDevices()
	})
	return nil
}

func (l *link) String() string {
	return fmt.Sprintf("%s: %d packets to the wire, %d to the device, %d dropped",
		l.name, atomic.LoadUint64(&l.toWire), atomic.LoadUint64(&l.toDevice),
		atomic.LoadUint64(&l.dropped))
}
