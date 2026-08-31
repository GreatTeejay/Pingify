//go:build linux

package carrier

import (
	"bufio"
	"net"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"

	"pingify/internal/config"
	"pingify/internal/logging"
)

// Smoothing what we put on the wire.
//
// A tunnel does not generate traffic, it repeats it - and the TCP inside has
// already decided when each packet should go. Then something stalls the reader
// for a few milliseconds, a hundred packets pile up behind it, and we hand all
// hundred to the wire as fast as the system calls will go. The path treats
// that the way paths treat bursts: it drops a run of it.
//
// Counted at the far end, one stream pushing, the same fifteen seconds:
//
//	the path lost 895 in the last 30s (9 gaps, 99 packets each)
//
// Ninety-nine at a time. A window survives losses spread one at a time; it
// does not survive nine cliffs a minute.
//
// The kernel already knows how to fix this, and it is the fq queue discipline.
// fq spaces a socket's packets out instead of letting them leave in a clump,
// and that alone - with no rate given, nothing tuned to this path - was most
// of the difference. Three runs each, interleaved:
//
//	eth0 qdisc      one stream    retransmissions
//	fq_codel        187.2 Mbit/s  247, 847, 201
//	fq              229.7         86
//	fq, paced       243.7         none
//
// A rate cap on top helps further but has to suit the path - 400 Mbit/s gave
// 253.8 here where 200 throttled us to 181 - so it is offered and not assumed.
// fq on its own needs no number and cannot be set too low.
const soMaxPacingRate = 47

// egressInterface is the one the default route leaves by, read from the
// kernel rather than guessed at from a name.
func egressInterface() string {
	f, err := os.Open("/proc/net/route")
	if err != nil {
		return ""
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Scan() // the header
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) > 1 && fields[1] == "00000000" {
			return fields[0]
		}
	}
	return ""
}

// rootQdisc is the whole line describing what currently spaces this
// interface's packets - the kind and everything it was set with.
//
// The whole line, not just the kind. Checking only for "fq" and stopping
// there left an interface someone had set to fq with a flow_limit of two
// hundred exactly as it was, and two hundred packets is not enough queue to
// carry anything: sixteen streams fell from 450 Mbit/s to 183 and one stream
// to 75, while the tunnel logged that the queue was already what it wanted.
func rootQdisc(dev string) string {
	out, err := exec.Command("tc", "qdisc", "show", "dev", dev, "root").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// smoothTheWire puts fq on the way out, unless it is already there or the
// config asked us not to.
//
// This is a change to the whole interface and is said out loud for that
// reason. fq is a reasonable queue for anything - it is the default on a lot
// of systems already - and it does not cap anything by itself, so the rest of
// what the server does is unaffected.
func smoothTheWire(cfg *config.Config) {
	if !cfg.Tuning.Pace {
		return
	}
	dev := egressInterface()
	if dev == "" {
		logging.Debug("could not tell which interface leaves this machine; not touching the queue")
		return
	}
	was := rootQdisc(dev)
	if was == "" {
		logging.Debug("could not read the queue on %s", dev)
		return
	}
	limit := strconv.Itoa(cfg.Tuning.QueuePkts)
	if strings.Contains(was, "qdisc fq ") && strings.Contains(was, "flow_limit "+limit+"p") {
		logging.Info("%s already spaces packets the way this wants", dev)
		return
	}

	// flow_limit is how many packets one flow may have waiting, and both ends
	// of the range are wrong. The default of a hundred is the size of the
	// burst this exists to smooth, so it would drop exactly what we came to
	// space out. Twenty thousand - which is what this asked for first - is a
	// quarter of a second of queue at four hundred megabits, and it behaves
	// like one: when the rate cap sits briefly under what is being offered,
	// the queue fills and every packet behind it waits.
	//
	//	  flow_limit   ping under load   16 streams    one stream
	//	     20000       102.8 ms         456.4         246.9 Mbit/s
	//	      2000       104.5            449.9         240.7
	//	       600        88.9            337.4         247.7
	//	       200        82.1            232.1          75.8
	//
	// Measured once at twenty thousand, with the cap still catching up: p50
	// 302 ms and a tail at 1174.
	//
	// Between the floor and that, it is one straight trade and there is no
	// setting on it that is free. Restarted fresh at each depth:
	//
	//	  queue    16 streams   one stream   under load
	//	   600      327.1        193.1        84.6 / 91.5 ms
	//	   900      476.5        245.6        99.8 / 116.3
	//	  1200      461.6        251.0       104.2 / 127.7
	//	  1500      451.5        254.3       111.6 / 127.3
	//
	// Nine hundred is where the two stop fighting. It carries more than any
	// other depth measured - more than flagtun on the same path - keeps a
	// single stream within a few percent of the best it ever manages, and
	// still answers under load faster than flagtun does. Six hundred buys
	// fifteen milliseconds more and pays a third of the throughput for them,
	// which is the wrong side of the trade for a link people watch video over.
	//
	// tuning.queue_packets moves it, and the table says what that costs.
	args := []string{"qdisc", "replace", "dev", dev, "root", "fq", "flow_limit", limit}
	if out, err := exec.Command("tc", args...).CombinedOutput(); err != nil {
		logging.Warn("could not put fq on %s (%v: %s) - packets will leave in bursts"+
			" and the path will drop runs of them", dev, err, strings.TrimSpace(string(out)))
		return
	}
	logging.Info("%s now spaces packets with fq, %s packets deep (%s), so a burst"+
		" leaves as a stream (this changes the queue for everything on %s)",
		dev, limit, cfg.Tuning.Profile, dev)
}

// Choosing the rate without being told it.
//
// Half the link speed was the obvious answer and it is not available: every
// server this runs on is a virtual machine, and virtio_net reports its speed
// as -1. Both of ours do. A number in the config is no better - nobody can
// compute what the path between Tehran and Frankfurt will carry, and a wrong
// one either throttles the tunnel or does nothing.
//
// So it is measured. The tunnel knows exactly how many bytes it put on the
// wire, so once a second it works out the rate, keeps the highest it has ever
// managed, and holds the cap half again above that.
//
// The peak only ever rises, which is what makes this safe: the cap cannot fall
// below a rate already achieved, so it can never throttle the tunnel to less
// than it was doing. And it cannot run away either - the peak only grows when
// the path actually carried more, so on a path that stops at 275 Mbit/s the
// cap settles at about 410 and stays there.
//
// Half again is where the measurements pointed. On this path, which carries
// about 275, the sweep was flat between 350 and 700:
//
//	cap      one stream
//	200      181.0 Mbit/s   throttled
//	280      235.0
//	400      253.8
//	600      245.3
//	1000     237.2
//	none     229.7          bursts get through and the path drops runs
const (
	paceHeadroom = 3       // over 2: the cap is one and a half times the peak
	paceIdleBps  = 1 << 20 // below this a second, nothing is being carried
	paceLearnFor = 3       // seconds of real traffic before clamping anything
)

// paceAdaptively keeps the socket's pacing rate a little above the fastest
// this tunnel has been seen to go.
//
// It starts with no cap at all, and that is not an oversight. A cap chosen
// before anything has been measured is a cap chosen at random, and the first
// attempt here proved it: starting at a floor of 25 Mbit/s throttled the TCP
// inside from the first second, so the rate never grew, so the cap never grew.
// It sat at 23 Mbit/s for three runs in a row. A loop that learns from what it
// limits has to be allowed to see the thing unlimited first.
//
// So it watches for a few seconds, takes the best second it saw, and holds the
// cap half again above it. The peak only ever rises, which is what makes this
// safe: the cap can never fall below a rate already achieved, so it cannot
// throttle the tunnel to less than it was doing. It cannot run away either -
// the peak only grows when the path actually carried more - so on a path that
// stops at 275 Mbit/s it settles around 410 and stays there.
func paceAdaptively(pc net.PacketConn, done <-chan struct{}, sent func() uint64) {
	tk := time.NewTicker(time.Second)
	defer tk.Stop()
	var last, peak, applied uint64
	var busy int
	for {
		select {
		case <-done:
			return
		case <-tk.C:
			now := sent()
			rate := now - last
			last = now
			if rate < paceIdleBps {
				continue // idle, and an idle second says nothing about the path
			}
			busy++

			// The peak follows what the tunnel is doing now, not the best it
			// ever did. Sixteen streams push it far above what one stream can
			// use, and a cap set from that is no cap at all: measured, after a
			// sixteen-stream run the cap sat at 793 Mbit/s and a single stream
			// fell back to 228 from the 255 it manages when the cap suits it.
			//
			// So a busy second that is slower than the peak lets the peak down
			// by a sixty-fourth, which halves it in about forty seconds, and it
			// can never fall below the rate actually being carried. An idle
			// second does nothing at all - it is not evidence about the path.
			if rate > peak {
				peak = rate
			} else if peak -= peak / 64; rate > peak {
				peak = rate
			}
			if busy < paceLearnFor {
				continue
			}
			want := peak * paceHeadroom / 2
			// A little hysteresis, so the cap is not rewritten every second
			// for a percent either way.
			if applied > 0 && want < applied+applied/16 && want > applied-applied/16 {
				continue
			}
			if !setPacingRate(pc, int(want)) {
				return // the kernel will not have it; stop asking
			}
			if applied == 0 {
				logging.Info("pacing follows the path: %d Mbit/s, from the %d it carried",
					want*8/1e6, peak*8/1e6)
			} else {
				logging.Debug("pacing now %d Mbit/s", want*8/1e6)
			}
			applied = want
		}
	}
}

// setPacingRate asks the kernel to spread this socket's packets over time, and
// says whether it was allowed to.
func setPacingRate(pc net.PacketConn, bytesPerSecond int) bool {
	sc, ok := pc.(syscall.Conn)
	if !ok {
		return false
	}
	raw, err := sc.SyscallConn()
	if err != nil {
		return false
	}
	ok = false
	_ = raw.Control(func(fd uintptr) {
		if e := syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET,
			soMaxPacingRate, bytesPerSecond); e != nil {
			logging.Debug("could not set a pacing rate: %v", e)
			return
		}
		ok = true
	})
	return ok
}

// pace spaces this socket's packets out. With a rate in the config that rate
// is used and nothing changes it; without one, it follows the path. Either way
// it does nothing at all unless the interface uses fq, which is why
// smoothTheWire runs first.
func pace(pc net.PacketConn, cfg *config.Config, done <-chan struct{}, sent func() uint64) {
	if !cfg.Tuning.Pace {
		return
	}
	if cfg.Tuning.PaceMbitSet {
		if cfg.Tuning.PaceMbit > 0 && setPacingRate(pc, cfg.Tuning.PaceMbit*1000*1000/8) {
			logging.Info("packets are paced at %d Mbit/s, as the config asks", cfg.Tuning.PaceMbit)
		}
		return
	}
	go paceAdaptively(pc, done, sent)
}
