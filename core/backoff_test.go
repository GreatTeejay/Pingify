package main

import (
	"testing"
	"time"
)

// A full window timing out together is ONE event - the path stopped carrying -
// and it was being treated as sixty-four. Each timed-out segment doubled the
// retransmit timeout and halved the window, so a single stall drove the
// timeout from 500ms to its five-second ceiling on the very first pass.
//
// Twelve retries at five seconds is sixty seconds, which is exactly how long
// a carrier is given before the braid declares the peer gone. So the first
// real stall killed every carrier at once, sixty seconds later, on the dot -
// which is the shape the field logs showed.
func TestOnePassOfLossIsOneBackoff(t *testing.T) {
	c := newARQ(1, 0, []byte("k"), 1200, 512, func([]byte) error { return nil })
	defer c.Close()

	c.mu.Lock()
	startRTO := c.rto
	startWin := c.window

	// a window's worth of segments, all sent long enough ago to have timed out
	old := time.Now().Add(-time.Minute)
	for i := 0; i < 64; i++ {
		c.sndBuf[uint32(i)] = &segment{seq: uint32(i), data: []byte("x"), sentAt: old}
	}
	c.mu.Unlock()

	// one pass of the timer
	time.Sleep(60 * time.Millisecond)

	c.mu.Lock()
	gotRTO := c.rto
	gotWin := c.window
	c.mu.Unlock()

	if gotRTO > startRTO*4 {
		t.Errorf("one pass took the timeout from %v to %v - it should roughly double, not run to the ceiling",
			startRTO, gotRTO)
	}
	if gotWin < startWin/4 {
		t.Errorf("one pass took the window from %d to %d - it should halve, not collapse",
			startWin, gotWin)
	}
	if gotWin >= startWin {
		t.Errorf("loss should still cost something: window %d -> %d", startWin, gotWin)
	}
	t.Logf("one pass of a full window timing out: rto %v -> %v, window %d -> %d",
		startRTO, gotRTO, startWin, gotWin)
}

// And the carrier still has to survive long enough to ride out a blip: twelve
// retries with a doubling back-off is about three quarters of a minute, not
// twelve flat five-second waits.
func TestACarrierRidesOutABlip(t *testing.T) {
	rto := 500 * time.Millisecond
	total := time.Duration(0)
	for i := 0; i < 12; i++ {
		total += rto
		rto *= 2
		if rto > arqMaxRTO {
			rto = arqMaxRTO
		}
	}
	if total < 40*time.Second || total > 55*time.Second {
		t.Errorf("twelve retries add up to %v, which is too little patience", total)
	}
	// and the ceiling is real, so it cannot run away either
	if rto > arqMaxRTO {
		t.Errorf("the back-off passed its ceiling: %v", rto)
	}
	t.Logf("twelve retries with doubling back-off: %v before a carrier is given up", total)
}
