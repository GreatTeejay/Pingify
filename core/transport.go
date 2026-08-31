package main

import (
	"fmt"
	"time"
)

// Choosing a carrier, which is the only place the rest of the core learns
// which transport it is running on.
//
// Everything above this line works against packetCarrier and cannot tell UDP
// from ICMP. That is what makes adding the next one a new file rather than a
// new set of branches through the private link.

// carrier is a packetCarrier plus the three things only main needs: how to
// start it, how to keep it alive, and what it has been doing.
type carrier interface {
	packetCarrier
	run()
	keepalive(time.Duration)
	counters() (rx, tx, bad, replay, errs uint64)

	// lost is what the far end sent that never arrived, counted from the gaps
	// in its sequence numbers. Nothing else on either machine can see this.
	lost() (missing, late, gaps uint64)
}

func openCarrier(cfg *Config) (carrier, error) {
	switch cfg.Transport.Type {
	case "icmp":
		return newICMPCarrier(cfg)
	case "udp":
		return newUDPCarrier(cfg)
	}
	return nil, fmt.Errorf("no transport called %q", cfg.Transport.Type)
}
