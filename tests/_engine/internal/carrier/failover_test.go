package carrier

import (
	"bytes"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"pingify/internal/buf"
	"pingify/internal/config"
)

// freePort finds a port nothing is using, for a transport of the given family.
func freePort(t *testing.T, udp bool) int {
	t.Helper()
	if udp {
		pc, err := net.ListenPacket("udp4", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		defer pc.Close()
		return pc.LocalAddr().(*net.UDPAddr).Port
	}
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	return ln.Addr().(*net.TCPAddr).Port
}

// failoverConfig writes a config the way the manager would and reads it back
// through the real loader, so what is tested is what a server runs.
func failoverConfig(t *testing.T, side string, tcpPort, kcpPort int) *config.Config {
	t.Helper()
	return failoverConfigN(t, side, tcpPort, kcpPort, 0, "")
}

// failoverConfigN is the same with a third member, Chrome TLS, when utlsPort
// is not zero, and a preference when one is given.
func failoverConfigN(t *testing.T, side string, tcpPort, kcpPort, utlsPort int, prefer string) *config.Config {
	t.Helper()
	backups := fmt.Sprintf(`["utls:%d", "kcp:%d"]`, utlsPort, kcpPort)
	if utlsPort == 0 {
		backups = fmt.Sprintf(`["kcp:%d"]`, kcpPort)
	}
	extra := ""
	if prefer != "" {
		extra = "prefer = \"" + prefer + "\"\n"
	}
	body := fmt.Sprintf(`
[tunnel]
side = %q
mode = "forward"
[transport]
type = "tcp"
iran = "127.0.0.1"
kharej = "127.0.0.1"
port = %d
connections = 2
[security]
token = "a token for the failover test"
[tuning]
pace = false
[failover]
backups = %s
%s[status]
port = 0
`, side, tcpPort, backups, extra)
	path := filepath.Join(t.TempDir(), side+".toml")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := config.Load(path)
	if err != nil {
		t.Fatalf("%s config: %v", side, err)
	}
	return cfg
}

// quick shortens every clock the decision runs on, from tens of seconds to
// what a test can wait for.
func quick(t *testing.T, c *failover) {
	t.Helper()
	c.switchAfter = time.Second
	c.returnAfter = 2 * time.Second
	c.probeEvery = time.Second
}

// quickClocks does the same for the clocks every carrier reads when it is
// made, so it goes before any is.
func quickClocks(t *testing.T) {
	t.Helper()
	ka, pat, hw, hg, greet := probeKeepalive, probePatience, huntWait, huntGrace, kcpGreetWait
	probeKeepalive, probePatience, huntWait, huntGrace, kcpGreetWait =
		200*time.Millisecond, time.Second, 3*time.Second, 300*time.Millisecond, time.Second
	t.Cleanup(func() { probeKeepalive, probePatience, huntWait, huntGrace, kcpGreetWait = ka, pat, hw, hg, greet })
}

func failoverPair(t *testing.T) (waiting, dialling *failover) {
	t.Helper()
	return failoverTrio(t, false, "")
}

// failoverTrio is a pair with three members - TCP, Chrome TLS, KCP - when
// three is asked for.
func failoverTrio(t *testing.T, three bool, prefer string) (waiting, dialling *failover) {
	t.Helper()
	quickClocks(t)
	tcpPort, kcpPort := freePort(t, false), freePort(t, true)
	utlsPort := 0
	if three {
		utlsPort = freePort(t, false)
	}
	mk := func(side string) *failover {
		f, err := newFailover(failoverConfigN(t, side, tcpPort, kcpPort, utlsPort, prefer))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = f.Close() })
		quick(t, f)
		return f
	}
	if three {
		return mk(config.SideIran), mk(config.SideKharej)
	}
	// Iran waits: a reverse tunnel is the default, and with it Kharej dials.
	w, err := newFailover(failoverConfig(t, config.SideIran, tcpPort, kcpPort))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = w.Close() })
	d, err := newFailover(failoverConfig(t, config.SideKharej, tcpPort, kcpPort))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = d.Close() })
	quick(t, w)
	quick(t, d)
	return w, d
}

// crosses sends a record each way and waits for both to arrive.
func crosses(t *testing.T, w, d *failover, got chan []byte, what string) {
	t.Helper()
	for _, dir := range []struct {
		from *failover
		body []byte
	}{
		{d, []byte("to iran, " + what)},
		{w, []byte("to kharej, " + what)},
	} {
		deadline := time.Now().Add(5 * time.Second)
		for {
			bp := buf.Take(dir.from.Headroom(), len(dir.body))
			copy((*bp)[dir.from.Headroom():], dir.body)
			if err := dir.from.SendFlow(0, bp); err == nil {
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("%s: could not send %q", what, dir.body)
			}
			time.Sleep(50 * time.Millisecond)
		}
		select {
		case b := <-got:
			if !bytes.Equal(b, dir.body) {
				t.Fatalf("%s: sent %q, %q arrived", what, dir.body, b)
			}
		case <-time.After(5 * time.Second):
			t.Fatalf("%s: %q did not arrive", what, dir.body)
		}
	}
}

// The whole feature, end to end: the tunnel runs on its primary, the primary
// dies, the tunnel moves to the backup by itself and carries on, and when the
// primary comes back and stays back the tunnel returns to it.
func TestATunnelMovesToItsBackupAndBack(t *testing.T) {
	w, d := failoverPair(t)
	got := make(chan []byte, 8)
	on := func(b []byte) { got <- append([]byte(nil), b...) }
	w.OnPacket(on)
	d.OnPacket(on)

	go w.Run()
	go d.Run()
	go d.Keepalive(200 * time.Millisecond)

	waitFor(t, "the primary connecting", 5*time.Second, func() bool { return d.Up() && w.Up() })
	if a := d.Active(); a != "tcp" {
		t.Fatalf("the tunnel started on %s, not its primary", a)
	}
	crosses(t, w, d, got, "on the primary")

	// The primary goes: its listener and every connection on it, as a path
	// that has started refusing it would look from the side that dials.
	w.retire(w.members[0])

	waitFor(t, "moving to the backup", 8*time.Second, func() bool { return d.Active() == "kcp" && d.Up() })
	crosses(t, w, d, got, "on the backup")
	if a := w.Active(); a != "kcp" {
		t.Errorf("the waiting side thinks %s is in use", a)
	}

	// The primary comes back.
	m := w.members[0]
	car, err := w.build(m.cfg)
	if err != nil {
		t.Fatal(err)
	}
	w.attach(m, car)
	go car.Run()

	waitFor(t, "returning to the primary", 12*time.Second, func() bool { return d.Active() == "tcp" && d.Up() })
	crosses(t, w, d, got, "back on the primary")
}

// A primary that never answers is left for the backup rather than waited on
// for ever, and a tunnel that starts that way still comes up.
func TestAPrimaryThatNeverAnswersIsPassedOver(t *testing.T) {
	w, d := failoverPair(t)
	got := make(chan []byte, 8)
	on := func(b []byte) { got <- append([]byte(nil), b...) }
	w.OnPacket(on)
	d.OnPacket(on)

	w.retire(w.members[0]) // before anything runs
	go w.Run()
	go d.Run()
	go d.Keepalive(200 * time.Millisecond)

	waitFor(t, "coming up on the backup", 8*time.Second, func() bool { return d.Active() == "kcp" && d.Up() })
	crosses(t, w, d, got, "a tunnel that started on its backup")
}

// A pair whose second server is not there yet moves through its members
// looking for it. When the far end turns up while a backup is being tried,
// that is not the primary failing, so the tunnel goes back to the primary as
// soon as it answers rather than after return_after_sec.
func TestAFarEndFirstReachedOnABackupGoesBackToThePrimaryAtOnce(t *testing.T) {
	w, d := failoverPair(t)
	d.returnAfter = time.Hour // only the first-contact path can bring it back in time
	// The primary's probe must still be waiting when the primary appears, or
	// the tunnel has watched it fail and the ordinary return applies.
	probePatience = 10 * time.Second
	d.OnPacket(func([]byte) {})
	w.OnPacket(func([]byte) {})

	// Only the backup answers at first, so that is where the far end is found.
	w.retire(w.members[0])
	go w.Run()
	go d.Run()
	go d.Keepalive(200 * time.Millisecond)
	waitFor(t, "finding the far end on the backup", 8*time.Second, func() bool { return d.Active() == "kcp" && d.Up() })

	// Now the primary appears too.
	m := w.members[0]
	car, err := w.build(m.cfg)
	if err != nil {
		t.Fatal(err)
	}
	w.attach(m, car)
	go car.Run()
	waitFor(t, "going back to the primary once it answers", 12*time.Second, func() bool { return d.Active() == "tcp" && d.Up() })
}

// Records are sized for the smallest member, and built with room for the
// largest header, so one written for either crosses on either.
func TestRecordsFitEveryMember(t *testing.T) {
	w, d := failoverPair(t)
	for _, c := range []*failover{w, d} {
		for _, m := range c.members {
			car := m.car.Load()
			if car.Headroom() > c.Headroom() {
				t.Errorf("%s wants %d bytes of headroom and the tunnel gives %d", m.kind, car.Headroom(), c.Headroom())
			}
			if car.MaxPayload() < c.MaxPayload() {
				t.Errorf("%s takes %d bytes and the tunnel writes %d", m.kind, car.MaxPayload(), c.MaxPayload())
			}
		}
	}
}

// With three members and the first two dead, the tunnel goes straight to the
// third rather than spending a silence on each; and when the second comes
// back it is taken, being better than the third, without waiting for the
// first.
func TestTheBestMemberThatAnswersIsTaken(t *testing.T) {
	w, d := failoverTrio(t, true, "")
	w.OnPacket(func([]byte) {})
	d.OnPacket(func([]byte) {})
	go w.Run()
	go d.Run()
	go d.Keepalive(200 * time.Millisecond)
	waitFor(t, "connecting on the primary", 5*time.Second, func() bool { return d.Active() == "tcp" && d.Up() })

	w.retire(w.members[0])
	w.retire(w.members[1])
	begin := time.Now()
	waitFor(t, "moving to the third member", 10*time.Second, func() bool { return d.Active() == "kcp" && d.Up() })
	if took := time.Since(begin); took > 6*time.Second {
		t.Errorf("the move took %s: one silence per dead member, not one hunt", took)
	}

	// The second member comes back, and the first stays dead.
	m := w.members[1]
	car, err := w.build(m.cfg)
	if err != nil {
		t.Fatal(err)
	}
	w.attach(m, car)
	go car.Run()
	waitFor(t, "returning to the second member", 12*time.Second, func() bool { return d.Active() == "utls" && d.Up() })
}

// Among the members that answer, "fastest" takes the least round trip, and
// "order" the first in the file.
func TestPickFollowsThePreference(t *testing.T) {
	ms := []*member{{idx: 0, kind: "tcp"}, {idx: 1, kind: "utls"}, {idx: 2, kind: "kcp"}}
	ps := []*probe{{m: ms[0]}, {m: ms[1]}, {m: ms[2]}}
	ps[0].best.Store(int64(90 * time.Millisecond))
	ps[1].best.Store(int64(40 * time.Millisecond))
	ps[2].best.Store(int64(70 * time.Millisecond))
	if got := (&failover{prefer: preferOrder}).pick(ps); got.m.kind != "tcp" {
		t.Errorf("order picked %s", got.m.kind)
	}
	if got := (&failover{prefer: preferFastest}).pick(ps); got.m.kind != "utls" {
		t.Errorf("fastest picked %s", got.m.kind)
	}
	if got := (&failover{prefer: preferFastest}).pick(nil); got != nil {
		t.Error("something was picked from nothing")
	}
}
