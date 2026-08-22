package main

import (
	"bytes"
	"fmt"

	"testing"
	"time"
)

// The two servers are configured by hand, one at a time, and nothing has ever
// forced their tuning to match. A real tunnel was built with "gaming" on one
// end and "balanced" on the other, and every carrier died on a nine second
// cycle: up, "peer closed the connection", up again.
//
// The reason is that a carrier's patience is set from the local keepalive
// (3 x KeepaliveSec) while what actually refreshes it is how often the *peer*
// speaks. Give the impatient end a keepalive of 3 and the talkative end one of
// 10, and the impatient end hangs up at 9s having heard nothing, forever.
func TestCarriersSurviveMismatchedKeepalive(t *testing.T) {
	if testing.Short() {
		t.Skip("takes ~15s of wall clock")
	}
	setLogLevel("error")

	port := freePort(t)

	// IRAN: listens, forwards ports, "balanced".
	iran := &Config{
		Role: "server", Mode: "forward",
		Listen:   fmt.Sprintf("127.0.0.1:%d", port),
		Forwards: []string{fmt.Sprint(freePort(t))},
		Carriers: 2,
	}
	// KHAREJ: dials, "gaming" with a hand-tuned keepalive.
	kharej := &Config{
		Role: "client", Mode: "forward",
		Connect:  fmt.Sprintf("127.0.0.1:%d", port),
		Carriers: 2,
	}

	for _, c := range []*Config{iran, kharej} {
		c.applyDefaults()
		if err := c.validate(); err != nil {
			t.Fatal(err)
		}
	}

	ip := newPool(iran)
	if err := ip.start(); err != nil {
		t.Fatal(err)
	}
	ifw, err := startForward(iran, ip)
	if err != nil {
		t.Fatal(err)
	}
	kp := newPool(kharej)
	if err := kp.start(); err != nil {
		t.Fatal(err)
	}
	kf, err := startForward(kharej, kp)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ifw.Close(); kf.Close(); kp.close(); ip.close() })

	// Let every carrier the dialler wants come up.
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if up, _, _, _ := kp.stats(); up >= kharej.Carriers {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	up, _, _, _ := kp.stats()
	if up < kharej.Carriers {
		t.Fatalf("only %d of %d carriers came up", up, kharej.Carriers)
	}

	// The impatient end gives up at 3*3 = 9s. Watch well past that, and past
	// the patient end's own 10s keepalive tick, without sending a single byte
	// of payload: keepalives alone have to hold the link open.
	sawDrop := 0
	for i := 0; i < 30; i++ {
		time.Sleep(500 * time.Millisecond)
		if up, _, _, _ := kp.stats(); up < kharej.Carriers {
			sawDrop++
			t.Logf("t=%4.1fs only %d of %d carriers up",
				float64(i)*0.5, up, kharej.Carriers)
		}
	}
	if sawDrop > 0 {
		t.Fatalf("carriers dropped on %d of 30 samples across 15s of an idle link; "+
			"a keepalive difference between the two ends must not kill the tunnel", sawDrop)
	}
}

// The question that matters when a tunnel is silent is "did my bytes leave,
// and did any of theirs arrive?" - and payload counters cannot answer it,
// because an idle tunnel carries no payload. These count the socket itself.
func TestWireCountersMoveOnAnIdleTunnel(t *testing.T) {
	if testing.Short() {
		t.Skip("waits for a keepalive round trip")
	}
	setLogLevel("error")

	port := freePort(t)
	iran := &Config{
		Role: "server", Mode: "forward",
		Listen:       fmt.Sprintf("127.0.0.1:%d", port),
		Forwards:     []string{fmt.Sprint(freePort(t))},
		Carriers:     2,
		KeepaliveSec: 1,
	}
	kharej := &Config{
		Role: "client", Mode: "forward",
		Connect:      fmt.Sprintf("127.0.0.1:%d", port),
		Carriers:     2,
		KeepaliveSec: 1,
	}
	for _, c := range []*Config{iran, kharej} {
		c.applyDefaults()
		if err := c.validate(); err != nil {
			t.Fatal(err)
		}
	}
	ip := newPool(iran)
	if err := ip.start(); err != nil {
		t.Fatal(err)
	}
	ifw, err := startForward(iran, ip)
	if err != nil {
		t.Fatal(err)
	}
	kp := newPool(kharej)
	if err := kp.start(); err != nil {
		t.Fatal(err)
	}
	kf, err := startForward(kharej, kp)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ifw.Close(); kf.Close(); kp.close(); ip.close() })

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if up, _, _, _ := kp.stats(); up >= kharej.Carriers {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	// Long enough for keepalives to have crossed in both directions, and not
	// one byte of payload sent by anybody.
	time.Sleep(3 * time.Second)

	for _, side := range []struct {
		name string
		p    *pool
		cfg  *Config
	}{{"IRAN", ip, iran}, {"KHAREJ", kp, kharej}} {
		d := snapshot(side.cfg, side.p)
		if d.TxBytes != 0 || d.RxBytes != 0 {
			t.Errorf("%s: payload counters moved on an idle tunnel: tx %d rx %d",
				side.name, d.TxBytes, d.RxBytes)
		}
		if d.WireTx == 0 {
			t.Errorf("%s: wire tx is zero after 3s of keepalives; "+
				"a silent tunnel cannot be told apart from a broken one", side.name)
		}
		if d.WireRx == 0 {
			t.Errorf("%s: wire rx is zero after 3s of keepalives", side.name)
		}
	}
}

// A tunnel is identified by the port its two ends meet on, and that is where
// the key comes from. Two tunnels on different ports must not share one, or a
// server would accept carriers meant for somebody else's tunnel.
func TestTheKeyComesFromTheTunnelAndNothingElse(t *testing.T) {
	listening := &Config{Role: "server", Listen: "0.0.0.0:9443"}
	dialling := &Config{Role: "client", Connect: "203.0.113.9:9443"}
	elsewhere := &Config{Role: "client", Connect: "203.0.113.9:9444"}
	sameHostOther := &Config{Role: "server", Listen: "127.0.0.1:9443"}

	if !bytes.Equal(listening.key(), dialling.key()) {
		t.Error("the two ends of one tunnel derived different keys; nothing would connect")
	}
	if bytes.Equal(listening.key(), elsewhere.key()) {
		t.Error("a tunnel on another port shares this one's key")
	}
	// The listening side stores 0.0.0.0 and the dialling side a real address,
	// so only the port can be common to both.
	if !bytes.Equal(listening.key(), sameHostOther.key()) {
		t.Error("the bind address changed the key; the two ends never agree on it")
	}
	if len(listening.key()) != 32 {
		t.Errorf("key is %d bytes, want 32", len(listening.key()))
	}
}
