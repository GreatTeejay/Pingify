package carrier

import (
	"crypto/tls"
	"fmt"
	"net"
	"strings"

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

	// The side that waits. A certificate turns the listener into a TLS one.
	// Without one there are two cases, and the address tells them apart: a
	// name in front of this server means a CDN or a proxy is doing the TLS
	// and this end speaks plain WebSocket behind it; a bare address means the
	// two servers are talking directly, and the dialler is going to speak TLS
	// whatever happens - so a certificate is made here, the way the UTLS
	// carrier makes one, and the dialler knows not to expect anyone to vouch
	// for it. Found by a direct WSS pair that never came up: the dialler's
	// ClientHello arrived at a plain HTTP listener and was refused as "not an
	// http request", eight times a minute, for ever.
	if cfg.Transport.Cert == "" && fronted(cfg) {
		logging.Info("carrier: no certificate here, so this end speaks plain " +
			"websocket - whatever fronts it is doing the TLS")
		return c, nil
	}
	conf, err := utlsServerConfig(cfg)
	if err != nil {
		return nil, err
	}
	conf.NextProtos = []string{"http/1.1"}
	inner := c.accept
	c.accept = func(nc net.Conn) (net.Conn, framing, error) {
		ts := tls.Server(nc, conf)
		if err := ts.Handshake(); err != nil {
			return nil, nil, fmt.Errorf("tls: %v", err)
		}
		return inner(ts)
	}
	return c, nil
}

// fronted says whether the address the dialler reaches is a name rather than
// an address - which is the whole of what a CDN or a proxy in front of the
// waiting side looks like from here.
func fronted(cfg *config.Config) bool {
	return strings.ContainsAny(cfg.DialHost(),
		"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
}

// tlsDial is the client half. The name it verifies against is the domain,
// which is also the name in the Host header and the one the CDN answers for.
//
// Verification is on whenever there is somebody to vouch for the certificate:
// behind a name, the edge presents a public one, and turning the check off
// there would let any machine on the way answer instead. Between two bare
// addresses with no certificate file there is nobody - the waiting side made
// its own - so the check is off, exactly as it is for the UTLS carrier.
// `insecure = true` in the file turns it off for a self-made pair behind a
// name too.
func tlsDial(cfg *config.Config) func(net.Conn, string) (net.Conn, error) {
	selfMade := cfg.Transport.Cert == "" && !fronted(cfg)
	return func(nc net.Conn, host string) (net.Conn, error) {
		tc := tls.Client(nc, &tls.Config{
			ServerName:         host,
			MinVersion:         tls.VersionTLS12,
			NextProtos:         []string{"http/1.1"},
			InsecureSkipVerify: cfg.Transport.Insecure || selfMade,
		})
		if err := tc.Handshake(); err != nil {
			return nil, fmt.Errorf("tls to %s: %v", host, err)
		}
		return tc, nil
	}
}
