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
iran = "198.51.100.7"
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

func TestOnlyTheDownloadProfileKeepsADeepReceiveQueue(t *testing.T) {
	// Three megabytes on the receiving socket is fifty milliseconds at the
	// rate this carries, and everything arriving waits behind it. That is the
	// trade the download profile exists to make and the other two do not.
	for _, c := range []struct {
		profile string
		rcv     int
	}{{"gaming", 256}, {"balanced", 256}, {"download", 3072}} {
		got := load(t, "[tuning]\nprofile = \""+c.profile+"\"\n")
		if got.Tuning.RcvBufKB != c.rcv {
			t.Errorf("%s asked for %d KB of receive queue, got %d",
				c.profile, c.rcv, got.Tuning.RcvBufKB)
		}
	}
}

func TestAReceiveQueueOfYourOwnBeatsTheProfile(t *testing.T) {
	got := load(t, "[tuning]\nprofile = \"gaming\"\nrcvbuf_kb = 2048\n")
	if got.Tuning.RcvBufKB != 2048 {
		t.Fatalf("an explicit receive queue was overruled by the profile: got %d",
			got.Tuning.RcvBufKB)
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
	// A reverse tunnel: the server abroad reaches in, and Iran waits, because
	// Iran is where the ports are and where users connect.
	if ir.Dials() || !kh.Dials() {
		t.Fatal("kharej dials iran and iran waits; this got it the wrong way round")
	}
	if kh.DialHost() != "198.51.100.7" {
		t.Fatalf("kharej dialled %q, not the iran address", kh.DialHost())
	}
}

// Every carrier that dials must ask DialHost for the address. tcp.go named
// cfg.Transport.Kharej directly, so once the direction settled the other way
// the server abroad reached in by dialling itself.
//
// DialHost belongs to the tunnel, not to the side asking: both files work it
// out the same way, which is what lets the two ends agree on a name without
// being told one.
func TestTheDialledAddressIsTheEndThatWaits(t *testing.T) {
	var hosts []string
	for _, side := range []string{SideIran, SideKharej} {
		c := &Config{}
		if err := parseTOML(head, c); err != nil {
			t.Fatal(err)
		}
		c.Side = side
		if err := c.check(); err != nil {
			t.Fatal(err)
		}
		if c.DialHost() != c.Transport.Iran {
			t.Fatalf("the %s file dials %q, not the iran address it waits on",
				side, c.DialHost())
		}
		hosts = append(hosts, c.DialHost())
	}
	if hosts[0] != hosts[1] {
		t.Fatalf("the two files disagree about what is dialled: %q and %q",
			hosts[0], hosts[1])
	}

	// And with the switch thrown, the other way round.
	c := &Config{}
	if err := parseTOML(head+"", c); err != nil {
		t.Fatal(err)
	}
	c.Transport.Dials = SideIran
	if c.DialHost() != c.Transport.Kharej {
		t.Fatalf("dials = iran dialled %q, not the kharej address", c.DialHost())
	}
}
