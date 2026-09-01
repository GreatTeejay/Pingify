package carrier

import (
	"crypto/tls"
	"fmt"
	"net"

	"pingify/internal/config"
	"pingify/internal/logging"
)

// WSS: the WebSocket carrier with TLS under it.
//
// The two ends are not symmetrical here, and that is the point rather than an
// oversight. What this transport is for is a name in front of a server - a
// CDN, or a reverse proxy - and a CDN terminates TLS at its edge: the dialling
// side speaks TLS to a name the whole internet trusts, and the edge connects
// inward to the origin in whatever way it was told to, usually plain.
//
// So the side that dials always does TLS, and the side that waits does TLS
// only when it has been given a certificate. Without one it speaks plain
// WebSocket and expects the thing in front of it to have done the TLS - which
// is exactly what Cloudflare's flexible mode does, and what a local nginx in
// front of this would do too.
func newWSSCarrier(cfg *config.Config) (*streamCarrier, error) {
	c, err := newWebSocketCarrier(cfg, "wss", tlsDial(cfg))
	if err != nil {
		return nil, err
	}
	if cfg.Dials() {
		return c, nil
	}

	// The side that waits. A certificate turns the listener into a TLS one;
	// without it this is a plain WebSocket behind something that has already
	// done the TLS.
	if cfg.Transport.Cert == "" {
		logging.Info("carrier: no certificate here, so this end speaks plain " +
			"websocket - whatever fronts it is doing the TLS")
		return c, nil
	}
	cert, err := tls.LoadX509KeyPair(cfg.Transport.Cert, cfg.Transport.Key)
	if err != nil {
		return nil, fmt.Errorf("certificate: %v", err)
	}
	conf := &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS12,
		NextProtos:   []string{"http/1.1"},
	}
	inner := c.accept
	c.accept = func(nc net.Conn) (net.Conn, framing, error) {
		ts := tls.Server(nc, conf)
		if err := ts.Handshake(); err != nil {
			return nil, nil, fmt.Errorf("tls: %v", err)
		}
		return inner(ts)
	}
	logging.Info("carrier: serving tls from %s", cfg.Transport.Cert)
	return c, nil
}

// tlsDial is the client half. The name it verifies against is the domain,
// which is also the name in the Host header and the one the CDN answers for.
//
// Verification is on, and it stays on: the certificate the edge presents is a
// public one for a name somebody owns, and turning the check off here would
// mean any machine on the way could answer instead. `insecure = true` in the
// file is for a certificate this pair generated for itself, which has nobody
// to vouch for it.
func tlsDial(cfg *config.Config) func(net.Conn, string) (net.Conn, error) {
	return func(nc net.Conn, host string) (net.Conn, error) {
		tc := tls.Client(nc, &tls.Config{
			ServerName:         host,
			MinVersion:         tls.VersionTLS12,
			NextProtos:         []string{"http/1.1"},
			InsecureSkipVerify: cfg.Transport.Insecure,
		})
		if err := tc.Handshake(); err != nil {
			return nil, fmt.Errorf("tls to %s: %v", host, err)
		}
		return tc, nil
	}
}
