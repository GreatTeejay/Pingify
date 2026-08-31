package main

import (
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"pingify/internal/carrier"
	"pingify/internal/config"
	"pingify/internal/link"
	"pingify/internal/logging"
	"pingify/internal/status"
)

// Pingify, the core.
//
// A tunnel between a server in Iran and a server abroad. The Iran server is
// the one users reach; the abroad server is the one with the internet on the
// other side of it. What matters about it, in the order it matters: latency,
// then throughput, then staying up. Nothing else is worth a millisecond.
//
// This is the second core. The first one worked, and worked well - by the end
// it was level with the tunnel it was being compared against on ping and ahead
// of it under load. What it did not have was a shape: it was written outward
// from a first working version over two days, so its structure was the order
// in which things were discovered rather than the way the problem is actually
// laid out.
//
// The way the problem is actually laid out:
//
//	a carrier moves messages between the two servers        carrier.go
//	over UDP, or ICMP, or something dressed as TLS          udp.go, ...
//	and one thing rides on it, chosen by the mode:
//	    the private link - one IP packet per message        link.go
//	    forwarded ports  - many connections per carrier     (not yet)
//
// Transports are added one at a time and each is measured on the real path
// between Tehran and Frankfurt before the next one starts. What was learned
// from the first core is in docs/measured.md, and none of it is re-learned
// here by accident: every finding in that file is either satisfied by this
// code or has not been reached yet.
const version = "2.0.0"

func main() {
	// Before anything else, because everything else is downstream of having
	// somewhere to run. See sched.go.
	widenScheduler()

	var (
		cfgPath = flag.String("c", "", "path to the config file")
		check   = flag.Bool("check", false, "read the config, say whether it is good, and stop")
		showVer = flag.Bool("version", false, "print the version and stop")
		ask     = flag.String("status", "", "ask a running tunnel how it is (host:port or just a port) and stop")
		healthz = flag.String("healthz", "", "exit 0 only if the tunnel at this address is up")
	)
	flag.Parse()

	if *showVer {
		fmt.Println("pingify-core " + version)
		return
	}
	if *healthz != "" {
		r, err := status.Fetch(*healthz)
		if err != nil || !r.Up {
			os.Exit(1)
		}
		return
	}
	if *ask != "" {
		r, err := status.Fetch(*ask)
		if err != nil {
			logging.Die("could not ask the tunnel at %s: %v", *ask, err)
		}
		status.Print(r)
		return
	}
	if *cfgPath == "" {
		logging.Die("no config: pass -c /path/to/config.toml")
	}

	cfg, err := config.Load(*cfgPath)
	if err != nil {
		logging.Die("%s: %v", *cfgPath, err)
	}
	if *check {
		fmt.Printf("%s: good - %s side, %s mode, %s transport\n",
			*cfgPath, cfg.Side, cfg.Mode, cfg.Transport.Type)
		return
	}
	logging.SetLevel(cfg.Level)

	logging.Info("pingify-core %s starting: %s, %s side, %s over %s",
		version, cfg.Name, cfg.Side, cfg.Mode, cfg.Transport.Type)

	car, err := carrier.Open(cfg)
	if err != nil {
		logging.Die("carrier: %v", err)
	}

	l, err := link.New(cfg, car)
	if err != nil {
		car.Close()
		logging.Die("private link: %v", err)
	}

	l.Start()
	go car.Run()
	if cfg.Dials() {
		go car.Keepalive(time.Duration(cfg.Transport.Keepalive) * time.Second)
	}
	go reportEvery(30*time.Second, car, l)
	go status.New(cfg, version, car, l).Serve(cfg.StatusPort)

	logging.Info("running")

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop

	logging.Info("stopping")
	l.Close()
	car.Close()
	logging.Info("%s", l)
}

// reportEvery says what the tunnel has been doing, but only when it has been
// doing something. A line every thirty seconds saying nothing happened fills
// a log with the absence of news, and the one line that matters is then in the
// middle of a thousand that do not.
func max64(a, b uint64) uint64 {
	if a > b {
		return a
	}
	return b
}

func reportEvery(every time.Duration, c carrier.Full, l *link.Link) {
	tk := time.NewTicker(every)
	defer tk.Stop()
	var lastRx, lastTx uint64
	var lastMissing, lastLate, lastGaps uint64
	for range tk.C {
		rx, tx, bad, replay, errs := c.Counters()
		if rx == lastRx && tx == lastTx {
			continue
		}
		secs := every.Seconds()
		logging.Info("carrier: %.1f Mbit/s in, %.1f Mbit/s out",
			float64(rx-lastRx)*8/secs/1e6, float64(tx-lastTx)*8/secs/1e6)
		if bad > 0 || replay > 0 {
			logging.Debug("carrier: %d not ours, %d already seen", bad, replay)
		}
		// How much was lost matters less than how it was lost. Losses spread
		// one at a time are noise a congestion window shrugs off; the same
		// number arriving in runs is a window halved once per run.
		if missing, late, gaps := c.Lost(); missing != lastMissing || late != lastLate {
			run := float64(missing-lastMissing) / float64(max64(gaps-lastGaps, 1))
			logging.Info("the path lost %d and reordered %d in the last %s (%d gaps, %.0f packets each)",
				missing-lastMissing, late-lastLate, every, gaps-lastGaps, run)
			lastMissing, lastLate, lastGaps = missing, late, gaps
		}
		if errs > 0 {
			logging.Debug("carrier: %d sends failed", errs)
		}
		if d := l.Dropped(); d > 0 {
			logging.Warn("private link: %d packets could not be put on the wire", d)
		}
		lastRx, lastTx = rx, tx
	}
}
