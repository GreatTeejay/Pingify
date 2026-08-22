package main

import (
	"fmt"
	"io"
	"net"
	"testing"
	"time"
)

// Which server dials the far end?
//
// Every other test runs both sides in one process, so "127.0.0.1:6526" means
// the same thing on both and a round trip proves nothing about direction. In
// the field they are different machines: IRAN accepts the user's connection
// and KHAREJ has to be the one that dials the service. If IRAN dialled its own
// loopback instead, the tunnel would come up, carriers would be healthy, and
// nothing would ever reach the other server.
//
// The allow list runs inside dialTCP, on whichever side handles the SYN, so
// pointing the two ends at different targets says exactly who did the dialling.
func TestTheFarSideDialsTheTarget(t *testing.T) {
	setLogLevel("error")

	echo := echoServer(t)
	local := freePort(t)
	port := freePort(t)
	psk := testPSK(t)
	target := fmt.Sprintf("127.0.0.1:%d", echo)

	iran := &Config{
		Role: "server", Mode: "forward",
		Listen: fmt.Sprintf("127.0.0.1:%d", port),
		Token:  psk, Carriers: 2,
		Forwards: []string{fmt.Sprintf("%d=%d", local, echo)},
		// IRAN must never dial the service. If it does, this refuses it and
		// the round trip below fails.
		Allow: []string{"nothing:0"},
	}
	kharej := &Config{
		Role: "client", Mode: "forward",
		Connect: fmt.Sprintf("127.0.0.1:%d", port),
		Token:   psk, Carriers: 2,
		Allow: []string{target},
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
		if up, _, _, _ := ip.stats(); up >= 2 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}

	c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", local), 3*time.Second)
	if err != nil {
		t.Fatalf("nothing is listening on the IRAN side: %v", err)
	}
	defer c.Close()

	want := []byte("the far side has to be the one that dials")
	go func() {
		c.Write(want)
		c.(*net.TCPConn).CloseWrite()
	}()
	got := make([]byte, len(want))
	c.SetReadDeadline(time.Now().Add(10 * time.Second))
	if _, err := io.ReadFull(c, got); err != nil {
		t.Fatalf("no round trip: %v - the SYN was handled by the wrong end, "+
			"so a real tunnel would dial the service on the Iran server "+
			"instead of the one abroad", err)
	}
	if string(got) != string(want) {
		t.Fatal("payload came back corrupted")
	}

	// And the ports belong to IRAN alone: the KHAREJ end must not have opened
	// a listener of its own, whatever its config says.
	if len(kf.listeners) != 0 {
		t.Errorf("the KHAREJ end bound %d local ports; ports live on IRAN only",
			len(kf.listeners))
	}
	if len(ifw.listeners) != 1 {
		t.Errorf("IRAN bound %d ports, want 1", len(ifw.listeners))
	}
}
