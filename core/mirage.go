package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"time"

	utls "github.com/refraction-networking/utls"
)

// ---------------------------------------------------------------------------
// mirage - a carrier that is a browser talking to a website, until it is not
//
// Everything else in this file exists because of one measured fact: on the
// path this tunnel is for, the only thing that survives is a TCP connection
// opened from inside Iran. So a transport cannot win by being cleverer about
// packets. It can only win by being harder to tell apart from the traffic
// nobody blocks, which is a browser fetching an ordinary HTTPS site.
//
// There are two observers to satisfy and they are not the same.
//
// THE ONE THAT WATCHES. It sees the TLS handshake in the clear - everything
// before the encryption starts - and the shape of what follows. What gives a
// tunnel away here is almost never the payload. It is the ClientHello: the
// order of the extensions, which curves are offered, whether the GREASE values
// a real browser scatters through it are there at all. Go's own TLS stack has
// a fingerprint of its own, and it is not Chrome's - no GREASE, the TLS 1.3
// suites in the wrong place, a hello about half the length. Anything using it
// says "a Go program" in the first packet it ever sends. So the hello here is
// not built by crypto/tls; it is built to match Chrome, byte for byte.
//
// THE ONE THAT ASKS. Watching is cheap, so a censor that suspects an address
// simply connects to it and looks. A server that answers a probe with a
// self-signed certificate for www.microsoft.com has confessed. This is the
// half that most obfuscation gets wrong, and it is the half that gets a server
// blocked within days.
//
// So the server never answers a probe at all. It reads the ClientHello,
// looks for an authenticator hidden where a browser puts a session ticket,
// and if it is not there the connection is spliced to the real site named in
// the SNI - the whole connection, from the ClientHello onwards, untouched.
// The prober completes a genuine handshake with the genuine site, gets its
// genuine certificate, and reads its genuine home page, because that is
// exactly what happened. There is nothing to notice, because for that
// connection this server really was a route to www.microsoft.com.
//
// The authenticator rides in the session id. A browser puts 32 bytes there;
// so does this. Sixteen are random and sixteen are an HMAC over them and the
// half-minute they were made in, under a key derived from the token. To
// anything without the token it is 32 bytes of a session ticket, which is what
// 32 random-looking bytes in that field are.
//
// What this does not do: it does not steal the real site's certificate, so a
// censor that both probes the address AND watches a real client's session
// could see two different certificates for one SNI. Defeating that needs the
// far end's handshake forwarded live, which is a much larger machine than this
// and buys nothing against either observer above on its own.
// ---------------------------------------------------------------------------

const (
	// The session id a browser sends. Anything else is a fingerprint in
	// itself, so the authenticator is sized to fit exactly.
	mirageAuthLen = 32

	// How coarse the clock has to agree. Half a minute, checked either side,
	// so two servers that have never heard of NTP still work.
	mirageWindow = 30 * time.Second

	// What to pretend to be when the config does not say. A name that is
	// unremarkable in any traffic log, on a host that is up.
	mirageDefaultSNI = "www.microsoft.com"
)

var errMirageProbe = errors.New("not one of ours")

type mirageTransport struct {
	cfg  *Config
	ln   net.Listener
	sni  string
	auth []byte // the key the authenticator is made with

	inbound chan net.Conn
	done    chan struct{}
	once    sync.Once
	guard   *replayGuard

	cert tls.Certificate
}

func mirageSNI(cfg *Config) string {
	if cfg.WSHost != "" {
		return cfg.WSHost
	}
	return mirageDefaultSNI
}

func newMirageTransport(cfg *Config) (*mirageTransport, error) {
	prk := hkdfExtract([]byte("pingify/v3 mirage"), cfg.key())
	t := &mirageTransport{
		cfg:     cfg,
		sni:     mirageSNI(cfg),
		auth:    hkdfExpand(prk, []byte("session id"), 32),
		inbound: make(chan net.Conn, 16),
		done:    make(chan struct{}),
		guard:   newReplayGuard(),
	}
	if cfg.Connect != "" {
		return t, nil // this end dials; it binds nothing
	}
	cert, err := wsCertificate(cfg)
	if err != nil {
		return nil, fmt.Errorf("mirage certificate: %w", err)
	}
	t.cert = cert
	ln, err := net.Listen("tcp", cfg.Listen)
	if err != nil {
		return nil, err
	}
	t.ln = ln
	go t.serve()
	return t, nil
}

func (t *mirageTransport) Name() string { return "mirage" }

func (t *mirageTransport) Close() error {
	t.once.Do(func() { close(t.done) })
	if t.ln != nil {
		return t.ln.Close()
	}
	return nil
}

// ---------------------------------------------------------------------------
// the authenticator
// ---------------------------------------------------------------------------

// mirageToken builds the 32 bytes that go in the session id.
func (t *mirageTransport) mirageToken(nonce []byte, at time.Time) []byte {
	out := make([]byte, mirageAuthLen)
	copy(out[:16], nonce)
	m := hmac.New(sha256.New, t.auth)
	m.Write(out[:16])
	var w [8]byte
	binary.BigEndian.PutUint64(w[:], uint64(at.Unix()/int64(mirageWindow/time.Second)))
	m.Write(w[:])
	copy(out[16:], m.Sum(nil)[:16])
	return out
}

// mirageValid says whether a session id is one of ours, within a window
// either side of now, and not one already seen.
func (t *mirageTransport) mirageValid(sid []byte) bool {
	if len(sid) != mirageAuthLen {
		return false
	}
	now := time.Now()
	for _, d := range []time.Duration{0, -mirageWindow, mirageWindow} {
		want := t.mirageToken(sid[:16], now.Add(d))
		if hmac.Equal(want[16:], sid[16:]) {
			var n [16]byte
			copy(n[:], sid[:16])
			return t.guard.accept(n)
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// dialling: a Chrome hello with our own session id in it
// ---------------------------------------------------------------------------

func (t *mirageTransport) Dial(idx int) (net.Conn, error) {
	d := &net.Dialer{Timeout: time.Duration(t.cfg.DialTimeout) * time.Second}
	raw, err := d.Dial("tcp", t.cfg.Connect)
	if err != nil {
		return nil, err
	}
	tuneSocket(raw, t.cfg)

	nonce := make([]byte, 16)
	if _, err := rand.Read(nonce); err != nil {
		raw.Close()
		return nil, err
	}

	// The certificate is not checked, and cannot be: the name presented is a
	// site we are only pretending to be. The token is what authenticates this
	// connection, and it authenticates it before any byte of ours is sent.
	c := utls.UClient(raw, &utls.Config{
		ServerName:         t.sni,
		InsecureSkipVerify: true,
	}, utls.HelloChrome_Auto)

	if err := c.BuildHandshakeState(); err != nil {
		raw.Close()
		return nil, fmt.Errorf("mirage hello: %w", err)
	}
	// Chrome sends 32 bytes here and so do we; the authenticator is the same
	// length as the session ticket it is standing in for.
	c.HandshakeState.Hello.SessionId = t.mirageToken(nonce, time.Now())
	if err := c.MarshalClientHello(); err != nil {
		raw.Close()
		return nil, fmt.Errorf("mirage hello: %w", err)
	}
	if err := c.Handshake(); err != nil {
		raw.Close()
		return nil, fmt.Errorf("mirage handshake: %w", err)
	}
	return c, nil
}

func (t *mirageTransport) Accept() (net.Conn, error) {
	select {
	case c, ok := <-t.inbound:
		if !ok {
			return nil, errors.New("mirage transport closed")
		}
		return c, nil
	case <-t.done:
		return nil, errors.New("mirage transport closed")
	}
}

// ---------------------------------------------------------------------------
// accepting: read the hello before deciding what this connection is
// ---------------------------------------------------------------------------

func (t *mirageTransport) serve() {
	for {
		c, err := t.ln.Accept()
		if err != nil {
			select {
			case <-t.done:
			default:
				logWarn("mirage: stopped accepting: %v", err)
			}
			return
		}
		go t.handle(c)
	}
}

func (t *mirageTransport) handle(c net.Conn) {
	// A hello that never arrives must not hold a goroutine, and a prober that
	// opens a socket and says nothing is the cheapest attack there is.
	_ = c.SetReadDeadline(time.Now().Add(10 * time.Second))
	hello, sid, sni, err := readClientHello(c)
	if err != nil {
		c.Close()
		return
	}
	_ = c.SetReadDeadline(time.Time{})

	if !t.mirageValid(sid) {
		// Not ours, or a replay. Hand the whole thing to the site it asked
		// for, starting with the hello it already sent, and stay out of the
		// way. Whoever this is gets a real answer from a real server.
		t.splice(c, hello, sni)
		return
	}

	// Ours. Finish the handshake here, with the hello put back.
	inner := tls.Server(&prefixConn{Conn: c, pre: hello}, &tls.Config{
		Certificates: []tls.Certificate{t.cert},
		MinVersion:   tls.VersionTLS12,
	})
	if err := inner.Handshake(); err != nil {
		c.Close()
		return
	}
	tuneSocket(c, t.cfg)
	select {
	case t.inbound <- inner:
	case <-t.done:
		inner.Close()
	}
}

// splice hands an unauthenticated connection to the site it asked for. What
// comes back is that site's real certificate and real content, because it is
// that site answering.
func (t *mirageTransport) splice(c net.Conn, hello []byte, sni string) {
	defer c.Close()
	if sni == "" {
		sni = t.sni
	}
	up, err := net.DialTimeout("tcp", net.JoinHostPort(sni, "443"), 8*time.Second)
	if err != nil {
		// Nothing useful to say to a prober. Closing is what a server with
		// nothing on that port does.
		return
	}
	defer up.Close()
	if _, err := up.Write(hello); err != nil {
		return
	}
	done := make(chan struct{}, 2)
	go func() { _, _ = io.Copy(up, c); done <- struct{}{} }()
	go func() { _, _ = io.Copy(c, up); done <- struct{}{} }()
	<-done
}

// ---------------------------------------------------------------------------
// just enough TLS to read a hello without consuming it
// ---------------------------------------------------------------------------

// prefixConn puts bytes already read back in front of a connection.
type prefixConn struct {
	net.Conn
	pre []byte
}

func (p *prefixConn) Read(b []byte) (int, error) {
	if len(p.pre) > 0 {
		n := copy(b, p.pre)
		p.pre = p.pre[n:]
		return n, nil
	}
	return p.Conn.Read(b)
}

// readClientHello reads exactly one TLS record and pulls the session id and
// the server name out of it. The raw bytes come back too, because whatever
// happens next needs to send them on: this end must not consume a byte it
// might have to hand to somebody else.
func readClientHello(c net.Conn) (raw, sessionID []byte, sni string, err error) {
	var hdr [5]byte
	if _, err = io.ReadFull(c, hdr[:]); err != nil {
		return nil, nil, "", err
	}
	// A handshake record, and one big enough to be a hello but not absurd.
	if hdr[0] != 0x16 {
		return nil, nil, "", errMirageProbe
	}
	n := int(binary.BigEndian.Uint16(hdr[3:5]))
	if n < 42 || n > 16384 {
		return nil, nil, "", errMirageProbe
	}
	raw = make([]byte, 5+n)
	copy(raw, hdr[:])
	if _, err = io.ReadFull(c, raw[5:]); err != nil {
		return nil, nil, "", err
	}
	sessionID, sni = parseClientHello(raw[5:])
	return raw, sessionID, sni, nil
}

// parseClientHello walks the handshake far enough to find the session id and
// the server name. Anything malformed returns nothing, which sends the
// connection to the real site - the safe direction to be wrong in.
func parseClientHello(b []byte) (sessionID []byte, sni string) {
	// handshake header: type, 3-byte length
	if len(b) < 4 || b[0] != 0x01 {
		return nil, ""
	}
	b = b[4:]
	// client_version (2) + random (32)
	if len(b) < 34 {
		return nil, ""
	}
	b = b[34:]
	// session id
	if len(b) < 1 {
		return nil, ""
	}
	sl := int(b[0])
	if len(b) < 1+sl {
		return nil, ""
	}
	sessionID = b[1 : 1+sl]
	b = b[1+sl:]
	// cipher suites
	if len(b) < 2 {
		return sessionID, ""
	}
	cl := int(binary.BigEndian.Uint16(b[:2]))
	if len(b) < 2+cl {
		return sessionID, ""
	}
	b = b[2+cl:]
	// compression methods
	if len(b) < 1 {
		return sessionID, ""
	}
	ml := int(b[0])
	if len(b) < 1+ml {
		return sessionID, ""
	}
	b = b[1+ml:]
	// extensions
	if len(b) < 2 {
		return sessionID, ""
	}
	el := int(binary.BigEndian.Uint16(b[:2]))
	b = b[2:]
	if len(b) < el {
		return sessionID, ""
	}
	b = b[:el]
	for len(b) >= 4 {
		typ := binary.BigEndian.Uint16(b[:2])
		ln := int(binary.BigEndian.Uint16(b[2:4]))
		if len(b) < 4+ln {
			return sessionID, ""
		}
		if typ == 0x0000 { // server_name
			sni = parseSNI(b[4 : 4+ln])
			return sessionID, sni
		}
		b = b[4+ln:]
	}
	return sessionID, ""
}

func parseSNI(b []byte) string {
	// server_name_list length, then entries of type+length+name
	if len(b) < 2 {
		return ""
	}
	b = b[2:]
	for len(b) >= 3 {
		typ := b[0]
		ln := int(binary.BigEndian.Uint16(b[1:3]))
		if len(b) < 3+ln {
			return ""
		}
		if typ == 0 {
			name := string(b[3 : 3+ln])
			if validHostname(name) {
				return name
			}
			return ""
		}
		b = b[3+ln:]
	}
	return ""
}

// validHostname keeps a forged SNI from turning this server into an open
// relay to anywhere: what comes back out of it is only ever a hostname.
func validHostname(s string) bool {
	if len(s) == 0 || len(s) > 253 {
		return false
	}
	dot := false
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		case c == '-' || c == '_':
		case c == '.':
			dot = true
		default:
			return false
		}
	}
	return dot
}
