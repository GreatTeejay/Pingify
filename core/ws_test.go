package main

import (
	"crypto/tls"
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
