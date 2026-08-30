package main

import (
	"net"
	"runtime"

	"golang.org/x/net/ipv4"
)

// packetReadTuning is deliberately about the packet transports, not TCP.
// A larger batch amortises recvmmsg and Go scheduler overhead, while a small
// one hands an interactive packet to the tunnel sooner. More readers help a
// fast ICMP/UDP path, but only up to the CPUs the process can actually run on.
func packetReadTuning(profile string) (workers, batch int) {
	cores := runtime.GOMAXPROCS(0)
	if cores < 1 {
		cores = 1
	}
	capWorkers := func(n int) int {
		if n > cores {
			n = cores
		}
		if n < 1 {
			n = 1
		}
		return n
	}

	switch profile {
	case "gaming":
		workers, batch = capWorkers(1), 32
	case "latency":
		workers, batch = capWorkers(2), 64
	case "throughput":
		workers, batch = capWorkers(6), 256
	case "extreme":
		workers, batch = capWorkers(8), 512
	default: // balanced, custom and configs written before profiles existed
		workers, batch = capWorkers(4), 128
	}

	// recvmmsg is the optimisation. ReadBatch is intentionally not used on
	// systems where x/net has no implementation; the core still builds and
	// the old one-packet path remains available there.
	if runtime.GOOS != "linux" {
		return 1, 1
	}
	return workers, batch
}

// startPacketReaders drains one datagram socket with a Linux recvmmsg fast
// path and a portable ReadFrom fallback. handle must finish before it returns:
// the slice belongs to the reader and is reused for the next batch.
//
// A few readers may receive packets from the same session out of order. Both
// ARQ and KCP are built to accept exactly that, and each ARQ session serialises
// its own state. What we gain is that one busy CPU no longer caps every ICMP
// carrier on the server.
//
// ordered says that assumption does not hold here. The private link's direct
// path has no reordering layer under it by design - a packet is sealed on its
// own and written to the device the moment it arrives - so two readers taking
// consecutive recvmmsg batches and finishing in either order is not a detail
// the layer above absorbs. It is delivered to the device that way, and the TCP
// inside the tunnel counts it as loss.
//
// It was measured doing exactly that. With two readers on a real Iran-Germany
// ICMP tunnel the inner connection reported 487 and then 7346 reordering
// events, its congestion window collapsed from 1165 segments to 48, and one
// stream delivered 6.3 Mbit/s. A reference tunnel on the same path, the same
// minute, with one reader, reported no reordering at all and delivered 122.
// One reader is not a compromise here: it is four times faster.
//
// endBatch, when it is not nil, is called once after every socket read,
// whatever the read brought back. That is what lets the layer above hand a
// whole batch onward in one go rather than a packet at a time - the thing the
// profile said was costing more than the work itself. It is called from this
// goroutine and from nowhere else, so what it touches needs no lock as long as
// there is one reader, which ordered guarantees.
func startPacketReaders(pc net.PacketConn, done <-chan struct{}, profile string,
	ordered bool, maxPacket int, handle func([]byte, net.Addr), endBatch func(),
	onError func(error)) (int, int) {
	workers, batch := packetReadTuning(profile)
	if ordered {
		workers = 1
	}
	for i := 0; i < workers; i++ {
		if batch > 1 {
			go packetBatchReadLoop(pc, done, batch, maxPacket, handle, endBatch, onError)
		} else {
			go packetSingleReadLoop(pc, done, maxPacket, handle, endBatch, onError)
		}
	}
	return workers, batch
}

func packetBatchReadLoop(pc net.PacketConn, done <-chan struct{}, batch, maxPacket int,
	handle func([]byte, net.Addr), endBatch func(), onError func(error)) {
	p := ipv4.NewPacketConn(pc)
	msgs := make([]ipv4.Message, batch)
	bufs := make([][]byte, batch)
	for i := range msgs {
		bufs[i] = make([]byte, maxPacket)
		msgs[i].Buffers = [][]byte{bufs[i]}
	}

	// Until this reader has delivered its first packet we do not know the
	// socket does recvmmsg at all. Three failures before that point and we
	// stop guessing: the plain reader works everywhere, and it is what this
	// transport used before batching existed.
	delivered := false
	fails := 0

	for {
		n, err := p.ReadBatch(msgs, 0)
		for i := 0; i < n; i++ {
			if msgs[i].N > 0 {
				delivered = true
				handle(bufs[i][:msgs[i].N], msgs[i].Addr)
			}
		}
		if endBatch != nil {
			endBatch()
		}
		if err == nil {
			fails = 0
			continue
		}
		select {
		case <-done:
			return
		default:
		}
		if !delivered {
			fails++
			if fails >= 3 {
				logWarn("batched receive is not working on this socket (%v) - "+
					"falling back to the plain reader", err)
				packetSingleReadLoop(pc, done, maxPacket, handle, endBatch, onError)
				return
			}
		}
		onError(err)
	}
}

func packetSingleReadLoop(pc net.PacketConn, done <-chan struct{}, maxPacket int,
	handle func([]byte, net.Addr), endBatch func(), onError func(error)) {
	buf := make([]byte, maxPacket)
	for {
		n, addr, err := pc.ReadFrom(buf)
		if err == nil {
			handle(buf[:n], addr)
			if endBatch != nil {
				endBatch()
			}
			continue
		}
		select {
		case <-done:
			return
		default:
			onError(err)
		}
	}
}

// tunePacketSocket gives a burst somewhere to wait while the userspace ARQ is
// scheduled. Packet transports did not pass through tuneSocket, so their
// sndbuf_kb/rcvbuf_kb settings used to be written to the config and ignored.
func tunePacketSocket(pc net.PacketConn, cfg *Config) {
	if c, ok := pc.(interface{ SetReadBuffer(int) error }); ok && cfg.RcvBufKB > 0 {
		_ = c.SetReadBuffer(cfg.RcvBufKB * 1024)
	}
	if c, ok := pc.(interface{ SetWriteBuffer(int) error }); ok && cfg.SndBufKB > 0 {
		_ = c.SetWriteBuffer(cfg.SndBufKB * 1024)
	}

	// And again without the clamp, because the calls above are quietly cut to
	// net.core.rmem_max and nothing says so. See sockbuf_linux.go: a socket
	// that asked for sixteen megabytes and got four hundred kilobytes had
	// thrown away nine hundred packets before anything above it noticed.
	gotR, gotS := forceSocketBuffer(pc, cfg.RcvBufKB*1024, cfg.SndBufKB*1024)
	if gotR > 0 || gotS > 0 {
		logInfo("packet socket buffers: asked %d/%d KiB, got %d/%d KiB",
			cfg.RcvBufKB, cfg.SndBufKB, gotR/1024, gotS/1024)
		if cfg.RcvBufKB > 0 && gotR < cfg.RcvBufKB*1024/2 {
			logWarn("the kernel cut the receive buffer to %d KiB - raise "+
				"net.core.rmem_max, or packets will be dropped before this "+
				"tunnel ever sees them", gotR/1024)
		}
	}
}
