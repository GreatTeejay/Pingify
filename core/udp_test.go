package main

import (
	"fmt"
	"io"
	"net"
	"testing"
	"time"
)

// A whole UDP tunnel, both ends, carrying real bytes through a forwarded port.
// This is the test that matters: the seam is only worth having if a transport
// written to it works without anything above it being touched.
func TestAUDPTunnelCarriesTraffic(t *testing.T) {
	setLogLevel("error")

	echo := echoServer(t)
	local := freePort(t)
	tunPort := freePort(t)
	psk := testPSK(t)

	iran := &Config{
		Role: "server", Mode: "forward", Transport: "udp",
		Listen: fmt.Sprintf("127.0.0.1:%d", tunPort),
		Token:  psk, Carriers: 2, BindAddr: "127.0.0.1",
		Forwards: []string{fmt.Sprintf("%d=%d", local, echo)},
	}
	kharej := &Config{
		Role: "client", Mode: "forward", Transport: "udp",
		Connect: fmt.Sprintf("127.0.0.1:%d", tunPort),
		Token:   psk, Carriers: 2,
	}
	for _, c := range []*Config{iran, kharej} {
		c.applyDefaults()
		if err := c.validate(); err != nil {
			t.Fatalf("%s: %v", c.Role, err)
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
		if up, _, _, _ := ip.stats(); up >= 2 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("UDP carriers never came up")
		}
		time.Sleep(20 * time.Millisecond)
	}

	// and now push something through it
	c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", local), 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(10 * time.Second))

	msg := make([]byte, 64*1024) // bigger than one datagram, so it must be segmented
	for i := range msg {
		msg[i] = byte(i)
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
	t.Logf("64 KiB through a UDP tunnel, segmented and reassembled intact")
}

// The wedge that killed the echo transport must not be reachable here either.
// The dialling end never accepts, so strays have to be ignored rather than
// queued - or the one read loop stops and every carrier on it goes silent.
func TestUDPStraysCannotWedgeTheReader(t *testing.T) {
	psk := []byte(testPSK(t))
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer pc.Close()

	tr := &udpTransport{
		pc:       pc,
		psk:      psk,
		window:   64,
		sessions: make(map[sessionKey]*arqConn),
		inbound:  make(chan net.Conn, 4),
		done:     make(chan struct{}),
	}
	defer close(tr.done)

	peer := &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 9}

	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 1; i <= 40; i++ {
			tr.dispatch(peer, udpStray(psk, uint32(0x57A00000+i)))
		}
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("dispatch wedged - the reader would be dead and every carrier with it")
	}

	tr.mu.Lock()
	n := len(tr.sessions)
	for _, c := range tr.sessions {
		close(c.done)
	}
	tr.mu.Unlock()
	if n > 6 {
		t.Errorf("kept %d sessions for strays nobody accepted", n)
	}
}

func udpStray(psk []byte, session uint32) []byte {
	k := hkdfExpand(hkdfExtract([]byte("pingify/v3 udp"), psk), []byte("arq header"), 32)
	buf := make([]byte, arqOver)
	for i := 0; i < arqNonce; i++ {
		buf[i] = byte(session >> (8 * uint(i)))
	}
	h := arqHeader{session: session, carrier: 0}
	h.put(buf[arqNonce:arqOver])
	maskHeader(blockFrom(k), buf[:arqNonce], buf[arqNonce:arqOver])
	return buf
}
