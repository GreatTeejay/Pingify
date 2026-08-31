package main

import (
	"flag"
	"fmt"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"
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
const version = "2.0.0-udp"

func main() {
	// Before anything else, because everything else is downstream of having
	// somewhere to run. See sched.go.
	widenScheduler()

	var (
		cfgPath = flag.String("c", "", "path to the config file")
		check   = flag.Bool("check", false, "read the config, say whether it is good, and stop")
		showVer = flag.Bool("version", false, "print the version and stop")
	)
	flag.Parse()

	if *showVer {
		fmt.Println("pingify-core " + version)
		return
	}
	if *cfgPath == "" {
		die("no config: pass -c /path/to/config.toml")
	}

	cfg, err := loadConfig(*cfgPath)
	if err != nil {
		die("%s: %v", *cfgPath, err)
	}
	if *check {
		fmt.Printf("%s: good - %s side, %s mode, %s transport\n",
			*cfgPath, cfg.Side, cfg.Mode, cfg.Transport.Type)
		return
	}
	setLogLevel(cfg.Level)

	logInfo("pingify-core %s starting: %s, %s side, %s over %s",
		version, cfg.Name, cfg.Side, cfg.Mode, cfg.Transport.Type)

	car, err := newUDPCarrier(cfg)
	if err != nil {
		die("carrier: %v", err)
	}

	l, err := newLink(cfg, car)
	if err != nil {
		car.Close()
		die("private link: %v", err)
	}

	l.start()
	go car.run()
	if cfg.dials() {
		go car.keepalive(time.Duration(cfg.Transport.Keepalive) * time.Second)
	}
	go reportEvery(30*time.Second, car, l)

	logInfo("running")

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop

	logInfo("stopping")
	l.Close()
	car.Close()
	logInfo("%s", l)
}

// reportEvery says what the tunnel has been doing, but only when it has been
// doing something. A line every thirty seconds saying nothing happened fills
// a log with the absence of news, and the one line that matters is then in the
// middle of a thousand that do not.
func reportEvery(every time.Duration, c *udpCarrier, l *link) {
	tk := time.NewTicker(every)
	defer tk.Stop()
	var lastRx, lastTx uint64
	for range tk.C {
		rx := atomic.LoadUint64(&c.rxBytes)
		tx := atomic.LoadUint64(&c.txBytes)
		if rx == lastRx && tx == lastTx {
			continue
		}
		secs := every.Seconds()
		logInfo("carrier: %.1f Mbit/s in, %.1f Mbit/s out",
			float64(rx-lastRx)*8/secs/1e6, float64(tx-lastTx)*8/secs/1e6)
		if bad := atomic.LoadUint64(&c.badTag); bad > 0 {
			logDebug("carrier: %d datagrams were not ours", bad)
		}
		if d := atomic.LoadUint64(&l.dropped); d > 0 {
			logWarn("private link: %d packets could not be put on the wire", d)
		}
		lastRx, lastTx = rx, tx
	}
}
