package main

import (
	"bufio"
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"io"
	"math/rand"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// ---------------------------------------------------------------------------
// what a ws tunnel has to be
// ---------------------------------------------------------------------------

// One connection, and every stream on it. That is what mux means, and the
// point of the transport: twenty WebSockets from one address is the shape that
// gets a flow looked at.
func TestWSIsOneConnectionCarryingEverything(t *testing.T) {
	testWebSocketIsOneConnectionCarryingEverything(t, "ws")
}

func TestWSSIsOneTLSConnectionCarryingEverything(t *testing.T) {
	testWebSocketIsOneConnectionCarryingEverything(t, "wss")
}

func TestWebSocketDefaultsToOneWithoutInventingARequest(t *testing.T) {
	for _, transport := range []string{"ws", "wss"} {
		cfg := &Config{Transport: transport}
		cfg.applyDefaults()
		if cfg.Carriers != 1 || cfg.CarriersAsked != 0 {
			t.Errorf("%s default: carriers=%d asked=%d, want 1 and 0", transport, cfg.Carriers, cfg.CarriersAsked)
		}
	}
}

func testWebSocketIsOneConnectionCarryingEverything(t *testing.T, transport string) {
	setLogLevel("error")
	echo := echoServer(t)
	local := freePort(t)
	port := freePort(t)
	psk := testPSK(t)

	iran := &Config{
		Role: "server", Mode: "forward", Transport: transport,
		Listen: fmt.Sprintf("127.0.0.1:%d", port),
		Token:  psk, Carriers: 20, BindAddr: "127.0.0.1",
		Forwards: []string{fmt.Sprintf("%d=%d", local, echo)},
	}
	kharej := &Config{
		Role: "client", Mode: "forward", Transport: transport,
		Connect: fmt.Sprintf("127.0.0.1:%d", port),
		Token:   psk, Carriers: 20,
	}
	for _, c := range []*Config{iran, kharej} {
		c.applyDefaults()
		if err := c.validate(); err != nil {
			t.Fatal(err)
		}
		if c.Carriers != 1 {
			t.Fatalf("%s %s asked for 20 carriers and got %d - it must be one connection",
				c.Role, transport, c.Carriers)
		}
		if c.CarriersAsked != 20 {
			t.Errorf("%s forgot that 20 were asked for, so startup cannot say the setting was ignored", c.Role)
		}
	}

	ip, kp, cleanup := twoEnds(t, iran, kharej)
	defer cleanup()
	waitUp(t, ip, 1, 10*time.Second)

	// Many streams at once, all of them on the one connection.
	const streams = 40
	var wg sync.WaitGroup
	errs := make(chan error, streams)
	for i := 0; i < streams; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", local), 5*time.Second)
			if err != nil {
				errs <- err
				return
			}
			defer c.Close()
			c.SetDeadline(time.Now().Add(15 * time.Second))
			msg := bytes.Repeat([]byte{byte(i)}, 8*1024)
			go c.Write(msg)
			got := make([]byte, len(msg))
			if _, err := io.ReadFull(c, got); err != nil {
				errs <- fmt.Errorf("stream %d: %v", i, err)
				return
			}
			if !bytes.Equal(got, msg) {
				errs <- fmt.Errorf("stream %d came back changed", i)
			}
		}(i)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatalf("%v", err)
	}

	if up, _, _, _ := ip.stats(); up != 1 {
		t.Fatalf("iran reports %d connections, want exactly 1", up)
	}
	if up, _, _, _ := kp.stats(); up != 1 {
		t.Fatalf("kharej reports %d connections, want exactly 1", up)
	}
	t.Logf("%d streams and %d KiB through one %s connection", streams, streams*8, strings.ToUpper(transport))
}

func TestWriteFullRepairsShortSocketWrites(t *testing.T) {
	w := &shortWriter{max: 7}
	want := bytes.Repeat([]byte("websocket-frame"), 50)
	if err := writeFull(w, want); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(w.Bytes(), want) {
		t.Fatalf("short writes changed the frame: got %d bytes, want %d", w.Len(), len(want))
	}
}

// ---------------------------------------------------------------------------
// the framing
// ---------------------------------------------------------------------------

// Both directions at once, random sizes, through a path that breaks every
// write into pieces of one to seven hundred bytes. A local socket delivers
// whole writes, which is exactly the case a framing bug survives.
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
	tr := &wsTransport{cfg: cfg, path: wsPathFor(cfg), auth: "example.com",
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

	c, err := wsDial(addr, "example.com", tr.path, 5*time.Second)
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

// A message that arrives in pieces is one message. We never fragment, but a
// proxy is entitled to, and a reader with no case for opcode 0 drops
// everything after the first piece with no error anywhere.
func TestWSReassemblesAFragmentedMessage(t *testing.T) {
	a, b := net.Pipe()
	client := newWSConn(a, nil, true)
	server := newWSConn(b, nil, false)
	defer client.Close()
	defer server.Close()
	defer a.Close()
	defer b.Close()

	go func() {
		// "hello " then "world", as two frames of one message.
		client.wmu <- struct{}{}
		buf, _ := client.appendFragment(nil, wsOpBinary, []byte("hello "), false)
		buf, _ = client.appendFragment(buf, wsOpCont, []byte("world"), true)
		client.c.Write(buf)
		<-client.wmu
	}()

	got := make([]byte, 11)
	server.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := io.ReadFull(server, got); err != nil {
		t.Fatalf("reading a fragmented message: %v", err)
	}
	if string(got) != "hello world" {
		t.Fatalf("got %q, want %q - the pieces were not joined", got, "hello world")
	}
}

// A ping between two fragments is normal and must be answered without
// disturbing the message being assembled.
func TestWSAnswersAPingBetweenFragments(t *testing.T) {
	a, b := net.Pipe()
	client := newWSConn(a, nil, true)
	server := newWSConn(b, nil, false)
	defer client.Close()
	defer server.Close()
	defer a.Close()
	defer b.Close()

	// Somebody has to be reading the client end before the server answers:
	// net.Pipe is unbuffered, and a pong nobody reads is dropped rather than
	// waited on, which is the rule that keeps a reader from deadlocking.
	pong := make(chan wsFrame, 1)
	go func() {
		client.SetReadDeadline(time.Now().Add(5 * time.Second))
		if f, err := client.readFrame(); err == nil {
			pong <- f
		}
	}()

	go func() {
		client.wmu <- struct{}{}
		buf, _ := client.appendFragment(nil, wsOpBinary, []byte("half "), false)
		buf, _ = client.appendFrame(buf, wsOpPing, []byte("are you there"))
		buf, _ = client.appendFragment(buf, wsOpCont, []byte("done"), true)
		client.c.Write(buf)
		<-client.wmu
	}()

	got := make([]byte, 9)
	server.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := io.ReadFull(server, got); err != nil {
		t.Fatalf("reading across a ping: %v", err)
	}
	if string(got) != "half done" {
		t.Fatalf("got %q - the ping disturbed the message", got)
	}

	select {
	case f := <-pong:
		if f.op != wsOpPong || string(f.payload) != "are you there" {
			t.Fatalf("answered with op %#x %q", f.op, f.payload)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the ping was never answered")
	}
}

// What we cannot parse we refuse. Skipping an unknown opcode reads the next
// frame out of the middle of this one and calls the result payload.
func TestWSRefusesWhatItCannotParse(t *testing.T) {
	for _, c := range []struct {
		name  string
		frame []byte
		want  string
	}{
		{"a reserved bit with no extension agreed", []byte{0xC2, 0x80, 1, 2, 3, 4}, "reserved"},
		{"an opcode nobody speaks", []byte{0x83, 0x80, 1, 2, 3, 4}, "opcode"},
		{"a control frame arriving fragmented", []byte{0x09, 0x80, 1, 2, 3, 4}, "fragmented"},
	} {
		t.Run(c.name, func(t *testing.T) {
			a, b := net.Pipe()
			defer a.Close()
			defer b.Close()
			server := newWSConn(b, nil, false)
			defer server.Close()
			go a.Write(c.frame)
			server.SetReadDeadline(time.Now().Add(3 * time.Second))
			_, err := server.Read(make([]byte, 16))
			if err == nil {
				t.Fatal("it was accepted")
			}
			if !strings.Contains(err.Error(), c.want) {
				t.Fatalf("error %q does not say %q", err, c.want)
			}
		})
	}
}

// An unmasked frame from a client, or a masked one from a server, is a peer
// that is not speaking WebSocket to us - or a middlebox rewriting frames it
// should be passing through.
func TestWSHoldsBothEndsToTheMaskingRule(t *testing.T) {
	a, b := net.Pipe()
	server := newWSConn(b, nil, false)
	defer server.Close()
	defer a.Close()
	defer b.Close()

	// A "client" that does not mask.
	go a.Write([]byte{0x82, 0x03, 'a', 'b', 'c'})
	server.SetReadDeadline(time.Now().Add(3 * time.Second))
	_, err := server.Read(make([]byte, 8))
	if err == nil || !strings.Contains(err.Error(), "unmasked") {
		t.Fatalf("an unmasked client frame gave %v", err)
	}
}

func TestWSMaskMatchesTheObviousLoop(t *testing.T) {
	r := rand.New(rand.NewSource(7))
	for n := 0; n < 200; n++ {
		src := make([]byte, n)
		r.Read(src)
		var key [4]byte
		r.Read(key[:])

		want := make([]byte, n)
		for i := range src {
			want[i] = src[i] ^ key[i&3]
		}
		got := make([]byte, n)
		wsMask(got, src, key)
		if !bytes.Equal(got, want) {
			t.Fatalf("%d bytes masked wrong", n)
		}
		// And in place, which is how the reader uses it.
		inPlace := append([]byte(nil), src...)
		wsMask(inPlace, inPlace, key)
		if !bytes.Equal(inPlace, want) {
			t.Fatalf("%d bytes masked wrong in place", n)
		}
	}
}

// Our own records reach 128 KiB. They go out as ordinary-sized messages,
// because a frame with an eight-byte length field is rare enough in the wild
// that plenty of middleboxes have never carried one.
func TestWSSendsOrdinarySizedFrames(t *testing.T) {
	a, b := net.Pipe()
	client := newWSConn(a, nil, true)
	defer client.Close()
	defer a.Close()
	defer b.Close()

	big := make([]byte, 100*1024)
	go func() { client.Write(big) }()

	br := bufio.NewReader(b)
	read := 0
	frames := 0
	for read < len(big) {
		var h [2]byte
		if _, err := io.ReadFull(br, h[:]); err != nil {
			t.Fatalf("frame %d: %v", frames, err)
		}
		if h[0]&0x0f == wsOpCont {
			t.Fatal("a fragment went out; every piece should be a whole message")
		}
		n := int(h[1] & 0x7f)
		switch n {
		case 127:
			t.Fatal("a frame used the eight-byte length field")
		case 126:
			var e [2]byte
			io.ReadFull(br, e[:])
			n = int(binary.BigEndian.Uint16(e[:]))
		}
		var key [4]byte
		io.ReadFull(br, key[:])
		if _, err := io.CopyN(io.Discard, br, int64(n)); err != nil {
			t.Fatal(err)
		}
		if n > wsMaxSend {
			t.Fatalf("a frame carried %d bytes, over the %d we meant to send", n, wsMaxSend)
		}
		read += n
		frames++
	}
	if frames < 2 {
		t.Fatalf("100 KiB went out as %d frame(s); it should have been split", frames)
	}
}

// ---------------------------------------------------------------------------
// the keepalive
// ---------------------------------------------------------------------------

// A path that stops forwarding does not close anything: both ends keep a
// socket that is open, writable, and carrying nothing. With one connection
// holding the tunnel up, this end has to reach that conclusion itself.
func TestWSHangsUpOnAPathThatStopsAnswering(t *testing.T) {
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()

	// b never answers anything: a peer that has gone, or a path that has.
	go io.Copy(io.Discard, b)

	w := newWSConn(a, nil, true)
	defer w.Close()

	// Reach the conclusion by hand on the clock the field would take minutes
	// to reach: pretend the last pong was long ago.
	atomic.StoreInt64(&w.lastPong, time.Now().Add(-2*wsPongOverdue).UnixNano())

	// The keepalive ticks on its own interval, so drive one round here rather
	// than waiting a minute for it.
	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 0; i < 200; i++ {
			if since := time.Since(time.Unix(0, atomic.LoadInt64(&w.lastPong))); since > wsPongOverdue {
				w.Close()
				return
			}
			time.Sleep(5 * time.Millisecond)
		}
	}()
	<-done

	if _, err := w.Read(make([]byte, 4)); err == nil {
		t.Fatal("the connection is still readable after the path went silent")
	}
}

// A pong puts the clock back. Otherwise a healthy connection hangs itself up
// on its own keepalive.
func TestWSAPongKeepsTheConnection(t *testing.T) {
	a, b := net.Pipe()
	client := newWSConn(a, nil, true)
	server := newWSConn(b, nil, false)
	defer client.Close()
	defer server.Close()
	defer a.Close()
	defer b.Close()

	// Both readers running: net.Pipe is unbuffered, so a control frame has
	// nowhere to go until somebody is reading. This is also what the real
	// thing looks like - a reader on each end, always.
	go io.Copy(io.Discard, client)
	go io.Copy(io.Discard, server)

	atomic.StoreInt64(&client.lastPong, time.Now().Add(-time.Hour).UnixNano())
	if err := client.writeControl(wsOpPing, []byte("tock")); err != nil {
		t.Fatal(err)
	}

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if time.Since(time.Unix(0, atomic.LoadInt64(&client.lastPong))) < time.Minute {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("the server answered the ping and the clock was not put forward")
}

// A control frame borrows the write deadline. The layer above sets its own
// before it asks for the write lock, so the borrow has to be given back
// without stepping on a fresher one - or the next write dies of a timeout that
// never came round, and the connection goes with it.
func TestWSPongDoesNotRestoreADeadlineTheWriterReplaced(t *testing.T) {
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
	defer w.Close()

	stale := time.Now().Add(-time.Hour)
	fresh := time.Now().Add(time.Minute)

	if err := w.SetWriteDeadline(stale); err != nil {
		t.Fatal(err)
	}
	go func() { w.writeControl(wsOpPong, []byte("x")) }()
	<-held

	done := make(chan error, 1)
	go func() { done <- w.SetWriteDeadline(fresh) }()

	// Whether that call goes through now or waits for the pong to finish is
	// the whole difference: waiting is the fix.
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
	time.Sleep(100 * time.Millisecond)

	if got := rec.lastWrite(); !got.Equal(fresh) {
		t.Fatalf("the socket was left with %v, not the deadline just set (%v); the next write would fail on the spot",
			got, fresh)
	}
}

// ---------------------------------------------------------------------------
// the handshake
// ---------------------------------------------------------------------------

// The Host header and the name are two different questions. TLS wants a name
// with no port in it; HTTP wants the port whenever it is not the default, and
// a browser always sends it. A request to :9445 saying "Host: 1.2.3.4" is one
// no browser makes, on the one line a middlebox can check against the socket
// it arrived on.
func TestWSHostCarriesThePortAndTheNameDoesNot(t *testing.T) {
	for _, c := range []struct {
		name    string
		cfg     Config
		bare    string
		want    string
		explain string
	}{
		{
			name: "a direct address on an odd port", cfg: Config{Connect: "203.0.113.9:9445"},
			bare: "203.0.113.9", want: "203.0.113.9:9445",
			explain: "this is the case in the field, and it was sending the address alone",
		},
		{
			name: "port 80 is left off", cfg: Config{Connect: "203.0.113.9:80"},
			bare: "203.0.113.9", want: "203.0.113.9",
			explain: "a browser does not write the default port either",
		},
		{
			name: "an edge keeps the domain and the port",
			cfg:  Config{Connect: "speedtest.net:8080", WSHost: "tunnel.example.com"},
			bare: "tunnel.example.com", want: "tunnel.example.com:8080",
			explain: "the name is what a CDN routes on, the port is where we knocked",
		},
		{
			name: "a portless target has no port to carry", cfg: Config{Connect: "tunnel.example.com"},
			bare: "tunnel.example.com", want: "tunnel.example.com",
			explain: "nothing to add, and nothing to invent",
		},
		{
			name: "the accepting end names itself", cfg: Config{Listen: "0.0.0.0:9445", WSHost: "tunnel.example.com"},
			bare: "tunnel.example.com", want: "tunnel.example.com:9445",
			explain: "otherwise it names itself 0.0.0.0",
		},
	} {
		t.Run(c.name, func(t *testing.T) {
			if got := wsHostFor(&c.cfg); got != c.bare {
				t.Errorf("name = %q, want %q", got, c.bare)
			}
			if got := wsAuthority(&c.cfg); got != c.want {
				t.Fatalf("Host = %q, want %q - %s", got, c.want, c.explain)
			}
		})
	}
}

// And the request on the wire has to carry it, not only the helper. The rest
// of the line-up is checked here too: this is the part a middlebox reads.
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
		buf := make([]byte, 2048)
		n, _ := c.Read(buf)
		got <- string(buf[:n])
	}()

	addr := ln.Addr().String()
	host, port, _ := net.SplitHostPort(addr)
	authority := net.JoinHostPort(host, port)
	go wsDial(addr, authority, "/x", 2*time.Second)

	select {
	case req := <-got:
		for _, want := range []string{
			"GET /x HTTP/1.1\r\n",
			"Host: " + authority + "\r\n",
			"Connection: Upgrade\r\n",
			"Upgrade: websocket\r\n",
			"Origin: http://" + authority + "\r\n",
			"Sec-WebSocket-Version: 13\r\n",
			"Sec-WebSocket-Key: ",
		} {
			if !strings.Contains(req, want) {
				t.Errorf("the request is missing %q:\n%s", want, req)
			}
		}
		// Offering an extension invites a peer to negotiate it, and then every
		// frame carries RSV1 and means something this does not implement.
		if strings.Contains(req, "Sec-WebSocket-Extensions") {
			t.Error("an extension was offered; permessage-deflate would break the reader")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("no request arrived")
	}
}

func TestWebSocketUpgradeIsStrictRFC6455(t *testing.T) {
	const path = "/secret"
	valid := func() *http.Request {
		r := httptest.NewRequest(http.MethodGet, "http://example.com"+path, nil)
		r.Header.Set("Connection", "keep-alive, Upgrade")
		r.Header.Set("Upgrade", "websocket")
		r.Header.Set("Sec-WebSocket-Version", "13")
		r.Header.Set("Sec-WebSocket-Key", base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{1}, 16)))
		return r
	}
	if _, ok := wsUpgradeRequest(valid(), path); !ok {
		t.Fatal("a valid RFC 6455 upgrade was refused")
	}

	cases := map[string]func(*http.Request){
		"method":     func(r *http.Request) { r.Method = http.MethodPost },
		"http 1.0":   func(r *http.Request) { r.ProtoMinor = 0 },
		"path":       func(r *http.Request) { r.URL.Path = "/public" },
		"key":        func(r *http.Request) { r.Header.Set("Sec-WebSocket-Key", "not-a-key") },
		"upgrade":    func(r *http.Request) { r.Header.Set("Upgrade", "h2c") },
		"connection": func(r *http.Request) { r.Header.Set("Connection", "keep-alive") },
		"version":    func(r *http.Request) { r.Header.Set("Sec-WebSocket-Version", "12") },
	}
	for name, breakRequest := range cases {
		t.Run(name, func(t *testing.T) {
			r := valid()
			breakRequest(r)
			if _, ok := wsUpgradeRequest(r, path); ok {
				t.Fatal("a malformed upgrade was accepted")
			}
		})
	}
}

// A server that accepts the connection and then says nothing must not park the
// dialler for good - which is exactly what a CDN does on a port it does not
// proxy, and what left a tunnel at "0 of 1" with nothing in the log.
func TestWSDialGivesUpOnASilentServer(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		time.Sleep(10 * time.Second) // never answers
		c.Close()
	}()

	start := time.Now()
	_, err = wsDial(ln.Addr().String(), "example.com", "/x", 2*time.Second)
	if err == nil {
		t.Fatal("a server that said nothing was treated as an upgrade")
	}
	if took := time.Since(start); took > 5*time.Second {
		t.Fatalf("it waited %v on a silent server", took)
	}
}

// ---------------------------------------------------------------------------
// what everything else on this port sees
// ---------------------------------------------------------------------------

// A port that returns nothing to a probe is rare, and rare is what gets looked
// at. Everything that is not the tunnel gets a web server with nothing on it.
func TestAScannerFindsOnlyNginx(t *testing.T) {
	setLogLevel("error")
	port := freePort(t)
	psk := testPSK(t)
	cfg := &Config{
		Role: "server", Mode: "forward", Transport: "ws",
		Listen: fmt.Sprintf("127.0.0.1:%d", port), Token: psk, Carriers: 1,
		BindAddr: "127.0.0.1", Forwards: []string{fmt.Sprintf("%d=%d", freePort(t), freePort(t))},
	}
	cfg.applyDefaults()
	if err := cfg.validate(); err != nil {
		t.Fatal(err)
	}
	decoyPSK = cfg.key()
	tr, err := newWSTransport(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer tr.Close()

	base := fmt.Sprintf("http://127.0.0.1:%d", port)
	for _, c := range []struct {
		path string
		want int
		body string
	}{
		{"/", 200, "nginx"},
		{"/admin", 404, "404 Not Found"},
	} {
		resp, err := (&net.Dialer{}).Dial("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if err != nil {
			t.Fatal(err)
		}
		fmt.Fprintf(resp, "GET %s HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", c.path)
		body, _ := io.ReadAll(resp)
		resp.Close()
		if !strings.Contains(string(body), c.body) {
			t.Errorf("%s%s did not look like nginx:\n%s", base, c.path, body)
		}
		if !strings.Contains(string(body), "Server: nginx") {
			t.Errorf("%s%s did not name nginx in the headers", base, c.path)
		}
	}
}

func TestAWSSScannerFindsHTTPSNginx(t *testing.T) {
	setLogLevel("error")
	port := freePort(t)
	cfg := &Config{
		Role: "server", Mode: "forward", Transport: "wss",
		Listen: fmt.Sprintf("127.0.0.1:%d", port), Token: testPSK(t), Carriers: 8,
		BindAddr: "127.0.0.1", Forwards: []string{fmt.Sprintf("%d=%d", freePort(t), freePort(t))},
	}
	cfg.applyDefaults()
	if err := cfg.validate(); err != nil {
		t.Fatal(err)
	}
	tr, err := newWSSTransport(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer tr.Close()

	c, err := tls.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", port), &tls.Config{
		InsecureSkipVerify: true,
		MinVersion:         tls.VersionTLS12,
		NextProtos:         []string{"http/1.1"},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := fmt.Fprint(c, "GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n"); err != nil {
		t.Fatal(err)
	}
	body, err := io.ReadAll(c)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(body), "Server: nginx") || !strings.Contains(string(body), "Welcome to nginx") {
		t.Fatalf("WSS decoy did not look like HTTPS nginx:\n%s", body)
	}
}

func TestWSSGeneratedCertificateNamesItsHost(t *testing.T) {
	for _, host := range []string{"tunnel.example.com", "127.0.0.1"} {
		cert, err := selfSignedFor(host)
		if err != nil {
			t.Fatal(err)
		}
		leaf, err := x509.ParseCertificate(cert.Certificate[0])
		if err != nil {
			t.Fatal(err)
		}
		if err := leaf.VerifyHostname(host); err != nil {
			t.Errorf("certificate for %q: %v", host, err)
		}
	}
}

func TestWSSRefusesHalfACertificatePair(t *testing.T) {
	cfg := &Config{CertFile: "certificate.pem"}
	if _, err := wsCertificate(cfg); err == nil || !strings.Contains(err.Error(), "both") {
		t.Fatalf("one half of a certificate pair was not clearly refused: %v", err)
	}
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

type shortWriter struct {
	bytes.Buffer
	max int
}

func (w *shortWriter) Write(p []byte) (int, error) {
	if len(p) > w.max {
		p = p[:w.max]
	}
	return w.Buffer.Write(p)
}

// appendFragment is appendFrame with FIN under the caller's control. Only the
// tests need it: the transport never fragments, it only has to read one.
func (w *wsConn) appendFragment(b []byte, op byte, payload []byte, fin bool) ([]byte, error) {
	at := len(b) // the first byte of this frame's header
	b, err := w.appendFrame(b, op, payload)
	if err == nil && !fin {
		b[at] &^= 0x80
	}
	return b, err
}

func twoEnds(t *testing.T, iran, kharej *Config) (*pool, *pool, func()) {
	t.Helper()
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
	return ip, kp, func() { ifw.Close(); kf.Close(); kp.close(); ip.close() }
}

func waitUp(t *testing.T, p *pool, want int, d time.Duration) {
	t.Helper()
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if up, _, _, _ := p.stats(); up >= want {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	up, _, _, _ := p.stats()
	t.Fatalf("only %d of %d connections came up", up, want)
}

// chopProxy copies a<->b but breaks every write into small pieces, the way a
// real path with a small MSS does.
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

func streamAt(seed int64, off int64, n int) []byte {
	r := rand.New(rand.NewSource(seed))
	b := make([]byte, off+int64(n))
	r.Read(b)
	return b[off:]
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
		for i := range got {
			if got[i] != want[i] {
				rerr = fmt.Errorf("stream diverged at byte %d of %d", i, total)
				return
			}
		}
	}()
	wg.Wait()
	if werr != nil {
		return werr
	}
	return rerr
}

// deadlineConn records the write deadline it was last given and lets a test
// hold a write open.
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
