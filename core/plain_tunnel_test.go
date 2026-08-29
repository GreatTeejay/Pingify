package main

import (
	"fmt"
	"io"
	"net"
	"testing"
	"time"
)

// A whole tunnel with the cipher off, carrying real bytes both ways.
//
// The reason this is a live test and not a unit one: the fault it exists for
// was a bound, not an algorithm. A sealed frame always carries a sixteen-byte
// GCM tag, so a length under sixteen was impossible and the read loop refused
// it outright. Without the tag a frame can be smaller than that - a keepalive
// is eleven bytes - so every carrier came up, sent one ping, and was torn down
// for "bad frame length". Nothing short of running it would have shown that.
func TestAnUnencryptedTunnelCarriesTrafficBothWays(t *testing.T) {
	setLogLevel("error")

	no := false
	echo := echoServer(t)
	local := freePort(t)
	tunPort := freePort(t)
	psk := testPSK(t)

	iran := &Config{
		Role: "server", Mode: "forward", Transport: "tcp",
		Listen: fmt.Sprintf("127.0.0.1:%d", tunPort),
		Token:  psk, Carriers: 2, BindAddr: "127.0.0.1",
		Forwards: []string{fmt.Sprintf("%d=%d", local, echo)},
		Encrypt:  &no,
	}
	kharej := &Config{
		Role: "client", Mode: "forward", Transport: "tcp",
		Connect: fmt.Sprintf("127.0.0.1:%d", tunPort),
		Token:   psk, Carriers: 2,
		Encrypt: &no,
	}
	for _, c := range []*Config{iran, kharej} {
		c.applyDefaults()
		if err := c.validate(); err != nil {
			t.Fatalf("%s: %v", c.Role, err)
		}
		if c.encrypted() {
			t.Fatalf("%s: the config says encrypt=false and the core disagrees", c.Role)
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

	deadline := time.Now().Add(10 * time.Second)
	for {
		if iu, _, _, _ := ip.stats(); iu >= 2 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("no carrier came up with the cipher off")
		}
		time.Sleep(20 * time.Millisecond)
	}

	// Long enough to span many frames, so the keepalives that broke this have
	// time to be sent while data is moving.
	c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", local), 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(15 * time.Second))

	msg := make([]byte, 256*1024)
	for i := range msg {
		msg[i] = byte(i * 31)
	}
	go func() { c.Write(msg) }()

	got := make([]byte, len(msg))
	if _, err := io.ReadFull(c, got); err != nil {
		t.Fatalf("reading it back: %v", err)
	}
	for i := range msg {
		if got[i] != msg[i] {
			t.Fatalf("byte %d came back as %d, want %d", i, got[i], msg[i])
		}
	}

	// And the carriers must still be up: the fault this covers killed them a
	// few seconds in, on the first keepalive, long after the first byte.
	time.Sleep(1500 * time.Millisecond)
	if up, _, _, _ := ip.stats(); up == 0 {
		t.Fatal("the carriers went down after the data did - a small frame was refused")
	}
}
