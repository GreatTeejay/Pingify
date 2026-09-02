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

// fqFlowFactor turns the profile's queue depth into fq's per-flow limit. The
// profile is written for one tunnel's queue; fq counts one flow, and the whole
// tunnel is that one flow. Ten times over is past anything measured here and
// still a bounded queue - at the balanced profile it is nine thousand packets,
// about twelve megabytes, which the tunnel never reaches.
const fqFlowFactor = 10

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
	// The whole tunnel is one flow to fq: a datagram carrier sends every
	// packet from one address to one address, and ICMP and GRE have no ports
	// to tell them apart. So flow_limit is not a fairness knob here, it is a
	// hard cap on the tunnel's own queue, and everything past it is dropped
	// before it leaves this machine.
	//
	// It was the profile's queue depth - nine hundred - and the tunnel was
	// sitting on it. Counted on the real pair during one transfer: 8799
	// packets dropped by our own qdisc going out, and 5754 of a download's
	// "path loss" was this, not the path. With a queue deep enough not to
	// drop, the same transfer lost 156. The throughput was the same either
	// way, so the nine hundred was buying nothing and lying about it: the
	// health check told the operator the path was losing packets that this
	// machine had thrown away itself.
	//
	// The profile still sets how deep, and it is deep enough now that the
	// tunnel does not hit it.
	limit := strconv.Itoa(cfg.Tuning.QueuePkts * fqFlowFactor)
	if strings.Contains(was, "qdisc fq ") && strings.Contains(was, "flow_limit "+limit+"p") {
		logging.Info("%s already spaces packets the way this wants", dev)
		return
	}

	// What the depth is worth, measured at the profile's own numbers when
	// this was the flow limit directly and the tunnel was hitting it:
	//
	//	  queue    16 streams   one stream   under load
	//	   600      327.1        193.1        84.6 / 91.5 ms
	//	   900      476.5        245.6        99.8 / 116.3
	//	  1200      461.6        251.0       104.2 / 127.7
	//	  1500      451.5        254.3       111.6 / 127.3
	//
	// tuning.queue_packets still moves it, ten times over, and the profile
	// still means what that table says about latency against throughput.
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

// pace caps this socket's rate, and by default it does not.
//
// The cap used to be worked out from what the tunnel had carried, raised and
// lowered a second at a time. That is gone. Measured against itself on the
// Tehran to Frankfurt pair, with the interface's queue deep enough not to drop
// (see smoothTheWire), it lost on every count:
//
//	                download   upload   ping p50/p90   path lost
//	cap applied       342       383       76 / 302        175
//	no cap            404       393       75 / 225        182
//
// More throughput, a better tail, and the same loss - the cap was buying
// nothing and charging a third of the download for it. fq on its own does the
// smoothing that mattered, and costs nothing.
//
// A number in the config still means what it says.
func pace(pc net.PacketConn, cfg *config.Config, done <-chan struct{}, sent func() uint64) {
	if !cfg.Tuning.Pace || !cfg.Tuning.PaceMbitSet {
		return
	}
	if cfg.Tuning.PaceMbit > 0 && setPacingRate(pc, cfg.Tuning.PaceMbit*1000*1000/8) {
		logging.Info("packets are paced at %d Mbit/s, as the config asks", cfg.Tuning.PaceMbit)
	}
}
