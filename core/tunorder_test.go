package main

import (
	"encoding/binary"
	"testing"
)

// One flow's packets must all take the same device queue.
//
// They did not: the queue was chosen round-robin, so a flow the send side had
// carefully pinned to one carrier was scattered across several queues that
// drain at once, and the TCP inside saw its own segments out of order. On a
// real path that cost 1071 reordering events, 400 KB of needless retransmits
// and a round trip of 187 ms where the wire was 37 ms.
func TestOneFlowKeepsToOneDeviceQueue(t *testing.T) {
	pkt := func(sport, dport uint16, dst byte) []byte {
		p := make([]byte, 40)
		p[0] = 0x45
		p[9] = 6 // tcp
		copy(p[12:16], []byte{10, 88, 0, 1})
		copy(p[16:20], []byte{10, 88, 0, dst})
		binary.BigEndian.PutUint16(p[20:22], sport)
		binary.BigEndian.PutUint16(p[22:24], dport)
		return p
	}

	for _, queues := range []int{2, 4, 8} {
		// every packet of one flow, however many are sent, lands on one queue
		want := flowHash(pkt(40322, 39202, 2)) % uint32(queues)
		for i := 0; i < 500; i++ {
			got := flowHash(pkt(40322, 39202, 2)) % uint32(queues)
			if got != want {
				t.Fatalf("with %d queues the same flow went to queue %d then %d",
					queues, want, got)
			}
		}
	}
}

// Flows that differ only in an ephemeral source port - which is every flow
// between one pair of hosts - have to spread across the carriers. A hash whose
// low bits move little would put them all on one, and the modulus takes only
// the low bits, so this guards the property rather than any past failure.
func TestFlowsSpreadAcrossCarriers(t *testing.T) {
	pkt := func(sport uint16) []byte {
		p := make([]byte, 40)
		p[0] = 0x45
		p[9] = 6
		copy(p[12:16], []byte{10, 88, 0, 1})
		copy(p[16:20], []byte{10, 88, 0, 2})
		binary.BigEndian.PutUint16(p[20:22], sport)
		binary.BigEndian.PutUint16(p[22:24], 39202)
		return p
	}

	for _, n := range []uint32{4, 8, 16} {
		// the kernel hands out ephemeral ports in runs, so that is the case
		// that matters, not random ones
		seen := make(map[uint32]int)
		const flows = 64
		for i := 0; i < flows; i++ {
			seen[flowHash(pkt(uint16(40000+i)))%n]++
		}
		if uint32(len(seen)) != n {
			t.Errorf("%d sequential flows over %d carriers used only %d of them",
				flows, n, len(seen))
		}
		// and no carrier may take a wildly unfair share
		for c, got := range seen {
			if got > flows/int(n)*3 {
				t.Errorf("with %d carriers, carrier %d took %d of %d flows",
					n, c, got, flows)
			}
		}
	}
}
