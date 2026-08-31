package main

import (
	"bytes"
	"fmt"
	"net"
	"sync"
	"testing"
	"time"
)

// The private link and the braid share one socket. A packet from the link has
// no session under it and a braid datagram does, and the only thing telling
// them apart is which key made the four-byte tag. If that ever collided, a
// packet would be handed to the session machinery or a carrier's datagram
// would be written to the network device - so it is worth proving on a real
// socket rather than reasoning about.
func TestBarePacketsAndSessionDatagramsShareASocket(t *testing.T) {
	setLogLevel("error")
	psk := testPSK(t)

	mk := func(listen, connect string) *udpTransport {
		cfg := &Config{
			Role: "server", Mode: "tun", Transport: "udp",
			Listen: listen, Connect: connect, Token: psk, Carriers: 1,
		}
		cfg.applyDefaults()
		tr, err := newUDPTransport(cfg)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { tr.Close() })
		return tr
	}

	server := mk(fmt.Sprintf("127.0.0.1:%d", freePort(t)), "")
	client := mk("127.0.0.1:0", server.pc.LocalAddr().String())

	var mu sync.Mutex
	var atServer [][]byte
	gotOne := make(chan struct{}, 16)
	server.SetPacketHandler(func(p []byte) {
		mu.Lock()
		atServer = append(atServer, append([]byte(nil), p...))
		mu.Unlock()
		select {
		case gotOne <- struct{}{}:
		default:
		}
	}, nil)

	// The client has to know where to send; a dialling end is told.
	host, _, _ := net.SplitHostPort(server.pc.LocalAddr().String())
	ip, err := net.ResolveIPAddr("ip4", host)
	if err != nil {
		t.Fatal(err)
	}
	client.SetPacketHandler(func([]byte) {}, ip)
	// SetPacketHandler only carries an IP; give it the port the server is on.
	client.pktMu.Lock()
	client.pktTo = server.pc.LocalAddr()
	client.pktMu.Unlock()

	// The transport fills its own header in front of the payload, so the
	// buffer handed to it has that much room at the start.
	pkt := []byte("an IP packet from the private link")
	buf := make([]byte, client.Headroom()+len(pkt))
	copy(buf[client.Headroom():], pkt)
	if err := client.SendPacket(&buf); err != nil {
		t.Fatal(err)
	}
	select {
	case <-gotOne:
	case <-time.After(5 * time.Second):
		t.Fatal("a bare packet never arrived")
	}
	mu.Lock()
	if len(atServer) != 1 || !bytes.Equal(atServer[0], pkt) {
		mu.Unlock()
		t.Fatalf("the packet arrived changed: %q", atServer)
	}
	mu.Unlock()

	// It must NOT have been taken for a session: nothing should have been
	// built, and nothing should be waiting to be accepted.
	server.mu.Lock()
	sessions := len(server.sessions)
	server.mu.Unlock()
	if sessions != 0 {
		t.Fatalf("a bare packet built %d ARQ sessions", sessions)
	}
	if q := len(server.inbound); q != 0 {
		t.Fatalf("a bare packet was queued as %d carriers", q)
	}

	// And the other direction still works: a real session datagram on the
	// same socket must still reach the session machinery.
	conn, err := client.Dial(server.pc.LocalAddr().String(), 0)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if _, err := conn.Write([]byte("a carrier saying hello")); err != nil {
		t.Fatal(err)
	}
	accepted := make(chan net.Conn, 1)
	go func() {
		c, err := server.Accept()
		if err == nil {
			accepted <- c
		}
	}()
	select {
	case c := <-accepted:
		c.Close()
	case <-time.After(5 * time.Second):
		t.Fatal("a session datagram did not reach Accept - the two tags are being confused")
	}

	// and the bare packet still did not become a session
	mu.Lock()
	n := len(atServer)
	mu.Unlock()
	if n != 1 {
		t.Fatalf("the packet handler saw %d packets, want 1", n)
	}
}

// A transport with no handler installed must ignore bare packets entirely,
// rather than pass them to the session machinery.
func TestABarePacketIsIgnoredWithNoHandler(t *testing.T) {
	setLogLevel("error")
	psk := testPSK(t)
	cfg := &Config{
		Role: "server", Mode: "forward", Transport: "udp",
		Listen: fmt.Sprintf("127.0.0.1:%d", freePort(t)), Token: psk, Carriers: 1,
	}
	cfg.applyDefaults()
	tr, err := newUDPTransport(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer tr.Close()

	// forge one the way SendPacket would
	body := make([]byte, udpTagLen+16)
	payload := []byte("sixteen bytes...")
	tr.putTagFor(udpTagDirect, body[:udpTagLen], payload[:min(len(payload), arqOver)])
	copy(body[udpTagLen:], payload)
	tr.handlePacket(body, &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 9})

	tr.mu.Lock()
	sessions := len(tr.sessions)
	tr.mu.Unlock()
	if sessions != 0 {
		t.Fatalf("a bare packet with no handler built %d sessions", sessions)
	}
}
