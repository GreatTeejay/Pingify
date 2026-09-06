package link

import (
	"fmt"
	"os"
	"runtime"
	"sync"
	"sync/atomic"
	"time"

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

	// Where a packet off the wire goes on its way to the device, when the
	// goroutine that read it does not carry it there itself. See writeQueue.
	writers []chan *[]byte
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
	if err := configureDevice(l.name, mine, cfg.TUN.MTU, cfg.TUN.TxQueueLen); err != nil {
		l.closeDevices()
		return nil, err
	}
	logging.Info("private link %s up: %s, mtu %d, %d queues", l.name, mine, cfg.TUN.MTU, n)
	return l, nil
}

// start puts the link to work: one reader per queue taking packets to the
// wire, and the carrier bringing them back the other way.
func (l *Link) Start() {
	l.startWriters()
	l.car.OnPacket(l.fromWire)
	for i := range l.dev {
		l.wg.Add(1)
		go func(f *os.File, q int) {
			defer l.wg.Done()
			l.readQueue(f, q)
		}(l.dev[i], i)
	}
}

// startWriters puts the write into the device on its own goroutines, if the
// config asked for that.
//
// The goroutine that takes a datagram off the socket used to carry it all the
// way into the device, and the device write is a system call: while it is in
// one, it is not reading the socket. A batch of a hundred and twenty eight
// datagrams is a hundred and twenty eight of them in a row, and what arrives
// meanwhile goes into the socket's queue - which is where this tunnel's
// packets were being lost, tens of thousands in a transfer, at every buffer
// size tried.
//
// So the read and the write are separated: the reader hands the packet over
// and goes back to the socket, and a writer goroutine puts it in the device.
// The handover is per flow, by the same hash the device queues use, because
// two goroutines writing one flow would deliver it out of order and the TCP
// inside reads that as loss.
//
// A queue that is full is a packet dropped here rather than by the kernel,
// which is the same signal arriving in the same place, counted honestly.
func (l *Link) startWriters() {
	n := l.cfg.TUN.WriteWorkers
	if n == 0 {
		n = defaultWriteWorkers()
	}
	if n < 0 {
		return // tun.write_workers = -1, the old behaviour, for comparing
	}
	depth := writeQueueDepth
	l.writers = make([]chan *[]byte, n)
	for i := range l.writers {
		l.writers[i] = make(chan *[]byte, depth)
		l.wg.Add(1)
		go func(q chan *[]byte) {
			defer l.wg.Done()
			l.writeQueue(q)
		}(l.writers[i])
	}
	logging.Info("%s: %d goroutines put packets into the device, %d deep,"+
		" so reading the wire never waits on a device write", l.name, n, depth)
}

// writeQueueDepth is how many packets may wait for one writer.
//
// Deep enough to hold a whole burst. The socket reader hands over up to 128
// packets per recvmmsg and the writer behind it may be mid-write, or on a
// one-core server not even scheduled: at 128 the queue was full the moment a
// burst arrived, and two hundred users downloading through an ICMP link lost
// five packets in a hundred inside this machine - 280,000 in two minutes -
// which the TCP inside then paid for in stalls. Three megabytes a worker at
// most, and only when it is behind.
const writeQueueDepth = 1024

// writeQueueWait is how long the reader will wait for a full queue before it
// drops the packet instead.
const writeQueueWait = 5 * time.Millisecond

func (l *Link) writeQueue(q chan *[]byte) {
	for {
		select {
		case bp := <-q:
			l.toDevice1(*bp)
			buf.Put(bp)
		case <-l.closing:
			return
		}
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

// fromWire takes one packet that arrived on the carrier to the device, either
// itself or by handing it to a writer - see startWriters.
//
// It runs on the goroutine that read the datagram off the socket. See
// udpCarrier.run for why there is nothing in between.
func (l *Link) fromWire(b []byte) {
	if len(b) < 20 {
		atomic.AddUint64(&l.short, 1)
		return
	}
	if len(l.writers) == 0 {
		l.toDevice1(b)
		return
	}
	// The buffer belongs to the reader and is reused the moment this returns,
	// so what is handed over is a copy.
	q := l.writers[flowHash(b)%uint32(len(l.writers))]
	bp := buf.Take(0, len(b))
	*bp = (*bp)[:len(b)]
	copy(*bp, b)
	select {
	case q <- bp:
		return
	default:
	}
	// The writer is behind. Wait for it a little rather than dropping at
	// once: a burst that fills the queue is over in a millisecond or two,
	// and a packet dropped here is one the TCP inside has to notice and ask
	// for again across the whole path. Not for long, though - a writer that
	// is stuck must not take the reader down with it, so past this the
	// packet goes and the counter says so.
	t := time.NewTimer(writeQueueWait)
	select {
	case q <- bp:
		t.Stop()
	case <-t.C:
		buf.Put(bp)
		atomic.AddUint64(&l.dropped, 1)
	}
}

// toDevice1 puts one packet into the device.
func (l *Link) toDevice1(b []byte) {
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

// defaultWriteWorkers is one per core, up to four - the same rule the carrier
// uses for how many goroutines read the socket, and for the same reason: a
// writer is what a reader hands to, so one each means no reader ever waits.
//
// It is the machine's number and not a profile's, because the two ends of one
// tunnel are usually not the same machine. Measured on the Tehran to Frankfurt
// pair, four rounds at each setting, every end set the same:
//
//	writers   download   upload   one stream down   p90 down / up   socket lost
//	   0        457        412        569 Mbit/s      106 / 94        5500
//	   1        572        388        578             108 / 82         160
//	   2        532        438        595             107 / 103        830
//
// One is best where the download arrives, which is the Iran server with one
// core; two is best where the upload arrives, which is Frankfurt with two.
// Both are the receiving end, and each wanted as many writers as it has cores,
// which is what this returns.
//
// Against flagtun's ICMP with that rule in place, both tunnels up at once on
// the same wire, six interleaved rounds, medians:
//
//	           download   one stream   upload   p90 under download / upload
//	pingify      528         614         436         106 / 89 ms
//	flagtun      563         523         436         124 / 106
//
// Before this the same six rounds were 467, 566, 388, 110/93 - so it is worth
// sixty megabits on the download, fifty on a single stream, and the whole of
// what the upload was behind by.
func defaultWriteWorkers() int {
	n := runtime.NumCPU()
	if n < 1 {
		return 1
	}
	if n > 4 {
		return 4
	}
	return n
}

// Dropped is how many packets the link could not put on the wire, and Packets
// is how many crossed it each way. The three of them are what a report is made
// of; nothing else above needs to see inside.
func (l *Link) Dropped() uint64 { return atomic.LoadUint64(&l.dropped) }

func (l *Link) Packets() (toWire, toDevice uint64) {
	return atomic.LoadUint64(&l.toWire), atomic.LoadUint64(&l.toDevice)
}

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
