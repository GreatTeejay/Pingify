package main

import "testing"

// The window is not just a number this end chooses. The receiving end drops
// anything too far ahead of what it has, so a wide sender talking to a narrow
// receiver has every segment past that point thrown away, resends them, and
// eventually declares the carrier dead.
//
// That is what updating one server and not the other did: the new end sent
// against a window of 873 while the old end still accepted 128, and the tunnel
// went down. Two things have to hold so it cannot happen again.
func TestAWideSenderCannotOutrunAnOldReceiver(t *testing.T) {
	// 1. Every connection starts where every previous version sat, so a peer
	//    that has not been updated accepts everything it is sent.
	c := newARQ(1, 0, []byte("k"), icmpARQLabel, 1200, arqWindowFor(4096, 1200), func([]byte) error { return nil })
	defer c.Close()
	if c.window != arqWinStart {
		t.Errorf("a fresh connection opens at %d segments, want %d", c.window, arqWinStart)
	}
	if c.maxWindow <= arqWinStart {
		t.Errorf("it should still be allowed to grow: max %d", c.maxWindow)
	}

	// 2. The receive guard is bounded by what any peer may send, never by
	//    what this end happens to be sending - or it becomes a wire parameter
	//    again and the next change to it breaks tunnels the same way.
	narrow := newARQ(2, 0, []byte("k"), icmpARQLabel, 1200, arqWinMin, func([]byte) error { return nil })
	defer narrow.Close()
	narrow.mu.Lock()
	narrow.deliver(uint32(arqWinMax), []byte("late but legal"))
	buffered := len(narrow.rcvBuf)
	narrow.mu.Unlock()
	if buffered == 0 {
		t.Error("a narrow receiver dropped a segment a wide sender is allowed to send")
	}
}

// And the width has to be earned, because a window past what the path carries
// does not go faster - it queues, which is the stall it was meant to cure.
func TestTheWindowGrowsOnProgressAndHalvesOnLoss(t *testing.T) {
	c := newARQ(3, 0, []byte("k"), icmpARQLabel, 1200, 1000, func([]byte) error { return nil })
	defer c.Close()

	c.mu.Lock()
	start := c.window
	for i := 0; i < 200; i++ {
		c.grow()
	}
	grown := c.window
	c.shrink()
	after := c.window
	c.mu.Unlock()

	if grown <= start {
		t.Errorf("window did not widen on clean progress: %d -> %d", start, grown)
	}
	if after != grown/2 {
		t.Errorf("loss should halve it: %d -> %d, want %d", grown, after, grown/2)
	}

	// never below the floor, however much loss there is
	c.mu.Lock()
	for i := 0; i < 50; i++ {
		c.shrink()
	}
	floor := c.window
	c.mu.Unlock()
	if floor != arqWinMin {
		t.Errorf("window fell to %d, want the floor %d", floor, arqWinMin)
	}

	// and never above what the tunnel asked for
	c2 := newARQ(4, 0, []byte("k"), icmpARQLabel, 1200, 100, func([]byte) error { return nil })
	defer c2.Close()
	c2.mu.Lock()
	for i := 0; i < 5000; i++ {
		c2.grow()
	}
	capped := c2.window
	c2.mu.Unlock()
	if capped != 100 {
		t.Errorf("window grew to %d, want it capped at the configured 100", capped)
	}
}

func TestCumulativeACKOpensTheWindowForEverySegment(t *testing.T) {
	c := newARQ(5, 0, []byte("k"), icmpARQLabel, 1200, 1000, func([]byte) error { return nil })
	defer c.Close()
	c.mu.Lock()
	start := c.window
	for i := 0; i < start; i++ {
		c.sndBuf[uint32(i)] = &segment{seq: uint32(i), retries: 1}
	}
	c.sndNext = uint32(start)
	c.processAck(uint32(start))
	got := c.window
	c.mu.Unlock()
	if got != start*2 {
		t.Fatalf("one cumulative ACK for %d clean segments grew %d -> %d, want %d", start, start, got, start*2)
	}
}

func TestARQIgnoresACKBeyondWhatItSent(t *testing.T) {
	c := newARQ(5, 0, []byte("k"), icmpARQLabel, 1200, 1000, func([]byte) error { return nil })
	defer c.Close()
	c.mu.Lock()
	beforeWindow, beforeUna := c.window, c.sndUna
	c.processAck(1000)
	gotWindow, gotUna := c.window, c.sndUna
	c.mu.Unlock()
	if gotWindow != beforeWindow || gotUna != beforeUna {
		t.Fatalf("invalid ACK changed state: window %d -> %d, sndUna %d -> %d", beforeWindow, gotWindow, beforeUna, gotUna)
	}
}
