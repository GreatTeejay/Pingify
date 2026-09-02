package carrier

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
	"strings"
	"sync"
	"time"

	utls "github.com/refraction-networking/utls"

	"pingify/internal/config"
	"pingify/internal/logging"
)

// TLS FALLBACK: a TLS server that is a route to somebody else's website until
// it is shown the token.
//
// There are two observers to satisfy on this path and they are not the same
// one. TCP UTLS answers the first: what a passive filter reads of a TLS
// connection is the ClientHello, and ours is Chrome's rather than Go's. This
// transport answers the second, which is the half that gets a server blocked
// within days of being found.
//
// Watching is cheap, so a censor that suspects an address simply connects to
// it and looks. A server that answers that probe with a self-signed
// certificate for a name it has no business serving has confessed, and no
// amount of care over the hello saves it.
//
// So this end never answers a probe at all. It reads the ClientHello, looks
// for an authenticator where a browser puts its session ticket, and if it is
// not there the whole connection - starting with the hello already read - is
// spliced to the site named in its SNI. The prober completes a real handshake
// with the real site, gets that site's real certificate, and reads its real
// home page, because that is precisely what happened: for that connection this
// server was a route to www.microsoft.com and nothing else.
//
// The authenticator rides in the session id, which is where a browser puts 32
// bytes and so do we. Sixteen are random and sixteen are an HMAC over them and
// the half minute they were made in, under a key derived from the token. To
// anything without the token they are 32 bytes of a session ticket, which is
// what 32 random looking bytes in that field are everywhere else on the
// internet.
//
// What this does not do: it does not serve the real site's certificate to us,
// so a censor that both probes the address and watches a genuine visitor's
// session could see two certificates for one name. Closing that needs the far
// site's handshake forwarded live, which is a much larger machine and buys
// nothing against either observer on its own.
const (
	// What a browser sends, so the authenticator is sized to fit exactly.
	// Anything else in that field is a fingerprint of its own.
	fallbackAuthLen = 32

	// How closely the two clocks have to agree. Half a minute, checked either
	// side, so a server that has never heard of NTP still works.
	fallbackWindow = 30 * time.Second

	// Who to be when the config gives no name to borrow. Unremarkable in any
	// traffic log, and up.
	fallbackDefaultSNI = "www.microsoft.com"

	// A hello that never arrives must not hold a goroutine: a prober that
	// opens a socket and says nothing is the cheapest attack there is.
	fallbackHelloWait = 10 * time.Second
)

var errNotOurs = errors.New("no token in the hello")

func newFallbackCarrier(cfg *config.Config) (*streamCarrier, error) {
	c, err := newStreamCarrier(cfg, "fallback", tcpLenLen)
	if err != nil {
		return nil, err
	}

	m := hmac.New(sha256.New, []byte("pingify fallback session id v1"))
	m.Write([]byte(cfg.Token))
	f := &fallback{key: m.Sum(nil), sni: fallbackSNI(cfg), seen: newNonceSet()}

	host := cfg.DialHost()
	addr := net.JoinHostPort(host, fmt.Sprint(cfg.Transport.Port))

	c.dial = func() (net.Conn, framing, error) {
		nc, err := net.DialTimeout("tcp4", addr, streamDialWait)
		if err != nil {
			return nil, nil, err
		}
		prepStream(nc)
		u, err := f.hello(nc)
		if err != nil {
			_ = nc.Close()
			return nil, nil, err
		}
		return u, lenFraming{}, nil
	}

	if cfg.Dials() {
		logging.Info("carrier: dialling %s as a browser visiting %s", addr, f.sni)
		return c, nil
	}

	conf, err := utlsServerConfig(cfg)
	if err != nil {
		return nil, err
	}
	c.accept = func(nc net.Conn) (net.Conn, framing, error) {
		return f.answer(nc, conf)
	}
	logging.Info("carrier: anything without the token is spliced to %s", f.sni)
	return c, nil
}

// fallbackSNI is the name this end pretends to be, which is the name the far
// end dials when there is one. A tunnel dialled by address has no name to
// borrow, and borrows the default.
func fallbackSNI(cfg *config.Config) string {
	h := cfg.DialHost()
	if strings.ContainsAny(h, "abcdefghijklmnopqrstuvwxyz") {
		return h
	}
	return fallbackDefaultSNI
}

type fallback struct {
	key  []byte
	sni  string
	seen *nonceSet
}

// token builds the 32 bytes that go in the session id.
func (f *fallback) token(nonce []byte, at time.Time) []byte {
	out := make([]byte, fallbackAuthLen)
	copy(out[:16], nonce)
	m := hmac.New(sha256.New, f.key)
	m.Write(out[:16])
	var w [8]byte
	binary.BigEndian.PutUint64(w[:], uint64(at.Unix()/int64(fallbackWindow/time.Second)))
	m.Write(w[:])
	copy(out[16:], m.Sum(nil)[:16])
	return out
}

// valid says whether a session id is one of ours, made within a window either
// side of now, and not one already used.
func (f *fallback) valid(sid []byte) bool {
	if len(sid) != fallbackAuthLen {
		return false
	}
	now := time.Now()
	for _, d := range []time.Duration{0, -fallbackWindow, fallbackWindow} {
		want := f.token(sid[:16], now.Add(d))
		if hmac.Equal(want[16:], sid[16:]) {
			var n [16]byte
			copy(n[:], sid[:16])
			return f.seen.accept(n, now)
		}
	}
	return false
}

// hello dials with Chrome's ClientHello and our own session id inside it.
//
// The certificate is not checked and cannot be: the name presented is a site
// we are only pretending to be. The token is what authenticates the
// connection, and it does so before a byte of ours is sent.
func (f *fallback) hello(nc net.Conn) (net.Conn, error) {
	nonce := make([]byte, 16)
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	u := utls.UClient(nc, &utls.Config{
		ServerName:         f.sni,
		InsecureSkipVerify: true,
	}, utls.HelloChrome_Auto)
	if err := u.BuildHandshakeState(); err != nil {
		return nil, fmt.Errorf("hello: %v", err)
	}
	u.HandshakeState.Hello.SessionId = f.token(nonce, time.Now())
	if err := u.MarshalClientHello(); err != nil {
		return nil, fmt.Errorf("hello: %v", err)
	}
	if err := u.Handshake(); err != nil {
		return nil, fmt.Errorf("handshake with %s: %v", f.sni, err)
	}
	return u, nil
}

// answer decides what an arriving connection is before speaking a word of TLS
// to it, which is this whole transport in one function.
func (f *fallback) answer(nc net.Conn, conf *tls.Config) (net.Conn, framing, error) {
	_ = nc.SetReadDeadline(time.Now().Add(fallbackHelloWait))
	hello, sid, sni, err := readClientHello(nc)
	if err != nil {
		return nil, nil, err
	}

	if !f.valid(sid) {
		// Not ours, or a replay. Hand the whole thing to the site it asked
		// for and stay out of the way. This holds the goroutine for as long
		// as that conversation lasts, which is what makes it convincing - so
		// the deadline the accept path set has to go first.
		_ = nc.SetDeadline(time.Time{})
		f.splice(nc, hello, sni)
		return nil, nil, errNotOurs
	}

	// Ours. Finish the handshake here, with the hello put back in front.
	_ = nc.SetReadDeadline(time.Time{})
	ts := tls.Server(&prefixConn{Conn: nc, pre: hello}, conf)
	if err := ts.Handshake(); err != nil {
		return nil, nil, fmt.Errorf("tls: %v", err)
	}
	return ts, lenFraming{}, nil
}

// splice is the connection this server does not own, carried to the site it
// asked for. What comes back is that site's real certificate and real page,
// because it is that site answering.
func (f *fallback) splice(nc net.Conn, hello []byte, sni string) {
	defer func() { _ = nc.Close() }()
	if sni == "" {
		sni = f.sni
	}
	// The name was written by whoever is probing, and this server is about
	// to open a connection to it on their behalf. A public address is what
	// an SNI proxy does all day; a private one is a way into whatever this
	// machine can reach and the internet cannot, so those get the same answer
	// as a bad hello - nothing.
	ip := publicAddressOf(sni)
	if ip == nil {
		return
	}
	up, err := net.DialTimeout("tcp", net.JoinHostPort(ip.String(), "443"), 8*time.Second)
	if err != nil {
		// There is nothing useful to say to a prober. Closing is what a
		// server with nothing on that port does.
		return
	}
	defer func() { _ = up.Close() }()
	if _, err := up.Write(hello); err != nil {
		return
	}
	// Both directions, and the end of one is passed on as a half close rather
	// than taken as the end of the connection. Closing on the first of the two
	// cuts the answer off mid-flight: a probing browser sees the page arrive
	// and the connection break, which is its own kind of confession.
	done := make(chan struct{}, 2)
	go func() { _, _ = io.Copy(up, nc); halfClose(up); done <- struct{}{} }()
	go func() { _, _ = io.Copy(nc, up); halfClose(nc); done <- struct{}{} }()
	<-done
	<-done
}

// halfClose says "nothing more from this end" without ending the conversation,
// which is what lets the other direction finish.
func halfClose(c net.Conn) {
	if tc, ok := c.(*net.TCPConn); ok {
		_ = tc.CloseWrite()
	}
}

// A nonce is good once. Without this, a recording of one valid hello opens a
// connection here for as long as the window lasts - which is exactly the probe
// this transport exists to survive: the replay cannot finish the handshake,
// but it does not need to. It only needs to see this server answer with its
// own certificate instead of Microsoft's.
//
// Three generations, not two. A hello is accepted from a window either side of
// now, so one made by a clock half a minute ahead is still valid two windows
// after it was first seen - and with two generations its nonce had been
// forgotten by then. Recorded, replayed a minute later, accepted.
const nonceGens = 3

type nonceSet struct {
	mu   sync.Mutex
	gen  int64
	gens [nonceGens]map[[16]byte]struct{} // [0] is this window, [1] the last, and so on
}

func newNonceSet() *nonceSet {
	s := &nonceSet{}
	for i := range s.gens {
		s.gens[i] = map[[16]byte]struct{}{}
	}
	return s
}

// accept remembers a nonce and reports whether it was new.
func (s *nonceSet) accept(n [16]byte, at time.Time) bool {
	g := at.Unix() / int64(fallbackWindow/time.Second)
	s.mu.Lock()
	defer s.mu.Unlock()
	if d := g - s.gen; d != 0 {
		if d < 0 || d >= nonceGens {
			// The clock went backwards, or so long passed that nothing
			// remembered can still be valid. Start clean either way.
			for i := range s.gens {
				s.gens[i] = map[[16]byte]struct{}{}
			}
		} else {
			for ; d > 0; d-- {
				copy(s.gens[1:], s.gens[:nonceGens-1])
				s.gens[0] = map[[16]byte]struct{}{}
			}
		}
		s.gen = g
	}
	for i := range s.gens {
		if _, ok := s.gens[i][n]; ok {
			return false
		}
	}
	s.gens[0][n] = struct{}{}
	return true
}

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
// happens next has to send them on: this end must not consume a byte it might
// have to hand to somebody else.
func readClientHello(c net.Conn) (raw, sessionID []byte, sni string, err error) {
	var hdr [5]byte
	if _, err = io.ReadFull(c, hdr[:]); err != nil {
		return nil, nil, "", err
	}
	// A handshake record, and one big enough to be a hello but not absurd.
	if hdr[0] != 0x16 {
		return nil, nil, "", errNotOurs
	}
	n := int(binary.BigEndian.Uint16(hdr[3:5]))
	if n < 42 || n > 16384 {
		return nil, nil, "", errNotOurs
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
	if len(b) < 4 || b[0] != 0x01 { // handshake type, then a 3-byte length
		return nil, ""
	}
	b = b[4:]
	if len(b) < 34 { // client_version, random
		return nil, ""
	}
	b = b[34:]
	if len(b) < 1 {
		return nil, ""
	}
	sl := int(b[0])
	if len(b) < 1+sl {
		return nil, ""
	}
	sessionID = b[1 : 1+sl]
	b = b[1+sl:]
	if len(b) < 2 { // cipher suites
		return sessionID, ""
	}
	cl := int(binary.BigEndian.Uint16(b[:2]))
	if len(b) < 2+cl {
		return sessionID, ""
	}
	b = b[2+cl:]
	if len(b) < 1 { // compression methods
		return sessionID, ""
	}
	ml := int(b[0])
	if len(b) < 1+ml {
		return sessionID, ""
	}
	b = b[1+ml:]
	if len(b) < 2 { // extensions
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
			return sessionID, parseSNI(b[4 : 4+ln])
		}
		b = b[4+ln:]
	}
	return sessionID, ""
}

func parseSNI(b []byte) string {
	if len(b) < 2 { // server_name_list length
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

// publicAddressOf resolves a name a prober asked for and hands back one public
// address of it, or nil. The address is what gets dialled, rather than the
// name a second time, so what was checked is what is connected to.
func publicAddressOf(host string) net.IP {
	ips, err := net.LookupIP(host)
	if err != nil {
		return nil
	}
	for _, ip := range ips {
		if ip4 := ip.To4(); ip4 != nil && publicIP(ip4) {
			return ip4
		}
	}
	return nil
}

// publicIP is "an address the whole internet could have reached by itself":
// not loopback, not the private ranges, not link local, not the carrier grade
// block, not multicast.
func publicIP(ip net.IP) bool {
	if ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() ||
		ip.IsMulticast() || ip.IsUnspecified() {
		return false
	}
	if ip4 := ip.To4(); ip4 != nil && ip4[0] == 100 && ip4[1]&0xc0 == 64 {
		return false // 100.64.0.0/10
	}
	return true
}

// validHostname keeps a forged SNI from turning this server into an open relay
// to anywhere: what comes back out of it is only ever a hostname.
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
