package main

import "testing"

// The pool holds whatever newTransport returned, which for the packet
// transports is a wrapper around the thing that owns the socket. Every test
// of the direct path had used the inner type directly, so every one passed
// while the wrapper quietly did not implement the interface - and the private
// link fell back to the braid on every real tunnel, with nothing to say so.
//
// This asserts against the type the pool actually holds.
func TestTheTypeThePoolHoldsCanCarryABarePacket(t *testing.T) {
	for _, c := range []struct {
		name string
		cfg  *Config
		want bool
		why  string
	}{
		{"icmp", &Config{Transport: "icmp"}, true, "the private link rides it directly"},
		{"udp", &Config{Transport: "udp"}, true, "same"},
		{"tcp", &Config{Transport: "tcp"}, false, "a stream has no packet boundaries to use"},
		{"ws", &Config{Transport: "ws"}, false, "same"},
	} {
		t.Run(c.name, func(t *testing.T) {
			var tr carrierTransport
			switch c.cfg.Transport {
			case "icmp":
				tr = (*icmpCarrier)(nil)
			case "udp":
				tr = (*udpCarrier)(nil)
			case "tcp":
				tr = (*tcpTransport)(nil)
			case "ws":
				tr = (*wsTransport)(nil)
			}
			_, ok := tr.(packetCarrier)
			if ok != c.want {
				t.Fatalf("%s implements packetCarrier = %v, want %v - %s",
					c.name, ok, c.want, c.why)
			}
		})
	}
}
