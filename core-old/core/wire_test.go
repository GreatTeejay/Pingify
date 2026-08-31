package main

import (
	"bytes"
	"crypto/rand"
	"fmt"
	"io"
	"net"
	"testing"
	"time"
)

// Off means the v2.1.1 wire, all of it. The frame lengths were already going
// out in the clear; the handshake was not, and half of one shape and half of
// another had never run anywhere.
func TestPlainWireSpeaksTheOldHandshake(t *testing.T) {
	setLogLevel("error")

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	got := make(chan []byte, 1)
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		b := make([]byte, 4)
		c.SetReadDeadline(time.Now().Add(3 * time.Second))
		io.ReadFull(c, b)
		got <- b
	}()

	cfg := &Config{Role: "client", Token: testPSK(t)}
	cfg.applyDefaults()
	c, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	go clientHandshakeFor(cfg, c, 0)

	select {
	case first := <-got:
		if !bytes.Equal(first, []byte(hs2Magic)) {
			t.Errorf("the plain wire opened with %q, want %q - this is the shape "+
				"that was observed to work on a real path", first, hs2Magic)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("nothing was sent")
	}
}

// And on means v3, which opens with nothing recognisable at all.
func TestShapedWireOpensWithNothingConstant(t *testing.T) {
	setLogLevel("error")
	on := true

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	seen := make(chan []byte, 8)
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				b := make([]byte, 4)
				c.SetReadDeadline(time.Now().Add(3 * time.Second))
				if _, err := io.ReadFull(c, b); err == nil {
					seen <- b
				}
			}(c)
		}
	}()

	cfg := &Config{Role: "client", Token: testPSK(t), Obfuscate: &on}
	cfg.applyDefaults()
	for i := 0; i < 6; i++ {
		c, err := net.Dial("tcp", ln.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		go clientHandshakeFor(cfg, c, i)
		defer c.Close()
	}

	var first [][]byte
	for i := 0; i < 6; i++ {
		select {
		case b := <-seen:
			first = append(first, b)
		case <-time.After(3 * time.Second):
			t.Fatal("not every handshake arrived")
		}
	}
	for i := 0; i < 4; i++ {
		same := true
		for _, b := range first[1:] {
			if b[i] != first[0][i] {
				same = false
				break
			}
		}
		if same {
			t.Errorf("byte %d is identical across every shaped handshake (0x%02x)", i, first[0][i])
		}
	}
}

// The two shapes must not half-work against each other. A server on one and a
// client on the other has to fail the handshake outright, so the log says the
// two ends disagree instead of the tunnel coming up and carrying nothing.
func TestTheTwoWiresRefuseEachOther(t *testing.T) {
	setLogLevel("error")
	on, off := true, false
	psk := testPSK(t)

	for _, tc := range []struct{ server, client *bool }{
		{&on, &off},
		{&off, &on},
	} {
		port := freePort(t)
		srv := &Config{
			Role: "server", Mode: "forward",
			Listen: fmt.Sprintf("127.0.0.1:%d", port),
			Token:  psk, Carriers: 1, Obfuscate: tc.server,
			BindAddr: "127.0.0.1",
			Forwards: []string{fmt.Sprint(freePort(t))},
		}
		cli := &Config{
			Role: "client", Mode: "forward",
			Connect: fmt.Sprintf("127.0.0.1:%d", port),
			Token:   psk, Carriers: 1, Obfuscate: tc.client,
		}
		for _, c := range []*Config{srv, cli} {
			c.applyDefaults()
			if err := c.validate(); err != nil {
				t.Fatal(err)
			}
		}
		sp := newPool(srv)
		if err := sp.start(); err != nil {
			t.Fatal(err)
		}
		cp := newPool(cli)
		if err := cp.start(); err != nil {
			t.Fatal(err)
		}

		deadline := time.Now().Add(2 * time.Second)
		for time.Now().Before(deadline) {
			if up, _, _, _ := sp.stats(); up > 0 {
				t.Errorf("shaped=%v and shaped=%v agreed on a carrier; they speak "+
					"different wires and must not", *tc.server, *tc.client)
				break
			}
			time.Sleep(50 * time.Millisecond)
		}
		cp.close()
		sp.close()
	}
	_ = rand.Reader
}
