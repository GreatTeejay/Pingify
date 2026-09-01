package carrier

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"net"
	"testing"
	"time"

	utls "github.com/refraction-networking/utls"
)

func newFallback(token string) *fallback {
	m := hmac.New(sha256.New, []byte("pingify fallback session id v1"))
	m.Write([]byte(token))
	return &fallback{key: m.Sum(nil), sni: "example.com", seen: newNonceSet()}
}

// The whole transport turns on this: our own hello is recognised, anybody
// else's is not, and neither is one of ours played back a second time.
func TestOnlyOurOwnSessionIdOpensAConnection(t *testing.T) {
	f := newFallback("a token nobody else has")

	sid := f.token([]byte("0123456789abcdef"), time.Now())
	if !f.valid(sid) {
		t.Fatal("our own session id was refused")
	}
	if f.valid(sid) {
		t.Fatal("the same session id was accepted twice - a recorded hello reopens the tunnel")
	}

	// A different nonce under the same key is a different connection, and is
	// fine: that is what a second link of the same tunnel sends.
	if !f.valid(f.token([]byte("fedcba9876543210"), time.Now())) {
		t.Fatal("a second connection of our own was refused")
	}

	// Somebody else's token, and 32 bytes of nothing, are both probes.
	other := newFallback("some other tunnel")
	if f.valid(other.token([]byte("0123456789abcdef"), time.Now())) {
		t.Fatal("another tunnel's token was accepted")
	}
	if f.valid(bytes.Repeat([]byte{7}, fallbackAuthLen)) {
		t.Fatal("32 bytes of filler were accepted")
	}
	if f.valid(nil) || f.valid(make([]byte, 16)) {
		t.Fatal("a session id of the wrong length was accepted")
	}
}

// Clocks drift and neither server has heard of NTP. A window either side is
// deliberate; two windows out is not.
func TestTheClocksMayDisagreeByAWindow(t *testing.T) {
	f := newFallback("a token")
	now := time.Now()
	// A nonce of its own for each, or the second one is refused as a replay
	// of the first and the test proves nothing about the clock.
	for i, d := range []time.Duration{-fallbackWindow, fallbackWindow} {
		nonce := []byte("nonce for case  ")
		nonce[15] = byte('0' + i)
		if !f.valid(f.token(nonce, now.Add(d))) {
			t.Errorf("a hello %v out was refused", d)
		}
	}
	if f.valid(f.token([]byte("a nonce not used"), now.Add(5*fallbackWindow))) {
		t.Error("a hello five windows out was accepted")
	}
}

// The parser has to find our authenticator in a hello that a real Chrome
// built, because that is the only kind this transport ever sends. Anything it
// cannot read goes to the real website, so a parser that quietly fails is a
// tunnel that quietly stops working.
func TestTheAuthenticatorIsFoundInARealChromeHello(t *testing.T) {
	f := newFallback("a token")
	sid := f.token([]byte("0123456789abcdef"), time.Now())

	c1, c2 := net.Pipe()
	defer func() { _ = c1.Close() }()
	defer func() { _ = c2.Close() }()

	u := utls.UClient(c1, &utls.Config{
		ServerName:         "www.microsoft.com",
		InsecureSkipVerify: true,
	}, utls.HelloChrome_Auto)
	if err := u.BuildHandshakeState(); err != nil {
		t.Fatalf("building the hello: %v", err)
	}
	u.HandshakeState.Hello.SessionId = sid
	if err := u.MarshalClientHello(); err != nil {
		t.Fatalf("marshalling the hello: %v", err)
	}
	hello := u.HandshakeState.Hello.Raw

	gotSID, gotSNI := parseClientHello(hello)
	if !bytes.Equal(gotSID, sid) {
		t.Fatalf("session id came back as %x, wanted %x", gotSID, sid)
	}
	if gotSNI != "www.microsoft.com" {
		t.Fatalf("server name came back as %q", gotSNI)
	}
	if !f.valid(gotSID) {
		t.Fatal("the authenticator did not survive the round trip through a hello")
	}

	// And the same hello through a record, which is how it arrives.
	rec := make([]byte, 5+len(hello))
	rec[0], rec[1], rec[2] = 0x16, 0x03, 0x01
	binary.BigEndian.PutUint16(rec[3:5], uint16(len(hello)))
	copy(rec[5:], hello)

	a, b := net.Pipe()
	go func() { _, _ = b.Write(rec); _ = b.Close() }()
	raw, sid2, sni2, err := readClientHello(a)
	if err != nil {
		t.Fatalf("reading the record: %v", err)
	}
	if !bytes.Equal(raw, rec) {
		t.Fatal("the bytes read are not the bytes that arrived - a spliced probe would be corrupted")
	}
	if !bytes.Equal(sid2, sid) || sni2 != "www.microsoft.com" {
		t.Fatalf("record parse gave %x / %q", sid2, sni2)
	}
	_ = a.Close()
}

// Anything that is not a hello is somebody scanning ports, and must not be
// read as one.
func TestJunkIsNotAHello(t *testing.T) {
	for _, junk := range [][]byte{
		{},
		{0x16},
		{0x47, 0x45, 0x54, 0x20, 0x2f}, // GET /
		{0x16, 0x03, 0x01, 0x00, 0x05, 1, 2, 3, 4, 5},
	} {
		a, b := net.Pipe()
		go func(j []byte) { _, _ = b.Write(j); _ = b.Close() }(junk)
		if _, _, _, err := readClientHello(a); err == nil {
			t.Errorf("%x was read as a hello", junk)
		}
		_ = a.Close()
	}
}

// The SNI decides where an unauthenticated connection is sent, and it is
// written by whoever is probing. Without this the server is an open relay to
// any address they name.
func TestAForgedServerNameCannotPointAnywhere(t *testing.T) {
	for _, bad := range []string{
		"", "no-dots", "10.0.0.1:22", "evil.com/../x", "a b.com",
		"localhost", "example.com;rm -rf /",
	} {
		if validHostname(bad) {
			t.Errorf("%q was accepted as a name to connect to", bad)
		}
	}
	for _, ok := range []string{"www.microsoft.com", "cdn.example.co.uk", "a-b_c.example.com"} {
		if !validHostname(ok) {
			t.Errorf("%q was refused", ok)
		}
	}
}
