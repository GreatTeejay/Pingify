package main

import (
	"bufio"
	"crypto/rand"
	"crypto/sha1"
	"crypto/tls"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

// ---------------------------------------------------------------------------
// the WebSocket transports
//
// Everything else here looks like what it is. TCP looks like a long-lived TCP
// connection, ICMP looks like a great many pings, GRE looks like GRE. On a
// path that only passes web traffic, none of them go anywhere.
//
// This one is an HTTP request that becomes a WebSocket, which is what a chat
// application, a live dashboard and a stock ticker all look like. Two things
// follow from that and both matter more than the framing:
//
//	it goes where HTTP goes. A proxy that passes 80 and 443 and nothing else
//	passes this.
//
//	it can sit behind a CDN. Point the tunnel at a CDN-proxied hostname and
//	the Kharej server's address never appears on the wire at all - the Iran
//	server is talking to Cloudflare, and blocking one address does not end
//	the tunnel.
//
// The frames are RFC 6455 rather than a raw stream after the upgrade, because
// a CDN parses them. A stream of unframed bytes behind a WebSocket handshake
// is not a WebSocket and does not survive the first middlebox that looks.
//
// Written against the standard library. Not because a module was unavailable -
// they are - but because this is 300 lines of well-specified framing, and one
// less dependency in a tool whose job is not being interfered with.
// ---------------------------------------------------------------------------

// The constant RFC 6455 requires the server to hash with the client's key.
const wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

const (
	wsOpBinary = 0x2
	wsOpClose  = 0x8
	wsOpPing   = 0x9
	wsOpPong   = 0xA
)

// wsConn is a net.Conn over WebSocket binary frames. The braid above it sees a
// byte stream and never learns there is framing underneath.
type wsConn struct {
	c    net.Conn
	br   *bufio.Reader
	mask bool // clients mask, servers must not

	wmu sync.Mutex

	rmu  sync.Mutex
	rest []byte // what is left of the frame last read
}

func newWSConn(c net.Conn, br *bufio.Reader, clientSide bool) *wsConn {
	if br == nil {
		br = bufio.NewReaderSize(c, 32*1024)
	}
	return &wsConn{c: c, br: br, mask: clientSide}
}

func (w *wsConn) Read(p []byte) (int, error) {
	w.rmu.Lock()
	defer w.rmu.Unlock()
	for len(w.rest) == 0 {
		op, payload, err := w.readFrame()
		if err != nil {
			return 0, err
		}
		switch op {
		case wsOpBinary:
			w.rest = payload
		case wsOpPing:
			w.writeFrame(wsOpPong, payload)
		case wsOpClose:
			return 0, io.EOF
		}
		// anything else - a pong, a continuation we do not use - is read past
	}
	n := copy(p, w.rest)
	w.rest = w.rest[n:]
	return n, nil
}

func (w *wsConn) Write(p []byte) (int, error) {
	if err := w.writeFrame(wsOpBinary, p); err != nil {
		return 0, err
	}
	return len(p), nil
}

func (w *wsConn) readFrame() (byte, []byte, error) {
	var h [2]byte
	if _, err := io.ReadFull(w.br, h[:]); err != nil {
		return 0, nil, err
	}
	op := h[0] & 0x0f
	masked := h[1]&0x80 != 0
	n := int(h[1] & 0x7f)
	switch n {
	case 126:
		var e [2]byte
		if _, err := io.ReadFull(w.br, e[:]); err != nil {
			return 0, nil, err
		}
		n = int(binary.BigEndian.Uint16(e[:]))
	case 127:
		var e [8]byte
		if _, err := io.ReadFull(w.br, e[:]); err != nil {
			return 0, nil, err
		}
		v := binary.BigEndian.Uint64(e[:])
		// A frame this large is not something we send, so it is either a bug
		// on the other side or somebody probing. Refuse it rather than
		// allocating whatever was asked for.
		if v > 1<<20 {
			return 0, nil, fmt.Errorf("ws: frame of %d bytes refused", v)
		}
		n = int(v)
	}
	var key [4]byte
	if masked {
		if _, err := io.ReadFull(w.br, key[:]); err != nil {
			return 0, nil, err
		}
	}
	payload := make([]byte, n)
	if _, err := io.ReadFull(w.br, payload); err != nil {
		return 0, nil, err
	}
	if masked {
		for i := range payload {
			payload[i] ^= key[i%4]
		}
	}
	return op, payload, nil
}

func (w *wsConn) writeFrame(op byte, payload []byte) error {
	w.wmu.Lock()
	defer w.wmu.Unlock()

	hdr := make([]byte, 0, 14)
	hdr = append(hdr, 0x80|op) // FIN set: we never fragment
	n := len(payload)
	var lenByte byte
	switch {
	case n < 126:
		lenByte = byte(n)
	case n < 1<<16:
		lenByte = 126
	default:
		lenByte = 127
	}
	if w.mask {
		lenByte |= 0x80
	}
	hdr = append(hdr, lenByte)
	switch {
	case n >= 1<<16:
		var e [8]byte
		binary.BigEndian.PutUint64(e[:], uint64(n))
		hdr = append(hdr, e[:]...)
	case n >= 126:
		var e [2]byte
		binary.BigEndian.PutUint16(e[:], uint16(n))
		hdr = append(hdr, e[:]...)
	}

	body := payload
	if w.mask {
		// RFC 6455 requires a client to mask every frame with a fresh key.
		// It buys no secrecy - the key travels with the frame - but a proxy
		// that sees an unmasked client frame is entitled to hang up.
		var key [4]byte
		if _, err := rand.Read(key[:]); err != nil {
			return err
		}
		hdr = append(hdr, key[:]...)
		body = make([]byte, n)
		for i := range payload {
			body[i] = payload[i] ^ key[i%4]
		}
	}
	if _, err := w.c.Write(append(hdr, body...)); err != nil {
		return err
	}
	return nil
}

func (w *wsConn) Close() error                       { return w.c.Close() }
func (w *wsConn) LocalAddr() net.Addr                { return w.c.LocalAddr() }
func (w *wsConn) RemoteAddr() net.Addr               { return w.c.RemoteAddr() }
func (w *wsConn) SetDeadline(t time.Time) error      { return w.c.SetDeadline(t) }
func (w *wsConn) SetReadDeadline(t time.Time) error  { return w.c.SetReadDeadline(t) }
func (w *wsConn) SetWriteDeadline(t time.Time) error { return w.c.SetWriteDeadline(t) }

// ---------------------------------------------------------------------------
// the handshake
// ---------------------------------------------------------------------------

func wsAccept(key string) string {
	h := sha1.New()
	h.Write([]byte(key + wsGUID))
	return base64.StdEncoding.EncodeToString(h.Sum(nil))
}

// wsDial opens one carrier: a plain TCP or TLS connection, an HTTP upgrade
// request over it, and the byte stream that follows.
func wsDial(addr, host, path string, useTLS bool, timeout time.Duration) (net.Conn, error) {
	var c net.Conn
	var err error
	d := &net.Dialer{Timeout: timeout}
	if useTLS {
		// The certificate is not verified: it is usually self-signed, and the
		// tunnel's own token is what proves who is on the other end. See the
		// handshake the braid runs immediately after this one.
		c, err = tls.DialWithDialer(d, "tcp", addr, &tls.Config{
			ServerName:         host,
			InsecureSkipVerify: true,
			NextProtos:         []string{"http/1.1"},
		})
	} else {
		c, err = d.Dial("tcp", addr)
	}
	if err != nil {
		return nil, err
	}

	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		c.Close()
		return nil, err
	}
	key := base64.StdEncoding.EncodeToString(raw[:])

	req := "GET " + path + " HTTP/1.1\r\n" +
		"Host: " + host + "\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Key: " + key + "\r\n" +
		"Sec-WebSocket-Version: 13\r\n" +
		"User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
		"(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36\r\n" +
		"\r\n"
	if _, err := c.Write([]byte(req)); err != nil {
		c.Close()
		return nil, err
	}

	br := bufio.NewReaderSize(c, 32*1024)
	resp, err := http.ReadResponse(br, nil)
	if err != nil {
		c.Close()
		return nil, err
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusSwitchingProtocols {
		c.Close()
		return nil, fmt.Errorf("ws: the server answered %s, not an upgrade", resp.Status)
	}
	if !strings.EqualFold(resp.Header.Get("Upgrade"), "websocket") ||
		resp.Header.Get("Sec-WebSocket-Accept") != wsAccept(key) {
		c.Close()
		return nil, fmt.Errorf("ws: the upgrade did not answer our key")
	}
	return newWSConn(c, br, true), nil
}

// ---------------------------------------------------------------------------
// the transport
// ---------------------------------------------------------------------------

type wsTransport struct {
	cfg    *Config
	useTLS bool
	path   string
	host   string

	ln      net.Listener
	inbound chan net.Conn
	done    chan struct{}
	once    sync.Once
}

func newWSTransport(cfg *Config, useTLS bool) (*wsTransport, error) {
	t := &wsTransport{
		cfg:     cfg,
		useTLS:  useTLS,
		path:    wsPathFor(cfg),
		host:    wsHostFor(cfg),
		inbound: make(chan net.Conn, 64),
		done:    make(chan struct{}),
	}
	if cfg.Connect != "" {
		return t, nil // this end dials; it binds nothing
	}

	ln, err := net.Listen("tcp", cfg.Listen)
	if err != nil {
		return nil, err
	}
	if useTLS {
		cert, err := wsCertificate(cfg)
		if err != nil {
			ln.Close()
			return nil, err
		}
		ln = tls.NewListener(ln, &tls.Config{
			Certificates: []tls.Certificate{cert},
			NextProtos:   []string{"http/1.1"},
			MinVersion:   tls.VersionTLS12,
		})
	}
	t.ln = ln
	go t.serve()
	return t, nil
}

// The path a carrier asks for. Derived from the token, so it is neither
// guessable from outside nor something anybody has to agree by hand: both ends
// reach the same one from the same secret. Anything asking for a different
// path is answered like an ordinary web server, and learns nothing.
func wsPathFor(cfg *Config) string {
	k := hkdfExpand(hkdfExtract([]byte("pingify/v3 ws path"), cfg.key()), []byte("path"), 9)
	return "/" + strings.TrimRight(base64.RawURLEncoding.EncodeToString(k), "=")
}

// The Host header. A CDN routes on it, so it has to be the hostname the tunnel
// was pointed at rather than an address.
func wsHostFor(cfg *Config) string {
	target := cfg.Connect
	if target == "" {
		target = cfg.Listen
	}
	if h, _, err := net.SplitHostPort(target); err == nil && h != "" {
		return h
	}
	return target
}

func (t *wsTransport) serve() {
	srv := &http.Server{
		ReadHeaderTimeout: 10 * time.Second,
		Handler:           http.HandlerFunc(t.handle),
	}
	srv.Serve(t.ln)
}

func (t *wsTransport) handle(w http.ResponseWriter, r *http.Request) {
	key := r.Header.Get("Sec-WebSocket-Key")
	if r.URL.Path != t.path || key == "" ||
		!strings.EqualFold(r.Header.Get("Upgrade"), "websocket") {
		// Not a carrier. Answer the way a web server with nothing on it
		// answers, so a scanner learns that and no more.
		wsDecoy(w, r)
		return
	}
	hj, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "", http.StatusInternalServerError)
		return
	}
	c, br, err := hj.Hijack()
	if err != nil {
		return
	}
	resp := "HTTP/1.1 101 Switching Protocols\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: " + wsAccept(key) + "\r\n\r\n"
	if _, err := c.Write([]byte(resp)); err != nil {
		c.Close()
		return
	}
	select {
	case t.inbound <- newWSConn(c, br.Reader, false):
	case <-t.done:
		c.Close()
	default:
		// Never block the HTTP handler waiting for an acceptor - the same
		// lesson the echo transport taught, in a different shape.
		c.Close()
	}
}

func (t *wsTransport) Dial(idx int) (net.Conn, error) {
	return wsDial(t.cfg.Connect, t.host, t.path, t.useTLS,
		time.Duration(t.cfg.DialTimeout)*time.Second)
}

func (t *wsTransport) Accept() (net.Conn, error) {
	if t.ln == nil {
		return nil, fmt.Errorf("ws: this end dials, it does not accept")
	}
	select {
	case c := <-t.inbound:
		return c, nil
	case <-t.done:
		return nil, io.EOF
	}
}

func (t *wsTransport) Close() error {
	t.once.Do(func() { close(t.done) })
	if t.ln != nil {
		return t.ln.Close()
	}
	return nil
}

func (t *wsTransport) Name() string {
	if t.useTLS {
		return "wss"
	}
	return "ws"
}
