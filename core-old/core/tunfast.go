package main

import (
	"crypto/cipher"
	"encoding/binary"
	"sync"
	"sync/atomic"
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
	tunReplayWords  = tunReplayWindow / 64
)

// Scratch space for one packet on its way out. Every packet on this path is
// built and sent and finished with inside one call, so the same buffers go
// round rather than being made and collected thousands of times a second.
var tunBufs = sync.Pool{New: func() any {
	b := make([]byte, 0, 2048)
	return &b
}}

// tunFast seals and opens one packet at a time.
//
// The counter never repeats for a given key, which is what AES-GCM requires:
// it is the packet number, and a packet number is used once. Both ends run
// their own, and the two directions use different keys, so they cannot collide.
type tunFast struct {
	tx cipher.AEAD // nil when the tunnel is not encrypted
	rx cipher.AEAD

	// send takes the buffer with it: the wire is written from another
	// thread, so whoever finishes with it is the one that returns it.
	send func(*[]byte) error
	recv func([]byte)

	// How much room the transport needs in front of what we build.
	headroom int

	counter uint64 // atomic: one packet, one number, and no lock to take

	// The replay window, one bit per counter in a ring. See fresh.
	rmu    sync.Mutex
	bits   [tunReplayWords]uint64
	newest uint64
}

func newTunFast(tx, rx cipher.AEAD, headroom int, send func(*[]byte) error, recv func([]byte)) *tunFast {
	return &tunFast{tx: tx, rx: rx, headroom: headroom, send: send, recv: recv}
}

// Send puts one IP packet on the wire. The buffer is not retained.
func (f *tunFast) Send(pkt []byte) error {
	n := atomic.AddUint64(&f.counter, 1)

	var nonce [12]byte
	binary.BigEndian.PutUint64(nonce[4:], n)

	// One buffer, with the transport's header room left empty at the front.
	// It used to be two: this one, and another inside the transport that the
	// payload was copied into. At a thousand packets a millisecond that copy
	// is real, and there was never a reason for it.
	bp := tunBufs.Get().(*[]byte)
	need := f.headroom + tunNonceLen + len(pkt) + 16
	if cap(*bp) < need {
		*bp = make([]byte, 0, need)
	}
	out := (*bp)[:f.headroom+tunNonceLen]
	binary.BigEndian.PutUint64(out[f.headroom:], n)
	if f.tx == nil {
		out = append(out, pkt...)
	} else {
		out = f.tx.Seal(out, nonce[:], pkt, nil)
	}
	*bp = out
	return f.send(bp)
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
		// Opened over the top of the sealed bytes, which Open allows when the
		// destination is the ciphertext's own start. The buffer belongs to the
		// reader and the packet is written to the device before it returns.
		body := buf[tunNonceLen:]
		var err error
		pkt, err = f.rx.Open(body[:0], nonce[:], body, nil)
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
// One bit per counter, in a ring that the newest packet drags forward. A
// packet in order touches one bit and clears one, so the cost does not depend
// on the size of the window - which matters more than it sounds. Keeping the
// seen counters in a map instead, and sweeping it for expired ones, cost a
// pass over four thousand entries under this lock for every packet in either
// direction, and held the private link to a third of its throughput with the
// processor nearly idle. It was not working, it was queueing behind itself.
//
// Without encryption there is nothing to replay-protect - anything on the path
// could write a packet anyway - so the check is only about not delivering the
// same packet twice.
func (f *tunFast) fresh(n uint64) bool {
	if n == 0 {
		return false // counters start at one
	}
	f.rmu.Lock()
	defer f.rmu.Unlock()

	switch {
	case n > f.newest:
		// Drag the window forward, clearing what the front passes over so a
		// bit left from an earlier lap cannot be read as this one.
		if n-f.newest >= tunReplayWindow {
			f.bits = [tunReplayWords]uint64{}
		} else {
			for i := f.newest + 1; i <= n; i++ {
				f.bits[(i/64)%tunReplayWords] &^= 1 << (i % 64)
			}
		}
		f.newest = n
	case f.newest-n >= tunReplayWindow:
		return false // too far behind to tell whether it has been seen
	}

	word, bit := (n/64)%tunReplayWords, uint64(1)<<(n%64)
	if f.bits[word]&bit != 0 {
		return false
	}
	f.bits[word] |= bit
	return true
}
