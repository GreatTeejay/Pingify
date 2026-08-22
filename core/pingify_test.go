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

func TestSessionKeysAreDirectionalAndPerCarrier(t *testing.T) {
	psk := []byte("a-shared-secret-value-here-32byte")
	nc, ns := []byte("0123456789abcdef"), []byte("fedcba9876543210")

	dialer := deriveSession(psk, nc, ns, 0, true)
	listener := deriveSession(psk, nc, ns, 0, false)

	// What one side seals, the other must open - and only that way round.
	msg := []byte("carrier payload")
	var nonce [12]byte
	sealed := dialer.tx.Seal(nil, nonce[:], msg, nil)
	got, err := listener.rx.Open(nil, nonce[:], sealed, nil)
	if err != nil || !bytes.Equal(got, msg) {
		t.Fatalf("the listener could not open what the dialer sealed: %v", err)
	}
	if _, err := listener.tx.Open(nil, nonce[:], sealed, nil); err == nil {
		t.Fatal("the two directions must not share a key")
	}

	other := deriveSession(psk, nc, ns, 1, true)
	if _, err := other.rx.Open(nil, nonce[:], sealed, nil); err == nil {
		t.Fatal("two carriers must not share a key")
	}
}

func TestLengthMaskIsReversibleAndPerFrame(t *testing.T) {
	k := deriveSession([]byte("psk"), []byte("0123456789abcdef"), []byte("fedcba9876543210"), 0, true)
	var a, b [4]byte
	copy(a[:], []byte{0, 1, 0, 0})
	copy(b[:], a[:])

	maskLen(k.maskTx, 7, a[:])
	if bytes.Equal(a[:], b[:]) {
		t.Fatal("masking changed nothing")
	}
	maskLen(k.maskTx, 7, a[:]) // XOR is its own inverse
	if !bytes.Equal(a[:], b[:]) {
		t.Fatal("unmasking did not restore the length")
	}

	var c [4]byte
	copy(c[:], b[:])
	maskLen(k.maskTx, 8, c[:])
	maskLen(k.maskTx, 7, b[:])
	if bytes.Equal(b[:], c[:]) {
		t.Fatal("consecutive frames must not reuse a mask")
	}
}

// The opening bytes of a connection are what a filter fingerprints. Nothing
// there may repeat: no magic number, no fixed field, not even a fixed length.
func TestHandshakeLeaksNoConstantBytes(t *testing.T) {
	setLogLevel("error")
	const runs = 12

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	captured := make(chan []byte, runs)
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				hdr := make([]byte, hsClientLen)
				if _, err := io.ReadFull(c, hdr); err != nil {
					return
				}
				// The padding length lives in the tag, so read it the way a
				// real listener would.
				padLen := int(hdr[hsNonceLen+hsSealedLen])
				pad := make([]byte, padLen)
				io.ReadFull(c, pad)
				captured <- append(append([]byte{}, hdr...), pad...)
			}(c)
		}
	}()

	cfg := &Config{Role: "edge", PSK: testPSK(t), Carriers: 1}
	cfg.applyDefaults()
	addr := ln.Addr().String()

	var seen [][]byte
	for i := 0; i < runs; i++ {
		c, err := net.DialTimeout("tcp", addr, 3*time.Second)
		if err != nil {
			t.Fatal(err)
		}
		clientHandshake(c, cfg, 0) // the listener never answers; that is fine
		c.Close()
		select {
		case b := <-captured:
			seen = append(seen, b)
		case <-time.After(3 * time.Second):
			t.Fatal("the listener never saw the handshake")
		}
	}

	// No byte position may hold the same value in every handshake.
	for pos := 0; pos < hsClientLen; pos++ {
		same := true
		for _, b := range seen[1:] {
			if b[pos] != seen[0][pos] {
				same = false
				break
			}
		}
		if same {
			t.Fatalf("byte %d is identical in all %d handshakes (value %#x) - that is a signature",
				pos, runs, seen[0][pos])
		}
	}

	// And the total length has to vary, or the size alone identifies it.
	lengths := map[int]bool{}
	for _, b := range seen {
		lengths[len(b)] = true
	}
	if len(lengths) < 2 {
		t.Fatalf("every handshake was %d bytes long", len(seen[0]))
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
	if _, err := clientHandshake(c, wrong, 0); err == nil {
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
