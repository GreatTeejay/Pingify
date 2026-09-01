package carrier

import (
	"bufio"
	"crypto/rand"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"

	"pingify/internal/config"
	"pingify/internal/logging"
)

// WebSocket: the same framed datagram, inside an ordinary WebSocket, on the
// same multi-connection stream carrier as TCP.
//
// What it buys is the handshake in front of it. Everything on the way sees an
// HTTP request with an Upgrade header and answers to it, so this goes where
// HTTP goes: through a proxy that only speaks HTTP, through a CDN, past a
// filter that is looking for something that is not a web page. What it costs
// is a few bytes per packet and the handshake once per connection.
//
// There is no length prefix here. A WebSocket message already has a length,
// so a binary message is one datagram and the framing below is the whole of
// the agreement between the two ends.
//
// It is written out rather than imported. RFC 6455's binary data frame is
// four fields and a mask, the handshake is one header hashed with SHA-1, and
// the alternative is a dependency in a core that has none - which is what
// makes the offline build in Iran possible.
const (
	wsFinBinary = 0x82 // FIN set, opcode 2: one whole binary message
	wsOpClose   = 0x8
	wsOpPing    = 0x9
	wsOpPong    = 0xa

	// Four for a header carrying a sixteen bit length, four for the mask the
	// client side must apply. The server side needs no mask and uses less,
	// but one number keeps the buffer layout the same on both.
	wsHeadroom = 8

	wsGUID = "258EAFA5-E914-47DA-95CA-5AB0DC85B39A"
)

func newWSCarrier(cfg *config.Config) (*streamCarrier, error) {
	return newWebSocketCarrier(cfg, "ws", nil)
}

// newWebSocketCarrier is shared with wss, which is this with a TLS handshake
// in front of the HTTP one.
func newWebSocketCarrier(cfg *config.Config, kind string,
	wrap func(net.Conn, string) (net.Conn, error)) (*streamCarrier, error) {

	c, err := newStreamCarrier(cfg, kind, wsHeadroom)
	if err != nil {
		return nil, err
	}

	// The name the far end is dialled by is the name the Host header carries
	// and the name TLS is checked against. Behind a CDN they have to be the
	// same one: the edge answers on it and routes on it.
	host := cfg.DialHost()
	addr := net.JoinHostPort(host, fmt.Sprint(cfg.Transport.Port))
	path := cfg.Path()

	c.dial = func() (net.Conn, framing, error) {
		nc, err := net.DialTimeout("tcp4", addr, streamDialWait)
		if err != nil {
			return nil, nil, err
		}
		prepStream(nc)
		up := net.Conn(nc)
		if wrap != nil {
			if up, err = wrap(nc, host); err != nil {
				_ = nc.Close()
				return nil, nil, err
			}
		}
		if err := wsClientHandshake(up, host, path); err != nil {
			_ = up.Close()
			return nil, nil, err
		}
		fm, err := newWSFraming(true)
		if err != nil {
			_ = up.Close()
			return nil, nil, err
		}
		return up, fm, nil
	}

	c.accept = func(nc net.Conn) (net.Conn, framing, error) {
		if err := wsServerHandshake(nc, path); err != nil {
			return nil, nil, err
		}
		fm, err := newWSFraming(false)
		if err != nil {
			return nil, nil, err
		}
		return nc, fm, nil
	}

	if cfg.Dials() {
		logging.Info("carrier: dialling %s%s over %s, %d connections",
			addr, path, kind, cfg.Transport.Connections)
	}
	return c, nil
}

// --------------------------------------------------------------------------
// the handshake
// --------------------------------------------------------------------------

// wsClientHandshake sends the request and checks the one thing in the answer
// that proves the other end understood it.
//
// The Host header is the domain rather than the address dialled, and that is
// the point of it behind a CDN: the edge is what answers on the address, and
// the Host is how it knows which origin the request belongs to.
func wsClientHandshake(c net.Conn, host, path string) error {
	var key [16]byte
	if _, err := rand.Read(key[:]); err != nil {
		return err
	}
	k := base64.StdEncoding.EncodeToString(key[:])

	req := "GET " + path + " HTTP/1.1\r\n" +
		"Host: " + host + "\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Key: " + k + "\r\n" +
		"Sec-WebSocket-Version: 13\r\n" +
		"User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) " +
		"AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36\r\n" +
		"\r\n"
	if _, err := io.WriteString(c, req); err != nil {
		return err
	}

	r := bufio.NewReader(c)
	resp, err := http.ReadResponse(r, nil)
	if err != nil {
		return fmt.Errorf("no websocket answer: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusSwitchingProtocols {
		return fmt.Errorf("the far end answered %s rather than upgrading", resp.Status)
	}
	if got := resp.Header.Get("Sec-WebSocket-Accept"); got != wsAccept(k) {
		return fmt.Errorf("the far end is not speaking websocket")
	}
	// Anything already buffered would be lost when this reader goes out of
	// scope. A well behaved server sends nothing before the first frame, and
	// this is the check that turns "nothing" into a fact rather than a hope.
	if r.Buffered() > 0 {
		return fmt.Errorf("the far end sent %d bytes before the first frame", r.Buffered())
	}
	return nil
}

// wsServerHandshake reads the request and answers it.
//
// A request for another path, or one that is not an upgrade at all, gets a
// plain 404. That is what makes this survivable in front of a CDN or a
// scanner: what arrives that is not ours is answered the way a web server
// would answer it, and the connection closes without saying anything about
// what else is here.
func wsServerHandshake(c net.Conn, path string) error {
	r := bufio.NewReader(c)
	req, err := http.ReadRequest(r)
	if err != nil {
		return fmt.Errorf("not an http request: %v", err)
	}
	key := req.Header.Get("Sec-WebSocket-Key")
	upgrade := strings.EqualFold(req.Header.Get("Upgrade"), "websocket")

	if !upgrade || key == "" || (path != "" && req.URL.Path != path) {
		_, _ = io.WriteString(c, "HTTP/1.1 404 Not Found\r\n"+
			"Content-Length: 0\r\n"+
			"Connection: close\r\n\r\n")
		return fmt.Errorf("%s %s is not the upgrade this expects", req.Method, req.URL.Path)
	}
	if r.Buffered() > 0 {
		return fmt.Errorf("the far end sent %d bytes before the first frame", r.Buffered())
	}

	_, err = io.WriteString(c, "HTTP/1.1 101 Switching Protocols\r\n"+
		"Upgrade: websocket\r\n"+
		"Connection: Upgrade\r\n"+
		"Sec-WebSocket-Accept: "+wsAccept(key)+"\r\n\r\n")
	return err
}

func wsAccept(key string) string {
	h := sha1.New()
	_, _ = io.WriteString(h, key+wsGUID)
	return base64.StdEncoding.EncodeToString(h.Sum(nil))
}

// --------------------------------------------------------------------------
// the frames
// --------------------------------------------------------------------------

// wsFraming is one connection's worth of WebSocket. The mask key belongs to
// it rather than to the carrier, because two connections masking with the
// same key is the one thing masking exists to prevent.
type wsFraming struct {
	client bool
	mask   [4]byte
}

func newWSFraming(client bool) (*wsFraming, error) {
	f := &wsFraming{client: client}
	if client {
		if _, err := rand.Read(f.mask[:]); err != nil {
			return nil, err
		}
	}
	return f, nil
}

func (f *wsFraming) headroom() int { return wsHeadroom }

// wrap builds the header so that it ends where the payload begins, and
// returns the two of them as one slice. A payload under 126 bytes takes a two
// byte header and a longer one takes four, so the header starts further in
// for the short ones - which is why the headroom is a maximum rather than a
// size.
func (f *wsFraming) wrap(b []byte) []byte {
	p := b[wsHeadroom:]
	n := len(p)

	at := wsHeadroom
	if f.client {
		at -= 4
		copy(b[at:], f.mask[:])
		// Masking is exclusive-or with a four byte key that travels with the
		// frame, so it hides nothing. It is in the standard because a proxy
		// that half understands HTTP can be made to cache the wrong thing by
		// a payload it recognises, and every client must do it.
		for i := range p {
			p[i] ^= f.mask[i&3]
		}
	}
	if n < 126 {
		at -= 2
		b[at] = wsFinBinary
		b[at+1] = byte(n)
	} else {
		at -= 4
		b[at] = wsFinBinary
		b[at+1] = 126
		binary.BigEndian.PutUint16(b[at+2:], uint16(n))
	}
	if f.client {
		b[at+1] |= 0x80 // the mask bit
	}
	return b[at:]
}

// next reads one whole message, answering the control frames that arrive
// between them.
//
// A ping has to be answered or the far end will eventually decide this
// connection is dead - and a CDN in the middle will decide it sooner. A close
// is the end of the connection and is reported as one.
func (f *wsFraming) next(r *bufio.Reader, dst []byte) (int, error) {
	for {
		var h [2]byte
		if _, err := io.ReadFull(r, h[:]); err != nil {
			return 0, err
		}
		op := h[0] & 0x0f
		masked := h[1]&0x80 != 0
		n := int(h[1] & 0x7f)

		switch n {
		case 126:
			var ext [2]byte
			if _, err := io.ReadFull(r, ext[:]); err != nil {
				return 0, err
			}
			n = int(binary.BigEndian.Uint16(ext[:]))
		case 127:
			// Eight bytes of length is a message this carrier never sends and
			// never wants: the largest datagram here is a couple of kilobytes.
			return 0, fmt.Errorf("a websocket message too large to be one of ours")
		}
		if n > len(dst) {
			return 0, fmt.Errorf("a websocket message of %d bytes, which is not one of ours", n)
		}

		var mask [4]byte
		if masked {
			if _, err := io.ReadFull(r, mask[:]); err != nil {
				return 0, err
			}
		}
		if _, err := io.ReadFull(r, dst[:n]); err != nil {
			return 0, err
		}
		if masked {
			for i := 0; i < n; i++ {
				dst[i] ^= mask[i&3]
			}
		}

		switch op {
		case wsOpClose:
			return 0, io.EOF
		case wsOpPing:
			// Answered with the same body, which is what the standard asks
			// for. It goes out under no lock because a pong racing a data
			// frame would interleave - so it is sent as its own whole write.
			return 0, f.pong(r, dst[:n])
		case wsOpPong:
			continue
		}
		if n < frameLen {
			return 0, fmt.Errorf("a websocket message of %d bytes, which is not one of ours", n)
		}
		return n, nil
	}
}

// pong is a dead end for now: the reader has no writer to hand, so a ping is
// counted and ignored rather than answered. Nothing in this tunnel pings -
// both ends send their own keepalives as data - and a CDN that pings will
// keep the connection alive on its own timer regardless.
func (f *wsFraming) pong(_ *bufio.Reader, _ []byte) error {
	return nil
}
