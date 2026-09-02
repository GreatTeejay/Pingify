package carrier

import (
	"bufio"
	"encoding/binary"
	"fmt"
	"io"
	"net"

	"pingify/internal/config"
	"pingify/internal/logging"
)

// TCP: a framed datagram with two bytes of length in front of it, on the
// shared multi-connection stream carrier.
//
// Two bytes of length, not a delimiter and not a fixed size. What comes off a
// stream is whatever the kernel had when it was asked, and a carrier that
// hands whole datagrams upward has to know where each one ends. A length this
// side did not write is a stream that cannot be resynchronised, so the
// connection goes rather than the frame.
const tcpLenLen = 2

func newTCPCarrier(cfg *config.Config) (*streamCarrier, error) {
	c, err := newStreamCarrier(cfg, "tcp", tcpLenLen)
	if err != nil {
		return nil, err
	}
	// DialHost, not the kharej address. This named one side directly, from
	// when Iran was the end that dialled, and it went on naming it after the
	// direction was settled the other way: the server abroad reached in by
	// dialling itself, and the tunnel sat there refusing its own connection.
	addr := net.JoinHostPort(cfg.DialHost(), fmt.Sprint(cfg.Transport.Port))
	c.dial = func() (net.Conn, framing, error) {
		nc, err := net.DialTimeout("tcp4", addr, streamDialWait)
		if err != nil {
			return nil, nil, err
		}
		prepStream(nc)
		return nc, lenFraming{}, nil
	}
	c.accept = func(nc net.Conn) (net.Conn, framing, error) {
		return nc, lenFraming{}, nil
	}
	if cfg.Dials() {
		logging.Info("carrier: dialling %s over tcp, %d connections",
			addr, cfg.Transport.Connections)
	}
	return c, nil
}

type lenFraming struct{}

func (lenFraming) headroom() int { return tcpLenLen }

func (lenFraming) wrap(b []byte) []byte {
	binary.BigEndian.PutUint16(b[:tcpLenLen], uint16(len(b)-tcpLenLen))
	return b
}

func (lenFraming) next(r *bufio.Reader, dst []byte) (int, error) {
	var hdr [tcpLenLen]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return 0, err
	}
	n := int(binary.BigEndian.Uint16(hdr[:]))
	if n < frameLen || n > len(dst) {
		return 0, fmt.Errorf("%d bytes announced on the stream, which is not one of ours", n)
	}
	if _, err := io.ReadFull(r, dst[:n]); err != nil {
		return 0, err
	}
	return n, nil
}
