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
		if err := bad[i].validate(); err == nil {
			t.Fatalf("invalid packet config %d was accepted: %+v", i, bad[i])
		}
	}
}
