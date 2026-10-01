package carrier

import (
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"pingify/internal/buf"
	"pingify/internal/config"
)

// freezer is a TCP proxy between the two ends whose connections can be made
// to stop carrying, one at a time or all at once, without being closed - what
// a path that has stopped delivering looks like from both ends.
type freezer struct {
	ln     net.Listener
	target string
	mu     sync.Mutex
	pairs  []*atomic.Bool
	from   []string // the dialling end of each, to find a slot's connection by
	// Whether a connection made from now on starts frozen: a path that
	// takes a new connection and then carries nothing on it.
	freezeNew atomic.Bool
}

func newFreezer(t *testing.T, target string) *freezer {
	t.Helper()
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	f := &freezer{ln: ln, target: target}
	t.Cleanup(func() {
		_ = ln.Close()
		f.thawAll()
	})
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			s, err := net.Dial("tcp4", target)
			if err != nil {
				_ = c.Close()
				continue
			}
			frozen := &atomic.Bool{}
			frozen.Store(f.freezeNew.Load())
			f.mu.Lock()
			f.pairs = append(f.pairs, frozen)
			f.from = append(f.from, c.RemoteAddr().String())
			f.mu.Unlock()
			go pump(s, c, frozen)
			go pump(c, s, frozen)
		}
	}()
	return f
}

// pump copies one way, and holds what it has read for as long as the pair is
// frozen: nothing more reaches the other end, and nothing is closed.
func pump(dst, src net.Conn, frozen *atomic.Bool) {
	defer func() { _ = dst.Close(); _ = src.Close() }()
	b := make([]byte, 32<<10)
	for {
		n, err := src.Read(b)
		for frozen.Load() {
			time.Sleep(10 * time.Millisecond)
		}
		if n > 0 {
			if _, werr := dst.Write(b[:n]); werr != nil {
				return
			}
		}
		if err != nil {
			return
		}
	}
}

func (f *freezer) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.pairs)
}

func (f *freezer) freeze(i int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.pairs[i].Store(true)
}

// freezeSlot freezes the connection a dialling carrier holds in one slot.
func (f *freezer) freezeSlot(t *testing.T, d *streamCarrier, slot int) {
	t.Helper()
	l := d.links[slot].Load()
	if l == nil {
		t.Fatalf("slot %d is empty", slot)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	for i, from := range f.from {
		if from == l.c.LocalAddr().String() {
			f.pairs[i].Store(true)
			return
		}
	}
	t.Fatalf("no connection through the path from %s", l.c.LocalAddr())
}

func (f *freezer) freezeAll() {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, p := range f.pairs {
		p.Store(true)
	}
}

func (f *freezer) thawAll() {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, p := range f.pairs {
		p.Store(false)
	}
}

// quickStalls makes the watch a matter of a second rather than of several.
func quickStalls(t *testing.T) {
	t.Helper()
	be, sa, sr := beatEvery, stallAfter, stallRest
	beatEvery, stallAfter, stallRest = 50*time.Millisecond, 400*time.Millisecond, 10*time.Second
	t.Cleanup(func() { beatEvery, stallAfter, stallRest = be, sa, sr })
}

// tcpPairVia is a waiting TCP carrier on loopback and a dialling one that
// reaches it through a freezer, with n connections.
func tcpPairVia(t *testing.T, n int) (waiting, dialling *streamCarrier, f *freezer) {
	t.Helper()
	w := &config.Config{Side: config.SideIran, Mode: "forward", Token: "a stall test"}
	w.Transport.Type = "tcp"
	w.Transport.Connections = n
	waiting, err := newTCPCarrier(w)
	if err != nil {
		t.Fatalf("waiting side: %v", err)
	}
	t.Cleanup(func() { _ = waiting.Close() })
	go waiting.Run()

	f = newFreezer(t, waiting.ln.Addr().String())
	d := &config.Config{Side: config.SideKharej, Mode: "forward", Token: "a stall test"}
	d.Transport.Type = "tcp"
	d.Transport.Connections = n
	d.Transport.Iran = "127.0.0.1"
	d.Transport.Port = f.ln.Addr().(*net.TCPAddr).Port
	dialling, err = newTCPCarrier(d)
	if err != nil {
		t.Fatalf("dialling side: %v", err)
	}
	t.Cleanup(func() { _ = dialling.Close() })
	go dialling.Run()

	waitFor(t, "every connection up", 5*time.Second, func() bool {
		for i := range dialling.links {
			if dialling.links[i].Load() == nil {
				return false
			}
		}
		return f.count() == n
	})
	waitFor(t, "the far end answering beats", 5*time.Second, dialling.beats.Load)
	return waiting, dialling, f
}

// One connection the path stops carrying is replaced in about stallAfter,
// not the kernel's twenty seconds, and its slot comes back; the others are
// left alone.
func TestAConnectionThatStopsCarryingIsReplacedSoon(t *testing.T) {
	quickStalls(t)
	_, d, f := tcpPairVia(t, 4)

	f.freeze(0)
	start := time.Now()
	waitFor(t, "the frozen connection replaced", 3*time.Second, func() bool { return d.Stalls() == 1 })
	took := time.Since(start)
	waitFor(t, "a new connection in its slot", 3*time.Second, func() bool { return f.count() == 5 })
	for i := range d.links {
		if d.links[i].Load() == nil {
			waitFor(t, "every slot filled again", 3*time.Second, func() bool { return d.links[i].Load() != nil })
		}
	}
	if took < 300*time.Millisecond {
		t.Errorf("replaced after %s, before it had been quiet for stallAfter", took)
	}
	// The three that kept carrying were never touched.
	time.Sleep(time.Second)
	if n := d.Stalls(); n != 1 {
		t.Errorf("%d connections replaced; only the frozen one should have been", n)
	}
	if n := f.count(); n != 5 {
		t.Errorf("%d connections made through the path; four and one replacement expected", n)
	}
}

// When the whole path stops, no connection is the odd one out: replacing them
// all is not a cure, and the failover and TCP itself are the ones to wait on.
func TestAPathThatStopsEverywhereIsLeftAlone(t *testing.T) {
	quickStalls(t)
	_, d, f := tcpPairVia(t, 4)

	f.freezeAll()
	time.Sleep(2 * time.Second)
	if n := d.Stalls(); n != 0 {
		t.Fatalf("%d connections replaced while every one was equally quiet", n)
	}
	f.thawAll()
}

// A quiet tunnel is not a stalled one: the beats keep every connection
// hearing, and nothing is replaced.
func TestAnIdleTunnelIsNeverReplaced(t *testing.T) {
	quickStalls(t)
	_, d, f := tcpPairVia(t, 4)

	time.Sleep(2 * time.Second)
	if n := d.Stalls(); n != 0 {
		t.Fatalf("%d connections of an idle tunnel replaced", n)
	}
	if n := f.count(); n != 4 {
		t.Fatalf("%d connections made; the four first ones should still be the ones", n)
	}
}

// The rule itself, including what the tests above cannot reach: a far end
// that has never answered a beat - a core of the version before - is never
// judged, and a slot replaced this way is left alone for stallRest.
func TestTheStallRule(t *testing.T) {
	c := &streamCarrier{stallAfter: 3 * time.Second, stallRest: 30 * time.Second}
	quiet, never := 4*time.Second, time.Duration(-1)

	if c.stalled(quiet, 15, 16, never, c.stallRest) {
		t.Error("judged with a far end that has never answered a beat")
	}
	c.beats.Store(true)
	for _, x := range []struct {
		why         string
		quiet       time.Duration
		heard, live int
		since       time.Duration
		want        bool
	}{
		{"quiet past stallAfter while the rest hear", quiet, 15, 16, never, true},
		{"not quiet for long enough", 2 * time.Second, 15, 16, never, false},
		{"everything quiet", quiet, 0, 16, never, false},
		{"most of them quiet: the path, not the connection", quiet, 7, 16, never, false},
		{"half of them hearing is enough", quiet, 8, 16, never, true},
		{"of two, the other one hearing", quiet, 1, 2, never, true},
		{"a single connection has nothing to compare with", quiet, 0, 1, never, false},
		{"replaced ten seconds ago", quiet, 15, 16, 10 * time.Second, false},
		{"replaced a minute ago", quiet, 15, 16, time.Minute, true},
	} {
		if got := c.stalled(x.quiet, x.heard, x.live, x.since, c.stallRest); got != x.want {
			t.Errorf("%s: %v, want %v", x.why, got, x.want)
		}
	}
}

// A reader handing a frame to a program that is slow to take it reads
// nothing more meanwhile, and its connection looks quiet - this end's doing,
// not the path's. The minute after a restart on the user's pair most of them
// did that at once, the rule held back as it should when most are quiet, and
// the one connection the path really had stopped waited twenty-nine seconds.
// Now a busy reader counts as hearing: it is never replaced, and it does not
// hide the one that has stopped.
func TestASlowReaderHereIsNotThePathStopping(t *testing.T) {
	quickStalls(t)
	w, d, f := tcpPairVia(t, 4)

	release := make(chan struct{})
	t.Cleanup(func() { close(release) })
	d.OnPacket(func(b []byte) {
		if string(b) == "hold" {
			<-release
		}
	})
	// Slots 0 to 2 are handed something the program here will not take.
	for flow := uint32(0); flow < 3; flow++ {
		bp := buf.Take(w.Headroom(), 4)
		copy((*bp)[w.Headroom():], "hold")
		if err := w.SendFlow(flow, bp); err != nil {
			buf.Put(bp)
			t.Fatal(err)
		}
	}
	waitFor(t, "three readers busy", 3*time.Second, func() bool {
		n := 0
		for i := 0; i < 3; i++ {
			if l := d.links[i].Load(); l != nil && l.busy.Load() {
				n++
			}
		}
		return n == 3
	})
	// And the path stops carrying the fourth.
	f.freezeSlot(t, d, 3)
	waitFor(t, "the stopped connection replaced", 2*time.Second, func() bool { return d.Stalls() == 1 })
	time.Sleep(time.Second)
	if n := d.Stalls(); n != 1 {
		t.Fatalf("%d connections replaced; the three busy ones should have been left alone", n)
	}
	for i := 0; i < 3; i++ {
		if l := d.links[i].Load(); l == nil || !l.busy.Load() {
			t.Errorf("slot %d was replaced while its reader was busy", i)
		}
	}
}

// The same from the other end: the side that waits has a reader stuck on a
// program that will not take what it is given. It says so, and the side that
// dials leaves the connection alone - while a connection the path really has
// stopped is still replaced.
func TestASlowReaderThereIsNotThePathStoppingEither(t *testing.T) {
	quickStalls(t)
	w, d, f := tcpPairVia(t, 8)

	release := make(chan struct{})
	t.Cleanup(func() { close(release) })
	w.OnPacket(func(b []byte) {
		if string(b) == "hold" {
			<-release
		}
	})
	// The waiting side's readers on slots 0 and 1 are handed something the
	// program there will not take - a few of many, as on the real pair,
	// so the rest hearing makes those two the odd ones out.
	for flow := uint32(0); flow < 2; flow++ {
		bp := buf.Take(d.Headroom(), 4)
		copy((*bp)[d.Headroom():], "hold")
		if err := d.SendFlow(flow, bp); err != nil {
			buf.Put(bp)
			t.Fatal(err)
		}
	}
	waitFor(t, "two far readers busy", 3*time.Second, func() bool {
		n := 0
		for i := 0; i < 2; i++ {
			if l := w.links[i].Load(); l != nil && l.busy.Load() {
				n++
			}
		}
		return n == 2
	})
	// Well past stallAfter with those two stuck.
	time.Sleep(1500 * time.Millisecond)
	if n := d.Stalls(); n != 0 {
		t.Fatalf("%d connections replaced while only the far end's program was slow", n)
	}
	// And a connection the path stops is still found.
	f.freezeSlot(t, d, 7)
	waitFor(t, "the stopped connection replaced", 2*time.Second, func() bool { return d.Stalls() == 1 })
}

// A replacement that never hears anything never worked, and waiting stallRest
// on it - which is for a working connection gone quiet - kept sixty programs
// frozen for thirty seconds on the user's pair. It is replaced again after
// stallAfter.
func TestAReplacementThatNeverWorksIsReplacedAgainSoon(t *testing.T) {
	quickStalls(t) // stallRest is ten seconds here
	_, d, f := tcpPairVia(t, 4)

	f.freezeNew.Store(true)
	f.freezeSlot(t, d, 0)
	waitFor(t, "the stopped connection replaced", 3*time.Second, func() bool { return d.Stalls() == 1 })
	first := time.Now()
	waitFor(t, "its replacement made, dead from the start", 3*time.Second, func() bool { return f.count() == 5 })
	f.freezeNew.Store(false)
	waitFor(t, "the dead replacement replaced", 3*time.Second, func() bool { return d.Stalls() == 2 })
	if took := time.Since(first); took > 3*time.Second {
		t.Errorf("the dead replacement lasted %s; stallRest is for connections that worked", took)
	}
	// The third is healthy, and stays.
	waitFor(t, "a working connection in the slot", 3*time.Second, func() bool {
		l := d.links[0].Load()
		return l != nil && l.heardSinceBorn()
	})
	time.Sleep(time.Second)
	if n := d.Stalls(); n != 2 {
		t.Errorf("%d replacements; the healthy third connection was replaced too", n)
	}
}

// Doubling, for a slot the path will not carry at all: after stallAfter, then
// twice that, and never more often.
func TestASlotThatNeverWorksIsRetriedLessAndLessOften(t *testing.T) {
	c := &streamCarrier{stallAfter: 3 * time.Second, stallRest: 30 * time.Second}
	c.beats.Store(true)
	for _, x := range []struct {
		since, rest time.Duration
		want        bool
	}{
		{4 * time.Second, 3 * time.Second, true},
		{4 * time.Second, 6 * time.Second, false},
		{7 * time.Second, 6 * time.Second, true},
		{25 * time.Second, 24 * time.Second, true},
	} {
		if got := c.stalled(4*time.Second, 15, 16, x.since, x.rest); got != x.want {
			t.Errorf("replaced %s ago, rest %s: %v, want %v", x.since, x.rest, got, x.want)
		}
	}
}
