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
	wsOpCont   = 0x0
	wsOpText   = 0x1
	wsOpBinary = 0x2
	wsOpClose  = 0x8
	wsOpPing   = 0x9
	wsOpPong   = 0xA
)

const (
	// RFC 6455 5.5: a control frame carries at most 125 bytes and is never
	// fragmented. Both are worth checking, because a peer that breaks either
	// is not sending what we are about to parse.
	wsMaxControl = 125

	// The largest frame we will read. Our own records stop at maxFrame, so
	// anything past it is a bug on the far side or somebody probing - and
	// allocating whatever was asked for is how that becomes a way to run this
	// server out of memory.
	wsMaxFrame = maxFrame + 1024

	// How long a pong may wait for the writer before it is given up on.
	// Losing a pong costs nothing. Blocking the reader costs the carrier.
	wsControlWait = 2 * time.Second
)

// The close frame's status code: 1000, a normal end.
var wsCloseNormal = []byte{0x03, 0xE8}

// wsConn is a net.Conn over RFC 6455 frames. The braid above it sees a byte
// stream and never learns there is framing underneath.
//
// Two things about that stream matter and both were got wrong before:
//
//	a message may arrive in pieces. The first frame carries the opcode and
//	the rest carry opcode 0, and an endpoint that does not join them back
//	together loses everything after the first piece. We never fragment - but
//	a proxy, a CDN or anything that reassembles and re-splits a stream does,
//	and it is entitled to. The old reader had no case for opcode 0, so those
//	bytes fell past the switch and were dropped, with no error anywhere and
//	the carrier still counted as up.
//
//	a control frame may arrive in the middle of one. A ping between two
//	fragments is normal and must be answered without disturbing the message
//	being assembled.
//
// Because this is a stream and not a message channel, each piece is handed up
// as it arrives rather than held until the message ends: nothing above cares
// where a message began, and waiting for the end would add latency for nothing.
type wsConn struct {
	c    net.Conn
	br   *bufio.Reader
	mask bool // clients mask, servers must not

	// A channel rather than a Mutex so a control frame can give up on it.
	// See writeControl.
	wmu  chan struct{}
	wbuf []byte // one frame, header and payload, reused

	rmu   sync.Mutex
	rest  []byte // what is left of the frame last read
	inMsg bool   // a fragmented message is part way through
	dbuf  []byte // data payloads, reused
	cbuf  []byte // control payloads, kept apart so a ping cannot clobber data

	closeOnce sync.Once
}

func newWSConn(c net.Conn, br *bufio.Reader, clientSide bool) *wsConn {
	if br == nil {
		br = bufio.NewReaderSize(c, 32*1024)
	}
	return &wsConn{
		c:    c,
		br:   br,
		mask: clientSide,
		wmu:  make(chan struct{}, 1),
	}
}

type wsFrame struct {
	fin     bool
	op      byte
	payload []byte
}

func (f wsFrame) control() bool { return f.op >= 0x8 }

func (w *wsConn) Read(p []byte) (int, error) {
	w.rmu.Lock()
	defer w.rmu.Unlock()
	for len(w.rest) == 0 {
		f, err := w.readFrame()
		if err != nil {
			return 0, err
		}
		switch f.op {
		case wsOpBinary, wsOpText:
			if w.inMsg {
				return 0, fmt.Errorf("ws: a message began before the last one ended")
			}
			w.inMsg = !f.fin
			w.rest = f.payload
		case wsOpCont:
			if !w.inMsg {
				return 0, fmt.Errorf("ws: a continuation with nothing to continue")
			}
			w.inMsg = !f.fin
			w.rest = f.payload
		case wsOpPing:
			// Best effort: see writeControl for why this must not block.
			w.writeControl(wsOpPong, f.payload)
		case wsOpPong:
			// Nothing asked for it and nothing is waiting on it.
		case wsOpClose:
			w.writeControl(wsOpClose, wsCloseNormal)
			return 0, io.EOF
		default:
			// Refused rather than skipped. Skipping is what hid the fault
			// this replaced: an opcode nobody handles is a stream nobody
			// understands, and carrying on reads the next frame out of the
			// middle of this one.
			return 0, fmt.Errorf("ws: opcode %#x is not one we speak", f.op)
		}
	}
	n := copy(p, w.rest)
	w.rest = w.rest[n:]
	return n, nil
}

func (w *wsConn) Write(p []byte) (int, error) {
	w.wmu <- struct{}{}
	defer func() { <-w.wmu }()
	if err := w.frameOut(wsOpBinary, p); err != nil {
		return 0, err
	}
	return len(p), nil
}

// buf hands back a scratch buffer of exactly n bytes. Data and control frames
// keep separate ones so that answering a ping cannot overwrite the payload the
// reader is part way through handing up.
func (w *wsConn) buf(n int, control bool) []byte {
	if control {
		if cap(w.cbuf) < n {
			w.cbuf = make([]byte, n)
		}
		return w.cbuf[:n]
	}
	if cap(w.dbuf) < n {
		w.dbuf = make([]byte, n)
	}
	return w.dbuf[:n]
}

func (w *wsConn) readFrame() (wsFrame, error) {
	var f wsFrame
	var h [2]byte
	if _, err := io.ReadFull(w.br, h[:]); err != nil {
		return f, err
	}
	f.fin = h[0]&0x80 != 0
	if h[0]&0x70 != 0 {
		// RSV1-3 mean an extension was negotiated. We negotiate none, so the
		// frame is not shaped the way we are about to read it, and reading on
		// would be reading rubbish and calling it payload.
		return f, fmt.Errorf("ws: reserved bits set, but no extension was agreed")
	}
	f.op = h[0] & 0x0f
	masked := h[1]&0x80 != 0
	n := int(h[1] & 0x7f)
	switch n {
	case 126:
		var e [2]byte
		if _, err := io.ReadFull(w.br, e[:]); err != nil {
			return f, err
		}
		n = int(binary.BigEndian.Uint16(e[:]))
	case 127:
		var e [8]byte
		if _, err := io.ReadFull(w.br, e[:]); err != nil {
			return f, err
		}
		v := binary.BigEndian.Uint64(e[:])
		if v > wsMaxFrame {
			return f, fmt.Errorf("ws: a frame of %d bytes was refused", v)
		}
		n = int(v)
	}
	if n > wsMaxFrame {
		return f, fmt.Errorf("ws: a frame of %d bytes was refused", n)
	}
	// RFC 6455 5.1: a client masks every frame it sends, a server masks none.
	// Getting it the wrong way round is a peer that is not talking WebSocket
	// to us - or a middlebox rewriting frames it should be passing through.
	if masked == w.mask {
		if w.mask {
			return f, fmt.Errorf("ws: the server masked a frame")
		}
		return f, fmt.Errorf("ws: the client sent an unmasked frame")
	}
	if f.control() {
		if !f.fin {
			return f, fmt.Errorf("ws: a control frame arrived fragmented")
		}
		if n > wsMaxControl {
			return f, fmt.Errorf("ws: a control frame carried %d bytes", n)
		}
	}
	var key [4]byte
	if masked {
		if _, err := io.ReadFull(w.br, key[:]); err != nil {
			return f, err
		}
	}
	body := w.buf(n, f.control())
	if _, err := io.ReadFull(w.br, body); err != nil {
		return f, err
	}
	if masked {
		for i := range body {
			body[i] ^= key[i&3]
		}
	}
	f.payload = body
	return f, nil
}

// frameOut writes one whole frame. The caller holds the write lock.
//
// Header and payload go out in a single write, out of a buffer that is grown
// once and then reused - a frame is up to 128 KiB and this carries video, so
// an allocation and a copy per frame is not free. Two writes would not be
// either: the header would leave in its own packet.
func (w *wsConn) frameOut(op byte, payload []byte) error {
	n := len(payload)
	if need := 14 + n; cap(w.wbuf) < need {
		w.wbuf = make([]byte, 0, need)
	}
	b := w.wbuf[:0]

	// FIN is always set: we hand every write out as one whole message. What
	// this had to learn was how to READ a fragmented one.
	b = append(b, 0x80|op)
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
	b = append(b, lenByte)
	switch {
	case n >= 1<<16:
		var e [8]byte
		binary.BigEndian.PutUint64(e[:], uint64(n))
		b = append(b, e[:]...)
	case n >= 126:
		var e [2]byte
		binary.BigEndian.PutUint16(e[:], uint16(n))
		b = append(b, e[:]...)
	}

	if !w.mask {
		b = append(b, payload...)
	} else {
		// A client masks with a fresh key per frame. It buys no secrecy - the
		// key travels in the header - but a proxy that sees an unmasked client
		// frame is entitled to hang up, and some do.
		var key [4]byte
		if _, err := rand.Read(key[:]); err != nil {
			return err
		}
		b = append(b, key[:]...)
		for i := 0; i < n; i++ {
			b = append(b, payload[i]^key[i&3])
		}
	}

	_, err := w.c.Write(b)
	w.wbuf = b // keep whatever capacity it grew to
	return err
}

// writeControl sends a ping, pong or close without ever waiting long for the
// writer.
//
// The reader answers pings, and the writer may be part way through a frame
// that has not gone out because the far end has stopped reading. If the reader
// waited for the writer there, it would stop reading too - and two ends each
// waiting for the other to read is a carrier that is up, idle, and finished.
// A dropped pong is worth nothing next to that.
func (w *wsConn) writeControl(op byte, payload []byte) error {
	if len(payload) > wsMaxControl {
		payload = payload[:wsMaxControl]
	}
	select {
	case w.wmu <- struct{}{}:
	default:
		t := time.NewTimer(wsControlWait)
		defer t.Stop()
		select {
		case w.wmu <- struct{}{}:
		case <-t.C:
			return nil
		}
	}
	defer func() { <-w.wmu }()
	return w.frameOut(op, payload)
}

func (w *wsConn) Close() error {
	w.closeOnce.Do(func() {
		// Say goodbye if it can be said quickly. Never wait on it: the point
		// of Close is that this carrier is done with.
		w.c.SetWriteDeadline(time.Now().Add(time.Second))
		w.writeControl(wsOpClose, wsCloseNormal)
	})
	return w.c.Close()
}

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

// The name this end presents: the TLS SNI and the HTTP Host header.
//
// A CDN routes on the name, so when there is a domain it wins over whatever
// address is being dialled - that is what lets a carrier go to an edge and
// still arrive at the right origin. Without one it falls back to the address,
// which is right for a tunnel that goes straight to the server.
func wsHostFor(cfg *Config) string {
	if cfg.WSHost != "" {
		return cfg.WSHost
	}
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
	// Only the header read is bounded. A carrier is hijacked out of this
	// server and then lives for hours, so a read, write or idle timeout here
	// would be a clock quietly killing the tunnel.
	err := srv.Serve(t.ln)
	select {
	case <-t.done:
	default:
		// The listener stopped but the tunnel did not. Carriers already up
		// keep working, so nothing else notices - and no new one can ever
		// arrive. Say so, or this is a tunnel that degrades in silence.
		logWarn("ws: stopped accepting carriers: %v", err)
	}
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
		// lesson the echo transport taught, in a different shape. But say it
		// happened: dropping a carrier on the floor and letting the far end
		// retry forever is exactly the kind of quiet failure that leaves
		// somebody staring at "0 of 16" with nothing to go on.
		logWarn("ws: no room to accept a carrier from %s, dropped", c.RemoteAddr())
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
