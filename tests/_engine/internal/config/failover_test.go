package config

import (
	"strings"
	"testing"
)

const forwardHead = `
[tunnel]
side = "iran"
mode = "forward"
[transport]
type = "tcp"
iran = "198.51.100.7"
kharej = "203.0.113.9"
port = 8443
[security]
token = "a token typed on both servers"
`

func checked(body string) (*Config, error) {
	c := &Config{}
	if err := parseTOML(body, c); err != nil {
		return nil, err
	}
	return c, c.check()
}

func TestBackupsAreReadInOrderAfterThePrimary(t *testing.T) {
	c, err := checked(forwardHead + "[failover]\nbackups = [\"kcp:8443\", \"utls:8444\"]\n")
	if err != nil {
		t.Fatal(err)
	}
	got := c.Members()
	want := []Member{{"tcp", 8443, ""}, {"kcp", 8443, ""}, {"utls", 8444, ""}}
	if len(got) != len(want) {
		t.Fatalf("members %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("member %d is %v, want %v", i, got[i], want[i])
		}
	}
	if c.Failover.SwitchAfter != 25 || c.Failover.ReturnAfter != 120 || c.Failover.ProbeEvery != 60 {
		t.Errorf("defaults came back %d/%d/%d", c.Failover.SwitchAfter, c.Failover.ReturnAfter, c.Failover.ProbeEvery)
	}
	// Each member reads the file as its own, and nothing else changes.
	k := c.For(got[1])
	if k.Transport.Type != "kcp" || k.Transport.Port != 8443 || k.Token != c.Token || k.Transport.Kharej != c.Transport.Kharej {
		t.Errorf("the kcp member reads the file as %+v", k.Transport)
	}
	if c.Transport.Type != "tcp" {
		t.Error("making a member's view changed the file itself")
	}
}

func TestATunnelWithoutBackupsIsItsOwnOnlyMember(t *testing.T) {
	c, err := checked(forwardHead)
	if err != nil {
		t.Fatal(err)
	}
	if m := c.Members(); len(m) != 1 || m[0] != (Member{"tcp", 8443, ""}) {
		t.Fatalf("members %v", m)
	}
}

// Zero is how the file says never come back, so it must not be read as unset.
func TestReturnAfterZeroMeansStayOnTheBackup(t *testing.T) {
	c, err := checked(forwardHead + "[failover]\nbackups = [\"kcp:8443\"]\nreturn_after_sec = 0\n")
	if err != nil {
		t.Fatal(err)
	}
	if c.Failover.ReturnAfter != 0 {
		t.Fatalf("return_after_sec = 0 came back as %d", c.Failover.ReturnAfter)
	}
}

func TestBackupsThatCannotWorkAreRefused(t *testing.T) {
	for _, c := range []struct {
		why, body, says string
	}{
		{"a private link cannot move",
			strings.Replace(strings.Replace(forwardHead, `mode = "forward"`, `mode = "tun"`, 1), `type = "tcp"`, `type = "udp"`, 1) +
				"[tun]\niran = \"10.9.0.1/24\"\nkharej = \"10.9.0.2/24\"\n[failover]\nbackups = [\"kcp:9000\"]\n",
			"mode"},
		{"a TUN transport is not a backup", forwardHead + "[failover]\nbackups = [\"icmp:0\"]\n", "has to be"},
		{"no port", forwardHead + "[failover]\nbackups = [\"kcp\"]\n", "kcp:8443"},
		{"a port that is not one", forwardHead + "[failover]\nbackups = [\"utls:70000\"]\n", "not a port"},
		{"two TCP transports on one port", forwardHead + "[failover]\nbackups = [\"utls:8443\"]\n", "both listen"},
		{"a switch too eager", forwardHead + "[failover]\nbackups = [\"kcp:8443\"]\nswitch_after_sec = 3\n", "switch_after"},
		{"a return too eager", forwardHead + "[failover]\nbackups = [\"kcp:8443\"]\nreturn_after_sec = 5\n", "return_after"},
	} {
		_, err := checked(c.body)
		if err == nil {
			t.Errorf("%s: accepted", c.why)
			continue
		}
		if !strings.Contains(err.Error(), c.says) {
			t.Errorf("%s: refused with %q, which does not say %q", c.why, err, c.says)
		}
	}
}

// Behind a CDN a WebSocket tunnel waits on 80 whatever port it names, so two
// of them in one tunnel would want the same socket there.
func TestTwoMembersBehindOneCDNPortAreRefused(t *testing.T) {
	body := strings.Replace(forwardHead, `type = "tcp"`, `type = "wss"`, 1)
	body = strings.Replace(body, `port = 8443`, `port = 443`, 1)
	body = strings.Replace(body, `iran = "198.51.100.7"`, `iran = "edge.example.com"`, 1)
	body = strings.Replace(body, "[tunnel]\nside = \"iran\"", "[tunnel]\nside = \"kharej\"", 1)
	body += "[transport]\ndials = \"kharej\"\n[failover]\nbackups = [\"ws:8443\"]\n"
	_, err := checked(body)
	if err == nil || !strings.Contains(err.Error(), "both listen on tcp/80") {
		t.Fatalf("ws and wss both waiting on 80 behind a name: %v", err)
	}
}

// A tunnel behind a CDN keeps a backup that goes straight to the server: the
// primary dials the name, the backup the address it names, on both servers,
// and on the side that waits the backup listens on its own port with nothing
// in front of it.
func TestABackupCanGoToAnAddressOfItsOwn(t *testing.T) {
	body := strings.Replace(forwardHead, `type = "tcp"`, `type = "wss"`, 1)
	body = strings.Replace(body, `port = 8443`, "port = 443\nlisten_port = 443", 1)
	body = strings.Replace(body, `iran = "198.51.100.7"`, `iran = "edge.example.com"`, 1)
	body += "[failover]\nbackups = [\"fallback:8443@198.51.100.7\", \"wss:2083\"]\n"
	for _, side := range []string{"kharej", "iran"} {
		c, err := checked(strings.Replace(body, `side = "iran"`, `side = "`+side+`"`, 1))
		if err != nil {
			t.Fatalf("%s: %v", side, err)
		}
		m := c.Members()
		if len(m) != 3 || m[1] != (Member{"fallback", 8443, "198.51.100.7"}) || m[2] != (Member{"wss", 2083, ""}) {
			t.Fatalf("%s: members %v", side, m)
		}
		if h := c.For(m[0]).DialHost(); h != "edge.example.com" {
			t.Errorf("%s: the primary dials %q", side, h)
		}
		b := c.For(m[1])
		if b.DialHost() != "198.51.100.7" || b.Transport.Type != "fallback" || b.Transport.Port != 8443 {
			t.Errorf("%s: the addressed backup reads %+v", side, b.Transport)
		}
		if b.ListenPort() != 8443 {
			t.Errorf("%s: the addressed backup waits on %d", side, b.ListenPort())
		}
		if h := c.For(m[2]).DialHost(); h != "edge.example.com" {
			t.Errorf("%s: a backup with no address of its own dials %q", side, h)
		}
		if c.Transport.Iran != "edge.example.com" {
			t.Errorf("%s: making the backup's view changed the file itself", side)
		}
	}
	// Dialled from Iran, the address is Kharej's.
	c, err := checked(forwardHead + "[transport]\ndials = \"iran\"\n[failover]\nbackups = [\"utls:8444@192.0.2.44\"]\n")
	if err != nil {
		t.Fatal(err)
	}
	if b := c.For(c.Members()[1]); b.DialHost() != "192.0.2.44" || b.Transport.Kharej != "192.0.2.44" {
		t.Errorf("dialled from Iran, the backup reads %+v", b.Transport)
	}
}

func TestABackupAddressThatCannotWorkIsRefused(t *testing.T) {
	for _, c := range []struct{ why, backup, says string }{
		{"nothing after the @", "utls:8444@", "missing"},
		{"an IPv6 address", "utls:8444@2001:db8::1", "IPv6"},
		{"not an address", "utls:8444@not an address", "not an address"},
		{"an address with a port", "utls:8444@192.0.2.44:8444", "not an address"},
		{"a name cut short", "utls:8444@edge.", "not an address"},
	} {
		_, err := checked(forwardHead + "[failover]\nbackups = [\"" + c.backup + "\"]\n")
		if err == nil || !strings.Contains(err.Error(), c.says) {
			t.Errorf("%s: %v", c.why, err)
		}
	}
}

// Off keeps the list in the file and runs the primary alone; on is the default.
func TestFailoverCanBeTurnedOffWithoutLosingTheBackups(t *testing.T) {
	c, err := checked(forwardHead + "[failover]\nbackups = [\"kcp:8443\"]\nenabled = false\n")
	if err != nil {
		t.Fatal(err)
	}
	if len(c.Members()) != 1 {
		t.Fatalf("off, and still %d members", len(c.Members()))
	}
	if len(c.Failover.Backups) != 1 || c.Failover.Enabled {
		t.Fatalf("the backups were lost, or enabled read back as %v", c.Failover.Enabled)
	}
	c, err = checked(forwardHead + "[failover]\nbackups = [\"kcp:8443\"]\n")
	if err != nil || !c.Failover.Enabled || len(c.Members()) != 2 {
		t.Fatalf("saying nothing should mean on: %v, enabled %v, %d members", err, c.Failover.Enabled, len(c.Members()))
	}
	if c.Failover.Prefer != "order" {
		t.Errorf("the default preference is %q", c.Failover.Prefer)
	}
	if _, err := checked(forwardHead + "[failover]\nbackups = [\"kcp:8443\"]\nprefer = \"cheapest\"\n"); err == nil {
		t.Error("a preference nobody built was accepted")
	}
}
