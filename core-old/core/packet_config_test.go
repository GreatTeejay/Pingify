package main

import "testing"

func TestPacketTransportConfigRoundTrip(t *testing.T) {
	text := `
[tunnel]
role = "server"
mode = "forward"
[transport]
type = "pck"
listen = "0.0.0.0:443"
carriers = 4
[security]
token = "secret"
[forward]
ports = ["8010"]
[kcp]
data_shards = 12
parity_shards = 4
mtu = 1180
interval_ms = 8
[pck]
flags = "PA"
`
	var c Config
	if err := parseTOML(text, &c); err != nil {
		t.Fatal(err)
	}
	c.applyDefaults()
	if err := c.validate(); err != nil {
		t.Fatal(err)
	}
	if c.Transport != "pck" || c.FECData != 12 || c.FECParity != 4 ||
		c.PacketMTU != 1180 || c.KCPInterval != 8 || c.PCKFlags != "PA" {
		t.Fatalf("packet settings were not parsed: %+v", c)
	}
}

func TestPacketTransportConfigRejectsUnsafeShapes(t *testing.T) {
	base := Config{
		Role: "server", Mode: "forward", Transport: "kcp", Listen: ":9443",
		Token: "secret", Forwards: []string{"8010"}, FECData: 10, FECParity: 3,
		PacketMTU: 1200, KCPInterval: 10, PCKFlags: "PA",
	}
	bad := []Config{base, base, base, base}
	bad[0].FECParity = 40
	bad[1].PacketMTU = 1500
	bad[2].KCPInterval = 1
	bad[3].PCKFlags = "R"
	for i := range bad {
		bad[i].applyDefaults()
		if err := bad[i].validate(); err == nil {
			t.Fatalf("invalid packet config %d was accepted: %+v", i, bad[i])
		}
	}
}

func TestTuningRejectsValuesTheRuntimeWouldNotApplyExactly(t *testing.T) {
	base := Config{
		Role: "server", Mode: "forward", Transport: "kcp", Listen: ":9443",
		Token: "secret", Forwards: []string{"8010"},
	}
	base.applyDefaults()
	tests := []struct {
		name string
		edit func(*Config)
	}{
		{"too many carriers", func(c *Config) { c.Carriers = 65 }},
		{"window below runtime floor", func(c *Config) { c.WindowKB = 63 }},
		{"packet window above engine cap", func(c *Config) { c.WindowKB = 4097 }},
		{"keepalive above bound", func(c *Config) { c.KeepaliveSec = 301 }},
		{"send buffer below bound", func(c *Config) { c.SndBufKB = 63 }},
		{"unknown profile", func(c *Config) { c.Profile = "magic" }},
	}
	for _, tc := range tests {
		c := base
		tc.edit(&c)
		if err := c.validate(); err == nil {
			t.Errorf("%s was accepted: %+v", tc.name, c)
		}
	}
}
