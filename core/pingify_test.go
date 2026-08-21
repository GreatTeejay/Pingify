package main

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"strconv"
	"sync/atomic"
	"testing"
	"time"
)

func freePort(t *testing.T) int {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	return ln.Addr().(*net.TCPAddr).Port
}

func testPSK(t *testing.T) string {
	t.Helper()
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	return hex.EncodeToString(b)
}

func TestParseForward(t *testing.T) {
	cases := []struct {
		in    string
		n     int
		first fwdRule
	}{
		{"443", 1, fwdRule{"tcp", 443, "127.0.0.1:443"}},
		{"443=8443", 1, fwdRule{"tcp", 443, "127.0.0.1:8443"}},
		{"443=10.0.0.5:8443", 1, fwdRule{"tcp", 443, "10.0.0.5:8443"}},
		{"udp:500=500", 1, fwdRule{"udp", 500, "127.0.0.1:500"}},
		{"8000-8002", 3, fwdRule{"tcp", 8000, "127.0.0.1:8000"}},
		{"8000-8002=9000", 3, fwdRule{"tcp", 8000, "127.0.0.1:9000"}},
	}
	for _, c := range cases {
		got, err := parseForward(c.in)
		if err != nil {
			t.Fatalf("%s: %v", c.in, err)
		}
		if len(got) != c.n {
			t.Fatalf("%s: got %d rules, want %d", c.in, len(got), c.n)
		}
		if got[0] != c.first {
			t.Fatalf("%s: got %+v, want %+v", c.in, got[0], c.first)
		}
	}
	if r, err := parseForward("8000-8002=9000"); err != nil || r[2].target != "127.0.0.1:9002" {
		t.Fatalf("range mapping wrong: %+v %v", r, err)
	}
	for _, bad := range []string{"", "0", "70000", "abc", "1-70000", "1-2000"} {
		if _, err := parseForward(bad); err == nil {
			t.Fatalf("%q should not parse", bad)
		}
	}
}

func TestDeriveKeysAreDirectionalAndPerCarrier(t *testing.T) {
	psk := []byte("a-shared-secret-value-here-32byte")
	nc, ns := []byte("0123456789abcdef"), []byte("fedcba9876543210")
	c2s, s2c := deriveKeys(psk, nc, ns, 0)
	if len(c2s) != 32 || len(s2c) != 32 {
		t.Fatal("keys must be 32 bytes")
	}
	if bytes.Equal(c2s, s2c) {
		t.Fatal("the two directions must not share a key")
	}
	other, _ := deriveKeys(psk, nc, ns, 1)
	if bytes.Equal(c2s, other) {
		t.Fatal("carriers must not share a key")
	}
}

// echoServer stands in for the real service on the origin side.
func echoServer(t *testing.T) int {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				io.Copy(c, c)
			}(c)
		}
	}()
	return ln.Addr().(*net.TCPAddr).Port
}

func udpEchoServer(t *testing.T) int {
	t.Helper()
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { pc.Close() })
	go func() {
		buf := make([]byte, 2048)
		for {
			n, addr, err := pc.ReadFrom(buf)
			if err != nil {
				return
			}
			pc.WriteTo(buf[:n], addr)
		}
	}()
	return pc.LocalAddr().(*net.UDPAddr).Port
}

// bringUp wires an origin (carrier listener) and an edge (carrier dialler)
// together in-process, exactly as the two servers would be wired in the field.
func bringUp(t *testing.T, forwards []string, carriers int) *pool {
	t.Helper()
	psk := testPSK(t)
	carrierPort := freePort(t)

	originCfg := &Config{
		Role: "origin", Mode: "forward",
		Listen: fmt.Sprintf("127.0.0.1:%d", carrierPort),
		PSK:    psk, Carriers: carriers,
	}
	originCfg.applyDefaults()
	if err := originCfg.validate(); err != nil {
		t.Fatal(err)
	}
	op := newPool(originCfg)
	if err := op.start(); err != nil {
		t.Fatal(err)
	}
	of, err := startForward(originCfg, op)
	if err != nil {
		t.Fatal(err)
	}

	edgeCfg := &Config{
		Role: "edge", Mode: "forward",
		Connect: fmt.Sprintf("127.0.0.1:%d", carrierPort),
		PSK:     psk, Carriers: carriers, Forwards: forwards,
	}
	edgeCfg.applyDefaults()
	if err := edgeCfg.validate(); err != nil {
		t.Fatal(err)
	}
	ep := newPool(edgeCfg)
	if err := ep.start(); err != nil {
		t.Fatal(err)
	}
	ef, err := startForward(edgeCfg, ep)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ef.Close(); of.Close(); ep.close(); op.close() })

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if up, _, _, _ := ep.stats(); up >= carriers {
			return ep
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("carriers never came up")
	return nil
}

func TestForwardTCPRoundTrip(t *testing.T) {
	setLogLevel("error")
	echo := echoServer(t)
	local := freePort(t)
	bringUp(t, []string{fmt.Sprintf("%d=%d", local, echo)}, 4)

	c, err := net.DialTimeout("tcp", "127.0.0.1:"+strconv.Itoa(local), 3*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()

	payload := make([]byte, 4<<20) // 4 MiB, well past one flow-control window
	if _, err := rand.Read(payload); err != nil {
		t.Fatal(err)
	}
	go func() {
		c.Write(payload)
		c.(*net.TCPConn).CloseWrite()
	}()

	got := make([]byte, len(payload))
	c.SetReadDeadline(time.Now().Add(30 * time.Second))
	if _, err := io.ReadFull(c, got); err != nil {
		t.Fatalf("read back: %v", err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatal("payload came back corrupted")
	}
}

func TestForwardManyConcurrentStreams(t *testing.T) {
	setLogLevel("error")
	echo := echoServer(t)
	local := freePort(t)
	bringUp(t, []string{fmt.Sprintf("%d=%d", local, echo)}, 4)

	const n = 32
	errs := make(chan error, n)
	for i := 0; i < n; i++ {
		go func(i int) {
			c, err := net.DialTimeout("tcp", "127.0.0.1:"+strconv.Itoa(local), 5*time.Second)
			if err != nil {
				errs <- err
				return
			}
			defer c.Close()
			msg := bytes.Repeat([]byte{byte(i)}, 64<<10)
			go func() { c.Write(msg); c.(*net.TCPConn).CloseWrite() }()
			got := make([]byte, len(msg))
			c.SetReadDeadline(time.Now().Add(30 * time.Second))
			if _, err := io.ReadFull(c, got); err != nil {
				errs <- err
				return
			}
			if !bytes.Equal(got, msg) {
				errs <- fmt.Errorf("stream %d corrupted", i)
				return
			}
			errs <- nil
		}(i)
	}
	for i := 0; i < n; i++ {
		if err := <-errs; err != nil {
			t.Fatal(err)
		}
	}
}

func TestForwardUDPRoundTrip(t *testing.T) {
	setLogLevel("error")
	echo := udpEchoServer(t)
	local := freePort(t)
	bringUp(t, []string{fmt.Sprintf("udp:%d=%d", local, echo)}, 2)

	c, err := net.Dial("udp", "127.0.0.1:"+strconv.Itoa(local))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	msg := []byte("pingify udp probe")
	var lastErr error
	for attempt := 0; attempt < 20; attempt++ {
		if _, err := c.Write(msg); err != nil {
			t.Fatal(err)
		}
		buf := make([]byte, 2048)
		c.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
		n, err := c.Read(buf)
		if err == nil && bytes.Equal(buf[:n], msg) {
			return
		}
		lastErr = err
	}
	t.Fatalf("udp datagram never came back: %v", lastErr)
}

func TestWrongPSKIsRejectedSilently(t *testing.T) {
	setLogLevel("error")
	carrierPort := freePort(t)
	originCfg := &Config{
		Role: "origin", Mode: "forward",
		Listen: fmt.Sprintf("127.0.0.1:%d", carrierPort),
		PSK:    testPSK(t), Carriers: 1,
	}
	originCfg.applyDefaults()
	op := newPool(originCfg)
	if err := op.start(); err != nil {
		t.Fatal(err)
	}
	defer op.close()

	wrong := &Config{Role: "edge", PSK: testPSK(t), Carriers: 1}
	wrong.applyDefaults()
	c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", carrierPort), 3*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if _, _, err := clientHandshake(c, wrong, 0); err == nil {
		t.Fatal("a mismatched key must not produce a session")
	}
}

// TestThroughput is a sanity check on the batching path, not a benchmark of a
// real link: run with -short to skip it.
func TestThroughput(t *testing.T) {
	if testing.Short() {
		t.Skip("throughput check skipped in short mode")
	}
	setLogLevel("error")
	sinkPort, served := discardServer(t)
	local := freePort(t)
	bringUp(t, []string{fmt.Sprintf("%d=%d", local, sinkPort)}, 4)

	c, err := net.DialTimeout("tcp", "127.0.0.1:"+strconv.Itoa(local), 3*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()

	const total = 256 << 20
	chunk := make([]byte, 256<<10)
	start := time.Now()
	for sent := 0; sent < total; sent += len(chunk) {
		if _, err := c.Write(chunk); err != nil {
			t.Fatal(err)
		}
	}
	c.(*net.TCPConn).CloseWrite()
	deadline := time.Now().Add(60 * time.Second)
	for atomic.LoadInt64(served) < total && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	got := atomic.LoadInt64(served)
	el := time.Since(start).Seconds()
	t.Logf("moved %.0f MiB in %.2fs = %.0f MiB/s", float64(got)/(1<<20), el, float64(got)/(1<<20)/el)
	if got < total {
		t.Fatalf("only %d of %d bytes arrived", got, total)
	}
}

func discardServer(t *testing.T) (int, *int64) {
	t.Helper()
	var n int64
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				buf := make([]byte, 256<<10)
				for {
					k, err := c.Read(buf)
					atomic.AddInt64(&n, int64(k))
					if err != nil {
						return
					}
				}
			}(c)
		}
	}()
	return ln.Addr().(*net.TCPAddr).Port, &n
}

func TestStreamsAreRetiredWhenBothSidesFinish(t *testing.T) {
	setLogLevel("error")
	echo := echoServer(t)
	local := freePort(t)
	ep := bringUp(t, []string{fmt.Sprintf("%d=%d", local, echo)}, 2)

	for i := 0; i < 12; i++ {
		c, err := net.DialTimeout("tcp", "127.0.0.1:"+strconv.Itoa(local), 5*time.Second)
		if err != nil {
			t.Fatal(err)
		}
		msg := []byte("ping")
		c.Write(msg)
		c.(*net.TCPConn).CloseWrite()
		got := make([]byte, len(msg))
		c.SetReadDeadline(time.Now().Add(10 * time.Second))
		if _, err := io.ReadFull(c, got); err != nil {
			t.Fatalf("stream %d: %v", i, err)
		}
		c.Close()
	}

	deadline := time.Now().Add(10 * time.Second)
	for {
		open := 0
		for _, l := range ep.liveLinks() {
			open += l.streamCount()
		}
		if open == 0 {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("%d streams never left the carrier's table", open)
		}
		time.Sleep(50 * time.Millisecond)
	}
}
