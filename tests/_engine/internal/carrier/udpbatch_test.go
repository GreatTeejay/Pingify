//go:build linux && (amd64 || arm64)

package carrier

import (
	"net"
	"testing"
	"time"

	"pingify/internal/buf"
	"pingify/internal/config"
)

// sendmmsg on a UDP socket needs the port in the address, in network byte
// order. Got wrong, every datagram goes to a port nobody is listening on and
// the tunnel simply never comes up - with nothing in any log to say why. So
// this sends a batch across loopback and counts what arrives where it should.
func TestABatchOfUDPDatagramsArrivesAtThePortItWasSentTo(t *testing.T) {
	rx, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer rx.Close()
	tx, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Close()
	rc, err := tx.SyscallConn()
	if err != nil {
		t.Fatal(err)
	}

	port := rx.LocalAddr().(*net.UDPAddr).Port
	pkts := make([][]byte, 16)
	for i := range pkts {
		pkts[i] = []byte{byte(i), 'p', 'f', 'y'}
	}
	w := newBatchWriter()
	sent, err := w.writeTo(rc, pkts, [4]byte{127, 0, 0, 1}, port)
	if err != nil {
		t.Fatalf("sendmmsg: %v", err)
	}
	if sent != len(pkts) {
		t.Fatalf("the kernel took %d of %d", sent, len(pkts))
	}

	got := make(map[byte]bool)
	b := make([]byte, 64)
	_ = rx.SetReadDeadline(time.Now().Add(2 * time.Second))
	for len(got) < len(pkts) {
		n, _, err := rx.ReadFromUDP(b)
		if err != nil {
			break
		}
		if n == 4 && string(b[1:4]) == "pfy" {
			got[b[0]] = true
		}
	}
	if len(got) != len(pkts) {
		t.Fatalf("%d of %d datagrams arrived on port %d - the port in the batch is wrong",
			len(got), len(pkts), port)
	}
}

// A port whose two bytes differ is the case that catches a missing swap. A
// port like 257 (0x0101) reads the same both ways round and would pass
// whether the swap is there or not, so this one is chosen to be lopsided.
func TestThePortIsSwappedNotJustCopied(t *testing.T) {
	rx, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 0x7a31})
	if err != nil {
		t.Skipf("port 31281 is taken here: %v", err)
	}
	defer rx.Close()
	tx, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Close()
	rc, err := tx.SyscallConn()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := newBatchWriter().writeTo(rc, [][]byte{[]byte("x")}, [4]byte{127, 0, 0, 1}, 0x7a31); err != nil {
		t.Fatal(err)
	}
	_ = rx.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, _, err := rx.ReadFromUDP(make([]byte, 8)); err != nil {
		t.Fatalf("nothing arrived on 0x7a31: %v", err)
	}
}

// The batched read, end to end over loopback: what recvmmsg hands back is the
// datagrams that were sent, from the address they were sent from - and a
// datagram larger than the buffer comes back empty rather than torn.
func TestABatchedReadReturnsWhatWasSentAndRefusesWhatWasCut(t *testing.T) {
	rx, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer rx.Close()
	rc, err := rx.SyscallConn()
	if err != nil {
		t.Fatal(err)
	}
	tx, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Close()
	to := rx.LocalAddr().(*net.UDPAddr)

	const size = 64
	for i := 0; i < 8; i++ {
		if _, err := tx.WriteToUDP([]byte{byte(i), 'o', 'k'}, to); err != nil {
			t.Fatal(err)
		}
	}
	// One that does not fit: it must not be handed on as the part that did.
	if _, err := tx.WriteToUDP(make([]byte, size*3), to); err != nil {
		t.Fatal(err)
	}

	r := newBatchReader(size)
	got, cut := map[byte]bool{}, 0
	_ = rx.SetReadDeadline(time.Now().Add(2 * time.Second))
	for len(got) < 8 || cut < 1 {
		n, err := r.read(rc)
		if err != nil {
			t.Fatalf("read: %v (got %d whole, %d cut)", err, len(got), cut)
		}
		for i := 0; i < n; i++ {
			b, from := r.packet(i)
			if from != [4]byte{127, 0, 0, 1} {
				t.Fatalf("datagram %d came from %v", i, from)
			}
			switch {
			case len(b) == 0:
				cut++
			case len(b) == 3 && b[1] == 'o' && b[2] == 'k':
				got[b[0]] = true
			default:
				t.Fatalf("a datagram of %d bytes that is neither whole nor refused", len(b))
			}
		}
	}
}

// The whole batched send path, two carriers over loopback: sixteen frames
// handed to the batch sender arrive as sixteen bodies at the far end's
// OnPacket, sealed so that the framer there accepts them, with both ends'
// byte counters agreeing.
func TestABatchOfFramesCrossesToTheOtherCarrier(t *testing.T) {
	free, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	port := free.LocalAddr().(*net.UDPAddr).Port
	free.Close()

	mk := func(side string) *config.Config {
		cfg := &config.Config{Side: side, Mode: "tun", Token: "a token typed on both servers"}
		cfg.Transport.Type = "udp"
		cfg.Transport.Kharej = "127.0.0.1"
		cfg.Transport.Iran = "127.0.0.1"
		cfg.Transport.Port = port
		cfg.Transport.Dials = "iran"
		cfg.Transport.Keepalive = 10
		cfg.Tuning.SendBatch = 32
		cfg.Tuning.RcvBufKB, cfg.Tuning.SndBufKB = 256, 256
		cfg.Tuning.PaceSet, cfg.Tuning.Pace = true, false // no tc in a test
		return cfg
	}
	waiter, err := newUDPCarrier(mk(config.SideKharej))
	if err != nil {
		t.Fatal(err)
	}
	defer waiter.Close()
	dialer, err := newUDPCarrier(mk(config.SideIran))
	if err != nil {
		t.Fatal(err)
	}
	defer dialer.Close()
	if !dialer.batched {
		t.Skip("the batched sender is not in use here")
	}

	got := make(chan byte, 64)
	waiter.OnPacket(func(b []byte) {
		if len(b) == 5 && string(b[1:]) == "body" {
			got <- b[0]
		}
	})
	go waiter.Run()

	s := dialer.NewSender()
	if _, ok := s.(*udpBatchSender); !ok {
		t.Fatalf("the dialler's sender is a %T, not the batch sender", s)
	}
	var bps []*[]byte
	for i := 0; i < 16; i++ {
		bp := buf.Take(dialer.Headroom(), 5)
		copy((*bp)[dialer.Headroom():], []byte{byte(i), 'b', 'o', 'd', 'y'})
		bps = append(bps, bp)
	}
	s.Send(bps)

	seen := map[byte]bool{}
	deadline := time.After(3 * time.Second)
	for len(seen) < 16 {
		select {
		case b := <-got:
			seen[b] = true
		case <-deadline:
			t.Fatalf("%d of 16 bodies arrived", len(seen))
		}
	}
	_, tx, _, _, errs := dialer.Counters()
	rx, _, _, _, _ := waiter.Counters()
	if errs != 0 {
		t.Fatalf("%d send errors", errs)
	}
	if tx == 0 || rx != tx {
		t.Fatalf("the dialler sent %d bytes and the waiter counted %d", tx, rx)
	}
}
