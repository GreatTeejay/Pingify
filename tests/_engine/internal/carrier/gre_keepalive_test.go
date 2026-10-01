package carrier

import (
	"encoding/binary"
	"testing"

	"pingify/internal/buf"
)

// The path between the servers parses what is inside a GRE packet and drops
// what is not a packet, so a keepalive has to be one: IPv4 whose header sums
// right, UDP inside, and a time to live that ends it at the first router.
func TestTheGREKeepaliveIsAPacket(t *testing.T) {
	p := greKeepalive
	if len(p) != 28 {
		t.Fatalf("the keepalive is %d bytes, expected an IPv4 header and a UDP one, 28", len(p))
	}
	if p[0] != 0x45 {
		t.Fatalf("version and header length %#x, expected IPv4 with a 20-byte header", p[0])
	}
	if n := binary.BigEndian.Uint16(p[2:4]); int(n) != len(p) {
		t.Fatalf("the header says %d bytes and the packet is %d", n, len(p))
	}
	if p[8] != 1 {
		t.Fatalf("time to live %d: a core that hands this to its device must see it dropped, not routed", p[8])
	}
	if p[9] != 17 || binary.BigEndian.Uint16(p[24:26]) != 8 {
		t.Fatal("not a UDP header of its own length inside")
	}
	var sum uint32
	for i := 0; i < 20; i += 2 {
		sum += uint32(binary.BigEndian.Uint16(p[i : i+2]))
	}
	for sum > 0xffff {
		sum = sum>>16 + sum&0xffff
	}
	if sum != 0xffff {
		t.Fatalf("the IPv4 header does not sum right (%#x); a parser on the path would drop it", sum)
	}
}

// A keepalive is recognised whether it comes from a core that sends the
// packet or from one that sends nothing - and a real packet never is.
func TestAGREKeepaliveIsKnownAndNothingElseIs(t *testing.T) {
	if !isGREKeepalive(nil) || !isGREKeepalive(append([]byte(nil), greKeepalive...)) {
		t.Fatal("a keepalive, old or new, was not recognised")
	}
	other := append([]byte(nil), greKeepalive...)
	other[19] = 3 // the same packet to 192.0.2.3
	if isGREKeepalive(other) {
		t.Fatal("a packet that is not the keepalive was taken for one, and would never reach the device")
	}
}

// What goes on the wire for a keepalive: the GRE header, then the packet.
// And what arrives is heard, and not handed up.
func TestAGREKeepaliveCrossesAsAPacketAndStopsAtTheCarrier(t *testing.T) {
	c := &greCarrier{key: 7, seen: buf.NewReplayWindow(), learn: true}
	c.listen(10)
	handed := 0
	f := func([]byte) { handed++ }
	c.onPacket.Store(&f)

	bp := buf.Take(c.Headroom(), 0) // what keepaliveLoop sends
	b := withKeepalive(bp)
	c.stamp(b)
	if len(b) != greHdrLen+len(greKeepalive) {
		t.Fatalf("a keepalive is %d bytes on the wire, expected the header and the packet", len(b))
	}
	if binary.BigEndian.Uint16(b[2:4]) != greProtoIPv4 {
		t.Fatal("the GRE header does not say IPv4")
	}

	c.handle(b, [4]byte{185, 31, 8, 15})
	if !c.recently() {
		t.Fatal("a keepalive arrived and the far end still counts as silent")
	}
	if handed != 0 {
		t.Fatal("a keepalive was handed up to the device as a packet")
	}
	if p := c.peer.Load(); p == nil || !p.IP.Equal([]byte{185, 31, 8, 15}) {
		t.Fatal("the side that waits did not learn the far end from a keepalive")
	}
}
