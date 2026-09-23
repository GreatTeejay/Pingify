package config

import (
	"fmt"
	"testing"
)

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

// The profile used to set three different queue depths. It sets one now,
// because measured on the real pair fq dropped nothing at any of the three -
// so the depth was never the trade it was described as. This test is here so
// that a fourth attempt at a queue-depth profile has to argue with a
// measurement first: see docs/measured.md section 35.
func TestTheProfileNoLongerPretendsToMoveTheQueue(t *testing.T) {
	for _, p := range []string{"gaming", "balanced", "download"} {
		got := load(t, `
[tuning]
profile = "`+p+`"
`)
		if got.Tuning.QueuePkts != DefaultQueuePkts {
			t.Errorf("%s asked fq for %d packets, expected %d for every profile",
				p, got.Tuning.QueuePkts, DefaultQueuePkts)
		}
		if got.Tuning.Profile != p {
			t.Errorf("%s came back as %q", p, got.Tuning.Profile)
		}
	}
}

// fq's own default is a hundred packets, which drops the burst it was put
// there to space out. Whatever the profile stops doing, the depth must stay
// well clear of that end.
func TestTheQueueIsNeverLeftAtSomethingFqWouldDrop(t *testing.T) {
	if DefaultQueuePkts < 600 {
		t.Fatalf("fq would be given %d packets, which is near where it starts"+
			" dropping what it is smoothing", DefaultQueuePkts)
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

// An explicit depth still wins, which is the whole of what the key is for now
// that no profile moves it.
func TestADepthOfYourOwnBeatsTheDefault(t *testing.T) {
	got := load(t, `
[tuning]
profile = "gaming"
queue_packets = 1100
`)
	if got.Tuning.QueuePkts != 1100 {
		t.Fatalf("an explicit depth was overruled: got %d", got.Tuning.QueuePkts)
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

func TestTheDeviceQueueAndTheMarkAreBounded(t *testing.T) {
	got := load(t, "")
	if got.TUN.TxQueueLen != DefaultTxQueueLen || got.Tuning.DSCP != 0 {
		t.Fatalf("defaults: txqueuelen %d, dscp %d", got.TUN.TxQueueLen, got.Tuning.DSCP)
	}
	got = load(t, "[tun]\ntxqueuelen = 250\n[tuning]\ndscp = 46\n")
	if got.TUN.TxQueueLen != 250 || got.Tuning.DSCP != 46 {
		t.Fatalf("set: txqueuelen %d, dscp %d", got.TUN.TxQueueLen, got.Tuning.DSCP)
	}
	for _, body := range []string{"[tun]\ntxqueuelen = 10\n", "[tuning]\ndscp = 64\n"} {
		c := &Config{}
		if err := parseTOML(head+body, c); err != nil {
			t.Fatal(err)
		}
		if err := c.check(); err == nil {
			t.Fatalf("%q was accepted", body)
		}
	}
}

// A private link is datagrams. Datagrams on a reliable stream is TCP inside
// TCP: every loss the connection inside has to see arrives late instead of
// not at all. kcp was refused for this and the other five were not - they
// came up and carried badly, which is worse than being refused.
func TestAStreamTransportCannotCarryAPrivateLink(t *testing.T) {
	for _, kind := range []string{"tcp", "ws", "wss", "utls", "fallback", "kcp"} {
		body := `
[tunnel]
side = "iran"
mode = "tun"
[transport]
type = "` + kind + `"
iran = "198.51.100.7"
kharej = "203.0.113.9"
port = 443
[security]
token = "a token typed on both servers"
[tun]
iran = "10.9.0.1/24"
kharej = "10.9.0.2/24"
`
		c := &Config{}
		if err := parseTOML(body, c); err != nil {
			t.Fatalf("%s: parse: %v", kind, err)
		}
		if err := c.check(); err == nil {
			t.Errorf("%s was accepted as a private link", kind)
		}
	}
}

// The certificate is not opened until the carrier starts, so -check used to
// call a file valid that could not come up.
func TestACertificateWithNoKeyIsRefused(t *testing.T) {
	c := &Config{}
	body := `
[tunnel]
side = "kharej"
mode = "forward"
[transport]
type = "wss"
iran = "198.51.100.7"
kharej = "203.0.113.9"
port = 443
cert = "/etc/pingify/nope.pem"
[security]
token = "a token typed on both servers"
[forward]
ports = ["443"]
`
	if err := parseTOML(body, c); err != nil {
		t.Fatalf("parse: %v", err)
	}
	if err := c.check(); err == nil {
		t.Fatal("a certificate with no key was accepted")
	}
}

// Every AmneziaWG file written before 1.1.0 says tun.mtu = 1280 inside a
// 1320 link. That fits exactly with parity off, and a backstop that counted
// the parity bytes unconditionally refused all of them at start - so this is
// the upgrade, in a test.
func TestAnOldAmneziaWGFileStillFitsItsLink(t *testing.T) {
	body := func(fec int, mtu int) string {
		return "\n[tunnel]\nside = \"iran\"\nmode = \"tun\"\n[transport]\ntype = \"awg\"\niran = \"198.51.100.7\"\nkharej = \"203.0.113.9\"\nport = 20909\n[security]\ntoken = \"a token typed on both servers\"\n[tuning]\nfec = " + itoa(fec) + "\n[awg]\nname = \"awg0\"\niran = \"10.9.20.1/24\"\nkharej = \"10.9.20.2/24\"\nmtu = 1320\nport = 51820\niran_key = \"k\"\niran_pub = \"k\"\nkharej_key = \"k\"\nkharej_pub = \"k\"\n[tun]\niran = \"10.9.10.1/24\"\nkharej = \"10.9.10.2/24\"\nmtu = " + itoa(mtu) + "\n"
	}
	for _, c := range []struct {
		fec, mtu int
		ok       bool
	}{
		{0, 1280, true},  // what every 1.0.x file says
		{0, 1281, false}, // one past the link
		{10, 1276, true}, // what the wizard writes, with parity on
		{10, 1280, false},
	} {
		cfg := &Config{}
		if err := parseTOML(body(c.fec, c.mtu), cfg); err != nil {
			t.Fatalf("parse: %v", err)
		}
		err := cfg.check()
		if (err == nil) != c.ok {
			t.Errorf("parity %d, tun.mtu %d: accepted=%v, expected %v (%v)", c.fec, c.mtu, err == nil, c.ok, err)
		}
	}
}

func itoa(n int) string { return fmt.Sprint(n) }
