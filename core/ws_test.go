package main

import (
	"bytes"
	"crypto/tls"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/http"
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
