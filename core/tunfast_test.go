package main

import (
	"bytes"
	"crypto/rand"
	"fmt"
	"sync"
	"testing"
)

func fastPair(t *testing.T, encrypted bool) (*tunFast, *tunFast, *[][]byte, *[][]byte) {
	t.Helper()
	key1 := make([]byte, 32)
	key2 := make([]byte, 32)
	rand.Read(key1)
	rand.Read(key2)

	var aWire, bWire [][]byte
	var mu sync.Mutex
	var gotA, gotB [][]byte

	var a, b *tunFast
	mk := func(tx, rx []byte, wire *[][]byte, got *[][]byte) *tunFast {
		var ta, ra = aeadFrom(tx), aeadFrom(rx)
		if !encrypted {
			ta, ra = nil, nil
		}
		return newTunFast(ta, ra,
			func(p []byte) error {
				mu.Lock()
				*wire = append(*wire, append([]byte(nil), p...))
				mu.Unlock()
				return nil
			},
			func(p []byte) {
				mu.Lock()
				*got = append(*got, append([]byte(nil), p...))
				mu.Unlock()
			})
	}
	a = mk(key1, key2, &aWire, &gotA)
	b = mk(key2, key1, &bWire, &gotB)
	return a, b, &aWire, &gotB
}

// A packet goes out and the same packet comes back up the other side.
func TestTheDirectPathCarriesAPacket(t *testing.T) {
	for _, enc := range []bool{true, false} {
		name := "encrypted"
		if !enc {
			name = "in the clear"
		}
		t.Run(name, func(t *testing.T) {
			a, b, wire, got := fastPair(t, enc)
			_ = b
			pkt := []byte("an IP packet, more or less")
			if err := a.Send(pkt); err != nil {
				t.Fatal(err)
			}
			if len(*wire) != 1 {
				t.Fatalf("%d datagrams for one packet", len(*wire))
			}
			b.Deliver((*wire)[0])
			if len(*got) != 1 || !bytes.Equal((*got)[0], pkt) {
				t.Fatalf("got %q back", *got)
			}
		})
	}
}

// IP is allowed to reorder, and every protocol above it is built for that. A
// reliable ordered layer would hold the later packet back until the earlier
// one arrived; this one must not.
func TestTheDirectPathDeliversOutOfOrder(t *testing.T) {
	a, b, wire, got := fastPair(t, true)
	for i := 0; i < 5; i++ {
		if err := a.Send([]byte(fmt.Sprintf("packet %d", i))); err != nil {
			t.Fatal(err)
		}
	}
	// arrive backwards
	for i := len(*wire) - 1; i >= 0; i-- {
		b.Deliver((*wire)[i])
	}
	if len(*got) != 5 {
		t.Fatalf("delivered %d of 5 - something is holding packets for their turn", len(*got))
	}
	if !bytes.Equal((*got)[0], []byte("packet 4")) {
		t.Fatalf("first delivered was %q, want the one that arrived first", (*got)[0])
	}
}

// And a loss must cost exactly one packet, not everything behind it.
func TestALostPacketCostsOnlyItself(t *testing.T) {
	a, b, wire, got := fastPair(t, true)
	for i := 0; i < 6; i++ {
		a.Send([]byte(fmt.Sprintf("packet %d", i)))
	}
	for i, d := range *wire {
		if i == 2 {
			continue // this one never arrives
		}
		b.Deliver(d)
	}
	if len(*got) != 5 {
		t.Fatalf("one packet was lost and %d of 6 arrived", len(*got))
	}
	for _, p := range *got {
		if bytes.Equal(p, []byte("packet 2")) {
			t.Fatal("the lost packet arrived anyway")
		}
	}
}

// The same packet twice must be delivered once. Without encryption there is
// nothing to forge, but a path that duplicates should not duplicate upward.
func TestTheDirectPathRefusesAReplay(t *testing.T) {
	a, b, wire, got := fastPair(t, true)
	a.Send([]byte("only once"))
	b.Deliver((*wire)[0])
	b.Deliver((*wire)[0])
	if len(*got) != 1 {
		t.Fatalf("delivered %d copies of one packet", len(*got))
	}
}

// A datagram sealed with another tunnel's key must not open.
func TestTheDirectPathRefusesAnotherTunnelsPacket(t *testing.T) {
	a, _, wire, _ := fastPair(t, true)
	_, other, _, otherGot := fastPair(t, true)
	a.Send([]byte("not for you"))
	other.Deliver((*wire)[0])
	if len(*otherGot) != 0 {
		t.Fatal("another tunnel's packet was accepted")
	}
}

// The replay window has to stay bounded however long the link runs.
func TestTheReplayWindowDoesNotGrowForever(t *testing.T) {
	a, b, wire, got := fastPair(t, true)
	const n = tunReplayWindow * 3
	for i := 0; i < n; i++ {
		a.Send([]byte("x"))
	}
	for _, d := range *wire {
		b.Deliver(d)
	}
	if len(*got) != n {
		t.Fatalf("delivered %d of %d", len(*got), n)
	}
	b.rmu.Lock()
	held := len(b.seen)
	b.rmu.Unlock()
	if held > tunReplayWindow+16 {
		t.Fatalf("the replay set holds %d entries after %d packets", held, n)
	}
}
