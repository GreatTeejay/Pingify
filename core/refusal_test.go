package main

import (
	"fmt"
	"net"
	"strings"
	"sync"
	"testing"
	"time"
)

// captureLog collects everything logged while fn runs.
func captureLog(fn func()) []string {
	var mu sync.Mutex
	var lines []string
	prev := logSink
	logSink = func(s string) {
		mu.Lock()
		lines = append(lines, s)
		mu.Unlock()
	}
	defer func() { logSink = prev }()
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
