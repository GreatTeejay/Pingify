package carrier

import (
	"fmt"
	"time"

	"pingify/internal/config"
)

// Choosing a carrier, which is the only place the rest of the core learns
// which transport it is running on.
//
// Everything above this line works against Carrier and cannot tell UDP
// from ICMP. That is what makes adding the next one a new file rather than a
// new set of branches through the private link.

// carrier is a Carrier plus the three things only main needs: how to
// start it, how to keep it alive, and what it has been doing.
type Full interface {
	Carrier
	Run()
	Keepalive(time.Duration)
	Counters() (rx, tx, bad, replay, errs uint64)

	// lost is what the far end sent that never arrived, counted from the gaps
	// in its sequence numbers. Nothing else on either machine can see this.
	Lost() (missing, late, gaps uint64)
}

// stream reports whether a transport cannot lose a packet, which is the one
// thing that decides whether parity is worth adding to it.
func stream(kind string) bool {
	switch kind {
	case "tcp", "ws", "wss", "utls":
		return true
	}
	return false
}

func Open(cfg *config.Config) (Full, error) {
	c, err := open(cfg)
	if err != nil {
		return nil, err
	}
	return WrapFEC(c, cfg.Tuning.FEC, stream(cfg.Transport.Type)), nil
}

func open(cfg *config.Config) (Full, error) {
	switch cfg.Transport.Type {
	case "icmp":
		return newICMPCarrier(cfg)
	case "udp":
		return newUDPCarrier(cfg)
	case "tcp":
		return newTCPCarrier(cfg)
	case "ws":
		return newWSCarrier(cfg)
	case "wss":
		return newWSSCarrier(cfg)
	case "gre":
		return newGRECarrier(cfg)
	// AmneziaWG is not a carrier of ours. The link is theirs, brought up by
	// awg-quick from their own packages, and what runs inside it is the same
	// UDP carrier as anywhere else - which is how a tunnel over it still has
	// this core's queue, its counters, its status and its health port.
	case "awg":
		return newUDPCarrier(cfg)
	case "rawtcp":
		return newRawTCPCarrier(cfg)
	case "utls":
		return newUTLSCarrier(cfg)
	}
	return nil, fmt.Errorf("no transport called %q", cfg.Transport.Type)
}
