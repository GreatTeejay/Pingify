package carrier

import (
	"strings"
	"testing"
	"time"

	"pingify/internal/buf"
)

// A trio running on its primary, for the menu's questions.
func runningTrio(t *testing.T) (w, d *failover) {
	t.Helper()
	w, d = failoverTrio(t, true, "")
	w.OnPacket(func([]byte) {})
	d.OnPacket(func([]byte) {})
	go w.Run()
	go d.Run()
	go d.Keepalive(200 * time.Millisecond)
	waitFor(t, "connecting on the primary", 5*time.Second, func() bool { return d.Active() == "tcp" && d.Up() })
	// A record each way every tenth of a second, as a tunnel with users on it
	// always has: a careful move waits to hear the far end on the member it
	// moves to, and the side that waits knows which member carries only by
	// the records that arrive on it.
	stop := make(chan struct{})
	t.Cleanup(func() { close(stop) })
	go func() {
		tk := time.NewTicker(100 * time.Millisecond)
		defer tk.Stop()
		for {
			select {
			case <-stop:
				return
			case <-tk.C:
			}
			for _, c := range []*failover{d, w} {
				bp := buf.Take(c.Headroom(), 8)
				copy((*bp)[c.Headroom():], "chatter!")
				_ = c.SendFlow(0, bp)
			}
		}
	}()
	return w, d
}

// field is one member's line from Lines, split.
func field(t *testing.T, c *failover, member int) []string {
	t.Helper()
	ls := c.Lines()
	if member >= len(ls) {
		t.Fatalf("no line for member %d in %q", member, ls)
	}
	return strings.Fields(ls[member])
}

// The menu's "check them now": every member but the one in use is tried, the
// tunnel stays where it is, and each line then says the member answered and
// how quickly.
func TestTheMenuCanCheckTheBackups(t *testing.T) {
	_, d := runningTrio(t)

	if f := field(t, d, 1); f[6] != "-" || f[7] != "-" {
		t.Fatalf("a member nobody has tried already reads %v", f)
	}
	said, err := d.Control("check", -1, false)
	if err != nil {
		t.Fatal(err)
	}
	if said != "2 of 2 answered" {
		t.Errorf("the check said %q", said)
	}
	if a := d.Active(); a != "tcp" {
		t.Errorf("checking moved the tunnel to %s", a)
	}
	for _, i := range []int{1, 2} {
		f := field(t, d, i)
		if f[4] != "-" || f[7] != "ok" || f[8] == "-" {
			t.Errorf("member %d after the check: %v", i, f)
		}
	}
	if f := field(t, d, 0); f[4] != "use" {
		t.Errorf("the member in use reads %v", f)
	}
}

// A member that does not answer is said to, and the tunnel stays put.
func TestACheckSaysWhichMemberDoesNotAnswer(t *testing.T) {
	w, d := runningTrio(t)
	w.retire(w.members[1]) // Chrome TLS stops listening

	said, err := d.Control("check", -1, false)
	if err != nil {
		t.Fatal(err)
	}
	if said != "1 of 2 answered" {
		t.Errorf("the check said %q", said)
	}
	if f := field(t, d, 1); f[7] != "no" {
		t.Errorf("the member that stopped reads %v", f)
	}
	if f := field(t, d, 2); f[7] != "ok" {
		t.Errorf("the member that answers reads %v", f)
	}
}

// Moved by hand without holding, the tunnel goes back to the primary once it
// has answered for return_after; held, it stays until let go, and then goes
// back.
func TestAMoveByHandIsHeldOnlyWhenAskedTo(t *testing.T) {
	_, d := runningTrio(t)

	said, err := d.Control("use", 2, false)
	if err != nil {
		t.Fatal(err)
	}
	if a := d.Active(); a != "kcp" || !strings.HasPrefix(said, "moved to kcp") {
		t.Fatalf("asked for kcp: on %s, said %q", a, said)
	}
	waitFor(t, "going back to the primary by itself", 12*time.Second, func() bool { return d.Active() == "tcp" })

	if _, err := d.Control("use", 1, true); err != nil {
		t.Fatal(err)
	}
	if f := field(t, d, 1); d.Active() != "utls" || f[4] != "use" || f[5] != "held" {
		t.Fatalf("held on utls: on %s, reads %v", d.Active(), f)
	}
	// Past return_after and a probe or two: a member not held would be back.
	time.Sleep(5 * time.Second)
	if a := d.Active(); a != "utls" {
		t.Fatalf("held on utls, and the tunnel went to %s by itself", a)
	}
	said, err = d.Control("auto", -1, false)
	if err != nil || !strings.HasPrefix(said, "deciding alone again") {
		t.Fatalf("letting go: %q, %v", said, err)
	}
	waitFor(t, "going back to the primary once let go", 12*time.Second, func() bool { return d.Active() == "tcp" })
	if f := field(t, d, 1); f[5] != "-" {
		t.Errorf("still marked held after being let go: %v", f)
	}
}

// A member held by hand that goes quiet is left like any other: holding is
// not a reason to carry nothing.
func TestAHeldMemberThatGoesQuietIsLeft(t *testing.T) {
	w, d := runningTrio(t)
	if _, err := d.Control("use", 1, true); err != nil {
		t.Fatal(err)
	}
	w.retire(w.members[1])
	waitFor(t, "leaving the held member once it went quiet", 12*time.Second, func() bool { return d.Active() != "utls" && d.Up() })
	if f := field(t, d, int(d.active.Load())); f[5] == "held" {
		t.Errorf("the member it moved to is marked held: %v", f)
	}
}

// The side that waits decides nothing, and says so; it still knows which
// member carries.
func TestTheWaitingSideCannotBeAskedToMove(t *testing.T) {
	w, _ := runningTrio(t)
	for _, op := range []string{"check", "use", "auto"} {
		if _, err := w.Control(op, 1, false); err == nil {
			t.Errorf("%s was accepted by the side that waits", op)
		}
	}
	waitFor(t, "the waiting side seeing the primary carry", 5*time.Second, func() bool {
		return field(t, w, 0)[4] == "use"
	})
}

func TestAMemberThatIsNotThereCannotBeAskedFor(t *testing.T) {
	_, d := runningTrio(t)
	for _, to := range []int{-1, 3} {
		if _, err := d.Control("use", to, false); err == nil {
			t.Errorf("member %d was accepted", to)
		}
	}
	if _, err := d.Control("fly", 0, false); err == nil {
		t.Error("an unknown request was accepted")
	}
}
