package main

import (
	"bytes"
	"io"
	"net"
	"sync/atomic"
	"testing"
	"time"
)

func freeUDPAddress(t *testing.T) string {
	t.Helper()
	pc, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := pc.LocalAddr().String()
	_ = pc.Close()
	return addr
}

func testKCPConfig(listen, connect string) *Config {
	c := &Config{
		Role: "server", Mode: "forward", Transport: "kcp", Listen: listen, Connect: connect,
		Token: "kcp test secret", Carriers: 1, WindowKB: 512,
		SndBufKB: 2048, RcvBufKB: 2048, FECData: 10, FECParity: 3,
		PacketMTU: 1200, KCPInterval: 10,
	}
	if connect != "" {
		c.Role = "client"
	}
	return c
}

func TestKCPFECTransportCarriesAStream(t *testing.T) {
	addr := freeUDPAddress(t)
	server, err := newKCPTransport(testKCPConfig(addr, ""))
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	client, err := newKCPTransport(testKCPConfig("", addr))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	want := bytes.Repeat([]byte("pingify-kcp-fec/"), 8192)
	errCh := make(chan error, 1)
	go func() {
		conn, e := server.Accept()
		if e != nil {
			errCh <- e
			return
		}
		defer conn.Close()
		_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
		got := make([]byte, len(want))
		if _, e = io.ReadFull(conn, got); e == nil && !bytes.Equal(got, want) {
			e = io.ErrUnexpectedEOF
		}
		errCh <- e
	}()

	conn, err := client.Dial(0)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
	if _, err := conn.Write(want); err != nil {
		t.Fatal(err)
	}
	if err := <-errCh; err != nil {
		t.Fatal(err)
	}
}

// A one-packet loss in each FEC stripe should not interrupt the stream. KCP
// would eventually retransmit too; this end-to-end test additionally catches
// a wrong FEC shape, cipher mismatch, or proxy-unfriendly peer addressing.
func TestKCPFECStreamSurvivesPacketLoss(t *testing.T) {
	serverAddr := freeUDPAddress(t)
	server, err := newKCPTransport(testKCPConfig(serverAddr, ""))
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()

	proxy, err := net.ListenUDP("udp4", mustUDPAddr(t, "127.0.0.1:0"))
	if err != nil {
		t.Fatal(err)
	}
	defer proxy.Close()
	realServer := mustUDPAddr(t, serverAddr)
	var dropped atomic.Int32
	proxyDone := make(chan struct{})
	go func() {
		buf := make([]byte, 65536)
		var client *net.UDPAddr
		forwarded := 0
		for {
			n, from, e := proxy.ReadFromUDP(buf)
			if e != nil {
				close(proxyDone)
				return
			}
			to := realServer
			if from.IP.Equal(realServer.IP) && from.Port == realServer.Port {
				if client == nil {
					continue
				}
				to = client
			} else {
				client = from
				forwarded++
				if forwarded%13 == 1 {
					dropped.Add(1)
					continue
				}
			}
			_, _ = proxy.WriteToUDP(buf[:n], to)
		}
	}()

	client, err := newKCPTransport(testKCPConfig("", proxy.LocalAddr().String()))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	want := bytes.Repeat([]byte("loss-recovery/"), 4096)
	errCh := make(chan error, 1)
	go func() {
		c, e := server.Accept()
		if e != nil {
			errCh <- e
			return
		}
		defer c.Close()
		_ = c.SetDeadline(time.Now().Add(15 * time.Second))
		got := make([]byte, len(want))
		_, e = io.ReadFull(c, got)
		if e == nil && !bytes.Equal(got, want) {
			e = io.ErrUnexpectedEOF
		}
		errCh <- e
	}()
	c, err := client.Dial(0)
	if err != nil {
		t.Fatal(err)
	}
	_ = c.SetDeadline(time.Now().Add(15 * time.Second))
	defer c.Close()
	_, err = c.Write(want)
	if err != nil {
		t.Fatal(err)
	}
	if err := <-errCh; err != nil {
		t.Fatal(err)
	}
	if dropped.Load() == 0 {
		t.Fatal("the proxy did not exercise packet loss")
	}
	_ = proxy.Close()
	<-proxyDone
}

func mustUDPAddr(t *testing.T, s string) *net.UDPAddr {
	t.Helper()
	a, err := net.ResolveUDPAddr("udp4", s)
	if err != nil {
		t.Fatal(err)
	}
	return a
}
