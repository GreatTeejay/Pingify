package buf

import "testing"

// The replay window is the one piece of this carrier whose mistakes are
// invisible: getting it wrong drops real packets, and a dropped packet on a
// link carrying IP looks exactly like the path losing one.

func TestAPacketInOrderIsAlwaysFresh(t *testing.T) {
	w := NewReplayWindow()
	for i := uint32(1); i < 20000; i++ {
		if !w.Fresh(i) {
			t.Fatalf("counter %d, arriving in order, was called a replay", i)
		}
	}
}

func TestTheSamePacketTwiceIsNotFreshTwice(t *testing.T) {
	w := NewReplayWindow()
	for _, n := range []uint32{5, 6, 7, 100, 101} {
		if !w.Fresh(n) {
			t.Fatalf("%d should have been Fresh", n)
		}
	}
	for _, n := range []uint32{5, 6, 7, 100, 101} {
		if w.Fresh(n) {
			t.Fatalf("%d came round a second time and was accepted", n)
		}
	}
}

func TestAPacketThatArrivesLateIsStillAccepted(t *testing.T) {
	w := NewReplayWindow()
	// 10 through 20 arrive, but 15 is overtaken and turns up at the end. On a
	// link with no ordering under it that is an ordinary Tuesday, and dropping
	// it would be inventing loss the path did not cause.
	for i := uint32(10); i <= 20; i++ {
		if i == 15 {
			continue
		}
		w.Fresh(i)
	}
	if !w.Fresh(15) {
		t.Fatal("a packet that arrived out of order was thrown away")
	}
	if w.Fresh(15) {
		t.Fatal("and then it was accepted twice")
	}
}

func TestAPacketOlderThanTheWindowIsRefused(t *testing.T) {
	w := NewReplayWindow()
	w.Fresh(1)
	w.Fresh(ReplayDepth + 500)
	if w.Fresh(2) {
		t.Fatal("a counter far below the window was accepted; the window is not sliding")
	}
}

func TestTheWindowStillRemembersAfterAJump(t *testing.T) {
	w := NewReplayWindow()
	for i := uint32(1); i <= 100; i++ {
		w.Fresh(i)
	}
	// A jump of exactly one word, and one of a few bits, are the two shifts
	// with different code paths.
	w.Fresh(164)
	if w.Fresh(100) {
		t.Fatal("64 places on, a counter still inside the window was accepted again")
	}
	w.Fresh(170)
	if w.Fresh(164) {
		t.Fatal("after a short shift, a counter inside the window was accepted again")
	}
	if !w.Fresh(165) {
		t.Fatal("a counter that had never been seen was refused")
	}
}

func TestTheWindowSurvivesTheCounterWrappingRound(t *testing.T) {
	// The counter is 32 bits and wraps. The comparison is signed-difference
	// for exactly this reason: at the wrap, the newer counter is numerically
	// smaller, and an unsigned comparison would call every packet after it a
	// replay and take the link down until a restart.
	w := NewReplayWindow()
	start := uint32(0xffffffff) - 5
	for i := 0; i < 20; i++ {
		if !w.Fresh(start + uint32(i)) {
			t.Fatalf("packet %d across the wrap was called a replay", i)
		}
	}
}

func TestTakeBufLeavesTheHeadroomAlone(t *testing.T) {
	bp := Take(12, 1320)
	if len(*bp) != 12+1320 {
		t.Fatalf("asked for 12 of headroom and 1320 of packet, got %d", len(*bp))
	}
	// Writing the packet must not need the header to move afterwards.
	copy((*bp)[12:], make([]byte, 1320))
	Put(bp)
}
