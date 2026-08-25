package main

import (
	"strings"
	"testing"
)

// The seam exists so that adding a transport is writing Dial, Accept and Close
// and touching nothing above them. These check the part that is easy to get
// wrong when a fourth and fifth arrive.
func TestATransportIsChosenByName(t *testing.T) {
	psk := testPSK(t)

	// The dialling end of a TCP tunnel binds nothing: it has no listen
	// address, and taking a port it will never accept on would be a port
	// stolen from something else.
	dial := &Config{Role: "client", Mode: "forward", Transport: "tcp",
		Connect: "198.51.100.4:9443", Token: psk, Carriers: 2}
	dial.applyDefaults()
	tr, err := newTransport(dial)
	if err != nil {
		t.Fatalf("tcp dialler: %v", err)
	}
	defer tr.Close()
	if tr.Name() != "tcp" {
		t.Errorf("name is %q, want tcp", tr.Name())
	}
	if _, err := tr.Accept(); err == nil {
		t.Error("the dialling end accepted something; it has nothing to accept on")
	}

	// An empty transport is a TCP tunnel written before the field existed.
	old := &Config{Role: "client", Mode: "forward", Connect: "198.51.100.4:9443",
		Token: psk, Carriers: 2}
	old.applyDefaults()
	tr2, err := newTransport(old)
	if err != nil {
		t.Fatalf("unset transport: %v", err)
	}
	defer tr2.Close()
	if tr2.Name() != "tcp" {
		t.Errorf("an unset transport became %q, want tcp", tr2.Name())
	}
}

// A name nothing implements has to be an error. Falling back to TCP would
// build a tunnel that cannot reach the other end and then look healthy doing
// it - which is the worst outcome available, worse than refusing to start.
func TestAnUnknownTransportIsRefused(t *testing.T) {
	cfg := &Config{Role: "client", Mode: "forward", Transport: "carrier-pigeon",
		Connect: "198.51.100.4:9443", Token: testPSK(t), Carriers: 2}
	cfg.applyDefaults()
	tr, err := newTransport(cfg)
	if err == nil {
		tr.Close()
		t.Fatal("an unknown transport was accepted")
	}
	if !strings.Contains(err.Error(), "carrier-pigeon") {
		t.Errorf("the error does not name what was asked for: %v", err)
	}
}

// Every transport must answer the same three questions, or the pool has to
// know which one it is holding - which is the thing the seam removes.
func TestEveryTransportSatisfiesTheSeam(t *testing.T) {
	var _ carrierTransport = (*tcpTransport)(nil)
	var _ carrierTransport = (*icmpCarrier)(nil)
	var _ carrierTransport = (*udpCarrier)(nil)
	var _ carrierTransport = (*kcpTransport)(nil)
	var _ carrierTransport = (*pckTransport)(nil)
	var _ carrierTransport = (*wsTransport)(nil)
}
