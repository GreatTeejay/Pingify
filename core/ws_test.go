package main

import (
	"bufio"
	"bytes"
	"crypto/tls"
	"encoding/binary"
	"fmt"
	"io"
	"math/rand"
	"net"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"
)

// A whole WebSocket tunnel, both ends, carrying real bytes. Plain and over
// TLS, because the two differ only in what is under the framing and both have
// to work.
func TestAWebSocketTunnelCarriesTraffic(t *testing.T) {
	for _, useTLS := range []bool{false, true} {
		name := "ws"
		if useTLS {
			name = "wss"
		}
		t.Run(name, func(t *testing.T) {
			setLogLevel("error")
			echo := echoServer(t)
			local := freePort(t)
			port := freePort(t)
			psk := testPSK(t)

			iran := &Config{
				Role: "server", Mode: "forward", Transport: name,
				Listen: fmt.Sprintf("127.0.0.1:%d", port),
				Token:  psk, Carriers: 2, BindAddr: "127.0.0.1",
				Forwards: []string{fmt.Sprintf("%d=%d", local, echo)},
			}
			kharej := &Config{
				Role: "client", Mode: "forward", Transport: name,
				Connect: fmt.Sprintf("127.0.0.1:%d", port),
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
					t.Fatalf("%s carriers never came up", name)
				}
				time.Sleep(20 * time.Millisecond)
			}

			c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", local), 5*time.Second)
			if err != nil {
				t.Fatal(err)
			}
			defer c.Close()
			c.SetDeadline(time.Now().Add(10 * time.Second))

			// Bigger than one frame's small-length encoding, so the extended
			// length path is exercised in both directions.
			msg := make([]byte, 200*1024)
			for i := range msg {
				msg[i] = byte(i * 7)
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
			t.Logf("200 KiB through a %s tunnel, framed and reassembled intact", name)
		})
	}
}

// Everything that is not a carrier gets a web server with nothing on it -
// because a port that answers nothing is far rarer, and rarer is what gets
// looked at.
func TestAScannerFindsOnlyNginx(t *testing.T) {
	setLogLevel("error")
	port := freePort(t)
	psk := testPSK(t)
	cfg := &Config{
		Role: "server", Mode: "forward", Transport: "wss",
		Listen: fmt.Sprintf("127.0.0.1:%d", port),
		Token:  psk, Carriers: 2, BindAddr: "127.0.0.1",
		Forwards: []string{fmt.Sprintf("%d", freePort(t))},
	}
	cfg.applyDefaults()
	p := newPool(cfg)
	if err := p.start(); err != nil {
		t.Fatal(err)
	}
	defer p.close()

	cl := &http.Client{
		Timeout: 5 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		},
	}
	base := fmt.Sprintf("https://127.0.0.1:%d", port)

	resp, err := cl.Get(base + "/")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Errorf("the front page answered %d, want 200", resp.StatusCode)
	}
	if !contains(string(body), "Welcome to nginx!") {
		t.Errorf("the front page is not the one nginx ships:\n%s", body)
	}
	srv := resp.Header.Get("Server")
	if !contains(srv, "nginx/") {
		t.Errorf("Server header is %q, want an nginx version", srv)
	}
	for _, h := range []string{"Date", "Content-Type", "Last-Modified", "ETag", "Accept-Ranges"} {
		if resp.Header.Get(h) == "" {
			t.Errorf("a real file would send %s", h)
		}
	}

	// anything else is an ordinary 404, not a hint that something is here
	resp2, err := cl.Get(base + "/admin")
	if err != nil {
		t.Fatal(err)
	}
	body2, _ := io.ReadAll(resp2.Body)
	resp2.Body.Close()
	if resp2.StatusCode != 404 {
		t.Errorf("an unknown path answered %d, want 404", resp2.StatusCode)
	}
	if !contains(string(body2), "404 Not Found") || !contains(string(body2), "nginx/") {
		t.Errorf("the 404 is not nginx's:\n%s", body2)
	}

	// and the carrier path is not guessable: it comes from the token
	if wsPathFor(cfg) == "/" || len(wsPathFor(cfg)) < 8 {
		t.Errorf("the carrier path is too short to be unguessable: %q", wsPathFor(cfg))
	}
	other := &Config{Token: "a different secret entirely"}
	if wsPathFor(cfg) == wsPathFor(other) {
		t.Error("two tunnels with different tokens share a carrier path")
	}
}

// Two servers must not answer identically, or one scan finds the whole fleet.
func TestTwoServersDoNotAnswerAlike(t *testing.T) {
	a := newDecoyIdentity([]byte("one token"))
	b := newDecoyIdentity([]byte("another token"))
	if a.version == b.version && a.modTime.Equal(b.modTime) && a.etag == b.etag {
		t.Error("two tokens produced the same decoy identity")
	}
	// and one server must answer the same after a restart
	c := newDecoyIdentity([]byte("one token"))
	if a.version != c.version || !a.modTime.Equal(c.modTime) || a.etag != c.etag {
		t.Error("the same token produced a different identity, so a restart is visible")
	}
}

func contains(h, n string) bool {
	return len(h) >= len(n) && (func() bool {
		for i := 0; i+len(n) <= len(h); i++ {
			if h[i:i+len(n)] == n {
				return true
			}
		}
		return false
	})()
}

// The name presented and the address dialled are two different things.
//
// A CDN routes on the name in the SNI and the Host header, and never looks at
// the address the packets arrived on. Keeping them separate is what lets a
// carrier go to an edge - somewhere cheap or unfiltered from where the client
// sits - and still arrive at the right origin, without the address it dialled
// ever naming the server.
func TestWSHostIsNotTheAddress(t *testing.T) {
	for _, c := range []struct {
		name    string
		cfg     Config
		want    string
		explain string
	}{
		{
			name:    "an edge dialled, the domain presented",
			cfg:     Config{Connect: "speedtest.net:8443", WSHost: "tunnel.example.com"},
			want:    "tunnel.example.com",
			explain: "the CDN has to see the domain or it cannot route the carrier",
		},
		{
			name:    "no domain falls back to the address",
			cfg:     Config{Connect: "203.0.113.9:8443"},
			want:    "203.0.113.9",
			explain: "a tunnel that goes straight to the server has only the address",
		},
		{
			name:    "the accepting end names itself for its certificate",
			cfg:     Config{Listen: "0.0.0.0:8443", WSHost: "tunnel.example.com"},
			want:    "tunnel.example.com",
			explain: "otherwise the self-signed certificate is issued for 0.0.0.0",
		},
	} {
		t.Run(c.name, func(t *testing.T) {
			if got := wsHostFor(&c.cfg); got != c.want {
				t.Fatalf("host = %q, want %q - %s", got, c.want, c.explain)
			}
		})
	}
}

// Go omits SNI entirely for an IP literal, so a tunnel pointed at a bare
// address arrives at a CDN with nothing to route on. That is not a bug to fix
// here - it is the reason the domain has to travel separately.
func TestWSHostSurvivesAPortlessTarget(t *testing.T) {
	cfg := Config{Connect: "tunnel.example.com", WSHost: ""}
	if got := wsHostFor(&cfg); got != "tunnel.example.com" {
		t.Fatalf("host = %q, want the bare name back", got)
	}
}

// ---------------------------------------------------------------------------
// framing
//
// The fault these are here for: a message that arrives in pieces. The reader
// had no case for a continuation frame, so everything after the first piece
// fell past the switch and was dropped - no error, no log, the carrier still
// counted as up. We never fragment, but anything that reassembles and re-splits
// a stream does, and is entitled to.
// ---------------------------------------------------------------------------

// wsFrameBytes builds one frame the way a conformant peer would.
func wsFrameBytes(fin bool, op byte, payload []byte, masked bool) []byte {
	var b []byte
	first := op
	if fin {
		first |= 0x80
	}
	b = append(b, first)
	n := len(payload)
	var l byte
	switch {
	case n < 126:
		l = byte(n)
	case n < 1<<16:
		l = 126
	default:
		l = 127
	}
	if masked {
		l |= 0x80
	}
	b = append(b, l)
	switch {
	case n >= 1<<16:
		var e [8]byte
		binary.BigEndian.PutUint64(e[:], uint64(n))
		b = append(b, e[:]...)
	case n >= 126:
		var e [2]byte
		binary.BigEndian.PutUint16(e[:], uint16(n))
		b = append(b, e[:]...)
	}
	if !masked {
		return append(b, payload...)
	}
	key := [4]byte{0x11, 0x22, 0x33, 0x44}
	b = append(b, key[:]...)
	for i := 0; i < n; i++ {
		b = append(b, payload[i]^key[i&3])
	}
	return b
}

// serverReading hands back a server-side wsConn fed by the bytes given, the
// way a client that masks would have sent them.
func serverReading(t *testing.T, wire []byte) *wsConn {
	t.Helper()
	a, b := net.Pipe()
	go func() {
		b.Write(wire)
		// leave it open: the reader must not need EOF to make progress
	}()
	t.Cleanup(func() { a.Close(); b.Close() })
	return newWSConn(a, nil, false)
}

func TestWSReassemblesAFragmentedMessage(t *testing.T) {
	// "hello world" split three ways, which is what a proxy does to a stream
	// it reassembled and then wrote out again.
	var wire []byte
	wire = append(wire, wsFrameBytes(false, wsOpBinary, []byte("hello "), true)...)
	wire = append(wire, wsFrameBytes(false, wsOpCont, []byte("world"), true)...)
	wire = append(wire, wsFrameBytes(true, wsOpCont, []byte("!"), true)...)

	w := serverReading(t, wire)
	got := make([]byte, 0, 12)
	buf := make([]byte, 4)
	for len(got) < 12 {
		w.SetReadDeadline(time.Now().Add(3 * time.Second))
		n, err := w.Read(buf)
		if err != nil {
			t.Fatalf("read: %v - got %q of %q", err, got, "hello world!")
		}
		got = append(got, buf[:n]...)
	}
	if string(got) != "hello world!" {
		t.Fatalf("got %q, want %q - the pieces after the first were dropped", got, "hello world!")
	}
}

func TestWSAnswersAPingBetweenFragments(t *testing.T) {
	// A ping is allowed to arrive in the middle of a message and must not
	// disturb it. It also must not overwrite the payload being handed up.
	var wire []byte
	wire = append(wire, wsFrameBytes(false, wsOpBinary, []byte("abc"), true)...)
	wire = append(wire, wsFrameBytes(true, wsOpPing, []byte("ping"), true)...)
	wire = append(wire, wsFrameBytes(true, wsOpCont, []byte("def"), true)...)

	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()
	w := newWSConn(a, nil, false)

	done := make(chan string, 1)
	go func() {
		got := make([]byte, 0, 6)
		buf := make([]byte, 64)
		for len(got) < 6 {
			a.SetReadDeadline(time.Now().Add(3 * time.Second))
			n, err := w.Read(buf)
			if err != nil {
				done <- "read failed: " + err.Error()
				return
			}
			got = append(got, buf[:n]...)
		}
		done <- string(got)
	}()

	b.SetDeadline(time.Now().Add(3 * time.Second))
	if _, err := b.Write(wire); err != nil {
		t.Fatalf("write: %v", err)
	}
	// the pong comes back on the same conn; drain it so the writer is not stuck
	go io.Copy(io.Discard, b)

	select {
	case got := <-done:
		if got != "abcdef" {
			t.Fatalf("got %q, want %q", got, "abcdef")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the reader never finished the message")
	}
}

func TestWSRefusesWhatItCannotParse(t *testing.T) {
	big := make([]byte, 200)
	for _, c := range []struct {
		name string
		wire []byte
		why  string
	}{
		{
			name: "a continuation with nothing to continue",
			wire: wsFrameBytes(true, wsOpCont, []byte("x"), true),
			why:  "there was no message open, so this is not our stream",
		},
		{
			name: "an opcode we do not speak",
			wire: wsFrameBytes(true, 0x3, []byte("x"), true),
			why:  "skipping it reads the next frame out of the middle of this one",
		},
		{
			name: "a control frame that was fragmented",
			wire: wsFrameBytes(false, wsOpPing, []byte("x"), true),
			why:  "RFC 6455 5.5 forbids it",
		},
		{
			name: "an oversized control frame",
			wire: wsFrameBytes(true, wsOpPing, big, true),
			why:  "a control frame carries at most 125 bytes",
		},
		{
			name: "an unmasked frame from a client",
			wire: wsFrameBytes(true, wsOpBinary, []byte("x"), false),
			why:  "RFC 6455 5.1: a client masks everything it sends",
		},
		{
			name: "reserved bits with no extension agreed",
			wire: func() []byte {
				f := wsFrameBytes(true, wsOpBinary, []byte("x"), true)
				f[0] |= 0x40 // RSV1
				return f
			}(),
			why: "the frame is not shaped the way we are about to read it",
		},
	} {
		t.Run(c.name, func(t *testing.T) {
			w := serverReading(t, c.wire)
			w.SetReadDeadline(time.Now().Add(3 * time.Second))
			if _, err := w.Read(make([]byte, 64)); err == nil {
				t.Fatalf("accepted it - %s", c.why)
			}
		})
	}
}

// A whole message still arrives whole, and a big one still goes out as one
// frame with the 64-bit length.
func TestWSCarriesALargeMessageIntact(t *testing.T) {
	payload := make([]byte, 100*1024)
	for i := range payload {
		payload[i] = byte(i * 7)
	}
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()
	client := newWSConn(a, nil, true)
	server := newWSConn(b, nil, false)

	go func() {
		a.SetWriteDeadline(time.Now().Add(5 * time.Second))
		client.Write(payload)
	}()

	got := make([]byte, 0, len(payload))
	buf := make([]byte, 16*1024)
	for len(got) < len(payload) {
		b.SetReadDeadline(time.Now().Add(5 * time.Second))
		n, err := server.Read(buf)
		if err != nil {
			t.Fatalf("read after %d of %d: %v", len(got), len(payload), err)
		}
		got = append(got, buf[:n]...)
	}
	if !bytes.Equal(got, payload) {
		t.Fatal("the payload came back different")
	}
}

// ---------------------------------------------------------------------------
// the socket under the framing
//
// tuneSocket type-asserted *net.TCPConn. A ws carrier is framing over a
// socket and a wss carrier is framing over TLS over a socket, so it matched
// neither and returned - leaving every WebSocket carrier with Nagle on, no
// keepalive, and the tuning's socket buffers silently ignored.
// ---------------------------------------------------------------------------

func TestBaseTCPReachesThroughTheFraming(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			defer c.Close()
		}
	}()
	raw, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()

	if baseTCP(raw) == nil {
		t.Fatal("a bare socket is not reachable")
	}
	if baseTCP(newWSConn(raw, nil, true)) == nil {
		t.Fatal("a ws carrier's socket is not reachable - Nagle stays on")
	}
	// wss is the same conn with TLS between, and *tls.Conn answers NetConn.
	tlsOver := tls.Client(raw, &tls.Config{InsecureSkipVerify: true})
	if baseTCP(newWSConn(tlsOver, nil, true)) == nil {
		t.Fatal("a wss carrier's socket is not reachable")
	}
	// and something with no socket under it at all is simply left alone
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()
	if baseTCP(a) != nil {
		t.Fatal("a pipe is not a socket")
	}
}

// ---------------------------------------------------------------------------
// the handshake has to end
// ---------------------------------------------------------------------------

// A server that accepts the connection and then says nothing used to park the
// dialling goroutine for good. Every carrier stopped in the same place, the
// tunnel showed "0 of 16", and nothing was logged - which is what a CDN does
// on a port it does not proxy.
func TestWSDialGivesUpOnASilentServer(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	accepted := make(chan net.Conn, 1)
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		accepted <- c // hold it open and answer nothing at all
	}()

	done := make(chan error, 1)
	go func() {
		_, err := wsDial(ln.Addr().String(), "example.com", "/x", false, 2*time.Second)
		done <- err
	}()

	select {
	case err := <-done:
		if err == nil {
			t.Fatal("it claimed to have upgraded against a server that said nothing")
		}
		if !strings.Contains(err.Error(), "no answer to the upgrade") {
			t.Fatalf("gave up, but not clearly: %v", err)
		}
	case <-time.After(8 * time.Second):
		t.Fatal("it never gave up - this is the carrier that parks forever")
	}
	if c := <-accepted; c != nil {
		c.Close()
	}
}

// ---------------------------------------------------------------------------
// masking
// ---------------------------------------------------------------------------

func TestWSMaskMatchesTheObviousLoop(t *testing.T) {
	key := [4]byte{0xA1, 0xB2, 0xC3, 0xD4}
	// lengths either side of the eight-byte step, so the tail is covered
	for _, n := range []int{0, 1, 7, 8, 9, 15, 16, 17, 4096, 131072 + 3} {
		src := make([]byte, n)
		for i := range src {
			src[i] = byte(i*31 + 7)
		}
		want := make([]byte, n)
		for i := range src {
			want[i] = src[i] ^ key[i&3]
		}
		got := make([]byte, n)
		wsMask(got, src, key)
		if !bytes.Equal(got, want) {
			t.Fatalf("n=%d: the fast path does not agree with the plain one", n)
		}
		// and in place, which is how the reader unmasks
		inplace := append([]byte(nil), src...)
		wsMask(inplace, inplace, key)
		if !bytes.Equal(inplace, want) {
			t.Fatalf("n=%d: in place gives something else", n)
		}
	}
}

// ---------------------------------------------------------------------------
// a pong under a stale deadline
// ---------------------------------------------------------------------------

// The braid sets a write deadline before its own writes. On an idle carrier
// that moment is long past, and a pong sent under it failed instantly with
// i/o timeout - so a peer that pinged heard nothing and hung up, which looked
// from here like the far end going away on its own.
func TestWSPongSurvivesAStaleWriteDeadline(t *testing.T) {
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()
	server := newWSConn(a, nil, false)

	// what the braid left behind: a deadline that expired a minute ago
	server.SetWriteDeadline(time.Now().Add(-time.Minute))

	go func() {
		b.SetWriteDeadline(time.Now().Add(3 * time.Second))
		b.Write(wsFrameBytes(true, wsOpPing, []byte("are you there"), true))
	}()

	got := make(chan []byte, 1)
	go func() {
		b.SetReadDeadline(time.Now().Add(3 * time.Second))
		buf := make([]byte, 64)
		n, err := b.Read(buf)
		if err != nil {
			got <- nil
			return
		}
		got <- buf[:n]
	}()

	// the reader is what answers the ping
	go func() {
		a.SetReadDeadline(time.Now().Add(3 * time.Second))
		server.Read(make([]byte, 64))
	}()

	select {
	case f := <-got:
		if f == nil {
			t.Fatal("no pong came back - the stale deadline killed it")
		}
		if f[0]&0x0f != wsOpPong {
			t.Fatalf("answered with opcode %#x, not a pong", f[0]&0x0f)
		}
	case <-time.After(6 * time.Second):
		t.Fatal("no pong came back at all")
	}
}

// A 100 KiB write used to leave as one frame with an eight-byte length field.
// That field is rare in real WebSocket traffic, and every piece of it has to
// survive whatever is on the path. Ordinary-sized frames now, and the reader
// still sees one unbroken stream.
func TestWSSendsOrdinarySizedFrames(t *testing.T) {
	payload := make([]byte, 100*1024)
	for i := range payload {
		payload[i] = byte(i * 13)
	}
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()
	client := newWSConn(a, nil, true)

	frames := make(chan []int, 1)
	go func() {
		// read the raw wire and record each frame's declared length
		var sizes []int
		br := bufioNewReader(b)
		for total := 0; total < len(payload); {
			var h [2]byte
			if _, err := io.ReadFull(br, h[:]); err != nil {
				break
			}
			n := int(h[1] & 0x7f)
			switch n {
			case 126:
				var e [2]byte
				io.ReadFull(br, e[:])
				n = int(binary.BigEndian.Uint16(e[:]))
			case 127:
				var e [8]byte
				io.ReadFull(br, e[:])
				n = int(binary.BigEndian.Uint64(e[:]))
				sizes = append(sizes, -1) // an eight-byte length: flag it
			}
			if h[1]&0x80 != 0 {
				var k [4]byte
				io.ReadFull(br, k[:])
			}
			io.CopyN(io.Discard, br, int64(n))
			sizes = append(sizes, n)
			total += n
		}
		frames <- sizes
	}()

	a.SetWriteDeadline(time.Now().Add(5 * time.Second))
	if _, err := client.Write(payload); err != nil {
		t.Fatalf("write: %v", err)
	}

	select {
	case sizes := <-frames:
		total := 0
		for _, n := range sizes {
			if n == -1 {
				t.Fatal("a frame used the eight-byte length field")
			}
			if n > wsMaxSend {
				t.Fatalf("a frame carried %d bytes, over the %d cap", n, wsMaxSend)
			}
			total += n
		}
		if total != len(payload) {
			t.Fatalf("the frames carried %d bytes of %d", total, len(payload))
		}
		if len(sizes) < 2 {
			t.Fatal("it did not split at all")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("nothing arrived")
	}
}

// The handshake claimed to be Chrome and then sent five headers in an order no
// browser uses. Header set and order are both fingerprints.
func TestWSHandshakeLooksLikeABrowser(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	got := make(chan string, 1)
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		c.SetReadDeadline(time.Now().Add(3 * time.Second))
		buf := make([]byte, 4096)
		n, _ := c.Read(buf)
		got <- string(buf[:n])
	}()
	go wsDial(ln.Addr().String(), "example.com", "/x", false, 2*time.Second)

	select {
	case req := <-got:
		for _, h := range []string{
			"Host: example.com", "Connection: Upgrade", "Pragma: no-cache",
			"Cache-Control: no-cache", "User-Agent: Mozilla/5.0",
			"Upgrade: websocket", "Origin: http://example.com",
			"Sec-WebSocket-Version: 13", "Accept-Encoding:",
			"Accept-Language:", "Sec-WebSocket-Key:",
		} {
			if !strings.Contains(req, h) {
				t.Errorf("a browser sends %q and this does not", h)
			}
		}
		// Extensions are deliberately absent: negotiating one means RSV1 on
		// every frame, which this does not implement.
		if strings.Contains(req, "Sec-WebSocket-Extensions") {
			t.Error("it offered an extension it cannot honour")
		}
		// and in Chrome's order, because order is a fingerprint too
		if strings.Index(req, "Pragma:") > strings.Index(req, "Upgrade: websocket") {
			t.Error("the headers are not in the order a browser sends them")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("no request arrived")
	}
}

func bufioNewReader(c net.Conn) *bufio.Reader { return bufio.NewReaderSize(c, 32*1024) }

// A control frame borrows the write deadline. The braid sets its own deadline
// before it asks for the write lock, so the borrow has to be given back
// without stepping on a fresher one - or the braid's very next write dies of a
// timeout that never came round, and the carrier goes with it.
func TestWSPongDoesNotRestoreADeadlineTheBraidReplaced(t *testing.T) {
	setLogLevel("error")

	held := make(chan struct{})
	release := make(chan struct{})
	rec := &deadlineConn{onWrite: func() {
		select {
		case held <- struct{}{}:
		default:
		}
		<-release
	}}
	w := newWSConn(rec, bufio.NewReader(bytes.NewReader(nil)), false)

	stale := time.Now().Add(-time.Hour)
	fresh := time.Now().Add(time.Minute)

	// What the braid last asked for, long expired: an idle carrier.
	if err := w.SetWriteDeadline(stale); err != nil {
		t.Fatal(err)
	}

	go func() { w.writeControl(wsOpPong, []byte("x")) }()
	<-held // the pong is on the wire, holding the deadline

	// The braid wakes with something to send and sets its own deadline first,
	// exactly as writeLoop does.
	done := make(chan error, 1)
	go func() { done <- w.SetWriteDeadline(fresh) }()

	// Whether that call goes through now or waits for the pong to finish is
	// the whole difference: waiting is the fix. Give it the chance to go
	// through, so that if it does, the pong still has its restore to do.
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
		done = nil
	case <-time.After(250 * time.Millisecond):
	}

	close(release)
	if done != nil {
		if err := <-done; err != nil {
			t.Fatal(err)
		}
	}
	// Give the pong's restore a moment to land if it is going to.
	time.Sleep(100 * time.Millisecond)

	if got := rec.lastWrite(); !got.Equal(fresh) {
		t.Fatalf("the socket was left with %v, not the deadline the braid just set (%v);"+
			" the braid's next write would fail on the spot", got, fresh)
	}
}

// deadlineConn is a net.Conn that records the write deadline it was last given
// and lets a test hold a write open.
type deadlineConn struct {
	net.Conn
	mu      sync.Mutex
	wdl     time.Time
	onWrite func()
}

func (c *deadlineConn) Write(p []byte) (int, error) {
	if c.onWrite != nil {
		c.onWrite()
	}
	return len(p), nil
}
func (c *deadlineConn) Read(p []byte) (int, error) { return 0, io.EOF }
func (c *deadlineConn) Close() error               { return nil }
func (c *deadlineConn) SetWriteDeadline(t time.Time) error {
	c.mu.Lock()
	c.wdl = t
	c.mu.Unlock()
	return nil
}
func (c *deadlineConn) SetDeadline(t time.Time) error { return c.SetWriteDeadline(t) }
func (c *deadlineConn) lastWrite() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.wdl
}

// chopper copies a<->b but breaks every write into small pieces, the way a
// real path with a small MSS does. Local tests deliver whole writes, which is
// exactly the case a framing bug survives.
func chopProxy(t *testing.T, target string) string {
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
			u, err := net.Dial("tcp", target)
			if err != nil {
				c.Close()
				continue
			}
			go chop(c, u)
			go chop(u, c)
		}
	}()
	return ln.Addr().String()
}

func chop(src, dst net.Conn) {
	defer src.Close()
	defer dst.Close()
	r := rand.New(rand.NewSource(time.Now().UnixNano()))
	buf := make([]byte, 64*1024)
	for {
		n, err := src.Read(buf)
		for off := 0; off < n; {
			k := 1 + r.Intn(700)
			if off+k > n {
				k = n - off
			}
			if _, e := dst.Write(buf[off : off+k]); e != nil {
				return
			}
			off += k
		}
		if err != nil {
			return
		}
	}
}

// prng stream both ends can generate and verify.
func streamAt(seed int64, off int64, n int) []byte {
	r := rand.New(rand.NewSource(seed))
	b := make([]byte, off+int64(n))
	r.Read(b)
	return b[off:]
}

// Two wsConns over a real socket, both directions at once, random sizes,
// through a path that chops every write. If the framing loses or duplicates a
// byte anywhere, the check fails at the first one.
func TestWSFullDuplexUnderChopping(t *testing.T) {
	setLogLevel("error")

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}

	addr := chopProxy(t, ln.Addr().String())

	psk := testPSK(t)
	cfg := &Config{Role: "server", Mode: "forward", Transport: "ws",
		Listen: ln.Addr().String(), Token: psk, Carriers: 1}
	cfg.applyDefaults()
	tr := &wsTransport{cfg: cfg, path: wsPathFor(cfg), host: "example.com",
		inbound: make(chan net.Conn, 8), done: make(chan struct{}), ln: ln}
	go tr.serve()

	const total = 3 << 20

	srvDone := make(chan error, 1)
	go func() {
		c, err := tr.Accept()
		if err != nil {
			srvDone <- err
			return
		}
		srvDone <- pump(c, 2, 1, total)
	}()

	c, err := wsDial(addr, "example.com", tr.path, false, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if err := pump(c, 1, 2, total); err != nil {
		t.Fatalf("client: %v", err)
	}
	if err := <-srvDone; err != nil {
		t.Fatalf("server: %v", err)
	}
}

// pump writes stream `send` and verifies stream `recv`, concurrently.
func pump(c net.Conn, send, recv int64, total int) error {
	var wg sync.WaitGroup
	var werr, rerr error
	wg.Add(2)
	go func() {
		defer wg.Done()
		r := rand.New(rand.NewSource(send * 977))
		want := streamAt(send, 0, total)
		for off := 0; off < total; {
			k := 1 + r.Intn(70000)
			if off+k > total {
				k = total - off
			}
			if _, err := c.Write(want[off : off+k]); err != nil {
				werr = err
				return
			}
			off += k
		}
	}()
	go func() {
		defer wg.Done()
		want := streamAt(recv, 0, total)
		got := make([]byte, total)
		if _, err := io.ReadFull(c, got); err != nil {
			rerr = err
			return
		}
		if !bytes.Equal(got, want) {
			for i := range got {
				if got[i] != want[i] {
					rerr = fmt.Errorf("stream diverged at byte %d of %d: got %d want %d", i, total, got[i], want[i])
					return
				}
			}
		}
	}()
	wg.Wait()
	if werr != nil {
		return werr
	}
	return rerr
}
