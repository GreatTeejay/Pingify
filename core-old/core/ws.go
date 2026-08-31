package main

import (
	"bufio"
	"crypto/rand"
	"crypto/sha1"
	"crypto/tls"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	stdlog "log"
	"net"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// ---------------------------------------------------------------------------
// ws: one WebSocket, with the whole tunnel multiplexed onto it
//
// Every other transport here is a braid: a number of connections sharing the
// traffic between them, so that loss on one does not stall the rest. That is
// the right shape for a long, lossy path and the wrong shape for this one.
//
// Twenty WebSocket connections, opened from one address inside forty
// milliseconds of each other, each sending a small binary frame every ten
// seconds and never closing, is not what any application on the web does. It
// is not a subtle tell either: it is the most recognisable thing about a
// tunnel that has otherwise gone to some trouble to look ordinary. The braided
// version did exactly that, and on a real Iran-Europe path the carriers came
// up, carried a few kilobytes, and went deaf in both directions at once, over
// and over - which is what a flow looks like after something has watched it
// long enough to decide.
//
// So this one opens a single connection, and the whole tunnel rides it.
//
// Nothing above had to be written for that. A carrier here has always been a
// multiplexer: streams are opened, fed and closed on it by id, with a credit
// window each, dozens at a time. Giving the pool one carrier is therefore
// exactly what mux means everywhere else it is offered - many streams over one
// connection - using the multiplexer that was already carrying them.
//
// What it costs is real and worth naming. One connection is one congestion
// window for everything, so a lost segment holds up every stream behind it;
// and there is no second carrier to hold the tunnel open while a broken one
// reconnects. Against that: a shape nothing has a reason to look at twice,
// which on this path is the difference between a tunnel and no tunnel. The
// keepalive below is part of paying that price - a single connection has to
// notice quickly that it has died, because nothing is moving while it works
// that out.
//
// The framing is RFC 6455 rather than a raw stream after the upgrade, because
// anything that parses WebSocket will parse this. A stream of unframed bytes
// behind a WebSocket handshake is not a WebSocket and does not survive the
// first middlebox that looks.
// ---------------------------------------------------------------------------

// How many WebSockets a ws or wss tunnel opens, and the most it will.
//
// Each one multiplexes every stream that lands on it, so this is not "how many
// connections the traffic needs" - it is how many places the tunnel can be cut
// at once and carry on. Two is the default: one is the quietest shape there is
// and also a tunnel with no spare, and a second costs nothing anybody is
// looking for, because a browser holds two or three open all day. Four is the
// ceiling, because twenty was the shape that got the braided version noticed.
const (
	wsConnsDefault = 2
	wsMaxConns     = 4
)

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

	// The largest frame we put on the wire.
	//
	// Not a limit of the protocol - a frame may be enormous - but of what
	// ordinary WebSocket traffic looks like. A browser sends kilobytes at a
	// time. Our own records reach 128 KiB, and a frame that size needs the
	// eight-byte length field, which is rare enough in the wild that plenty
	// of middleboxes have never carried one.
	//
	// The layer above is a byte stream with no message boundaries of its own,
	// so each piece goes out as a whole message rather than a fragment. That
	// is also what a chat, a dashboard or a live feed looks like: a great many
	// small binary messages, one after another.
	wsMaxSend = 16 * 1024

	// How long a control frame may wait for the writer before it is given up
	// on. Losing a pong costs nothing. Blocking the reader costs the
	// connection, and here the connection is the whole tunnel.
	wsControlWait = 2 * time.Second

	// The WebSocket keepalive: a Ping frame on this interval, and the
	// connection is finished when this many go unanswered.
	//
	// Two reasons, and the second is the one that matters. It is what a real
	// WebSocket does - servers ping idle sockets, and a connection that never
	// exchanges a control frame in an hour is itself unusual. And with one
	// connection carrying everything, a path that has quietly stopped
	// forwarding has to be found in tens of seconds rather than the minute
	// the multiplexer's own keepalive is allowed to take, because nothing at
	// all is getting through while we wait for it.
	wsPingEvery   = 20 * time.Second
	wsPingMissed  = 3
	wsPongOverdue = wsPingEvery*wsPingMissed + 5*time.Second
)

// The close frame's status code: 1000, a normal end.
var wsCloseNormal = []byte{0x03, 0xE8}

// A control frame that could not get the writer promptly is not a broken
// socket. It usually means a large data frame is still leaving. Keepalive may
// skip that ping, while a real write error must tear the connection down now.
var errWSControlBusy = errors.New("ws: data writer busy")

// net/http reports every random TLS scanner as a server error by default.
// Public port 443 receives old SSL, malformed ClientHello and cipher probes
// all day; they are not tunnel failures and should not drown the live log.
// Real listener failures are still reported by serve below.
type wsHTTPErrorWriter struct{}

func (wsHTTPErrorWriter) Write(p []byte) (int, error) {
	msg := strings.TrimSpace(string(p))
	if strings.Contains(msg, "TLS handshake error") {
		logDebug("wss rejected an invalid TLS probe: %s", msg)
	} else if msg != "" {
		logWarn("web server: %s", msg)
	}
	return len(p), nil
}

// wsMask XORs src into dst with the frame's key, eight bytes at a time.
//
// A byte at a time is the obvious way and on a full frame it is the difference
// between microseconds and tens of them - per frame, on every frame the client
// sends, on a link carrying video. dst and src may be the same slice, which is
// how the reader unmasks in place.
func wsMask(dst, src []byte, key [4]byte) {
	var k [8]byte
	copy(k[0:4], key[:])
	copy(k[4:8], key[:])
	kw := binary.LittleEndian.Uint64(k[:])
	n := len(src)
	i := 0
	for ; i+8 <= n; i += 8 {
		binary.LittleEndian.PutUint64(dst[i:], binary.LittleEndian.Uint64(src[i:])^kw)
	}
	// i is a multiple of eight here, so i&3 is zero and the tail picks the key
	// up exactly where the wide loop left it.
	for ; i < n; i++ {
		dst[i] = src[i] ^ key[i&3]
	}
}

// wsConn is a net.Conn over RFC 6455 frames. The multiplexer above it sees a
// byte stream and never learns there is framing underneath.
//
// Two things about that stream matter:
//
//	a message may arrive in pieces. The first frame carries the opcode and
//	the rest carry opcode 0, and an endpoint that does not join them back
//	together loses everything after the first piece. We never fragment - but
//	a proxy, a CDN or anything that reassembles and re-splits a stream does,
//	and it is entitled to.
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
	wbuf []byte // one write, header and payload, reused

	// The deadline the layer above last asked for, so that a control frame can
	// put its own on for the length of one write and then hand it back. Held
	// across the whole borrow: the writer above sets its deadline before it
	// asks for the write lock, and giving back a value read before that would
	// leave an expired deadline on a socket about to be written to.
	dmu sync.Mutex
	wdl time.Time

	rmu   sync.Mutex
	rest  []byte // what is left of the frame last read
	inMsg bool   // a fragmented message is part way through
	dbuf  []byte // data payloads, reused
	cbuf  []byte // control payloads, kept apart so a ping cannot clobber data

	lastSeen int64 // unix nano; any received frame proves the path is alive

	// Why this end closed, when this end is the one that closed. See reason.
	whyMu sync.Mutex
	why   string
	done  chan struct{}
	once  sync.Once
}

func newWSConn(c net.Conn, br *bufio.Reader, clientSide bool) *wsConn {
	if br == nil {
		br = bufio.NewReaderSize(c, 32*1024)
	}
	w := &wsConn{
		c:    c,
		br:   br,
		mask: clientSide,
		wmu:  make(chan struct{}, 1),
		done: make(chan struct{}),
	}
	atomic.StoreInt64(&w.lastSeen, time.Now().UnixNano())
	go w.keepalive()
	return w
}

// keepalive pings, and hangs up on a path that has stopped answering.
//
// Both ends run it. A ping is answered by the reader below without troubling
// anything above, so an idle connection exchanges two control frames an
// interval and looks like every other long-lived WebSocket on the internet.
//
// The hanging up is the point. When a path stops forwarding a flow it does not
// close it: both ends are left holding a socket that is open, writable, and
// carrying nothing at all. The layer above works that out on its own clock,
// which has a floor of a minute because the two ends are configured separately
// and one of them must not hang up on the other for being slower. A single
// connection cannot afford that minute, so this end reaches the same
// conclusion sooner and closes, which turns a silent hole into a reconnect.
// giveUp closes the connection and remembers what for, so that the read which
// finds out says something an operator can act on.
func (w *wsConn) giveUp(format string, a ...interface{}) {
	w.whyMu.Lock()
	if w.why == "" {
		w.why = fmt.Sprintf(format, a...)
	}
	w.whyMu.Unlock()
	w.abort()
}

// reason puts our words on the socket's error when the close was ours.
//
// Go reports a read on a socket somebody in this process has shut as "use of
// closed network connection", which is true and useless: it names the symptom
// of a decision taken elsewhere and leaves an operator reading a log that
// looks like a network fault when it is this end giving up on purpose. That
// line cost real time in the field. When the decision was ours, say what it
// was.
func (w *wsConn) reason(err error) error {
	w.whyMu.Lock()
	why := w.why
	w.whyMu.Unlock()
	if why == "" {
		return err
	}
	return errors.New(why)
}

func (w *wsConn) keepalive() {
	t := time.NewTicker(wsPingEvery)
	defer t.Stop()
	for {
		select {
		case <-w.done:
			return
		case <-t.C:
		}
		if !w.keepaliveStep() {
			return
		}
	}
}

func (w *wsConn) keepaliveStep() bool {
	if since := time.Since(time.Unix(0, atomic.LoadInt64(&w.lastSeen))); since > wsPongOverdue {
		logDebug("ws: no frame from %s for %s - the path is carrying nothing, closing",
			w.c.RemoteAddr(), since.Round(time.Second))
		w.giveUp("nothing arrived for %s, not even an answer to a ping - "+
			"this end gave up on the path and closed", since.Round(time.Second))
		return false
	}
	var payload [4]byte
	binary.BigEndian.PutUint32(payload[:], uint32(time.Now().Unix()))
	if err := w.writeControl(wsOpPing, payload[:]); err != nil {
		if errors.Is(err, errWSControlBusy) {
			return true // data is already using the socket; try next tick
		}
		logDebug("ws: ping to %s: %v", w.c.RemoteAddr(), err)
		w.abort()
		return false
	}
	return true
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
			return 0, w.reason(err)
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
			// Best effort: see writeControl for why this must not block. Said
			// out loud when it fails, because a peer that pings and hears
			// nothing back hangs up at its own timeout, and that looks from
			// here like the far end simply going away.
			if err := w.writeControl(wsOpPong, f.payload); err != nil {
				logDebug("ws: could not answer a ping: %v", err)
			}
		case wsOpPong:
			atomic.StoreInt64(&w.lastSeen, time.Now().UnixNano())
		case wsOpClose:
			w.writeControl(wsOpClose, wsCloseNormal)
			return 0, io.EOF
		default:
			// Refused rather than skipped. An opcode nobody handles is a
			// stream nobody understands, and carrying on reads the next frame
			// out of the middle of this one.
			return 0, fmt.Errorf("ws: opcode %#x is not one we speak", f.op)
		}
	}
	n := copy(p, w.rest)
	w.rest = w.rest[n:]
	return n, nil
}

func (w *wsConn) Write(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	w.wmu <- struct{}{}
	defer func() { <-w.wmu }()

	// Split into ordinary-sized frames, but build them all into one buffer and
	// put them on the wire in a single write - so looking like everyone else
	// costs nothing in system calls.
	b := w.wbuf[:0]
	var err error
	for off := 0; off < len(p); {
		end := off + wsMaxSend
		if end > len(p) {
			end = len(p)
		}
		if b, err = w.appendFrame(b, wsOpBinary, p[off:end]); err != nil {
			w.wbuf = b
			return 0, err
		}
		off = end
	}
	err = writeFull(w.c, b)
	w.wbuf = b
	if err != nil {
		return 0, w.reason(err)
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
		wsMask(body, body, key)
	}
	// A data frame is every bit as strong a liveness signal as a pong. Under
	// heavy one-way traffic a pong can wait behind a large data write; closing
	// a connection that is visibly delivering data is a false timeout.
	atomic.StoreInt64(&w.lastSeen, time.Now().UnixNano())
	f.payload = body
	return f, nil
}

// frameOut writes one whole frame. The caller holds the write lock.
func (w *wsConn) frameOut(op byte, payload []byte) error {
	b, err := w.appendFrame(w.wbuf[:0], op, payload)
	w.wbuf = b
	if err != nil {
		return err
	}
	return writeFull(w.c, b)
}

// writeFull is io.WriteString's missing byte-slice counterpart. net.Conn is
// allowed to return a short write without an error; leaving half a WebSocket
// frame on the wire makes every byte after it undecodable, so every protocol
// write here must finish or fail the connection.
func writeFull(w io.Writer, b []byte) error {
	for len(b) > 0 {
		n, err := w.Write(b)
		if n > 0 {
			b = b[n:]
		}
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrShortWrite
		}
	}
	return nil
}

// appendFrame puts one whole frame on the end of b and hands it back.
//
// Header and payload go out of one buffer that is grown once and then reused:
// this carries video, and an allocation and a copy per frame is not free. Two
// writes would not be either - the header would leave in its own packet, which
// is both slower and a shape of its own.
func (w *wsConn) appendFrame(b []byte, op byte, payload []byte) ([]byte, error) {
	n := len(payload)
	if need := len(b) + 14 + n; cap(b) < need {
		grown := make([]byte, len(b), need*2)
		copy(grown, b)
		b = grown
	}

	// FIN is always set: every piece goes out as a whole message. What this
	// has to know is how to READ a fragmented one.
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
		return b, nil
	}
	// A client masks with a fresh key per frame. It buys no secrecy - the key
	// travels in the header - but a proxy that sees an unmasked client frame
	// is entitled to hang up, and some do.
	var key [4]byte
	if _, err := rand.Read(key[:]); err != nil {
		return b, err
	}
	b = append(b, key[:]...)
	at := len(b)
	b = b[:at+n]
	wsMask(b[at:], payload, key)
	return b, nil
}

// writeControl sends a ping, pong or close without ever waiting long for the
// writer.
//
// The reader answers pings, and the writer may be part way through a frame
// that has not gone out because the far end has stopped reading. If the reader
// waited for the writer there, it would stop reading too - and two ends each
// waiting for the other to read is a connection that is up, idle, and
// finished. A dropped pong is worth nothing next to that.
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
			return errWSControlBusy
		}
	}
	defer func() { <-w.wmu }()

	// The write deadline belongs to whatever the layer above last set for its
	// own writes, and on an idle connection that moment is long past - a pong
	// sent under it fails instantly with i/o timeout. Borrow the socket for
	// one write and give the deadline back, both under dmu, because the writer
	// above sets its deadline before it asks for the write lock and handing
	// back a value read before that would leave an expired one behind it.
	w.dmu.Lock()
	w.c.SetWriteDeadline(time.Now().Add(wsControlWait))
	err := w.frameOut(op, payload)
	w.c.SetWriteDeadline(w.wdl)
	w.dmu.Unlock()
	return err
}

func (w *wsConn) Close() error {
	w.once.Do(func() {
		close(w.done)
		// Say goodbye if it can be said quickly. Never wait on it: the point
		// of Close is that this connection is done with.
		w.c.SetWriteDeadline(time.Now().Add(time.Second))
		w.writeControl(wsOpClose, wsCloseNormal)
	})
	return w.c.Close()
}

// abort is for a socket already known to be bad. A graceful close frame would
// only spend wsControlWait trying to write to the same dead path and delay the
// reconnect that restores every multiplexed stream.
func (w *wsConn) abort() {
	w.once.Do(func() { close(w.done) })
	_ = w.c.Close()
}

// netConn is the socket under the framing. tuneSocket walks down to it to turn
// Nagle off and put the tuning's buffers on; without a way through, a carrier
// that is framing over a socket looked like neither.
func (w *wsConn) netConn() net.Conn { return w.c }

func (w *wsConn) LocalAddr() net.Addr  { return w.c.LocalAddr() }
func (w *wsConn) RemoteAddr() net.Addr { return w.c.RemoteAddr() }

// The two write-deadline setters hold dmu across the socket call, not only
// around the field, so that a control frame borrowing the deadline and the
// layer above changing it cannot overlap and end with the older of the two on
// the socket.
func (w *wsConn) SetDeadline(t time.Time) error {
	w.dmu.Lock()
	defer w.dmu.Unlock()
	w.wdl = t
	return w.c.SetDeadline(t)
}

func (w *wsConn) SetReadDeadline(t time.Time) error { return w.c.SetReadDeadline(t) }

func (w *wsConn) SetWriteDeadline(t time.Time) error {
	w.dmu.Lock()
	defer w.dmu.Unlock()
	w.wdl = t
	return w.c.SetWriteDeadline(t)
}

// ---------------------------------------------------------------------------
// the handshake
// ---------------------------------------------------------------------------

func wsAccept(key string) string {
	h := sha1.New()
	h.Write([]byte(key + wsGUID))
	return base64.StdEncoding.EncodeToString(h.Sum(nil))
}

func hasHTTPToken(value, want string) bool {
	for _, token := range strings.Split(value, ",") {
		if strings.EqualFold(strings.TrimSpace(token), want) {
			return true
		}
	}
	return false
}

func validWSKey(key string) bool {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(key))
	return err == nil && len(raw) == 16
}

func wsUpgradeRequest(r *http.Request, path string) (string, bool) {
	key := r.Header.Get("Sec-WebSocket-Key")
	ok := r.Method == http.MethodGet && r.ProtoMajor == 1 && r.ProtoMinor >= 1 &&
		r.URL.Path == path && validWSKey(key) &&
		strings.EqualFold(r.Header.Get("Upgrade"), "websocket") &&
		hasHTTPToken(r.Header.Get("Connection"), "upgrade") &&
		r.Header.Get("Sec-WebSocket-Version") == "13"
	return key, ok
}

// wsDial opens the connection: TCP, an HTTP upgrade request over it, and the
// byte stream that follows.
//
// authority is what goes in the Host header and the Origin: the name this end
// presents, with the port it dialled when that port is not the default. RFC
// 7230 5.4 requires it and every browser sends it, so a request that says it
// is Chrome and then leaves it off disagrees with the socket it arrived on.
func wsDial(addr, authority, path string, timeout time.Duration) (net.Conn, error) {
	return dialWebSocket(addr, "", authority, path, false, timeout)
}

func wssDial(addr, serverName, authority, path string, timeout time.Duration,
	cache tls.ClientSessionCache) (net.Conn, error) {
	return dialWebSocket(addr, serverName, authority, path, true, timeout, cache)
}

func dialWebSocket(addr, serverName, authority, path string, useTLS bool, timeout time.Duration,
	cache ...tls.ClientSessionCache) (net.Conn, error) {
	if timeout <= 0 {
		timeout = 15 * time.Second
	}
	d := &net.Dialer{Timeout: timeout, KeepAlive: 30 * time.Second}
	var c net.Conn
	var err error
	if useTLS {
		// A supplied certificate or a public CDN certificate is accepted, but a
		// direct origin also works with Pingify's generated self-signed one. The
		// outer TLS layer is camouflage and transport encryption; the Pingify
		// handshake immediately inside it authenticates the peer with the token.
		tlsCfg := &tls.Config{
			ServerName:         serverName,
			InsecureSkipVerify: true, // authenticated by the inner token handshake
			MinVersion:         tls.VersionTLS12,
			NextProtos:         []string{"http/1.1"},
			CurvePreferences:   []tls.CurveID{tls.X25519, tls.CurveP256},
		}
		if len(cache) > 0 {
			tlsCfg.ClientSessionCache = cache[0]
		}
		c, err = tls.DialWithDialer(d, "tcp", addr, tlsCfg)
	} else {
		c, err = d.Dial("tcp", addr)
	}
	if err != nil {
		return nil, err
	}
	if err := c.SetDeadline(time.Now().Add(timeout)); err != nil {
		c.Close()
		return nil, err
	}

	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		c.Close()
		return nil, err
	}
	key := base64.StdEncoding.EncodeToString(raw[:])

	// Chrome's own header set, in Chrome's own order. Extensions are the one
	// thing deliberately left out: advertising permessage-deflate invites a
	// peer to negotiate it, and then every frame carries RSV1 and means
	// something this does not implement.
	scheme := "http"
	if useTLS {
		scheme = "https"
	}
	req := "GET " + path + " HTTP/1.1\r\n" +
		"Host: " + authority + "\r\n" +
		"Connection: Upgrade\r\n" +
		"Pragma: no-cache\r\n" +
		"Cache-Control: no-cache\r\n" +
		"User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
		"(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36\r\n" +
		"Upgrade: websocket\r\n" +
		"Origin: " + scheme + "://" + authority + "\r\n" +
		"Sec-WebSocket-Version: 13\r\n" +
		"Accept-Encoding: gzip, deflate, br\r\n" +
		"Accept-Language: en-US,en;q=0.9\r\n" +
		"Sec-WebSocket-Key: " + key + "\r\n" +
		"\r\n"
	if err := writeFull(c, []byte(req)); err != nil {
		c.Close()
		return nil, err
	}

	// The dial timeout covered the TCP connect, and nothing covered the
	// answer. A server that accepts the connection and then says nothing
	// parks this goroutine for good, with not one line in the log to say why,
	// because the dial loop only reports what returns. Which is exactly what a
	// CDN does on a port it does not proxy.
	br := bufio.NewReaderSize(c, 32*1024)
	resp, err := http.ReadResponse(br, nil)
	if err != nil {
		c.Close()
		return nil, fmt.Errorf("ws: no answer to the upgrade: %v", err)
	}
	// The connection lives for hours after this; the deadline was for the
	// handshake alone.
	if err := c.SetDeadline(time.Time{}); err != nil {
		c.Close()
		return nil, err
	}
	if resp.StatusCode != http.StatusSwitchingProtocols {
		sample, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		resp.Body.Close()
		c.Close()
		detail := strings.Join(strings.Fields(string(sample)), " ")
		if len(detail) > 160 {
			detail = detail[:160]
		}
		ray := strings.TrimSpace(resp.Header.Get("CF-Ray"))
		if ray != "" {
			detail = strings.TrimSpace(detail + " CF-Ray=" + ray)
		}
		if detail != "" {
			return nil, fmt.Errorf("ws: the server answered %s, not an upgrade (%s)", resp.Status, detail)
		}
		return nil, fmt.Errorf("ws: the server answered %s, not an upgrade", resp.Status)
	}
	resp.Body.Close()
	if !strings.EqualFold(resp.Header.Get("Upgrade"), "websocket") ||
		!hasHTTPToken(resp.Header.Get("Connection"), "upgrade") ||
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
	cfg  *Config
	path string
	auth string
	host string
	tls  bool
	// Reconnects should not pay a full public-key handshake every time a path
	// blips. Go's cache is concurrency-safe and Cloudflare/origin tickets are
	// scoped by the SNI name.
	tlsCache tls.ClientSessionCache

	ln      net.Listener
	inbound chan net.Conn
	done    chan struct{}
	once    sync.Once
}

func newWSTransport(cfg *Config) (*wsTransport, error) {
	return newWebSocketTransport(cfg, false)
}

func newWSSTransport(cfg *Config) (*wsTransport, error) {
	return newWebSocketTransport(cfg, true)
}

func newWebSocketTransport(cfg *Config, useTLS bool) (*wsTransport, error) {
	t := &wsTransport{
		cfg:  cfg,
		path: wsPathFor(cfg),
		auth: wsAuthority(cfg),
		host: wsHostFor(cfg),
		tls:  useTLS,
		// One connection is the whole point, but a replacement can arrive
		// before the old one has been noticed as gone. Room for a couple, and
		// no more, so a flood of upgrades cannot queue here.
		inbound: make(chan net.Conn, 4),
		done:    make(chan struct{}),
	}
	if useTLS && cfg.Connect != "" {
		t.tlsCache = tls.NewLRUClientSessionCache(8)
	}
	if cfg.Connect != "" {
		return t, nil // this end dials; it binds nothing
	}
	ln, err := net.Listen("tcp", cfg.Listen)
	if err != nil {
		return nil, err
	}
	if useTLS {
		cert, certErr := wsCertificate(cfg)
		if certErr != nil {
			ln.Close()
			return nil, fmt.Errorf("wss certificate: %w", certErr)
		}
		ln = tls.NewListener(ln, &tls.Config{
			Certificates: []tls.Certificate{cert},
			MinVersion:   tls.VersionTLS12,
			NextProtos:   []string{"http/1.1"},
		})
	}
	t.ln = ln
	go t.serve()
	return t, nil
}

// The path the connection asks for. Derived from the token, so it is neither
// guessable from outside nor something anybody has to agree by hand: both ends
// reach the same one from the same secret. Anything asking for a different
// path is answered like an ordinary web server, and learns nothing.
func wsPathFor(cfg *Config) string {
	k := hkdfExpand(hkdfExtract([]byte("pingify/v3 ws path"), cfg.key()), []byte("path"), 9)
	return "/" + strings.TrimRight(base64.RawURLEncoding.EncodeToString(k), "=")
}

// wsHostFor is the name this end presents: the name half of the Host header,
// and the name a certificate would be issued for.
//
// A CDN routes on the name, so when there is a domain it wins over whatever
// address is being dialled - that is what lets a connection go to an edge and
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

// wsAuthority is what the Host header and the Origin carry: that name, with
// the port actually dialled, and without it when it is 80 - which is what a
// browser leaves off too.
func wsAuthority(cfg *Config) string {
	host := wsHostFor(cfg)
	target := cfg.Connect
	if target == "" {
		target = cfg.Listen
	}
	_, port, err := net.SplitHostPort(target)
	defaultPort := "80"
	if cfg.Transport == "wss" {
		defaultPort = "443"
	}
	if err != nil || port == "" || port == defaultPort {
		return host
	}
	return net.JoinHostPort(host, port)
}

func (t *wsTransport) serve() {
	srv := &http.Server{
		ReadHeaderTimeout: 10 * time.Second,
		Handler:           http.HandlerFunc(t.handle),
		ErrorLog:          stdlog.New(wsHTTPErrorWriter{}, "", 0),
	}
	// Only the header read is bounded. The connection is hijacked out of this
	// server and then lives for hours, so a read, write or idle timeout here
	// would be a clock quietly killing the tunnel.
	err := srv.Serve(t.ln)
	select {
	case <-t.done:
	default:
		// The listener stopped but the tunnel did not. A connection already up
		// keeps working, so nothing else notices - and no new one can ever
		// arrive. Say so, or this is a tunnel that degrades in silence.
		logWarn("%s: stopped accepting: %v", t.Name(), err)
	}
}

func (t *wsTransport) handle(w http.ResponseWriter, r *http.Request) {
	key, valid := wsUpgradeRequest(r, t.path)
	if !valid {
		// Not ours. Answer the way a web server with nothing on it answers, so
		// a scanner learns that and no more.
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
	id := decoyFor(decoyPSK)
	resp := "HTTP/1.1 101 Switching Protocols\r\n" +
		"Server: nginx/" + id.version + "\r\n" +
		"Date: " + time.Now().UTC().Format(http.TimeFormat) + "\r\n" +
		"Connection: upgrade\r\n" +
		"Upgrade: websocket\r\n" +
		"Sec-WebSocket-Accept: " + wsAccept(key) + "\r\n\r\n"
	if err := writeFull(c, []byte(resp)); err != nil {
		c.Close()
		return
	}
	select {
	case t.inbound <- newWSConn(c, br.Reader, false):
	case <-t.done:
		c.Close()
	default:
		// Never block the HTTP handler waiting for an acceptor. But say it
		// happened: dropping a connection on the floor and letting the far end
		// retry forever is the kind of quiet failure that leaves somebody
		// staring at "0 of 1" with nothing to go on.
		logWarn("%s: no room to accept a connection from %s, dropped", t.Name(), c.RemoteAddr())
		c.Close()
	}
}

func (t *wsTransport) Dial(idx int) (net.Conn, error) {
	if t.tls {
		return wssDial(t.cfg.Connect, t.host, t.auth, t.path,
			time.Duration(t.cfg.DialTimeout)*time.Second, t.tlsCache)
	}
	return wsDial(t.cfg.Connect, t.auth, t.path,
		time.Duration(t.cfg.DialTimeout)*time.Second)
}

func (t *wsTransport) Accept() (net.Conn, error) {
	if t.ln == nil {
		return nil, fmt.Errorf("%s: this end dials, it does not accept", t.Name())
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
	if t.tls {
		return "wss"
	}
	return "ws"
}
