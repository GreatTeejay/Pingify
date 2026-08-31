package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
)

// ==========================================================================
// 3. key derivation
// ==========================================================================

// HKDF (RFC 5869) over HMAC-SHA256, hand-rolled on crypto/hmac because
// hand-rolled rather than taken from golang.org/x/crypto, which is thirty
// lines against a dependency in the one part of the engine that must never
// surprise anybody. It predates the vendored modules and has no reason to
// change now that they exist.

func hkdfExtract(salt, ikm []byte) []byte {
	if len(salt) == 0 {
		salt = make([]byte, sha256.Size)
	}
	m := hmac.New(sha256.New, salt)
	m.Write(ikm)
	return m.Sum(nil)
}

func hkdfExpand(prk, info []byte, n int) []byte {
	out := make([]byte, 0, n)
	var t []byte
	for i := byte(1); len(out) < n; i++ {
		m := hmac.New(sha256.New, prk)
		m.Write(t)
		m.Write(info)
		m.Write([]byte{i})
		t = m.Sum(nil)
		out = append(out, t...)
	}
	return out[:n]
}

// sessionKeys is everything one carrier connection needs: an AEAD per
// direction, plus a block cipher per direction used to mask the frame length
// prefix. Masking the length is what stops the stream from looking like clean
// length-delimited framing to anything watching it go past.
type sessionKeys struct {
	tx     cipher.AEAD
	rx     cipher.AEAD
	maskTx cipher.Block
	maskRx cipher.Block
}

func blockFrom(key []byte) cipher.Block {
	b, err := aes.NewCipher(key)
	if err != nil {
		panic(err) // key length is fixed at 32 by the caller
	}
	return b
}

// deriveSession turns the PSK plus both handshake nonces into four independent
// keys. Every carrier gets its own set, because every carrier runs its own
// handshake with fresh nonces - so no two connections, and no two directions,
// ever share a keystream.
func deriveSession(psk, nonceC, nonceS []byte, carrier uint16, dialer bool) *sessionKeys {
	salt := make([]byte, 0, len(nonceC)+len(nonceS)+2)
	salt = append(salt, nonceC...)
	salt = append(salt, nonceS...)
	salt = append(salt, byte(carrier>>8), byte(carrier))
	prk := hkdfExtract(salt, psk)

	c2s := hkdfExpand(prk, []byte("pingify/v3 c2s"), 32)
	s2c := hkdfExpand(prk, []byte("pingify/v3 s2c"), 32)
	lenC2S := hkdfExpand(prk, []byte("pingify/v3 len c2s"), 32)
	lenS2C := hkdfExpand(prk, []byte("pingify/v3 len s2c"), 32)

	if dialer {
		return &sessionKeys{aeadFrom(c2s), aeadFrom(s2c), blockFrom(lenC2S), blockFrom(lenS2C)}
	}
	return &sessionKeys{aeadFrom(s2c), aeadFrom(c2s), blockFrom(lenS2C), blockFrom(lenC2S)}
}

// maskLen XORs the four-byte length prefix with an AES block keyed per
// direction and indexed by the frame counter. One block cipher call per frame
// is nothing next to encrypting the payload, and it removes the last piece of
// visible structure from the stream.
func maskLen(b cipher.Block, ctr uint64, p []byte) {
	var in, out [16]byte
	binary.BigEndian.PutUint64(in[8:], ctr)
	b.Encrypt(out[:], in[:])
	for i := 0; i < 4; i++ {
		p[i] ^= out[i]
	}
}
