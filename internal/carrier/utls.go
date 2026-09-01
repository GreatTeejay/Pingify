package carrier

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"fmt"
	"math/big"
	"net"
	"time"

	utls "github.com/refraction-networking/utls"

	"pingify/internal/config"
	"pingify/internal/logging"
)

// TCP UTLS: our datagrams inside a TLS connection that looks like Chrome's.
//
// What a passive filter sees of a TLS connection is the handshake, and almost
// all of what it can tell from that is in the first packet the client sends.
// The ClientHello says which extensions are offered and in what order, which
// curves and which cipher suites, and whether the GREASE values a real browser
// scatters through it are there at all. Go's own TLS stack has a fingerprint
// and it is not a browser's: no GREASE, the 1.3 suites in the wrong order, a
// hello about half the length. Anything built on crypto/tls announces "a Go
// program" in its first packet, which on a path that is looking for tunnels is
// the end of it.
//
// So the hello here is not built by crypto/tls. It is built by uTLS, from
// their own repository, to match Chrome - which is the technique's actual name
// and the same thing `fp=chrome` selects in a v2ray config.
//
// What this is not: it is not a WebSocket, so nothing about it needs a path or
// an HTTP server, and it is not a CDN transport - that is WSS. This is a TLS
// connection to a server that answers on a port, which is what most of the
// TLS on the internet is.
//
// The waiting end serves a certificate: the one the config names, or one made
// here for the name being dialled if it does not. A made-up certificate is
// enough for a passive watcher and not enough for one that connects and looks,
// so a real one is worth having and the manager says so.
func newUTLSCarrier(cfg *config.Config) (*streamCarrier, error) {
	c, err := newStreamCarrier(cfg, "utls", tcpLenLen)
	if err != nil {
		return nil, err
	}

	host := cfg.DialHost()
	addr := net.JoinHostPort(host, fmt.Sprint(cfg.Transport.Port))

	c.dial = func() (net.Conn, framing, error) {
		nc, err := net.DialTimeout("tcp4", addr, streamDialWait)
		if err != nil {
			return nil, nil, err
		}
		prepStream(nc)
		// HelloChrome_Auto is whichever Chrome the vendored uTLS is current
		// with, so this follows the browser rather than freezing one version
		// of it - a hello that was Chrome two years ago is its own
		// fingerprint.
		u := utls.UClient(nc, &utls.Config{
			ServerName:         host,
			InsecureSkipVerify: cfg.Transport.Insecure || cfg.Transport.Cert == "",
		}, utls.HelloChrome_Auto)
		if err := u.Handshake(); err != nil {
			_ = nc.Close()
			return nil, nil, fmt.Errorf("tls to %s: %v", host, err)
		}
		return u, lenFraming{}, nil
	}

	if cfg.Dials() {
		logging.Info("carrier: dialling %s over tls as chrome, %d connections",
			addr, cfg.Transport.Connections)
		return c, nil
	}

	conf, err := utlsServerConfig(cfg)
	if err != nil {
		return nil, err
	}
	c.accept = func(nc net.Conn) (net.Conn, framing, error) {
		ts := tls.Server(nc, conf)
		if err := ts.Handshake(); err != nil {
			return nil, nil, fmt.Errorf("tls: %v", err)
		}
		return ts, lenFraming{}, nil
	}
	return c, nil
}

func utlsServerConfig(cfg *config.Config) (*tls.Config, error) {
	if cfg.Transport.Cert != "" {
		cert, err := tls.LoadX509KeyPair(cfg.Transport.Cert, cfg.Transport.Key)
		if err != nil {
			return nil, fmt.Errorf("certificate: %v", err)
		}
		logging.Info("carrier: serving tls from %s", cfg.Transport.Cert)
		return &tls.Config{
			Certificates: []tls.Certificate{cert},
			MinVersion:   tls.VersionTLS12,
		}, nil
	}

	name := cfg.DialHost()
	if name == "" {
		name = "localhost"
	}
	cert, err := selfSigned(name)
	if err != nil {
		return nil, err
	}
	logging.Warn("no certificate: serving one made here for %s", name)
	logging.Warn("that is enough for a filter watching, and not enough for one that connects")
	return &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS12,
	}, nil
}

// selfSigned makes a certificate for one name, valid for a year.
//
// It is made fresh on every start rather than kept, because a certificate on
// disk is one more file with a private key in it and this one is worth
// nothing: what it buys is a handshake that completes, not trust.
func selfSigned(name string) (tls.Certificate, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return tls.Certificate{}, err
	}
	tpl := x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: name},
		DNSNames:     []string{name},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(365 * 24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, &tpl, &tpl, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, err
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, nil
}
