package main

import (
	"fmt"
	"net"
	"runtime"
	"sync"
	"testing"
	"time"
)

func TestPacketProfilesTradeLatencyForBatchThroughput(t *testing.T) {
	profiles := []struct {
		name  string
		batch int
	}{
		{"gaming", 32},
		{"latency", 64},
		{"balanced", 128},
		{"throughput", 256},
		{"extreme", 512},
	}
	last := 0
	for _, tc := range profiles {
		workers, batch := packetReadTuning(tc.name)
		if runtime.GOOS == "linux" && batch != tc.batch {
			t.Errorf("%s batch=%d, want %d", tc.name, batch, tc.batch)
		}
		if runtime.GOOS != "linux" && (workers != 1 || batch != 1) {
			t.Errorf("portable fallback is %d workers / %d batch, want 1/1", workers, batch)
		}
		if workers < 1 || workers > runtime.GOMAXPROCS(0) {
			t.Errorf("%s workers=%d outside available CPUs", tc.name, workers)
		}
		if runtime.GOOS == "linux" && batch <= last {
			t.Errorf("%s batch=%d did not grow past %d", tc.name, batch, last)
		}
		last = batch
	}
}

func TestUnknownPacketProfileUsesBalancedTuning(t *testing.T) {
	wantWorkers, wantBatch := packetReadTuning("balanced")
	gotWorkers, gotBatch := packetReadTuning("old-config-with-no-known-profile")
	if gotWorkers != wantWorkers || gotBatch != wantBatch {
		t.Fatalf("old config got %d/%d, balanced is %d/%d",
			gotWorkers, gotBatch, wantWorkers, wantBatch)
	}
}

// The read loop itself had no test - only the function that picks how many
// workers to run. So the one thing that had to work everywhere, on every
// socket, was the one thing nothing exercised.
//
// This drives the real readers over a real socket: the recvmmsg path where
// the platform has one, the plain path where it does not.
func TestPacketReadersDeliverEveryDatagramWithAUsableAddress(t *testing.T) {
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Skip("no loopback udp here:", err)
	}
	defer pc.Close()

	done := make(chan struct{})
	defer close(done)

	var mu sync.Mutex
	seen := map[string]net.Addr{}
	arrived := make(chan struct{}, 64)

	startPacketReaders(pc, done, "extreme", false, 2048,
		func(b []byte, a net.Addr) {
			mu.Lock()
			seen[string(b)] = a
			mu.Unlock()
			select {
			case arrived <- struct{}{}:
			default:
			}
		},
		func(err error) { t.Logf("reader: %v", err) })

	send, err := net.Dial("udp", pc.LocalAddr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer send.Close()

	const n = 25
	for i := 0; i < n; i++ {
		if _, err := send.Write([]byte(fmt.Sprintf("packet-%02d", i))); err != nil {
			t.Fatal(err)
		}
	}

	deadline := time.After(5 * time.Second)
	for count := 0; count < n; {
		select {
		case <-arrived:
			mu.Lock()
			count = len(seen)
			mu.Unlock()
		case <-deadline:
			mu.Lock()
			count = len(seen)
			mu.Unlock()
			t.Fatalf("only %d of %d datagrams reached the handler", count, n)
		}
	}

	// Every one has to arrive with an address the transport can actually use.
	// The old reader always produced a *net.IPAddr, so the type assert that
	// used to be here never failed; a batched read need not, and when it does
	// not, every packet is dropped where nothing can see it happen.
	mu.Lock()
	defer mu.Unlock()
	for payload, a := range seen {
		if addrIP(a) == nil {
			t.Fatalf("%q arrived as %T, which the transport cannot read a peer out of", payload, a)
		}
	}
}

func TestAddrIPReadsAPeerOutOfWhateverTheReaderGives(t *testing.T) {
	for _, c := range []struct {
		name string
		in   net.Addr
		want string
	}{
		{"a raw socket's address", &net.IPAddr{IP: net.ParseIP("185.31.8.93")}, "185.31.8.93"},
		{"a datagram socket's", &net.UDPAddr{IP: net.ParseIP("185.31.8.93"), Port: 9443}, "185.31.8.93"},
		{"a stream socket's", &net.TCPAddr{IP: net.ParseIP("10.0.0.1"), Port: 443}, "10.0.0.1"},
	} {
		t.Run(c.name, func(t *testing.T) {
			got := addrIP(c.in)
			if got == nil || got.IP.String() != c.want {
				t.Fatalf("addrIP(%T) = %v, want %s", c.in, got, c.want)
			}
		})
	}
	if addrIP(nil) != nil {
		t.Fatal("nothing is not an address")
	}
}
