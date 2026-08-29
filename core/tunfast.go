package main

import (
	"crypto/cipher"
	"encoding/binary"
	"sync"
)

// ---------------------------------------------------------------------------
// the private link, carried the way a private link should be
//
// A TUN device hands us IP packets. IP is allowed to lose them and allowed to
// deliver them out of order - every protocol that runs on top is built for
// exactly that, and TCP inside the tunnel has its own retransmission and its
// own ordering.
//
// So putting a reliable, ordered layer underneath is not merely redundant. It
// costs twice:
//
//	two things retransmit the same loss. The inner TCP's timer and ours both
//	fire, and they fight - the same fault that makes a TCP tunnel inside TCP
//	slower than the path it rides on.
//
//	worse, ordering. A reliable layer holds packet N+1 until N arrives, so
//	one lost packet stalls everything behind it. IP would simply have
//	delivered N+1 and let the endpoints sort it out.
//
// Measured on a real path: a stateless tunnel over the same route adds nothing
// to the round trip - 75.0 ms against a 74.7 ms ping - where this one added
// thirty-six. That difference is the layer, not the distance.
//
// So TUN packets do not use the braid or the ARQ at all. Each one is sealed on
// its own and put on the wire as one datagram, and each one that arrives is
// opened on its own and written to the device. Losing one loses one packet,
// which is what the wire was always allowed to do.
//
// The braid is still there beside this, carrying the handshake, the keepalives
// and any forwarded ports, all of which do want to arrive.
// ---------------------------------------------------------------------------

const (
	// nonce, and nothing else. The counter is on the wire because a receiver
	// that keeps its own cannot survive a lost packet - which is the whole
	// point of this path.
	tunNonceLen = 8

	// How far out of order a packet may arrive and still be accepted. A path
	// that reorders by more than this is reordering by more than any protocol
	// inside is prepared for.
	tunReplayWindow = 4096
)

// tunFast seals and opens one packet at a time.
//
// The counter never repeats for a given key, which is what AES-GCM requires:
// it is the packet number, and a packet number is used once. Both ends run
// their own, and the two directions use different keys, so they cannot collide.
type tunFast struct {
	tx cipher.AEAD // nil when the tunnel is not encrypted
	rx cipher.AEAD

	send func([]byte) error
	recv func([]byte)

	mu      sync.Mutex
	counter uint64

	rmu    sync.Mutex
	seen   map[uint64]bool
	newest uint64
}

func newTunFast(tx, rx cipher.AEAD, send func([]byte) error, recv func([]byte)) *tunFast {
	return &tunFast{tx: tx, rx: rx, send: send, recv: recv, seen: make(map[uint64]bool)}
}

// Send puts one IP packet on the wire. The buffer is not retained.
func (f *tunFast) Send(pkt []byte) error {
	f.mu.Lock()
	f.counter++
	n := f.counter
	f.mu.Unlock()

	var nonce [12]byte
	binary.BigEndian.PutUint64(nonce[4:], n)

	out := make([]byte, tunNonceLen, tunNonceLen+len(pkt)+16)
	binary.BigEndian.PutUint64(out[:tunNonceLen], n)
	if f.tx == nil {
		out = append(out, pkt...)
	} else {
		out = f.tx.Seal(out, nonce[:], pkt, nil)
	}
	return f.send(out)
}

// Deliver opens one datagram and hands the packet up. A datagram that does not
// open, or that has been seen before, is dropped without a word: on a raw
// socket that is ordinary traffic, not a fault.
func (f *tunFast) Deliver(buf []byte) {
	if len(buf) <= tunNonceLen {
		return
	}
	n := binary.BigEndian.Uint64(buf[:tunNonceLen])
	if !f.fresh(n) {
		return
	}

	var pkt []byte
	if f.rx == nil {
		pkt = buf[tunNonceLen:]
	} else {
		var nonce [12]byte
		binary.BigEndian.PutUint64(nonce[4:], n)
		var err error
		pkt, err = f.rx.Open(nil, nonce[:], buf[tunNonceLen:], nil)
		if err != nil {
			return
		}
	}
	if len(pkt) > 0 {
		f.recv(pkt)
	}
}

// fresh is the replay check: a counter is accepted once, and only if it is
// within the window of what has already been seen.
//
// Without encryption there is nothing to replay-protect - anything on the path
// could write a packet anyway - so the check is only about not delivering the
// same packet twice.
func (f *tunFast) fresh(n uint64) bool {
	f.rmu.Lock()
	defer f.rmu.Unlock()

	if n > f.newest {
		// Everything now too old to matter goes, so the map cannot grow.
		if n-f.newest > tunReplayWindow {
			f.seen = make(map[uint64]bool, tunReplayWindow)
		} else {
			for old := range f.seen {
				if n-old > tunReplayWindow {
					delete(f.seen, old)
				}
			}
		}
		f.newest = n
		f.seen[n] = true
		return true
	}
	if f.newest-n >= tunReplayWindow {
		return false // too far behind to tell whether it has been seen
	}
	if f.seen[n] {
		return false
	}
	f.seen[n] = true
	return true
}
