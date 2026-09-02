package buf

import "testing"

// One end restarts, its counter goes back to nought, and the other end must
// not go on refusing everything it sends until somebody restarts that one
// too. Measured on the real pair before this: "2084 already seen", nothing
// carried, for as long as anyone waited.
func TestAFarEndThatRestartedIsBelievedAfterARunOfOldPackets(t *testing.T) {
	w := NewReplayWindow()
	for seq := uint32(1); seq <= 100000; seq++ {
		w.Fresh(seq)
	}
	// One packet from before the window is a replay and stays refused.
	if w.Fresh(5) {
		t.Fatal("a single ancient packet was accepted")
	}
	// A run of them is a restart. The last of the run is accepted, and the
	// window has moved: what follows it is fresh again.
	accepted := false
	for seq := uint32(6); seq < 6+restartRun; seq++ {
		accepted = w.Fresh(seq)
	}
	if !accepted {
		t.Fatalf("after %d packets from a restarted far end, still refusing it", restartRun)
	}
	if !w.Fresh(6 + restartRun) {
		t.Fatal("the packet after the run was refused; the window did not move")
	}
	if w.Fresh(6 + restartRun) {
		t.Fatal("the same packet twice was accepted; the window is not a window any more")
	}
}

// The run has to be a run. An in-window packet between two ancient ones is
// ordinary reordering, and it starts the count again.
func TestOldPacketsSpacedOutAreStillReplays(t *testing.T) {
	w := NewReplayWindow()
	for seq := uint32(1); seq <= 100000; seq++ {
		w.Fresh(seq)
	}
	for i := uint32(0); i < 3*restartRun; i++ {
		if w.Fresh(10 + i) {
			t.Fatalf("ancient packet %d was accepted with fresh ones in between", 10+i)
		}
		w.Fresh(100001 + i) // a live packet, which is what a real path sends
	}
}
