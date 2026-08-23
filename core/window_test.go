package main

import "testing"

// A stream is pinned to one carrier for its life, so the segments the ARQ
// allows in flight decide how fast a single download can go - window * payload
// / round-trip - however many carriers the tunnel has.
//
// That number used to be the constant 64. At 1200 bytes and 75 ms it caps one
// stream at about 8 Mbit/s, which is under what a 1080p video asks for, and
// nothing in the manager could change it: the Tuning screen offered window_kb
// and the ICMP transport never read it.
func TestTheIcmpWindowFollowsTheTunnelSetting(t *testing.T) {
	const payload = 1200

	// what the presets ask for, in the unit the ARQ counts in
	for _, c := range []struct {
		windowKB int
		want     int
	}{
		{256, 218},   // gaming: small on purpose, latency over throughput
		{1024, 873},  // balanced
		{4096, 3495}, // extreme
	} {
		if got := arqWindowFor(c.windowKB, payload); got != c.want {
			t.Errorf("window_kb %d -> %d segments, want %d", c.windowKB, got, c.want)
		}
	}

	// and it stays inside bounds that mean something
	if got := arqWindowFor(1, payload); got != arqWinMin {
		t.Errorf("a tiny window gave %d, want the floor %d", got, arqWinMin)
	}
	if got := arqWindowFor(1<<20, payload); got != arqWinMax {
		t.Errorf("an absurd window gave %d, want the ceiling %d", got, arqWinMax)
	}
	if got := arqWindowFor(0, payload); got != arqWinMin {
		t.Errorf("an unset window gave %d, want the floor %d", got, arqWinMin)
	}
}

// The point of the change, stated as the thing a user would notice.
func TestOneStreamCanNowOutrunTheOldCeiling(t *testing.T) {
	const payload = 1200
	const rttSeconds = 0.075

	mbit := func(segments int) float64 {
		return float64(segments*payload*8) / rttSeconds / 1e6
	}

	old := mbit(64)
	if old > 10 {
		t.Fatalf("the old ceiling was meant to be about 8 Mbit/s, got %.1f", old)
	}
	now := mbit(arqWindowFor(1024, payload))
	if now < 80 {
		t.Errorf("one stream on the balanced preset reaches %.0f Mbit/s, want at least 80", now)
	}
	t.Logf("one stream at 75ms: was %.0f Mbit/s, now %.0f Mbit/s", old, now)
}
