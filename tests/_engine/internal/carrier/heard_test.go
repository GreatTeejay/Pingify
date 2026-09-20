package carrier

import (
	"testing"
	"time"
)

// A datagram carrier has no connection to lose. Before this, one that had
// learned the far end's address reported itself up for ever - through an
// outage, through the far end being switched off, through the path being
// taken away - and the manager, the health check and the watchdog all
// believed it.
func TestSilenceIsNotBeingUp(t *testing.T) {
	var h heard
	h.listen(10) // ten second keepalives

	if h.recently() {
		t.Fatal("nothing has been heard yet, so nothing was heard recently")
	}
	h.touch()
	if !h.recently() {
		t.Fatal("a packet has just arrived and the far end counts as silent")
	}
	if h.FarSeen().IsZero() {
		t.Fatal("a packet has arrived and there is no time for it")
	}

	// Far enough back to be outside the window, without waiting for it.
	h.at.Store(int64(time.Since(carrierStart) - h.within - time.Second))
	if h.recently() {
		t.Fatal("the far end has been silent past the window and still counts as heard")
	}
	h.touch()
	if !h.recently() {
		t.Fatal("the far end came back and is still counted as gone")
	}
}

// Three keepalives of silence, and never less than half a minute - so a
// tunnel whose keepalive is a second is not called down between two of them.
func TestTheWindowIsThreeKeepalivesAndNeverLessThanHalfAMinute(t *testing.T) {
	for _, c := range []struct {
		keepalive int
		want      time.Duration
	}{
		{1, 30 * time.Second},
		{10, 30 * time.Second},
		{15, 45 * time.Second},
		{60, 180 * time.Second},
	} {
		var h heard
		h.listen(c.keepalive)
		if h.within != c.want {
			t.Errorf("keepalive %ds: the window is %s, expected %s", c.keepalive, h.within, c.want)
		}
	}
}
