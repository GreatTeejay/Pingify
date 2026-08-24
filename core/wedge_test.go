package main

import (
	"net"
	"testing"
	"time"
)

// The read loop is shared by every carrier on an ICMP transport, and it was
// possible to wedge it forever.
//
// A raw ICMP socket receives every echo reply the host sees, so a datagram for
// a session this end does not know is routine - a peer retransmitting to a
// session already torn down is enough. Each one created a connection and
// handed it to Accept. But the DIALLING end never calls Accept: it only dials.
// So the first strays filled the channel, the reader blocked waiting for an
// acceptor that does not exist, and stopped delivering to the live carriers.
//
// Every carrier then went silent at once. Sixty seconds later the braid
// declared the peer gone and took all of them down together, the service
// restarted, and the same thing happened a minute after that - which is
// exactly the cycle the field logs showed.
func TestStraySessionsCannotWedgeTheReader(t *testing.T) {
	psk := []byte(testPSK(t))
	// A real socket, so the connections this creates can write somewhere
	// harmless instead of into a nil pointer. What they send does not matter;
	// the test is about whether dispatch returns.
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer pc.Close()
	tr := &icmpTransport{
		pc:       pc,
		psk:      psk,
		window:   64,
		sessions: make(map[sessionKey]*arqConn),
		inbound:  make(chan net.Conn, 4), // small on purpose
		done:     make(chan struct{}),
	}
	defer close(tr.done)

	peer := &net.IPAddr{IP: net.ParseIP("198.51.100.4")}

	// One session this end is actually using, as a dialled carrier would be.
	live := newARQ(0x11110001, 0, psk, icmpARQLabel, 1200, 64, func([]byte) error { return nil })
	defer live.Close()
	tr.sessions[sessionKey{peer: peer.String(), session: 0x11110001, carrier: 0}] = live

	// Far more strays than the channel can hold, with nobody accepting.
	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 1; i <= 40; i++ {
			tr.dispatch(peer, uint16(i), strayDatagram(psk, uint32(0x57A00000+i), 0))
		}
	}()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("dispatch wedged on the inbound channel - the reader would be dead and every carrier with it")
	}

	// And the sessions nobody accepted were not kept either, or the map grows
	// without bound on a public address.
	tr.mu.Lock()
	n := len(tr.sessions)
	for _, c := range tr.sessions {
		if c != live {
			close(c.done) // stop its timer without sending anything
		}
	}
	tr.mu.Unlock()
	if n > 4+1+1 {
		t.Errorf("kept %d sessions for strays nobody accepted", n)
	}
}

// strayDatagram builds a datagram for a session the transport has never seen,
// masked the way a real peer would mask it.
func strayDatagram(psk []byte, session uint32, carrier uint8) []byte {
	k := hkdfExpand(hkdfExtract([]byte("pingify/v3 icmp"), psk), []byte("arq header"), 32)
	buf := make([]byte, arqOver)
	for i := 0; i < arqNonce; i++ {
		buf[i] = byte(session >> (8 * uint(i)))
	}
	h := arqHeader{session: session, carrier: carrier, flags: 0}
	h.put(buf[arqNonce:arqOver])
	maskHeader(blockFrom(k), buf[:arqNonce], buf[arqNonce:arqOver])
	return buf
}
