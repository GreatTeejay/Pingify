package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"io"
	"net"
	"time"
)

// The plain handshake, byte for byte as v2.1.1 shipped it.
//
// v3 removed every constant from the wire so nothing could be fingerprinted:
// no magic, no version, a header XORed with a key-derived block, a variable
// amount of trailing padding, and masked frame lengths. On a real Iran<->Europe
// path that stream stopped carrying anything a few seconds after each carrier
// came up, in both directions, every time - while this one, with a four-byte
// magic in the clear, worked on the same two servers.
//
// Both are kept. Which one a tunnel speaks is [transport] obfuscate, and it has
// to match on the two ends. Off - this one - is the default, because a tunnel
// that carries no traffic protects nothing.
const (
	hs2Magic     = "PFY2"
	hs2Version   = 2
	hs2ClientLen = 4 + 1 + 1 + 2 + 8 + 16 + 32
	hs2ServerLen = 16 + 32
)

func deriveSessionV2(psk, nonceC, nonceS []byte, carrier uint16, dialer bool) *sessionKeys {
	salt := make([]byte, 0, len(nonceC)+len(nonceS)+2)
	salt = append(salt, nonceC...)
	salt = append(salt, nonceS...)
	salt = append(salt, byte(carrier>>8), byte(carrier))
	prk := hkdfExtract(salt, psk)
	c2s := hkdfExpand(prk, []byte("pingify/v2 c2s"), 32)
	s2c := hkdfExpand(prk, []byte("pingify/v2 s2c"), 32)

	// The length masks are never used in this mode; they are filled in so the
	// struct is always whole and nothing has to check before reading it.
	if dialer {
		return &sessionKeys{aeadFrom(c2s), aeadFrom(s2c), blockFrom(c2s), blockFrom(s2c)}
	}
	return &sessionKeys{aeadFrom(s2c), aeadFrom(c2s), blockFrom(s2c), blockFrom(c2s)}
}

func clientHandshakeV2(conn net.Conn, cfg *Config, carrier int) (*sessionKeys, error) {
	psk := cfg.key()
	buf := make([]byte, hs2ClientLen)
	copy(buf[0:4], hs2Magic)
	buf[4] = hs2Version
	buf[5] = roleByte(cfg.Role)
	binary.BigEndian.PutUint16(buf[6:8], uint16(carrier))
	binary.BigEndian.PutUint64(buf[8:16], uint64(time.Now().Unix()))
	if _, err := rand.Read(buf[16:32]); err != nil {
		return nil, err
	}
	m := hmac.New(sha256.New, psk)
	m.Write(buf[:32])
	copy(buf[32:], m.Sum(nil))

	conn.SetDeadline(time.Now().Add(15 * time.Second))
	if _, err := conn.Write(buf); err != nil {
		return nil, err
	}
	resp := make([]byte, hs2ServerLen)
	if _, err := io.ReadFull(conn, resp); err != nil {
		return nil, err
	}
	m2 := hmac.New(sha256.New, psk)
	m2.Write([]byte("pingify/v2 srv"))
	m2.Write(buf[16:32])
	m2.Write(resp[:16])
	if !hmac.Equal(m2.Sum(nil), resp[16:]) {
		return nil, errHandshake
	}
	conn.SetDeadline(time.Time{})

	return deriveSessionV2(psk, buf[16:32], resp[:16], uint16(carrier), true), nil
}

func serverHandshakeV2(conn net.Conn, cfg *Config, g *replayGuard) (*sessionKeys, int, error) {
	psk := cfg.key()
	buf := make([]byte, hs2ClientLen)
	conn.SetDeadline(time.Now().Add(15 * time.Second))
	if _, err := io.ReadFull(conn, buf); err != nil {
		return nil, 0, err
	}
	if string(buf[0:4]) != hs2Magic || buf[4] != hs2Version {
		return nil, 0, errHandshake
	}
	if buf[5] == roleByte(cfg.Role) {
		return nil, 0, errHandshake // both ends configured with the same role
	}
	ts := int64(binary.BigEndian.Uint64(buf[8:16]))
	if d := time.Since(time.Unix(ts, 0)); d > hsSkew || d < -hsSkew {
		return nil, 0, errHandshake
	}
	m := hmac.New(sha256.New, psk)
	m.Write(buf[:32])
	if !hmac.Equal(m.Sum(nil), buf[32:]) {
		return nil, 0, errHandshake
	}
	var nc [16]byte
	copy(nc[:], buf[16:32])
	if !g.accept(nc) {
		return nil, 0, errHandshake
	}

	resp := make([]byte, hs2ServerLen)
	if _, err := rand.Read(resp[:16]); err != nil {
		return nil, 0, err
	}
	m2 := hmac.New(sha256.New, psk)
	m2.Write([]byte("pingify/v2 srv"))
	m2.Write(buf[16:32])
	m2.Write(resp[:16])
	copy(resp[16:], m2.Sum(nil))
	if _, err := conn.Write(resp); err != nil {
		return nil, 0, err
	}
	conn.SetDeadline(time.Time{})

	carrier := int(binary.BigEndian.Uint16(buf[6:8]))
	return deriveSessionV2(psk, buf[16:32], resp[:16], uint16(carrier), false), carrier, nil
}
