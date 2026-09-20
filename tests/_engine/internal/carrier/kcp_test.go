package carrier

import (
	"bytes"
	"net"
	"testing"
	"time"

	"pingify/internal/buf"
	"pingify/internal/config"
)

// kcpPair is a waiting KCP carrier on loopback and the side that dials it.
func kcpPair(t *testing.T, waitToken, dialToken string) (waiting, dialling *streamCarrier) {
	t.Helper()

	w := &config.Config{Side: config.SideIran, Mode: "forward", Token: waitToken}
	w.Transport.Type = "kcp"
	w.Transport.Connections = 2
	waiting, err := newKCPCarrier(w)
	if err != nil {
		t.Fatalf("waiting side: %v", err)
	}
	t.Cleanup(func() { _ = waiting.Close() })
	go waiting.Run()

	d := &config.Config{Side: config.SideKharej, Mode: "forward", Token: dialToken}
	d.Transport.Type = "kcp"
	d.Transport.Connections = 2
	d.Transport.Iran = "127.0.0.1"
	d.Transport.Port = waiting.ln.Addr().(*net.UDPAddr).Port
	dialling, err = newKCPCarrier(d)
	if err != nil {
		t.Fatalf("dialling side: %v", err)
	}
	t.Cleanup(func() { _ = dialling.Close() })
	go dialling.Run()
	return waiting, dialling
}

func shortKCPTimers(t *testing.T, idle, greet time.Duration) {
	t.Helper()
	oldIdle, oldGreet := kcpIdleMin, kcpGreetWait
	kcpIdleMin, kcpGreetWait = idle, greet
	t.Cleanup(func() { kcpIdleMin, kcpGreetWait = oldIdle, oldGreet })
}

func waitFor(t *testing.T, what string, within time.Duration, ok func() bool) {
	t.Helper()
	end := time.Now().Add(within)
	for !ok() {
		if time.Now().After(end) {
			t.Fatalf("%s: not within %s", what, within)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func sendOne(t *testing.T, c *streamCarrier, payload []byte) {
	t.Helper()
	bp := buf.Take(c.Headroom(), len(payload))
	copy((*bp)[c.Headroom():], payload)
	if err := c.SendFlow(0, bp); err != nil {
		buf.Put(bp)
		t.Fatalf("send: %v", err)
	}
}

func TestKCPCarriesFramesBothWays(t *testing.T) {
	shortKCPTimers(t, 5*time.Second, 2*time.Second)
	waiting, dialling := kcpPair(t, "the same token on both", "the same token on both")

	got := make(chan []byte, 4)
	on := func(b []byte) { got <- append([]byte(nil), b...) }
	waiting.OnPacket(on)
	dialling.OnPacket(on)

	waitFor(t, "the dialling side connecting", 5*time.Second, dialling.Up)
	waitFor(t, "the waiting side taking the connection", 5*time.Second, waiting.Up)

	// A small record, and one near the largest a KCP connection allows: a
	// frame bigger than the far end's buffer would end the connection.
	big := dialling.MaxPayload() - 8
	for _, dir := range []struct {
		from *streamCarrier
		body []byte
	}{
		{dialling, bytes.Repeat([]byte("to iran "), 150)},
		{waiting, bytes.Repeat([]byte("to kharej "), 150)},
		{dialling, bytes.Repeat([]byte{'i'}, big)},
		{waiting, bytes.Repeat([]byte{'k'}, big)},
	} {
		sendOne(t, dir.from, dir.body)
		select {
		case b := <-got:
			if !bytes.Equal(b, dir.body) {
				t.Fatalf("a %d byte frame arrived as %d different bytes", len(dir.body), len(b))
			}
		case <-time.After(5 * time.Second):
			t.Fatal("a frame did not arrive")
		}
	}
}

// A session nobody writes to must not be taken for a dead one. The side that
// dials sends keepalives and the side that waits answers them, and that is
// the only thing either side hears on a quiet tunnel.
func TestAQuietKCPTunnelStaysUp(t *testing.T) {
	shortKCPTimers(t, time.Second, 2*time.Second)
	waiting, dialling := kcpPair(t, "a token", "a token")
	waitFor(t, "connecting", 5*time.Second, func() bool { return dialling.Up() && waiting.Up() })

	first := dialling.links[0].Load()
	go dialling.Keepalive(200 * time.Millisecond)
	time.Sleep(3 * time.Second)

	if dialling.links[0].Load() != first {
		t.Fatal("slot 0 was redialled on a tunnel that was only quiet")
	}
}

// And a far end that has gone must be noticed, or the slot holds a session
// that will never carry anything again.
func TestAGoneKCPPeerIsNoticed(t *testing.T) {
	shortKCPTimers(t, time.Second, 500*time.Millisecond)
	waiting, dialling := kcpPair(t, "a token", "a token")
	waitFor(t, "connecting", 5*time.Second, func() bool { return dialling.Up() && waiting.Up() })
	go dialling.Keepalive(200 * time.Millisecond)

	_ = waiting.Close()
	waitFor(t, "the dialling side noticing", 5*time.Second, func() bool { return !dialling.Up() })
}

// UDP has no handshake, so without the greeting a server that is not ours -
// or not there - would look like a connected tunnel.
func TestKCPDoesNotConnectToAnotherTunnel(t *testing.T) {
	shortKCPTimers(t, 5*time.Second, 300*time.Millisecond)
	waiting, dialling := kcpPair(t, "this tunnel's token", "another tunnel's token")
	time.Sleep(1500 * time.Millisecond)
	if dialling.Up() || waiting.Up() {
		t.Fatal("two tunnels with different tokens connected")
	}
}
