package main

import (
	"net"
	"strings"
	"testing"
	"time"
)

// ---------------------------------------------------------------------------
// ARQ deadlines
//
// These were accepted and ignored, on the grounds that the keepalive and the
// retransmit counter already noticed a wedged carrier. That was one mechanism
// where TCP has two - and the day the keepalive itself got stuck behind a full
// send queue, nothing was left watching: the reader sat in cond.Wait forever
// and the carrier stayed up with a peer that had gone.
// ---------------------------------------------------------------------------

func testARQ(t *testing.T) *arqConn {
	t.Helper()
	c := newARQ(1, 0, testPSKBytes(t), "pingify/test arq", 1200, 32,
		func([]byte) error { return nil })
	t.Cleanup(func() { c.Close() })
	return c
}

func testPSKBytes(t *testing.T) []byte {
	t.Helper()
	return []byte("0123456789abcdef0123456789abcdef")
}

// A read on a carrier whose peer has gone must come back, not wait for ever.
func TestARQReadHonoursItsDeadline(t *testing.T) {
	c := testARQ(t)
	c.SetReadDeadline(time.Now().Add(150 * time.Millisecond))

	start := time.Now()
	done := make(chan error, 1)
	go func() {
		_, err := c.Read(make([]byte, 64))
		done <- err
	}()

	select {
	case err := <-done:
		if err == nil {
			t.Fatal("the read returned no error")
		}
		ne, ok := err.(net.Error)
		if !ok || !ne.Timeout() {
			// The layer above tells "nothing arrived" from "the peer went
			// away" by asking exactly this, and reports them differently.
			t.Fatalf("error %v does not report Timeout(), so the log will call it the wrong thing", err)
		}
		if took := time.Since(start); took > 3*time.Second {
			t.Fatalf("it waited %v for a 150ms deadline", took)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the read ignored its deadline and blocked - which is how a dead carrier stays up for ever")
	}
}

// The writer waits on window space rather than on data, and a peer that
// acknowledges nothing wedges that side first.
func TestARQWriteHonoursItsDeadline(t *testing.T) {
	c := testARQ(t)
	c.SetWriteDeadline(time.Now().Add(150 * time.Millisecond))

	done := make(chan error, 1)
	go func() {
		// Far more than the window, against a peer that never acknowledges,
		// so the second batch has nowhere to go.
		_, err := c.Write(make([]byte, 1200*512))
		done <- err
	}()

	select {
	case err := <-done:
		if err == nil {
			t.Fatal("the write returned no error against a peer that acknowledges nothing")
		}
		if ne, ok := err.(net.Error); !ok || !ne.Timeout() {
			t.Fatalf("error %v does not report Timeout()", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the write ignored its deadline and blocked")
	}
}

// A deadline that has not arrived must not wake anybody early, or an idle
// carrier tears itself down between keepalives.
func TestARQReadWaitsUntilTheDeadlineActuallyPasses(t *testing.T) {
	c := testARQ(t)
	c.SetReadDeadline(time.Now().Add(2 * time.Second))

	done := make(chan error, 1)
	go func() {
		_, err := c.Read(make([]byte, 64))
		done <- err
	}()

	select {
	case err := <-done:
		t.Fatalf("the read came back after no time at all with %v", err)
	case <-time.After(400 * time.Millisecond):
		// Still waiting, which is right.
	}
}

// Clearing it puts the connection back to waiting indefinitely, which is what
// the handshake does when it is finished with its own deadline.
func TestARQAClearedDeadlineStopsExpiring(t *testing.T) {
	c := testARQ(t)
	c.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
	time.Sleep(200 * time.Millisecond)
	c.SetReadDeadline(time.Time{})

	done := make(chan error, 1)
	go func() {
		_, err := c.Read(make([]byte, 64))
		done <- err
	}()

	select {
	case err := <-done:
		t.Fatalf("a cleared deadline still expired: %v", err)
	case <-time.After(400 * time.Millisecond):
	}
}

// ---------------------------------------------------------------------------
// the version the other server is running
// ---------------------------------------------------------------------------

// Two builds disagree quietly. The far end dials the carrier count ITS preset
// table says, and this end reports "20 of 8 carriers up" against a config that
// asked for eight - with nothing in that line to say why, and both servers
// looking healthy from where they are standing.
func TestAVersionMismatchIsSaidOutLoud(t *testing.T) {
	setLogLevel("warn")
	p := newPool(&Config{Carriers: 1})
	l := &link{idx: 0, pool: p, closed: make(chan struct{})}

	lines := captureLog(func() { l.peerVersion("0.9.1") })

	joined := strings.Join(lines, "\n")
	if !strings.Contains(joined, "0.9.1") || !strings.Contains(joined, version) {
		t.Fatalf("the warning does not name both builds:\n%s", joined)
	}
	if !strings.Contains(joined, "carriers") {
		t.Errorf("it does not say what the mismatch looks like, which is the part that saves the time:\n%s", joined)
	}

	// Said once, not once per carrier and not once a second. The rule this
	// codebase keeps is that log volume follows the clock, not the events.
	again := captureLog(func() {
		for i := 0; i < 100; i++ {
			l.peerVersion("0.9.1")
		}
	})
	if len(again) != 0 {
		t.Fatalf("it repeated %d more times for the same mismatch", len(again))
	}
}

// And a matching peer says nothing at all.
func TestAMatchingVersionIsQuiet(t *testing.T) {
	setLogLevel("warn")
	p := newPool(&Config{Carriers: 1})
	l := &link{idx: 0, pool: p, closed: make(chan struct{})}

	lines := captureLog(func() { l.peerVersion(version) })
	if len(lines) != 0 {
		t.Fatalf("a matching build produced %d lines:\n%s", len(lines), strings.Join(lines, "\n"))
	}
	if got, _ := p.peerVer.Load().(string); got != version {
		t.Errorf("the peer version was not recorded for the status endpoint: %q", got)
	}
}

// The status endpoint carries it too, because that is where the health check
// and an operator with curl both look.
func TestTheStatusEndpointReportsThePeerVersion(t *testing.T) {
	cfg := &Config{Carriers: 1, Name: "t", Role: "server", Transport: "tcp"}
	cfg.applyDefaults()
	p := newPool(cfg)
	p.peerVer.Store("0.9.1")

	d := snapshot(cfg, p)
	if d.PeerVer != "0.9.1" {
		t.Fatalf("peer_version = %q, want 0.9.1", d.PeerVer)
	}
	if d.Version != version {
		t.Fatalf("version = %q, want %q", d.Version, version)
	}
}
