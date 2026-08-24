package main

import (
	"fmt"
	"io"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// captureLog collects everything logged while fn runs.
func captureLog(fn func()) []string {
	var mu sync.Mutex
	var lines []string
	prev := setLogSink(func(s string) {
		mu.Lock()
		lines = append(lines, s)
		mu.Unlock()
	})
	defer setLogSink(prev)
	fn()
	mu.Lock()
	defer mu.Unlock()
	out := make([]string, len(lines))
	copy(out, lines)
	return out
}

// When the service on the far server is not running, the near server used to
// close the user's connection with nothing to say - which is exactly the state
// a working tunnel with a dead service is in, and exactly what "it does not
// work" looks like from the outside. The reason now comes back with the reset.
func TestARefusalSaysWhichServerAndWhy(t *testing.T) {
	setLogLevel("warn")

	// A port with nothing behind it: whatever the far side dials, it fails.
	dead := freePort(t)
	local := freePort(t)
	port := freePort(t)
	psk := testPSK(t)

	iran := &Config{
		Role: "server", Mode: "forward",
		Listen: fmt.Sprintf("127.0.0.1:%d", port),
		Token:  psk, Carriers: 2,
		BindAddr: "127.0.0.1",
		Forwards: []string{fmt.Sprintf("%d=%d", local, dead)},
	}
	kharej := &Config{
		Role: "client", Mode: "forward",
		Connect: fmt.Sprintf("127.0.0.1:%d", port),
		Token:   psk, Carriers: 2,
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

	lines := captureLog(func() {
		c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", local), 3*time.Second)
		if err != nil {
			t.Fatalf("the near side did not even accept: %v", err)
		}
		defer c.Close()
		c.Write([]byte("hello"))
		c.SetReadDeadline(time.Now().Add(3 * time.Second))
		buf := make([]byte, 16)
		c.Read(buf) // expected to fail; the far side refuses
		time.Sleep(300 * time.Millisecond)
	})

	joined := strings.Join(lines, "\n")
	if !strings.Contains(joined, "the other server refused a connection") {
		t.Fatalf("nothing told the near side why the connection died.\nlogged:\n%s", joined)
	}
	// The message has to name the address that could not be reached, or it
	// sends the reader hunting through the wrong config.
	if !strings.Contains(joined, fmt.Sprintf("127.0.0.1:%d", dead)) {
		t.Errorf("the refusal did not name the target %d.\nlogged:\n%s", dead, joined)
	}
}

// A target that is down refuses every connection there is, and the far side
// sends a record saying so for each one. This used to write a line per record
// out of the carrier's read loop - which is the read loop of a carrier, not
// reading, for as long as the write took. The volume has to follow the clock.
func TestARefusedTargetDoesNotFloodTheLog(t *testing.T) {
	setLogLevel("warn")
	p := newPool(&Config{Carriers: 1})
	l := &link{idx: 0, pool: p, closed: make(chan struct{})}

	lines := captureLog(func() {
		for i := 0; i < 2000; i++ {
			l.refused("127.0.0.1:8009: connect: connection refused")
		}
	})

	if len(lines) != 1 {
		t.Fatalf("two thousand refusals wrote %d lines, want 1:\n%s",
			len(lines), strings.Join(lines, "\n"))
	}
	if !strings.Contains(lines[0], "8009") {
		t.Errorf("the line does not say what was refused: %s", lines[0])
	}
	if got := atomic.LoadUint64(&p.refusals); got != 2000 {
		t.Errorf("the status endpoint counted %d refusals, want 2000", got)
	}

	// The next minute's first line carries the ones that were swallowed, or
	// the operator is told a target flapped once when it never came back.
	p.errMu.Lock()
	p.errSeen["refused"] = time.Now().Add(-2 * time.Minute)
	p.errMu.Unlock()
	next := captureLog(func() { l.refused("127.0.0.1:8009: connect: connection refused") })
	if len(next) != 1 || !strings.Contains(next[0], "1999 more") {
		t.Fatalf("the next line did not carry the count it stood for:\n%s", strings.Join(next, "\n"))
	}
}

// The sink under systemd is a pipe to journald, and a pipe blocks when it is
// full. Nothing in this process may wait on it: a log line is never worth the
// carrier whose read loop wrote it.
func TestTheLogDoesNotWaitForAWedgedJournal(t *testing.T) {
	stuck := make(chan struct{})
	defer close(stuck)
	a := newAsyncWriter(blockingWriter{stuck})

	done := make(chan time.Duration, 1)
	go func() {
		start := time.Now()
		for i := 0; i < logQueue*4; i++ {
			a.write(fmt.Sprintf("line %d", i))
		}
		done <- time.Since(start)
	}()

	select {
	case took := <-done:
		if took > 2*time.Second {
			t.Fatalf("writing %d lines to a wedged journal took %v", logQueue*4, took)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the log blocked on a journal that stopped reading - a carrier would have died waiting")
	}
	if atomic.LoadUint64(&a.dropped) == 0 {
		t.Error("nothing was recorded as dropped, so the gap would go unreported")
	}
}

// blockingWriter is a journald that has stopped reading.
type blockingWriter struct{ stuck chan struct{} }

func (w blockingWriter) Write(p []byte) (int, error) {
	<-w.stuck
	return len(p), nil
}

// The tunnel in the field report: a ws braid whose forward target is a port
// with nothing on it, and a client that keeps trying. Every attempt is one
// refusal on the far server and one record back saying so - and both ends
// used to write a line for each, one of them out of the carrier's own read
// loop.
//
// What matters here is the count. Two hundred refused connections must not be
// four hundred lines, because that is a journal that stops keeping up and a
// read loop that waits for it.
func TestARefusedTargetUnderLoadStaysQuietAndKeepsItsCarriers(t *testing.T) {
	setLogLevel("warn")

	dead := freePort(t)
	local := freePort(t)
	port := freePort(t)
	psk := testPSK(t)

	iran := &Config{
		Role: "server", Mode: "forward", Transport: "ws",
		Listen: fmt.Sprintf("127.0.0.1:%d", port),
		Token:  psk, Carriers: 4, BindAddr: "127.0.0.1",
		Forwards: []string{fmt.Sprintf("%d=%d", local, dead)},
	}
	kharej := &Config{
		Role: "client", Mode: "forward", Transport: "ws",
		Connect: fmt.Sprintf("127.0.0.1:%d", port),
		Token:   psk, Carriers: 4,
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

	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if up, _, _, _ := ip.stats(); up >= 4 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if up, _, _, _ := ip.stats(); up < 4 {
		t.Fatalf("only %d of 4 carriers came up", up)
	}

	lines := captureLog(func() {
		for i := 0; i < 200; i++ {
			c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", local), 3*time.Second)
			if err != nil {
				continue
			}
			c.SetDeadline(time.Now().Add(3 * time.Second))
			c.Write([]byte("hello"))
			io.Copy(io.Discard, c)
			c.Close()
		}
		time.Sleep(500 * time.Millisecond)
	})

	// One line from each end at most, plus whatever else a healthy tunnel
	// says in half a second, which is nothing.
	if len(lines) > 4 {
		t.Fatalf("two hundred refused connections wrote %d log lines, want at most 4:\n%s",
			len(lines), strings.Join(lines[:min(len(lines), 12)], "\n"))
	}
	joined := strings.Join(lines, "\n")
	if !strings.Contains(joined, "refused") {
		t.Fatalf("the operator was told nothing at all:\n%s", joined)
	}

	// And the braid is still whole. The point of rationing the log was never
	// the log.
	if up, _, _, _ := ip.stats(); up < 4 {
		t.Errorf("iran ended with %d of 4 carriers", up)
	}
	if up, _, _, _ := kp.stats(); up < 4 {
		t.Errorf("kharej ended with %d of 4 carriers", up)
	}
	t.Logf("200 refusals, %d log lines, braid intact", len(lines))
}
