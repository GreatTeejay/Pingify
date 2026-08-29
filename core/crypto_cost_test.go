package main

import (
	"crypto/rand"
	"testing"
)

// What the frame cipher actually costs, so "encryption makes it heavy" is a
// measurement rather than a feeling.
func BenchmarkFrameSeal(b *testing.B) {
	key := make([]byte, 32)
	rand.Read(key)
	a := aeadFrom(key)
	pt := make([]byte, 32*1024)
	rand.Read(pt)
	out := make([]byte, 0, len(pt)+64)
	var n [12]byte

	b.SetBytes(int64(len(pt)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		out = a.Seal(out[:0], n[:], pt, nil)
	}
}

func BenchmarkFrameOpen(b *testing.B) {
	key := make([]byte, 32)
	rand.Read(key)
	a := aeadFrom(key)
	pt := make([]byte, 32*1024)
	rand.Read(pt)
	var n [12]byte
	ct := a.Seal(nil, n[:], pt, nil)
	out := make([]byte, 0, len(pt))

	b.SetBytes(int64(len(pt)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		out, _ = a.Open(out[:0], n[:], ct, nil)
	}
}
