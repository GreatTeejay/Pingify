package main

import (
	"encoding/binary"
	"net"
	"testing"
	"time"
)

// A stream is pinned to one carrier for its life, so the segments the ARQ
// allows in flight decide how fast a single download can go - window * payload
// / round-trip - however many carriers the tunnel has.
//
// That number used to be the constant 64. At 1200 bytes and 75 ms it caps one
// stream at about 8 Mbit/s, which is under what a 1080p video asks for, and
// nothing in the manager could change it: the Tuning screen offered window_kb
// and the ICMP transport never read it.
func TestTheIcmpWindowFollowsTheTunnelSetting(t *testing.T) {
	const payload = 1200

	// what the presets ask for, in the unit the ARQ counts in
	for _, c := range []struct {
		windowKB int
		want     int
	}{
		{256, 218},   // gaming: small on purpose, latency over throughput
		{1024, 873},  // balanced
		{4096, 3495}, // extreme
	} {
		if got := arqWindowFor(c.windowKB, payload); got != c.want {
			t.Errorf("window_kb %d -> %d segments, want %d", c.windowKB, got, c.want)
		}
	}

	// and it stays inside bounds that mean something
	if got := arqWindowFor(1, payload); got != arqWinMin {
		t.Errorf("a tiny window gave %d, want the floor %d", got, arqWinMin)
	}
	if got := arqWindowFor(1<<20, payload); got != arqWinMax {
		t.Errorf("an absurd window gave %d, want the ceiling %d", got, arqWinMax)
	}
	if got := arqWindowFor(0, payload); got != arqWinMin {
		t.Errorf("an unset window gave %d, want the floor %d", got, arqWinMin)
	}
}

// The point of the change, stated as the thing a user would notice.
func TestOneStreamCanNowOutrunTheOldCeiling(t *testing.T) {
	const payload = 1200
	const rttSeconds = 0.075

	mbit := func(segments int) float64 {
		return float64(segments*payload*8) / rttSeconds / 1e6
	}

	old := mbit(64)
	if old > 10 {
		t.Fatalf("the old ceiling was meant to be about 8 Mbit/s, got %.1f", old)
	}
	now := mbit(arqWindowFor(1024, payload))
	if now < 80 {
		t.Errorf("one stream on the balanced preset reaches %.0f Mbit/s, want at least 80", now)
	}
	t.Logf("one stream at 75ms: was %.0f Mbit/s, now %.0f Mbit/s", old, now)
}

// Credit has to go back in as few records as the sender can afford to wait
// for. One per read is a control record for every 32 KiB consumed - hundreds a
// second on a busy stream, each one a frame to seal, a wakeup for the writer,
// and a place in the queue ahead of traffic that is actually going somewhere.
// That is where jitter under load comes from.
func TestCreditGoesBackInFewRecordsUnderLoad(t *testing.T) {
	setLogLevel("error")
	cfg := &Config{WindowKB: 512, KeepaliveSec: 10}
	cfg.applyDefaults()
	l := &link{idx: 0, cfg: cfg, closed: make(chan struct{}), sendQ: make(chan *recBuf, 4096)}

	s := &stream{id: 7, l: l, rb: newRecvBuf(), done: make(chan struct{}), winCh: make(chan struct{}, 1)}

	// A megabyte already waiting, and a local side that takes it as fast as it
	// is offered: the buffer never drains between reads, which is what a busy
	// stream looks like.
	const total = 1 << 20
	chunk := make([]byte, 16*1024)
	for i := 0; i < total/len(chunk); i++ {
		s.rb.push(chunk)
	}
	s.rb.closeEOF()

	done := make(chan struct{})
	go func() { s.pumpIn(devNull{}); close(done) }()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("pumpIn never finished")
	}

	var records, credit int
	for {
		select {
		case r := <-l.sendQ:
			b := r.bytes()
			if len(b) >= recHdr && b[0] == cmdWND {
				records++
				credit += int(binary.BigEndian.Uint32(b[recHdr : recHdr+4]))
			}
			continue
		default:
		}
		break
	}

	// Every byte consumed has to be given back, or the sender stalls forever.
	if credit != total {
		t.Fatalf("returned %d bytes of credit for %d consumed", credit, total)
	}
	// A read is 32 KiB and half the window is 256 KiB, so a megabyte should
	// cost about four records, not thirty-two.
	if records > 8 {
		t.Fatalf("%d window records for %d KiB - the bookkeeping is back in front of the traffic",
			records, total/1024)
	}
	t.Logf("%d KiB returned in %d records", total/1024, records)
}

// And an idle stream must not sit on credit the sender is waiting for.
func TestCreditIsReturnedAtOnceWhenTheStreamGoesQuiet(t *testing.T) {
	setLogLevel("error")
	cfg := &Config{WindowKB: 512, KeepaliveSec: 10}
	cfg.applyDefaults()
	l := &link{idx: 0, cfg: cfg, closed: make(chan struct{}), sendQ: make(chan *recBuf, 64)}
	s := &stream{id: 9, l: l, rb: newRecvBuf(), done: make(chan struct{}), winCh: make(chan struct{}, 1)}

	go s.pumpIn(devNull{})

	// One small record, far below any threshold, and then nothing.
	s.rb.push([]byte("a page of a subscription file"))

	select {
	case r := <-l.sendQ:
		b := r.bytes()
		if b[0] != cmdWND {
			t.Fatalf("first record was cmd %d, not a window update", b[0])
		}
		if got := binary.BigEndian.Uint32(b[recHdr : recHdr+4]); got != 29 {
			t.Fatalf("returned %d bytes of credit, want 29", got)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("a quiet stream sat on its credit; the sender would be waiting on it")
	}
}

type devNull struct{ net.Conn }

func (devNull) Write(p []byte) (int, error) { return len(p), nil }
func (devNull) Close() error                { return nil }
