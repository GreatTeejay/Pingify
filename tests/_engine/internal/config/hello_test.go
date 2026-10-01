package config

import (
	"strings"
	"testing"
)

// forwardDoc is a forward tunnel over one transport, with extra lines for
// its [transport] table.
func forwardDoc(kind, extra string) string {
	return `
[tunnel]
side = "kharej"
mode = "forward"
[transport]
type = "` + kind + `"
iran = "198.51.100.7"
kharej = "203.0.113.9"
port = 443
dials = "kharej"
` + extra + `
[security]
token = "a token typed on both servers"
[forward]
ports = ["8443"]
`
}

func checkedDoc(body string) (*Config, error) {
	c := &Config{}
	if err := parseTOML(body, c); err != nil {
		return nil, err
	}
	return c, c.check()
}

// The name a Chrome TLS or Decoy TLS hello shows is one a hello can carry:
// a domain, never an address, and never something with no dot in it.
func TestTheNameInTheHelloIsADomain(t *testing.T) {
	c, err := checkedDoc(forwardDoc("fallback", `sni = "cdn.example.com"`))
	if err != nil {
		t.Fatalf("a plain domain was refused: %v", err)
	}
	if c.Transport.SNI != "cdn.example.com" {
		t.Fatalf("sni came back as %q", c.Transport.SNI)
	}
	for _, bad := range []string{"203.0.113.9", "localhost", "exa mple.com", "example..com", ".example.com"} {
		if _, err := checkedDoc(forwardDoc("utls", `sni = "`+bad+`"`)); err == nil {
			t.Errorf("sni %q was taken, and no hello can carry it", bad)
		} else if !strings.Contains(err.Error(), "transport.sni") {
			t.Errorf("sni %q refused without naming the key: %v", bad, err)
		}
	}
}

// A connection lives somewhere between a minute and a day when rotate_sec is
// set, and for as long as it works when it is not.
func TestHowLongAConnectionLivesIsBounded(t *testing.T) {
	c, err := checkedDoc(forwardDoc("utls", ""))
	if err != nil {
		t.Fatal(err)
	}
	if c.Transport.RotateSec != 0 {
		t.Fatalf("a file that says nothing rotates every %d s", c.Transport.RotateSec)
	}
	if _, err := checkedDoc(forwardDoc("utls", "rotate_sec = 600")); err != nil {
		t.Fatalf("ten minutes was refused: %v", err)
	}
	for _, bad := range []string{"-5", "10", "59", "90000"} {
		if _, err := checkedDoc(forwardDoc("utls", "rotate_sec = "+bad)); err == nil {
			t.Errorf("rotate_sec = %s was taken", bad)
		}
	}
}

// The name is read by the two transports that make their own hello, and the
// lifetime by the ones made of TCP connections. Anywhere else the file says
// so instead of pretending.
func TestTheNameAndTheLifetimeAreInertWhereNothingReadsThem(t *testing.T) {
	for _, tc := range []struct {
		kind  string
		extra string
		inert string
	}{
		{"tcp", `sni = "cdn.example.com"`, "transport.sni"},
		{"wss", `sni = "cdn.example.com"`, "transport.sni"},
		{"kcp", "rotate_sec = 600", "transport.rotate_sec"},
	} {
		c, err := checkedDoc(forwardDoc(tc.kind, tc.extra))
		if err != nil {
			t.Fatalf("%s: %v", tc.kind, err)
		}
		if got := strings.Join(c.Inert(), " "); !strings.Contains(got, tc.inert) {
			t.Errorf("%s with %s: inert says %q", tc.kind, tc.extra, got)
		}
	}
	for _, kind := range []string{"utls", "fallback"} {
		c, err := checkedDoc(forwardDoc(kind, "sni = \"cdn.example.com\"\nrotate_sec = 600"))
		if err != nil {
			t.Fatalf("%s: %v", kind, err)
		}
		if got := c.Inert(); len(got) != 0 {
			t.Errorf("%s reads both, and inert says %v", kind, got)
		}
	}
}
