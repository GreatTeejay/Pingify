package l3switch

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type fakeNAT struct {
	mu     sync.Mutex
	points []string
	setup  bool
	down   bool
}

func (f *fakeNAT) Setup([]Route) error { f.setup = true; return nil }
func (f *fakeNAT) Teardown() error     { f.down = true; return nil }
func (f *fakeNAT) Point(t string) error {
	f.mu.Lock()
	f.points = append(f.points, t)
	f.mu.Unlock()
	return nil
}

// world is which routes answer, and a clock the test moves.
type world struct {
	mu  sync.Mutex
	ok  map[string]bool
	now time.Time
}

func (w *world) check(r Route) bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.ok[r.Target]
}
func (w *world) set(t string, ok bool) { w.mu.Lock(); w.ok[t] = ok; w.mu.Unlock() }

func twoLinks() (*Config, *world, *fakeNAT, *Switch) {
	cfg := &Config{
		Ports:  []PortRange{{8002, 8010}},
		Routes: []Route{{"10.1.10.2", "10.1.10.2:19999"}, {"10.3.10.2", "10.3.10.2:19998"}},
		Every:  time.Second, Rise: 2, Fall: 3, ReturnAfter: 30 * time.Second,
	}
	w := &world{ok: map[string]bool{}, now: time.Unix(1_000_000, 0)}
	n := &fakeNAT{}
	s := New(cfg, n, w.check)
	s.now = func() time.Time { return w.now }
	return cfg, w, n, s
}

func (w *world) tick(s *Switch, n int) int {
	a := -1
	for i := 0; i < n; i++ {
		w.now = w.now.Add(time.Second)
		a = s.Step()
	}
	return a
}

// The first route that answers takes the users, and nothing is pointed
// anywhere before a route has answered Rise times in a row.
func TestTheFirstRouteThatAnswersTakesTheUsers(t *testing.T) {
	_, w, n, s := twoLinks()
	w.set("10.1.10.2", true)
	w.set("10.3.10.2", true)
	if a := w.tick(s, 1); a != -1 {
		t.Fatalf("pointed at route %d after one answer", a)
	}
	if a := w.tick(s, 1); a != 0 {
		t.Fatalf("after two answers the users are on %d, expected the first route", a)
	}
	if len(n.points) != 1 || n.points[0] != "10.1.10.2" {
		t.Fatalf("pointed %v", n.points)
	}
}

// A route that stops answering loses the users to the next one after Fall
// misses; with none answering they go back to this machine's own listeners.
func TestUsersMoveDownTheListAndThenHome(t *testing.T) {
	_, w, n, s := twoLinks()
	w.set("10.1.10.2", true)
	w.set("10.3.10.2", true)
	w.tick(s, 2)
	w.set("10.1.10.2", false)
	if a := w.tick(s, 2); a != 0 {
		t.Fatalf("moved after two misses, before Fall: now on %d", a)
	}
	if a := w.tick(s, 1); a != 1 {
		t.Fatalf("after three misses the users are on %d, expected the second route", a)
	}
	w.set("10.3.10.2", false)
	if a := w.tick(s, 3); a != -1 {
		t.Fatalf("with no route answering the users are on %d, expected this machine", a)
	}
	want := []string{"10.1.10.2", "10.3.10.2", ""}
	if strings.Join(n.points, ",") != strings.Join(want, ",") {
		t.Fatalf("pointed %q, expected %q", n.points, want)
	}
}

// A better route that comes back takes the users back only once it has
// answered for ReturnAfter: a link that flaps must not drag every new user
// back and forth with it.
func TestABetterRouteIsGoneBackToOnlyOnceItStays(t *testing.T) {
	_, w, _, s := twoLinks()
	w.set("10.3.10.2", true)
	if a := w.tick(s, 3); a != 1 { // the first misses Fall checks: it has failed
		t.Fatalf("on %d with only the second route answering", a)
	}
	w.set("10.1.10.2", true)
	if a := w.tick(s, 10); a != 1 {
		t.Fatalf("went back to the first route %s after it came back", "10 s")
	}
	w.set("10.1.10.2", false)
	w.tick(s, 3)
	w.set("10.1.10.2", true)
	if a := w.tick(s, 25); a != 1 {
		t.Fatal("a route that came back, went, and came back again was trusted before ReturnAfter")
	}
	if a := w.tick(s, 10); a != 0 {
		t.Fatalf("after answering for over ReturnAfter the first route has not got the users back: on %d", a)
	}
}

// With nothing answering at start the users are never pointed anywhere:
// the ports stay this machine's, which is the forward tunnel.
func TestNothingAnsweringLeavesThePortsHere(t *testing.T) {
	_, w, n, s := twoLinks()
	if a := w.tick(s, 5); a != -1 || len(n.points) != 0 {
		t.Fatalf("with no route answering: on %d, pointed %v", a, n.points)
	}
}

// Run sets the chains up, and takes them out when it stops.
func TestRunCleansUpAfterItself(t *testing.T) {
	cfg, w, n, _ := twoLinks()
	cfg.Every = 10 * time.Millisecond
	w.set("10.1.10.2", true)
	s := New(cfg, n, w.check)
	done := make(chan struct{})
	finished := make(chan error, 1)
	go func() { finished <- s.Run(done) }()
	time.Sleep(100 * time.Millisecond)
	close(done)
	if err := <-finished; err != nil {
		t.Fatal(err)
	}
	if !n.setup || !n.down {
		t.Fatalf("set up %v, taken down %v", n.setup, n.down)
	}
}

// The rules: one commit that empties the chain and fills it, for tcp and udp,
// to this machine's own addresses only, fifteen port runs to a rule.
func TestTheRulesAreOneCommit(t *testing.T) {
	var got []string
	ipt := &IPTables{
		Ports:   []PortRange{{8002, 8010}, {443, 443}},
		restore: func(in string) error { got = append(got, in); return nil },
		run:     func(...string) error { return nil },
	}
	if err := ipt.Point("10.1.10.2"); err != nil {
		t.Fatal(err)
	}
	r := got[0]
	for _, want := range []string{
		"*nat\n:PINGIFY_L3 - [0:0]\n-F PINGIFY_L3\n",
		"-A PINGIFY_L3 -p tcp -m addrtype --dst-type LOCAL -m multiport --dports 8002:8010,443 -j DNAT --to-destination 10.1.10.2\n",
		"-A PINGIFY_L3 -p udp -m addrtype --dst-type LOCAL -m multiport --dports 8002:8010,443 -j DNAT --to-destination 10.1.10.2\n",
		"COMMIT\n",
	} {
		if !strings.Contains(r, want) {
			t.Fatalf("the rules lack %q:\n%s", want, r)
		}
	}
	if err := ipt.Point(""); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(got[1], "DNAT") {
		t.Fatalf("pointing nowhere still sends users somewhere:\n%s", got[1])
	}
	many := &IPTables{restore: func(in string) error { got = append(got, in); return nil }}
	for p := 1000; p < 1020; p++ {
		many.Ports = append(many.Ports, PortRange{p, p})
	}
	_ = many.Point("10.1.10.2")
	if n := strings.Count(got[2], "-p tcp"); n != 2 {
		t.Fatalf("twenty ports made %d tcp rules, expected two of at most fifteen", n)
	}
}

// Setup hooks each chain in once, however often it runs.
func TestSetupHooksInOnce(t *testing.T) {
	hooked := map[string]bool{}
	var restored []string
	ipt := &IPTables{
		restore: func(in string) error { restored = append(restored, in); return nil },
		run: func(a ...string) error {
			key := strings.Join([]string{a[1], a[3], a[len(a)-1]}, " ")
			switch a[2] {
			case "-C":
				if hooked[key] {
					return nil
				}
				return os.ErrNotExist
			case "-I":
				if hooked[key] {
					t.Fatalf("hooked %s twice", key)
				}
				hooked[key] = true
			}
			return nil
		},
	}
	routes := []Route{{"10.1.10.2", "10.1.10.2:19999"}}
	for i := 0; i < 2; i++ {
		if err := ipt.Setup(routes); err != nil {
			t.Fatal(err)
		}
	}
	if len(hooked) != 4 {
		t.Fatalf("%d hooks, expected four: %v", len(hooked), hooked)
	}
	for _, want := range []string{"-A PINGIFY_L3_POST -d 10.1.10.2 -j MASQUERADE", "--clamp-mss-to-pmtu", "-A PINGIFY_L3_FWD -s 10.1.10.2 -j ACCEPT"} {
		if !strings.Contains(restored[0], want) {
			t.Fatalf("setup lacks %q", want)
		}
	}
}

// The file: ports, routes in order, and the timings; anything else refused.
func TestASwitchFile(t *testing.T) {
	p := filepath.Join(t.TempDir(), "s.toml")
	os.WriteFile(p, []byte(`
[switch]
name   = "iran1-users"   # who
ports  = ["8002-8010", "443"]
routes = ["10.1.10.2:19999", "10.3.10.2:19998"]
return_after_sec = 20
`), 0o600)
	c, err := Load(p)
	if err != nil {
		t.Fatal(err)
	}
	if c.Name != "iran1-users" || len(c.Ports) != 2 || c.Ports[0] != (PortRange{8002, 8010}) ||
		len(c.Routes) != 2 || c.Routes[1].Target != "10.3.10.2" || c.ReturnAfter != 20*time.Second ||
		c.Rise != 2 || c.Fall != 3 || c.Every != time.Second {
		t.Fatalf("read %+v", c)
	}
	for _, bad := range []string{
		"ports = [\"9-2\"]\nroutes = [\"10.1.10.2:1\"]",
		"ports = [\"8002\"]\nroutes = [\"far.example:19999\"]",
		"ports = [\"8002\"]\nroutes = [\"10.1.10.2\"]",
		"ports = [\"8002\"]",
		"ports = [\"8002\"]\nroutes = [\"10.1.10.2:1\"]\nspeed = 3",
	} {
		os.WriteFile(p, []byte(bad), 0o600)
		if _, err := Load(p); err == nil {
			t.Errorf("took %q", bad)
		}
	}
}

// Two links half dead at once, each missing checks by turns - the Iran 1
// peak of 2026-09-30. The users go to this machine's own listeners and stay
// there, instead of being taken back to whichever link answered last.
func TestTwoHalfDeadLinksDoNotDragUsersAround(t *testing.T) {
	_, w, n, s := twoLinks()
	w.set("10.1.10.2", true)
	w.set("10.3.10.2", true)
	w.tick(s, 2)
	// Each answers for a few seconds and misses for a few, out of step.
	for sec := 0; sec < 120; sec++ {
		w.set("10.1.10.2", sec%7 < 3)
		w.set("10.3.10.2", (sec+3)%7 < 3)
		w.tick(s, 1)
	}
	if len(n.points) > 4 {
		t.Fatalf("the ports were moved %d times in two minutes of flapping links: %q", len(n.points), n.points)
	}
	if n.points[len(n.points)-1] != "" {
		t.Fatalf("with both links flapping the users are on %q, expected this machine", n.points[len(n.points)-1])
	}
	// Once one of them is steady again for ReturnAfter, the users go back.
	w.set("10.1.10.2", true)
	w.set("10.3.10.2", false)
	if a := w.tick(s, 20); a != -1 {
		t.Fatalf("taken back to a link steady for only 20 s: on %d", a)
	}
	if a := w.tick(s, 15); a != 0 {
		t.Fatalf("a link steady for over ReturnAfter did not get the users back: on %d", a)
	}
}
