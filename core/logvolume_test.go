package main

import (
	"strings"
	"testing"
	"time"
)

// A 24-carrier tunnel wrote 24 near-identical lines every time it came up,
// and the same again every time the far end restarted. The one line that
// said something - the far server refusing the token, a port with nothing
// behind it - arrived in the middle of that and was never seen.
//
// What an operator needs is the strength of the braid and the reason it
// changed, so the volume must follow the count of carriers, not the count of
// events.
func TestTheLogReportsStrengthNotEveryCarrier(t *testing.T) {
	setLogLevel("info")
	cfg := &Config{Carriers: 8}
	p := newPool(cfg)

	lines := captureLog(func() {
		for i := 0; i < cfg.Carriers; i++ {
			p.mu.Lock()
			p.links[i] = &link{idx: i, closed: make(chan struct{})}
			p.mu.Unlock()
			p.noteStrength()
		}
	})

	if len(lines) > 2 {
		t.Fatalf("eight carriers arriving wrote %d lines, want at most 2:\n%s",
			len(lines), strings.Join(lines, "\n"))
	}
	joined := strings.Join(lines, "\n")
	if !strings.Contains(joined, "tunnel up") {
		t.Errorf("nothing announced the tunnel arriving:\n%s", joined)
	}
	if !strings.Contains(joined, "all 8 carriers up") {
		t.Errorf("nothing announced full strength:\n%s", joined)
	}
}

// Losing carriers is the interesting direction, and it has to say so once
// with a count rather than once per carrier.
func TestLosingCarriersIsOneLineWithACount(t *testing.T) {
	setLogLevel("info")
	cfg := &Config{Carriers: 8}
	p := newPool(cfg)
	for i := 0; i < cfg.Carriers; i++ {
		p.links[i] = &link{idx: i, closed: make(chan struct{})}
	}
	p.noteStrength()

	lines := captureLog(func() {
		for i := 0; i < 3; i++ {
			close(p.links[i].closed)
		}
		p.noteStrength()
	})
	if len(lines) != 1 {
		t.Fatalf("three carriers dropping wrote %d lines, want 1:\n%s",
			len(lines), strings.Join(lines, "\n"))
	}
	if !strings.Contains(lines[0], "5 of 8") || !strings.Contains(lines[0], "3 went down") {
		t.Errorf("the line does not say how many are left or how many went:\n%s", lines[0])
	}
}

// Every carrier fails the same way at the same instant when the other server
// is unreachable, so the dial error has to be throttled - and it has to name
// the machine, because "carrier 7 dial" tells a reader nothing about which of
// their two servers to go and look at.
func TestAnUnreachablePeerIsSaidOnceAndNamed(t *testing.T) {
	setLogLevel("warn")
	cfg := &Config{Carriers: 8, Connect: "198.51.100.4:9443"}
	p := newPool(cfg)

	lines := captureLog(func() {
		for i := 0; i < cfg.Carriers; i++ {
			if p.firstIn("dial", time.Minute) {
				logWarn("cannot reach the other server at %s: %v", cfg.Connect, errICMPClosed)
			}
		}
	})
	if len(lines) != 1 {
		t.Fatalf("eight carriers failing wrote %d lines, want 1:\n%s",
			len(lines), strings.Join(lines, "\n"))
	}
	if !strings.Contains(lines[0], cfg.Connect) {
		t.Errorf("the line does not name the server that could not be reached:\n%s", lines[0])
	}
}
