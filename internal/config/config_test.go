package config

import "testing"

// The profile is the one thing in this file a user picks by name, so it is the
// one thing worth a test: a name that does nothing, or quietly does something
// else, is worse than no profile at all.

func load(t *testing.T, body string) *Config {
	t.Helper()
	c := &Config{}
	if err := parseTOML(head+body, c); err != nil {
		t.Fatalf("parse: %v", err)
	}
	if err := c.check(); err != nil {
		t.Fatalf("check: %v", err)
	}
	return c
}

const head = `
[tunnel]
side = "iran"
[transport]
type = "icmp"
kharej = "203.0.113.9"
[security]
token = "a token typed on both servers"
[tun]
iran = "10.9.0.1/24"
kharej = "10.9.0.2/24"
`

func TestEachProfileMovesTheQueue(t *testing.T) {
	for _, c := range []struct {
		profile string
		depth   int
	}{{"gaming", 600}, {"balanced", 900}, {"download", 1500}} {
		got := load(t, "[tuning]\nprofile = \""+c.profile+"\"\n")
		if got.Tuning.QueuePkts != c.depth {
			t.Errorf("%s asked for a queue of %d, got %d", c.profile, c.depth, got.Tuning.QueuePkts)
		}
		if got.Tuning.Profile != c.profile {
			t.Errorf("%s came back as %q", c.profile, got.Tuning.Profile)
		}
	}
}

func TestSayingNothingIsBalanced(t *testing.T) {
	got := load(t, "")
	if got.Tuning.Profile != ProfileBalanced || got.Tuning.QueuePkts != 900 {
		t.Fatalf("with no profile named, got %q and a queue of %d",
			got.Tuning.Profile, got.Tuning.QueuePkts)
	}
}

func TestADepthOfYourOwnBeatsTheProfile(t *testing.T) {
	// Three profiles are three points on a line. Somebody who measured their
	// own path is entitled to a fourth.
	got := load(t, "[tuning]\nprofile = \"gaming\"\nqueue_packets = 1100\n")
	if got.Tuning.QueuePkts != 1100 {
		t.Fatalf("an explicit depth was overruled by the profile: got %d", got.Tuning.QueuePkts)
	}
}

func TestAProfileNobodyBuiltIsRefused(t *testing.T) {
	c := &Config{}
	if err := parseTOML(head+"[tuning]\nprofile = \"extreme\"\n", c); err != nil {
		t.Fatalf("parse: %v", err)
	}
	if err := c.check(); err == nil {
		t.Fatal("a profile that does not exist was accepted, and would have done nothing")
	}
}

func TestAQueueTooShallowToCarryAnythingIsRefused(t *testing.T) {
	c := &Config{}
	if err := parseTOML(head+"[tuning]\nqueue_packets = 100\n", c); err != nil {
		t.Fatalf("parse: %v", err)
	}
	if err := c.check(); err == nil {
		t.Fatal("a hundred packets was accepted; one stream measured 75 Mbit/s there")
	}
}

func TestTheTwoServersDifferByOneLine(t *testing.T) {
	// The whole point of naming the sides rather than calling them server and
	// client: the same file is right on both machines.
	ir := load(t, "")
	kh := &Config{}
	if err := parseTOML(head+"", kh); err != nil {
		t.Fatal(err)
	}
	kh.Side = SideKharej
	if err := kh.check(); err != nil {
		t.Fatal(err)
	}
	mineIR, theirsIR := ir.Mine()
	mineKH, theirsKH := kh.Mine()
	if mineIR != theirsKH || theirsIR != mineKH {
		t.Fatalf("the two ends disagree about who is where: %s/%s against %s/%s",
			mineIR, theirsIR, mineKH, theirsKH)
	}
	if !ir.Dials() || kh.Dials() {
		t.Fatal("iran dials out and kharej waits; this got it the wrong way round")
	}
}
