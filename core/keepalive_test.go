package main

import (
	"fmt"
	"strings"
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

	psk := testPSK(t)
	port := freePort(t)

	// IRAN: listens, forwards ports, "balanced".
	iran := &Config{
		Role: "server", Mode: "forward",
		Listen: fmt.Sprintf("127.0.0.1:%d", port),
		Token:  psk, Carriers: 4, KeepaliveSec: 10,
		Forwards: []string{fmt.Sprint(freePort(t))},
	}
	// KHAREJ: dials, "gaming" with a hand-tuned keepalive.
	kharej := &Config{
		Role: "client", Mode: "forward",
		Connect: fmt.Sprintf("127.0.0.1:%d", port),
		Token:   psk, Carriers: 8, KeepaliveSec: 3,
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

// Two servers with the same token must print the same fingerprint, and two
// with different tokens must not - that is the entire contract, and the
// manager script computes it independently in sh.
func TestTokenPrintIdentifiesTheSecret(t *testing.T) {
	a := &Config{Token: "a token typed on both servers"}
	b := &Config{Token: "  a token typed on both servers  "} // whitespace is not the secret
	c := &Config{Token: "a token typed on one server"}

	if a.tokenPrint() != b.tokenPrint() {
		t.Errorf("surrounding whitespace changed the fingerprint: %s vs %s",
			a.tokenPrint(), b.tokenPrint())
	}
	if a.tokenPrint() == c.tokenPrint() {
		t.Error("two different tokens share a fingerprint")
	}
	if len(a.tokenPrint()) != 8 {
		t.Errorf("fingerprint is %d characters, want 8", len(a.tokenPrint()))
	}
	// Pinned: the manager script computes this in sh with sha256sum, and the
	// two must agree or comparing the two servers by eye is worthless.
	if got := a.tokenPrint(); got != "a24f91a4" {
		t.Errorf("fingerprint is %s; sh computes a24f91a4 for the same token, "+
			"so the core and the manager no longer agree", got)
	}
	if (&Config{}).tokenPrint() != "none" {
		t.Error("an empty token should say none, not print a hash of nothing")
	}
	// The secret itself must never be recoverable from what we print.
	if strings.Contains(a.tokenPrint(), "token") {
		t.Error("the fingerprint leaked the token")
	}
}

// A token's length is the operator's decision, not ours. There is exactly one
// rule: there has to be one. This exists so the minimum does not creep back.
func TestShortTokensAreAccepted(t *testing.T) {
	base := func(tok string) *Config {
		c := &Config{
			Role: "server", Mode: "forward", Transport: "tcp",
			Listen: "0.0.0.0:9443", Token: tok, Forwards: []string{"443"},
		}
		c.applyDefaults()
		return c
	}
	for _, tok := range []string{"mit", "a", "12", "ab cd", "!"} {
		if err := base(tok).validate(); err != nil {
			t.Errorf("token %q rejected: %v", tok, err)
		}
	}
	if err := base("").validate(); err == nil {
		t.Error("an empty token was accepted; the core has no key without one")
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

	psk := testPSK(t)
	port := freePort(t)
	iran := &Config{
		Role: "server", Mode: "forward",
		Listen: fmt.Sprintf("127.0.0.1:%d", port),
		Token:  psk, Carriers: 2, KeepaliveSec: 1,
		Forwards: []string{fmt.Sprint(freePort(t))},
	}
	kharej := &Config{
		Role: "client", Mode: "forward",
		Connect: fmt.Sprintf("127.0.0.1:%d", port),
		Token:   psk, Carriers: 2, KeepaliveSec: 1,
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
