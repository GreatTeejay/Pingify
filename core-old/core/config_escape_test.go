package main

import "testing"

func TestQuotedTokenKeepsQuoteHashAndBackslash(t *testing.T) {
	doc := `[tunnel]
role = "server"
mode = "forward"
[transport]
type = "tcp"
listen = ":9443"
[security]
token = "sec|ret\"#\\path"
[forward]
ports = ["8010"]
`
	var c Config
	if err := parseTOML(doc, &c); err != nil {
		t.Fatal(err)
	}
	if want := `sec|ret"#\path`; c.Token != want {
		t.Fatalf("token changed while parsing: got %q, want %q", c.Token, want)
	}
	c.applyDefaults()
	if err := c.validate(); err != nil {
		t.Fatalf("escaped token made an otherwise valid config fail: %v", err)
	}
}

func TestLegacyTokenProfileGetsARealRuntimeProfile(t *testing.T) {
	c := Config{Profile: "from token"}
	c.applyDefaults()
	if c.Profile != "custom" {
		t.Fatalf("legacy profile became %q, want custom", c.Profile)
	}
}
