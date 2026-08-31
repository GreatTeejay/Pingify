package main

import (
	"crypto/rand"
	"testing"
)

// Where a datagram's time goes on the way out.
//
// UDP carries 359 Mbit/s where TCP carries 5179 on the same machine, and both
// ride the same braid - so the difference is underneath, in here. These break
// the per-datagram cost into its pieces so the fix goes where the time is
// rather than where it looks like it should be.

// The whole send path with a sender that does nothing, so this is the CPU cost
// of preparing one datagram and none of the socket.
func BenchmarkARQEmit(b *testing.B) {
	psk := make([]byte, 32)
	rand.Read(psk)
	c := newARQ(1, 0, psk, "pingify/v3 udp", 1200, 4096, func([]byte) error { return nil })
	defer c.Close()
	seg := &segment{seq: 0, data: make([]byte, 1200)}

	b.SetBytes(1200)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		c.mu.Lock()
		seg.seq = uint32(i)
		c.emit(seg, flagData)
		c.mu.Unlock()
	}
}

// Just the randomness. crypto/rand per datagram is a real line item at tens of
// thousands of packets a second.
func BenchmarkARQNonce(b *testing.B) {
	buf := make([]byte, arqNonce)
	b.SetBytes(1200)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		rand.Read(buf)
	}
}

// Just the header mask.
func BenchmarkARQHeaderMask(b *testing.B) {
	psk := make([]byte, 32)
	rand.Read(psk)
	blk := blockFrom(arqMaskKey("pingify/v3 udp", psk))
	nonce := make([]byte, arqNonce)
	rand.Read(nonce)
	hdr := make([]byte, arqHdr)

	b.SetBytes(1200)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		maskHeader(blk, nonce, hdr)
	}
}

// And what one segment costs the writer, allocation included.
func BenchmarkARQWriteSegment(b *testing.B) {
	psk := make([]byte, 32)
	rand.Read(psk)
	c := newARQ(1, 0, psk, "pingify/v3 udp", 1200, 1<<20, func([]byte) error { return nil })
	defer c.Close()
	payload := make([]byte, 1200)

	b.SetBytes(1200)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		c.mu.Lock()
		// what Write does for one segment, minus the window wait
		seg := &segment{seq: c.sndNext, data: append([]byte(nil), payload...)}
		c.sndBuf[seg.seq] = seg
		c.sndNext++
		c.emit(seg, flagData)
		delete(c.sndBuf, seg.seq) // keep the map from growing without bound
		c.mu.Unlock()
	}
}
