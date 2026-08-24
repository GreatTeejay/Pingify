package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"fmt"
	"math/big"
	"net/http"
	"sync"
	"time"
)

// ---------------------------------------------------------------------------
// what answers everything that is not a carrier
//
// A tunnel that returns nothing to a probe is a port that returns nothing to a
// probe, and there are not many of those on the internet. What a scanner
// should find is a web server with nothing interesting on it - because that is
// the most common thing there is.
//
// So: the front page nginx ships with, a normal 404 everywhere else, and the
// headers a real one sends. The details are derived from the tunnel's own
// token rather than fixed, so two servers running this do not answer
// identically and a fleet cannot be found by matching one response against the
// rest of the internet.
// ---------------------------------------------------------------------------

const decoyPage = `<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
<style>
html { color-scheme: light dark; }
body { width: 35em; margin: 0 auto;
font-family: Tahoma, Verdana, Arial, sans-serif; }
</style>
</head>
<body>
<h1>Welcome to nginx!</h1>
<p>If you see this page, the nginx web server is successfully installed and
working. Further configuration is required.</p>

<p>For online documentation and support please refer to
<a href="http://nginx.org/">nginx.org</a>.<br/>
Commercial support is available at
<a href="http://nginx.com/">nginx.com</a>.</p>

<p><em>Thank you for using nginx.</em></p>
</body>
</html>
`

const decoy404 = `<html>
<head><title>404 Not Found</title></head>
<body>
<center><h1>404 Not Found</h1></center>
<hr><center>nginx/%s</center>
</body>
</html>
`

// decoyIdentity is the version string, page date and ETag this install claims.
// All three come from the token, so they are stable for one server and
// different from the next - which is the point. A fixed set would be a
// fingerprint shared by everyone running this.
type decoyIdentity struct {
	version string
	modTime time.Time
	etag    string
}

func newDecoyIdentity(psk []byte) decoyIdentity {
	k := hkdfExpand(hkdfExtract([]byte("pingify/v3 decoy"), psk), []byte("identity"), 32)

	// A version that exists: these are all real nginx releases, so a scanner
	// matching against known versions finds an ordinary one.
	versions := []string{
		"1.18.0", "1.20.1", "1.20.2", "1.22.0", "1.22.1",
		"1.24.0", "1.25.3", "1.26.0", "1.26.1", "1.27.0",
	}
	v := versions[int(k[0])%len(versions)]

	// A page date somewhere in the last two years, on a whole minute, the way
	// a file written by a package manager would be.
	off := time.Duration(binary.BigEndian.Uint32(k[1:5])%(730*24*60)) * time.Minute
	mod := time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC).Add(off)

	return decoyIdentity{
		version: v,
		modTime: mod,
		etag:    fmt.Sprintf(`"%x-%x"`, mod.Unix(), len(decoyPage)),
	}
}

// Worked out once and then read from every connection at the same time. The
// unguarded "have I done this yet" flag was a data race from the day it was
// written; nothing caught it while only the decoy handler read it, and the
// moment the upgrade reply started carrying the same Server header - so that
// the one response that was not the decoy's finally matched the rest - every
// carrier coming up hit it at once.
var (
	decoyOnce sync.Once
	decoyID   decoyIdentity
)

func decoyFor(psk []byte) decoyIdentity {
	decoyOnce.Do(func() { decoyID = newDecoyIdentity(psk) })
	return decoyID
}

// wsDecoy answers anything that is not a carrier.
func wsDecoy(w http.ResponseWriter, r *http.Request) {
	id := decoyFor(decoyPSK)
	h := w.Header()
	h.Set("Server", "nginx/"+id.version)
	h.Set("Date", time.Now().UTC().Format(http.TimeFormat))

	if r.URL.Path != "/" {
		h.Set("Content-Type", "text/html")
		body := fmt.Sprintf(decoy404, id.version)
		h.Set("Content-Length", fmt.Sprint(len(body)))
		w.WriteHeader(http.StatusNotFound)
		if r.Method != http.MethodHead {
			w.Write([]byte(body))
		}
		return
	}

	h.Set("Content-Type", "text/html")
	h.Set("Content-Length", fmt.Sprint(len(decoyPage)))
	h.Set("Last-Modified", id.modTime.Format(http.TimeFormat))
	h.Set("ETag", id.etag)
	h.Set("Accept-Ranges", "bytes")
	// A real static file answers a conditional request rather than resending.
	if r.Header.Get("If-None-Match") == id.etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	w.WriteHeader(http.StatusOK)
	if r.Method != http.MethodHead {
		w.Write([]byte(decoyPage))
	}
}

// decoyPSK is set once at startup so the handler, which has no config, can
// derive the same identity every time.
var decoyPSK []byte

// ---------------------------------------------------------------------------
// the certificate
//
// A real one from Let's Encrypt is better and the manager can arrange it. When
// there is none, a self-signed certificate is generated and kept, because the
// alternative is refusing to start - and the tunnel does not trust the
// certificate anyway. What proves the far end is the token, in the handshake
// the braid runs immediately after the upgrade.
// ---------------------------------------------------------------------------

func wsCertificate(cfg *Config) (tls.Certificate, error) {
	if cfg.CertFile != "" && cfg.KeyFile != "" {
		return tls.LoadX509KeyPair(cfg.CertFile, cfg.KeyFile)
	}
	return selfSignedFor(wsHostFor(cfg), cfg.key())
}

// selfSignedFor makes a certificate that looks like one a small site would
// have: a real-looking issuer, a year of validity, the hostname it is for.
// Derived from the token so it is the same one after a restart - a certificate
// that changes on every start is itself a signal.
func selfSignedFor(host string, psk []byte) (tls.Certificate, error) {
	k := hkdfExpand(hkdfExtract([]byte("pingify/v3 cert"), psk), []byte("serial"), 16)

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, err
	}
	serial := new(big.Int).SetBytes(k)
	if host == "" {
		host = "localhost"
	}
	tmpl := x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: host},
		DNSNames:     []string{host},
		NotBefore:    time.Now().Add(-30 * 24 * time.Hour),
		NotAfter:     time.Now().Add(335 * 24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, &tmpl, &tmpl, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, err
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, nil
}
