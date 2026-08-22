// Pingify engine - one encrypted tunnel between an Iran server and a server
// abroad, carried over several parallel TCP connections.
//
// Everything lives in this one file on purpose. It is standard-library only:
// Iranian servers frequently cannot reach proxy.golang.org, so the engine has
// to compile with GOPROXY=off and no module downloads of any kind. The only
// companions are tun_linux.go and tun_other.go, which cannot be merged in
// because a Go build constraint applies to a whole file.
//
// Layout:
//     1. configuration and entry point
//     2. logging
//     3. key derivation
//     4. handshake and the carrier pool
//     5. framing, encryption and stream multiplexing
//     6. forward mode - TCP/UDP port forwarding
//     7. tun mode - layer 3
//     8. socket tuning and forward specs
//     9. status endpoint

package main

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	mrand "math/rand"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// ==========================================================================
// 1. configuration and entry point
// ==========================================================================

const version = "4.7.0"

// Config is the on-disk tunnel description. One file per tunnel; the same file
// shape is used on both servers, only a few fields differ.
type Config struct {
	Name string `json:"name"`

	// Role decides who owns the user-facing ports.
	//   server — users connect here; normally the Iran box
	//   client — the real services live here; normally the Kharej box
	// "edge" and "origin" are accepted as the old names for these.
	Role string `json:"role"`

	// Mode selects what rides on top of the carrier pool.
	//   forward — TCP/UDP port forwarding
	//   tun     — full layer-3 IP tunnel
	Mode string `json:"mode"`

	// Transport is how the carriers themselves travel.
	//   braid — several parallel TCP connections braided into one encrypted
	//           stream; what "direct" and "tcp" used to be called
	// TLS, WebSocket and ICMP variants slot in here without touching a line
	// above.
	Transport string `json:"transport,omitempty"`

	// Exactly one of Listen/Connect is set. It is independent of Role, so the
	// dial direction can be chosen to suit whichever side has clean inbound.
	Listen  string `json:"listen,omitempty"`
	Connect string `json:"connect,omitempty"`

	// Token is what both servers are given; it may be any text. The 32-byte
	// key is derived from it, so a memorable token is still a strong key.
	// PSK is the older form: 32 bytes of hex, used directly.
	Token    string `json:"token,omitempty"`
	PSK      string `json:"psk,omitempty"`
	Carriers int    `json:"carriers"`
	WindowKB int    `json:"window_kb"`

	// forward mode: "443", "443=8443", "443=10.0.0.5:8443", "udp:500=500",
	// "8000-8010" (range, same port on the far side).
	Forwards []string `json:"forwards,omitempty"`

	// BindAddr is the address the forwarded ports listen on. Empty means every
	// interface, which is what an Iran server wants: clients arrive from
	// outside. Setting it to 127.0.0.1 keeps the ports off the network, which
	// is what the tests want and what a host firewall stops asking about.
	BindAddr string `json:"bind_addr,omitempty"`
	// origin side: if non-empty, only these host:port targets may be dialled.
	Allow []string `json:"allow,omitempty"`

	TUN TUNConfig `json:"tun,omitempty"`

	StatusAddr   string `json:"status_addr,omitempty"`
	KeepaliveSec int    `json:"keepalive_sec,omitempty"`

	// Obfuscate hides the shape of the traffic: the frame length prefix is
	// masked per frame and the opening frames carry random filler, so nothing
	// on the wire has a fixed offset or a recognisable value.
	//
	// The cost is that the stream then looks like nothing at all - uniformly
	// random from the first byte - and a filter that drops flows it cannot
	// identify will drop exactly that. Turning it off puts a plaintext length
	// in front of each frame, which is what an ordinary length-prefixed
	// protocol looks like. The payload stays encrypted either way.
	//
	// It must be the same on both servers. Nil means on.
	Obfuscate   *bool  `json:"obfuscate,omitempty"`
	DialTimeout int    `json:"dial_timeout_sec,omitempty"`
	SndBufKB    int    `json:"sndbuf_kb,omitempty"`
	RcvBufKB    int    `json:"rcvbuf_kb,omitempty"`
	LogLevel    string `json:"log_level,omitempty"`
}

type TUNConfig struct {
	Name  string `json:"name,omitempty"`
	Local string `json:"local,omitempty"` // e.g. 10.71.0.1/30
	Peer  string `json:"peer,omitempty"`  // e.g. 10.71.0.2
	MTU   int    `json:"mtu,omitempty"`
}

func (c *Config) applyDefaults() {
	switch c.Role {
	case "edge":
		c.Role = "server"
	case "origin":
		c.Role = "client"
	}
	if c.Mode == "" {
		c.Mode = "forward"
	}
	switch c.Transport {
	case "", "braid", "direct":
		c.Transport = "tcp"
	case "echo":
		c.Transport = "icmp"
	}
	if c.Carriers <= 0 {
		c.Carriers = 4
	}
	if c.Carriers > 64 {
		c.Carriers = 64
	}
	if c.WindowKB <= 0 {
		// 512 KiB per stream is roughly 50 Mbit/s on an 80 ms path, and it
		// bounds what one stalled connection can hold in memory. Raise it for
		// a very fat link; every open stream can buffer this much.
		c.WindowKB = 512
	}
	if c.WindowKB < 64 {
		c.WindowKB = 64
	}
	if c.KeepaliveSec <= 0 {
		c.KeepaliveSec = 10
	}
	if c.DialTimeout <= 0 {
		c.DialTimeout = 10
	}
	if c.SndBufKB <= 0 {
		c.SndBufKB = 4096
	}
	if c.RcvBufKB <= 0 {
		c.RcvBufKB = 4096
	}
	if c.TUN.MTU <= 0 {
		c.TUN.MTU = 1380
	}
	if c.TUN.Name == "" {
		c.TUN.Name = "pfy0"
	}
	if c.LogLevel == "" {
		c.LogLevel = "info"
	}
	if c.Name == "" {
		c.Name = "tunnel"
	}
}

func (c *Config) validate() error {
	switch c.Role {
	case "server", "client":
	default:
		return fmt.Errorf("role must be \"server\" or \"client\", got %q", c.Role)
	}
	switch c.Mode {
	case "forward", "tun", "both":
	default:
		return fmt.Errorf("mode must be \"forward\", \"tun\" or \"both\", got %q", c.Mode)
	}
	switch c.Transport {
	case "tcp", "icmp":
	default:
		return fmt.Errorf("transport %q is not available in this build", c.Transport)
	}
	if (c.Listen == "") == (c.Connect == "") {
		return fmt.Errorf("set exactly one of \"listen\" or \"connect\"")
	}
	if c.Token == "" && c.PSK == "" {
		return fmt.Errorf("a security token is required, and must be the same on both servers")
	}
	if c.Token == "" {
		if k, err := hex.DecodeString(strings.TrimSpace(c.PSK)); err != nil || len(k) < 16 {
			return fmt.Errorf("psk must be at least 16 bytes of hex")
		}
	}
	if c.Mode != "tun" && c.Role == "server" && len(c.Forwards) == 0 {
		return fmt.Errorf("edge side in forward mode needs at least one entry in \"forwards\"")
	}
	if (c.Mode == "tun" || c.Mode == "both") && c.Local() == "" {
		return fmt.Errorf("tun mode needs tun.local (e.g. 10.71.0.1/30)")
	}
	return nil
}

func (c *Config) Local() string { return c.TUN.Local }

// key is the 32 bytes everything else is derived from. A token of any length
// is stretched to it; a legacy hex psk is used as-is.
// tokenPrint is a short public name for the shared secret: the same token
// gives the same eight characters on both servers, and a different token
// gives different ones. It is safe to print, paste into a chat, and compare
// by eye - which is the only way to tell "the tokens differ" apart from
// "the network ate it" when a tunnel will not come up.
func (c *Config) tokenPrint() string {
	secret := strings.TrimSpace(c.Token)
	if secret == "" {
		secret = strings.TrimSpace(c.PSK)
	}
	if secret == "" {
		return "none"
	}
	sum := sha256.Sum256([]byte(secret))
	return hex.EncodeToString(sum[:4])
}

// obfuscated reports whether this tunnel hides the shape of its traffic.
func (c *Config) obfuscated() bool { return c.Obfuscate == nil || *c.Obfuscate }

func (c *Config) key() []byte {
	if c.Token != "" {
		return hkdfExpand(hkdfExtract([]byte("pingify/v3 token"),
			[]byte(strings.TrimSpace(c.Token))), []byte("tunnel key"), 32)
	}
	k, _ := hex.DecodeString(strings.TrimSpace(c.PSK))
	return k
}

func main() {
	var (
		cfgPath = flag.String("c", "", "path to tunnel config JSON")
		genPSK  = flag.Bool("genpsk", false, "print a fresh 32-byte pre-shared key and exit")
		showVer = flag.Bool("version", false, "print version and exit")
		check   = flag.Bool("check", false, "validate the config and exit")
		status  = flag.String("status", "", "print the status of a running tunnel (host:port) and exit")
		healthz = flag.String("healthz", "", "probe a running tunnel (host:port); exit 0 only when a carrier is up")
		brief   = flag.Bool("brief", false, "with -status, print one machine-readable line")
		probe   = flag.Bool("probe", false, "with -c, try every forwarded port end to end and exit")
	)
	flag.Parse()

	if *healthz != "" {
		if _, err := fetchStatus(*healthz); err != nil {
			os.Exit(1)
		}
		os.Exit(0)
	}
	if *status != "" {
		os.Exit(printStatus(*status, *brief))
	}

	if *showVer {
		fmt.Println("pingify-core " + version)
		return
	}
	if *genPSK {
		b := make([]byte, 32)
		if _, err := rand.Read(b); err != nil {
			fmt.Fprintln(os.Stderr, "rand:", err)
			os.Exit(1)
		}
		fmt.Println(hex.EncodeToString(b))
		return
	}
	if *cfgPath == "" {
		fmt.Fprintln(os.Stderr, "usage: pingify-core -c /etc/pingify/<name>.json")
		os.Exit(2)
	}

	cfg, err := loadConfig(*cfgPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	cfg.applyDefaults()
	if err := cfg.validate(); err != nil {
		fmt.Fprintln(os.Stderr, "config:", err)
		os.Exit(1)
	}
	if *probe {
		os.Exit(runProbe(cfg))
	}
	if *check {
		fmt.Println("config OK")
		return
	}

	setLogLevel(cfg.LogLevel)
	logInfo("pingify-core %s starting: tunnel=%s role=%s mode=%s transport=%s carriers=%d keepalive=%ds token=%s",
		version, cfg.Name, cfg.Role, cfg.Mode, cfg.Transport, cfg.Carriers,
		cfg.KeepaliveSec, cfg.tokenPrint())
	if !cfg.obfuscated() {
		logInfo("traffic shaping is off: frame lengths are in the clear, and both servers must agree")
	}

	p := newPool(cfg)
	if err := p.start(); err != nil {
		logError("start: %v", err)
		os.Exit(1)
	}

	var top interface{ Close() error }
	switch cfg.Mode {
	case "forward":
		f, err := startForward(cfg, p)
		if err != nil {
			logError("forward: %v", err)
			p.close()
			os.Exit(1)
		}
		top = f
	case "tun":
		t, err := startTUN(cfg, p)
		if err != nil {
			logError("tun: %v", err)
			p.close()
			os.Exit(1)
		}
		top = t
	case "both":
		f, err := startForward(cfg, p)
		if err != nil {
			logError("forward: %v", err)
			p.close()
			os.Exit(1)
		}
		t, err := startTUN(cfg, p)
		if err != nil {
			logError("tun: %v", err)
			f.Close()
			p.close()
			os.Exit(1)
		}
		b := &bothHandler{f: f, t: t}
		p.setHandler(b) // startTUN replaced it; put the pair back
		top = b
	}

	if cfg.StatusAddr != "" {
		startStatusServer(cfg.StatusAddr, cfg, p)
	}

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	s := <-sig
	logInfo("received %s, shutting down", s)
	if top != nil {
		top.Close()
	}
	p.close()
}

// ==========================================================================
// 2. logging
// ==========================================================================

const (
	lvlError = 0
	lvlWarn  = 1
	lvlInfo  = 2
	lvlDebug = 3
)

var logLevel int32 = lvlInfo

func setLogLevel(s string) {
	switch s {
	case "error":
		atomic.StoreInt32(&logLevel, lvlError)
	case "warn":
		atomic.StoreInt32(&logLevel, lvlWarn)
	case "debug":
		atomic.StoreInt32(&logLevel, lvlDebug)
	default:
		atomic.StoreInt32(&logLevel, lvlInfo)
	}
}

// logSink is where a formatted line goes. Only the tests replace it, so they
// can assert on what an operator would actually have seen.
var logSink = func(line string) { fmt.Fprintln(os.Stderr, line) }

func logAt(lvl int32, tag, format string, args ...interface{}) {
	if atomic.LoadInt32(&logLevel) < lvl {
		return
	}
	logSink(fmt.Sprintf("%s %s %s",
		time.Now().Format("2006-01-02 15:04:05"), tag, fmt.Sprintf(format, args...)))
}

func logError(f string, a ...interface{}) { logAt(lvlError, "ERR ", f, a...) }
func logWarn(f string, a ...interface{})  { logAt(lvlWarn, "WARN", f, a...) }
func logInfo(f string, a ...interface{})  { logAt(lvlInfo, "INFO", f, a...) }
func logDebug(f string, a ...interface{}) { logAt(lvlDebug, "DBG ", f, a...) }

// ==========================================================================
// 3. key derivation
// ==========================================================================

// HKDF (RFC 5869) over HMAC-SHA256, hand-rolled on crypto/hmac because
// golang.org/x/crypto is off-limits: the engine must build with GOPROXY=off.

func hkdfExtract(salt, ikm []byte) []byte {
	if len(salt) == 0 {
		salt = make([]byte, sha256.Size)
	}
	m := hmac.New(sha256.New, salt)
	m.Write(ikm)
	return m.Sum(nil)
}

func hkdfExpand(prk, info []byte, n int) []byte {
	out := make([]byte, 0, n)
	var t []byte
	for i := byte(1); len(out) < n; i++ {
		m := hmac.New(sha256.New, prk)
		m.Write(t)
		m.Write(info)
		m.Write([]byte{i})
		t = m.Sum(nil)
		out = append(out, t...)
	}
	return out[:n]
}

// sessionKeys is everything one carrier connection needs: an AEAD per
// direction, plus a block cipher per direction used to mask the frame length
// prefix. Masking the length is what stops the stream from looking like clean
// length-delimited framing to anything watching it go past.
type sessionKeys struct {
	tx     cipher.AEAD
	rx     cipher.AEAD
	maskTx cipher.Block
	maskRx cipher.Block
}

func blockFrom(key []byte) cipher.Block {
	b, err := aes.NewCipher(key)
	if err != nil {
		panic(err) // key length is fixed at 32 by the caller
	}
	return b
}

// deriveSession turns the PSK plus both handshake nonces into four independent
// keys. Every carrier gets its own set, because every carrier runs its own
// handshake with fresh nonces - so no two connections, and no two directions,
// ever share a keystream.
func deriveSession(psk, nonceC, nonceS []byte, carrier uint16, dialer bool) *sessionKeys {
	salt := make([]byte, 0, len(nonceC)+len(nonceS)+2)
	salt = append(salt, nonceC...)
	salt = append(salt, nonceS...)
	salt = append(salt, byte(carrier>>8), byte(carrier))
	prk := hkdfExtract(salt, psk)

	c2s := hkdfExpand(prk, []byte("pingify/v3 c2s"), 32)
	s2c := hkdfExpand(prk, []byte("pingify/v3 s2c"), 32)
	lenC2S := hkdfExpand(prk, []byte("pingify/v3 len c2s"), 32)
	lenS2C := hkdfExpand(prk, []byte("pingify/v3 len s2c"), 32)

	if dialer {
		return &sessionKeys{aeadFrom(c2s), aeadFrom(s2c), blockFrom(lenC2S), blockFrom(lenS2C)}
	}
	return &sessionKeys{aeadFrom(s2c), aeadFrom(c2s), blockFrom(lenS2C), blockFrom(lenC2S)}
}

// maskLen XORs the four-byte length prefix with an AES block keyed per
// direction and indexed by the frame counter. One block cipher call per frame
// is nothing next to encrypting the payload, and it removes the last piece of
// visible structure from the stream.
func maskLen(b cipher.Block, ctr uint64, p []byte) {
	var in, out [16]byte
	binary.BigEndian.PutUint64(in[8:], ctr)
	b.Encrypt(out[:], in[:])
	for i := 0; i < 4; i++ {
		p[i] ^= out[i]
	}
}

// ==========================================================================
// 4. handshake and the carrier pool
// ==========================================================================

// ---------------------------------------------------------------------------
// handshake
//
//	dialer  -> listener : NONCE(16) SEALED(16) TAG(32) PAD(0..255)
//	listener -> dialer  : NONCE(16) TAG(32)     PAD(0..255)
//
// Not one byte of this is constant. There is no magic number and no plaintext
// version, role, carrier index or timestamp: those sixteen bytes are XORed
// with an AES block keyed by the pre-shared key and this connection's nonce,
// so two handshakes never share a byte. The length varies too, because the
// amount of trailing padding is read out of the tag - unpredictable to an
// observer, known to both ends.
//
// That matters more than it sounds. The previous revision opened every
// connection with the four ASCII bytes "PFY2", which is a one-line signature
// for anything doing deep packet inspection.
//
// A wrong key, a stale timestamp or a replayed nonce all end the same way: the
// socket closes after a random delay without a byte of reply, so a scanner
// cannot tell the port from a black hole.
// ---------------------------------------------------------------------------

const (
	hsVersion   = 3
	hsNonceLen  = 16
	hsSealedLen = 16
	hsTagLen    = 32
	hsClientLen = hsNonceLen + hsSealedLen + hsTagLen
	hsServerLen = hsNonceLen + hsTagLen
	hsSkew      = 180 * time.Second
)

var errHandshake = errors.New("handshake rejected")

func roleByte(role string) byte {
	if role == "server" {
		return 0
	}
	return 1
}

type replayGuard struct {
	mu   sync.Mutex
	seen map[[16]byte]int64
}

func newReplayGuard() *replayGuard {
	g := &replayGuard{seen: make(map[[16]byte]int64)}
	go func() {
		t := time.NewTicker(time.Minute)
		for range t.C {
			cut := time.Now().Add(-2 * hsSkew).UnixNano()
			g.mu.Lock()
			for k, v := range g.seen {
				if v < cut {
					delete(g.seen, k)
				}
			}
			g.mu.Unlock()
		}
	}()
	return g
}

func (g *replayGuard) accept(n [16]byte) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if _, dup := g.seen[n]; dup {
		return false
	}
	g.seen[n] = time.Now().UnixNano()
	return true
}

func aeadFrom(key []byte) cipher.AEAD {
	blk, err := aes.NewCipher(key)
	if err != nil {
		panic(err) // key length is fixed at 32 by deriveKeys
	}
	a, err := cipher.NewGCM(blk)
	if err != nil {
		panic(err)
	}
	return a
}

// headerPad XORs the 16 header bytes with a one-time AES block keyed by the
// pre-shared key and this connection's nonce. Both ends can compute it; nobody
// else can, and the result carries no recognisable structure.
func headerPad(psk, nonce []byte) [16]byte {
	k := hkdfExpand(hkdfExtract(nonce, psk), []byte("pingify/v3 header"), 32)
	blk, err := aes.NewCipher(k)
	if err != nil {
		panic(err)
	}
	var out [16]byte
	blk.Encrypt(out[:], nonce)
	return out
}

// writePadding appends the trailing random bytes. The count comes out of the
// tag, so the handshake is never the same length twice.
func writePadding(conn net.Conn, tag []byte) error {
	n := int(tag[0])
	if n == 0 {
		return nil
	}
	pad := make([]byte, n)
	if _, err := rand.Read(pad); err != nil {
		return err
	}
	_, err := conn.Write(pad)
	return err
}

func readPadding(conn net.Conn, tag []byte) error {
	n := int(tag[0])
	if n == 0 {
		return nil
	}
	_, err := io.CopyN(io.Discard, conn, int64(n))
	return err
}

// clientHandshake runs on the side that dials out.
func clientHandshake(conn net.Conn, cfg *Config, carrier int) (*sessionKeys, error) {
	psk := cfg.key()
	buf := make([]byte, hsClientLen)
	nonceC := buf[:hsNonceLen]
	sealed := buf[hsNonceLen : hsNonceLen+hsSealedLen]
	tag := buf[hsNonceLen+hsSealedLen:]

	if _, err := rand.Read(nonceC); err != nil {
		return nil, err
	}
	var hdr [16]byte
	hdr[0] = hsVersion
	hdr[1] = roleByte(cfg.Role)
	binary.BigEndian.PutUint16(hdr[2:4], uint16(carrier))
	binary.BigEndian.PutUint64(hdr[4:12], uint64(time.Now().Unix()))
	if _, err := rand.Read(hdr[12:]); err != nil { // filler, never inspected
		return nil, err
	}
	pad := headerPad(psk, nonceC)
	for i := range hdr {
		sealed[i] = hdr[i] ^ pad[i]
	}
	m := hmac.New(sha256.New, psk)
	m.Write(nonceC)
	m.Write(sealed)
	copy(tag, m.Sum(nil))

	conn.SetDeadline(time.Now().Add(15 * time.Second))
	if _, err := conn.Write(buf); err != nil {
		return nil, err
	}
	if err := writePadding(conn, tag); err != nil {
		return nil, err
	}

	resp := make([]byte, hsServerLen)
	if _, err := io.ReadFull(conn, resp); err != nil {
		return nil, err
	}
	m2 := hmac.New(sha256.New, psk)
	m2.Write([]byte("pingify/v3 server"))
	m2.Write(nonceC)
	m2.Write(resp[:hsNonceLen])
	if !hmac.Equal(m2.Sum(nil), resp[hsNonceLen:]) {
		return nil, errHandshake
	}
	if err := readPadding(conn, resp[hsNonceLen:]); err != nil {
		return nil, err
	}
	conn.SetDeadline(time.Time{})

	return deriveSession(psk, nonceC, resp[:hsNonceLen], uint16(carrier), true), nil
}

// serverHandshake runs on the side that listens.
func serverHandshake(conn net.Conn, cfg *Config, g *replayGuard) (*sessionKeys, int, error) {
	psk := cfg.key()
	buf := make([]byte, hsClientLen)
	conn.SetDeadline(time.Now().Add(15 * time.Second))
	if _, err := io.ReadFull(conn, buf); err != nil {
		return nil, 0, err
	}
	nonceC := buf[:hsNonceLen]
	sealed := buf[hsNonceLen : hsNonceLen+hsSealedLen]
	tag := buf[hsNonceLen+hsSealedLen:]

	// Authenticate before trusting a single field.
	m := hmac.New(sha256.New, psk)
	m.Write(nonceC)
	m.Write(sealed)
	if !hmac.Equal(m.Sum(nil), tag) {
		return nil, 0, errHandshake
	}
	var nc [16]byte
	copy(nc[:], nonceC)
	if !g.accept(nc) {
		return nil, 0, errHandshake
	}

	pad := headerPad(psk, nonceC)
	var hdr [16]byte
	for i := range hdr {
		hdr[i] = sealed[i] ^ pad[i]
	}
	if hdr[0] != hsVersion {
		return nil, 0, errHandshake
	}
	if hdr[1] == roleByte(cfg.Role) {
		return nil, 0, errHandshake // both ends configured with the same role
	}
	ts := int64(binary.BigEndian.Uint64(hdr[4:12]))
	if d := time.Since(time.Unix(ts, 0)); d > hsSkew || d < -hsSkew {
		return nil, 0, errHandshake
	}
	carrier := int(binary.BigEndian.Uint16(hdr[2:4]))

	if err := readPadding(conn, tag); err != nil {
		return nil, 0, err
	}

	resp := make([]byte, hsServerLen)
	if _, err := rand.Read(resp[:hsNonceLen]); err != nil {
		return nil, 0, err
	}
	m2 := hmac.New(sha256.New, psk)
	m2.Write([]byte("pingify/v3 server"))
	m2.Write(nonceC)
	m2.Write(resp[:hsNonceLen])
	copy(resp[hsNonceLen:], m2.Sum(nil))
	if _, err := conn.Write(resp); err != nil {
		return nil, 0, err
	}
	if err := writePadding(conn, resp[hsNonceLen:]); err != nil {
		return nil, 0, err
	}
	conn.SetDeadline(time.Time{})

	return deriveSession(psk, nonceC, resp[:hsNonceLen], uint16(carrier), false), carrier, nil
}

// ---------------------------------------------------------------------------
// carrier pool
// ---------------------------------------------------------------------------

const maxCarriers = 64

// No carrier is declared dead before this much true silence, whatever the
// local keepalive is set to. See link.idleLimit.
const minIdle = 60 * time.Second

type recordHandler interface {
	onRecord(l *link, cmd byte, id uint32, body []byte)
	onLinkDown(l *link)
}

type pool struct {
	cfg *Config

	mu    sync.RWMutex
	links [maxCarriers]*link
	h     recordHandler

	ln        net.Listener
	icmp      *icmpTransport
	guard     *replayGuard
	closed    chan struct{}
	closeOnce sync.Once

	startedAt time.Time
}

func newPool(cfg *Config) *pool {
	return &pool{cfg: cfg, guard: newReplayGuard(), closed: make(chan struct{}), startedAt: time.Now()}
}

func (p *pool) setHandler(h recordHandler) {
	p.mu.Lock()
	p.h = h
	p.mu.Unlock()
}

func (p *pool) handler() recordHandler {
	p.mu.RLock()
	h := p.h
	p.mu.RUnlock()
	return h
}

func (p *pool) start() error {
	// The echo transport owns a single raw socket for every carrier, so it is
	// set up once here rather than per connection.
	if p.cfg.Transport == "icmp" {
		t, err := newICMPTransport(p.cfg.key())
		if err != nil {
			return err
		}
		p.icmp = t
		go t.reap()
		if p.cfg.Connect != "" {
			for i := 0; i < p.cfg.Carriers; i++ {
				go p.dialLoop(i)
			}
			logInfo("opening %d echo carriers to %s", p.cfg.Carriers, p.cfg.Connect)
		} else {
			go p.acceptEcho()
			logInfo("waiting for echo carriers")
		}
		return nil
	}
	if p.cfg.Connect != "" {
		for i := 0; i < p.cfg.Carriers; i++ {
			go p.dialLoop(i)
		}
		logInfo("dialling %d carriers to %s", p.cfg.Carriers, p.cfg.Connect)
		return nil
	}
	ln, err := net.Listen("tcp", p.cfg.Listen)
	if err != nil {
		return err
	}
	p.ln = ln
	go p.acceptLoop(ln)
	logInfo("waiting for carriers on %s", p.cfg.Listen)
	return nil
}

func (p *pool) acceptEcho() {
	for {
		c, err := p.icmp.Accept()
		if err != nil {
			return
		}
		go p.serveInbound(c)
	}
}

// dialCarrier opens one carrier with whichever transport is configured.
func (p *pool) dialCarrier(idx int) (net.Conn, error) {
	if p.icmp != nil {
		host := p.cfg.Connect
		if h, _, err := net.SplitHostPort(host); err == nil {
			host = h
		}
		return p.icmp.Dial(host, idx)
	}
	return net.DialTimeout("tcp", p.cfg.Connect, time.Duration(p.cfg.DialTimeout)*time.Second)
}

func (p *pool) acceptLoop(ln net.Listener) {
	for {
		conn, err := ln.Accept()
		if err != nil {
			select {
			case <-p.closed:
				return
			default:
			}
			logWarn("accept: %v", err)
			time.Sleep(200 * time.Millisecond)
			continue
		}
		go p.serveInbound(conn)
	}
}

func (p *pool) serveInbound(conn net.Conn) {
	tuneSocket(conn, p.cfg)
	keys, idx, err := serverHandshake(conn, p.cfg, p.guard)
	if err != nil {
		// Stay quiet: a probe should learn nothing from timing or content.
		time.Sleep(time.Duration(200+mrand.Intn(600)) * time.Millisecond)
		conn.Close()
		logDebug("rejected %s: %v", conn.RemoteAddr(), err)
		return
	}
	if idx < 0 || idx >= maxCarriers {
		conn.Close()
		return
	}
	if idx >= p.cfg.Carriers {
		// Not fatal - the pool holds it either way - but it means the two
		// configs were written with different tuning, and every setting that
		// has to match is now suspect.
		logWarn("carrier %d arrived but this side is configured for %d: the two ends disagree on [transport] carriers",
			idx, p.cfg.Carriers)
	}
	l := newLink(idx, p.cfg, conn, keys, p)
	p.install(idx, l)
	logInfo("carrier %d up from %s", idx, conn.RemoteAddr())
	l.run()
}

func (p *pool) dialLoop(idx int) {
	backoff := 500 * time.Millisecond
	for {
		select {
		case <-p.closed:
			return
		default:
		}
		conn, err := p.dialCarrier(idx)
		if err != nil {
			logWarn("carrier %d dial %s: %v", idx, p.cfg.Connect, err)
			p.sleepBackoff(&backoff)
			continue
		}
		tuneSocket(conn, p.cfg)
		keys, err := clientHandshake(conn, p.cfg, idx)
		if err != nil {
			conn.Close()
			logWarn("carrier %d handshake: %v (check the key on both servers)", idx, err)
			p.sleepBackoff(&backoff)
			continue
		}
		backoff = 500 * time.Millisecond
		l := newLink(idx, p.cfg, conn, keys, p)
		p.install(idx, l)
		logInfo("carrier %d up to %s", idx, p.cfg.Connect)
		l.run() // blocks until the carrier dies
		select {
		case <-p.closed:
			return
		case <-time.After(300 * time.Millisecond):
		}
	}
}

func (p *pool) sleepBackoff(b *time.Duration) {
	j := time.Duration(mrand.Int63n(int64(*b/2 + 1)))
	select {
	case <-time.After(*b + j):
	case <-p.closed:
	}
	if *b < 8*time.Second {
		*b *= 2
	}
}

func (p *pool) install(idx int, l *link) {
	p.mu.Lock()
	old := p.links[idx]
	p.links[idx] = l
	p.mu.Unlock()
	if old != nil && old != l {
		old.close()
	}
}

// pick returns the live carrier with the fewest open streams. Spreading
// streams this way keeps every carrier's congestion window busy, which is the
// whole point of running more than one.
func (p *pool) pick() *link {
	p.mu.RLock()
	defer p.mu.RUnlock()
	var best *link
	bestN := 1 << 30
	for _, l := range p.links {
		if l == nil || !l.alive() {
			continue
		}
		if n := l.streamCount(); n < bestN {
			best, bestN = l, n
		}
	}
	return best
}

// pickHash pins a flow to a carrier by hash so that packets of one inner
// connection always take the same path and never arrive out of order.
func (p *pool) pickHash(h uint32) *link {
	p.mu.RLock()
	defer p.mu.RUnlock()
	n := 0
	for _, l := range p.links {
		if l != nil && l.alive() {
			n++
		}
	}
	if n == 0 {
		return nil
	}
	// Two passes rather than building a slice: in tun mode this runs once per
	// packet, and an allocation there would show up as GC pressure.
	k := int(h % uint32(n))
	for _, l := range p.links {
		if l != nil && l.alive() {
			if k == 0 {
				return l
			}
			k--
		}
	}
	return nil
}

func (p *pool) liveLinks() []*link {
	p.mu.RLock()
	defer p.mu.RUnlock()
	out := make([]*link, 0, maxCarriers)
	for _, l := range p.links {
		if l != nil {
			out = append(out, l)
		}
	}
	return out
}

func (p *pool) close() {
	p.closeOnce.Do(func() {
		close(p.closed)
		if p.ln != nil {
			p.ln.Close()
		}
		if p.icmp != nil {
			p.icmp.Close()
		}
		p.mu.Lock()
		links := p.links
		p.links = [maxCarriers]*link{}
		p.mu.Unlock()
		for _, l := range links {
			if l != nil {
				l.close()
			}
		}
	})
}

func (p *pool) stats() (up int, tx, rx uint64, rttUS int64) {
	for _, l := range p.liveLinks() {
		if !l.alive() {
			continue
		}
		up++
		tx += atomic.LoadUint64(&l.txBytes)
		rx += atomic.LoadUint64(&l.rxBytes)
		if r := atomic.LoadInt64(&l.rttUS); r > rttUS {
			rttUS = r
		}
	}
	return
}

// ==========================================================================
// 5. framing, encryption and stream multiplexing
// ==========================================================================

// ---------------------------------------------------------------------------
// wire format
//
// Every carrier connection carries a stream of frames:
//
//	[4-byte big-endian ciphertext length][AES-256-GCM ciphertext]
//
// The plaintext of a frame is one or more back-to-back records:
//
//	[1-byte cmd][4-byte stream id][4-byte payload length][payload]
//
// The writer coalesces everything queued at that instant into a single frame,
// so a burst of small packets costs one seal and one write syscall instead of
// dozens. That batching is most of the throughput win over a naive tunnel.
// ---------------------------------------------------------------------------

const (
	recHdr    = 9
	maxRecord = 32 * 1024
	maxPlain  = 128 * 1024
	maxFrame  = maxPlain + 64

	// Control records - window credits, keepalives, opens and closes - are a
	// handful of bytes each and vastly outnumber data records. Giving them
	// their own small pool keeps a four-byte credit update from borrowing a
	// 32 KiB buffer, which is where most of the idle memory used to go.
	smallRecord = 512

	sendQueue      = 128 // records queued per carrier before the writer blocks
	earlyPadFrames = 8   // pad only the opening frames of a connection
	earlyPadMax    = 512
)

const (
	cmdData = 1  // stream payload
	cmdSYN  = 2  // open TCP stream; payload = target "host:port"
	cmdFIN  = 3  // half-close: no more data from this side
	cmdRST  = 4  // hard close
	cmdWND  = 5  // flow-control credit; payload = 4-byte byte count
	cmdPing = 6  // payload = 8-byte stamp
	cmdPong = 7  // echo of the ping payload
	cmdUSYN = 8  // open UDP session; payload = target "host:port"
	cmdUDP  = 9  // one UDP datagram
	cmdUFIN = 10 // UDP session gone
	cmdTUN  = 11 // one raw IP packet (tun mode)
	cmdPad  = 12 // random filler, discarded on arrival
)

var errLinkClosed = errors.New("carrier closed")

// ---------------------------------------------------------------------------
// pooled records
// ---------------------------------------------------------------------------

type recBuf struct {
	a   []byte
	n   int
	big bool
}

func (r *recBuf) body() []byte  { return r.a[recHdr:] }
func (r *recBuf) bytes() []byte { return r.a[:r.n] }

func (r *recBuf) seal(cmd byte, id uint32, n int) {
	r.a[0] = cmd
	binary.BigEndian.PutUint32(r.a[1:5], id)
	binary.BigEndian.PutUint32(r.a[5:9], uint32(n))
	r.n = recHdr + n
}

var bigPool = sync.Pool{New: func() interface{} {
	return &recBuf{a: make([]byte, recHdr+maxRecord), big: true}
}}

var smallPool = sync.Pool{New: func() interface{} {
	return &recBuf{a: make([]byte, recHdr+smallRecord)}
}}

// getRec hands out a full-size buffer, for the data path.
func getRec() *recBuf { return bigPool.Get().(*recBuf) }

// getCtrl sizes the buffer to the payload, so a keepalive does not cost 32 KiB.
func getCtrl(payload int) *recBuf {
	if payload <= smallRecord {
		return smallPool.Get().(*recBuf)
	}
	return bigPool.Get().(*recBuf)
}

func putRec(r *recBuf) {
	if r.big {
		bigPool.Put(r)
	} else {
		smallPool.Put(r)
	}
}

func ctrlRec(cmd byte, id uint32, payload []byte) *recBuf {
	r := getCtrl(len(payload))
	copy(r.a[recHdr:], payload)
	r.seal(cmd, id, len(payload))
	return r
}

// appendPad tacks a random-length filler record onto a frame.
func appendPad(frame []byte) []byte {
	n := mrand.Intn(earlyPadMax)
	if n == 0 {
		return frame
	}
	var hdr [recHdr]byte
	hdr[0] = cmdPad
	binary.BigEndian.PutUint32(hdr[5:9], uint32(n))
	frame = append(frame, hdr[:]...)
	start := len(frame)
	frame = append(frame, make([]byte, n)...)
	rand.Read(frame[start:])
	return frame
}

// ---------------------------------------------------------------------------
// receive buffer: byte-bounded, never blocks the carrier reader
// ---------------------------------------------------------------------------

type recvBuf struct {
	mu  sync.Mutex
	cv  *sync.Cond
	buf bytes.Buffer
	eof bool
	err error
}

func newRecvBuf() *recvBuf {
	r := &recvBuf{}
	r.cv = sync.NewCond(&r.mu)
	return r
}

func (r *recvBuf) push(p []byte) {
	r.mu.Lock()
	if r.err == nil && !r.eof {
		r.buf.Write(p)
	}
	r.cv.Broadcast()
	r.mu.Unlock()
}

func (r *recvBuf) Read(p []byte) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for r.buf.Len() == 0 {
		if r.err != nil {
			return 0, r.err
		}
		if r.eof {
			return 0, io.EOF
		}
		r.cv.Wait()
	}
	return r.buf.Read(p)
}

func (r *recvBuf) closeEOF() {
	r.mu.Lock()
	r.eof = true
	r.cv.Broadcast()
	r.mu.Unlock()
}

func (r *recvBuf) fail(err error) {
	r.mu.Lock()
	if r.err == nil {
		r.err = err
	}
	r.cv.Broadcast()
	r.mu.Unlock()
}

// ---------------------------------------------------------------------------
// stream
// ---------------------------------------------------------------------------

// stream is one multiplexed TCP connection riding a single carrier. It never
// migrates between carriers: a stream is pinned at open time so its bytes can
// never be reordered by uneven carrier latency, which is what would otherwise
// make the inner TCP connection collapse.
type stream struct {
	id     uint32
	l      *link
	rb     *recvBuf
	win    int32
	winCh  chan struct{}
	done   chan struct{}
	once   sync.Once
	halves int32

	lmu   sync.Mutex
	local net.Conn
	dead  bool
}

// attach hands the stream its local socket. A stream is registered the moment
// its SYN is parsed, before the dial finishes, so that data arriving right
// behind the SYN is buffered instead of dropped; attach closes that gap.
func (s *stream) attach(c net.Conn) bool {
	s.lmu.Lock()
	defer s.lmu.Unlock()
	if s.dead {
		return false
	}
	s.local = c
	return true
}

// halfDone retires the stream once both directions have finished. Without it
// a completed connection would sit in the carrier's stream table forever and
// its local socket would never be closed.
func (s *stream) halfDone() {
	if atomic.AddInt32(&s.halves, 1) == 2 {
		s.reset()
	}
}

func (s *stream) acquireUpTo(max int32) int32 {
	for {
		cur := atomic.LoadInt32(&s.win)
		if cur > 0 {
			n := cur
			if n > max {
				n = max
			}
			if atomic.CompareAndSwapInt32(&s.win, cur, cur-n) {
				return n
			}
			continue
		}
		select {
		case <-s.winCh:
		case <-s.done:
			return 0
		case <-s.l.closed:
			return 0
		}
	}
}

func (s *stream) addWin(n int32) {
	if n <= 0 {
		return
	}
	atomic.AddInt32(&s.win, n)
	select {
	case s.winCh <- struct{}{}:
	default:
	}
}

// pumpOut moves bytes from the local socket into the carrier, never sending
// more than the credit the far side has granted.
func (s *stream) pumpOut(local net.Conn) {
	defer s.halfDone()
	defer s.l.send(ctrlRec(cmdFIN, s.id, nil))
	for {
		credit := s.acquireUpTo(maxRecord)
		if credit == 0 {
			return
		}
		r := getRec()
		n, err := local.Read(r.body()[:credit])
		if n > 0 {
			r.seal(cmdData, s.id, n)
			atomic.AddUint64(&s.l.txBytes, uint64(n))
			if !s.l.send(r) {
				return
			}
		} else {
			putRec(r)
		}
		s.addWin(credit - int32(n)) // hand back the slice we did not use
		if err != nil {
			return
		}
	}
}

// pumpIn drains the receive buffer into the local socket and returns the
// consumed credit to the far side.
func (s *stream) pumpIn(local net.Conn) {
	defer s.halfDone()
	buf := make([]byte, 32*1024)
	for {
		n, err := s.rb.Read(buf)
		if n > 0 {
			if _, werr := local.Write(buf[:n]); werr != nil {
				s.reset()
				return
			}
			atomic.AddUint64(&s.l.rxBytes, uint64(n))
			var c [4]byte
			binary.BigEndian.PutUint32(c[:], uint32(n))
			s.l.send(ctrlRec(cmdWND, s.id, c[:]))
		}
		if err != nil {
			// Far side stopped sending: half-close so the local peer sees EOF
			// but can still finish its own upload.
			if cw, ok := local.(interface{ CloseWrite() error }); ok {
				cw.CloseWrite()
			} else {
				s.reset()
			}
			return
		}
	}
}

func (s *stream) reset() {
	s.once.Do(func() {
		close(s.done)
		s.rb.fail(errLinkClosed)
		s.lmu.Lock()
		s.dead = true
		c := s.local
		s.lmu.Unlock()
		if c != nil {
			c.Close()
		}
		s.l.removeStream(s.id)
	})
}

// ---------------------------------------------------------------------------
// link
// ---------------------------------------------------------------------------

type link struct {
	idx  int
	cfg  *Config
	conn net.Conn
	pool *pool

	keys  *sessionKeys
	txCtr uint64
	rxCtr uint64

	sendQ     chan *recBuf
	closed    chan struct{}
	closeOnce sync.Once

	mu      sync.Mutex
	streams map[uint32]*stream
	nextID  uint32

	obf     bool   // mask frame lengths and pad the opening frames
	downWhy string // why the carrier died; read once, when it is logged

	txBytes uint64 // payload carried for streams, tun and UDP
	rxBytes uint64
	// Bytes actually written to and read from the socket, keepalives and all.
	// txBytes only counts payload, so an idle tunnel reports zero either way
	// and cannot answer the one question that matters when nothing works:
	// did our bytes leave this machine, and did any of theirs arrive?
	wireTx  uint64
	wireRx  uint64
	lastRx  int64 // unix nano
	rttUS   int64
	upSince int64
}

func newLink(idx int, cfg *Config, conn net.Conn, k *sessionKeys, p *pool) *link {
	l := &link{
		idx: idx, cfg: cfg, conn: conn, pool: p, obf: cfg.obfuscated(),
		keys:    k,
		sendQ:   make(chan *recBuf, sendQueue),
		closed:  make(chan struct{}),
		streams: make(map[uint32]*stream),
	}
	// Odd ids from the edge, even from the origin. Ids are per-carrier, so this
	// is only belt and braces against a future origin-initiated stream.
	if cfg.Role == "server" {
		l.nextID = 1
	} else {
		l.nextID = 2
	}
	now := time.Now().UnixNano()
	atomic.StoreInt64(&l.lastRx, now)
	atomic.StoreInt64(&l.upSince, now)
	return l
}

func (l *link) run() {
	go l.writeLoop()
	go l.keepaliveLoop()
	l.readLoop()
}

func (l *link) alive() bool {
	select {
	case <-l.closed:
		return false
	default:
		return true
	}
}

// died records why this carrier is going away and then closes it. The first
// reason wins: the read loop, the write loop and the keepalive all race to
// close a dying carrier, and the first one to notice knows the most.
func (l *link) died(format string, a ...interface{}) {
	l.mu.Lock()
	if l.downWhy == "" {
		l.downWhy = fmt.Sprintf(format, a...)
	}
	l.mu.Unlock()
	l.close()
}

func (l *link) send(r *recBuf) bool {
	select {
	case l.sendQ <- r:
		return true
	case <-l.closed:
		putRec(r)
		return false
	}
}

func (l *link) trySend(r *recBuf) bool {
	select {
	case l.sendQ <- r:
		return true
	default:
		putRec(r)
		return false
	}
}

func nonceFor(ctr uint64) [12]byte {
	var n [12]byte
	binary.BigEndian.PutUint64(n[4:], ctr)
	return n
}

func (l *link) writeLoop() {
	defer l.close()
	frame := make([]byte, 0, maxPlain)
	out := make([]byte, 0, 4+maxPlain+32)
	for {
		var r *recBuf
		select {
		case r = <-l.sendQ:
		case <-l.closed:
			return
		}
		frame = append(frame[:0], r.bytes()...)
		putRec(r)
	drain:
		for len(frame) <= maxPlain-recHdr-maxRecord {
			select {
			case r2 := <-l.sendQ:
				frame = append(frame, r2.bytes()...)
				putRec(r2)
			default:
				break drain
			}
		}
		// Only the opening frames are padded. That is where a fingerprint
		// would be taken, and padding every frame would cost real bandwidth.
		if ctr := l.txCtr; l.obf && ctr < earlyPadFrames && len(frame) < maxPlain-recHdr-earlyPadMax {
			frame = appendPad(frame)
		}
		ctr := l.txCtr
		l.txCtr++
		n := nonceFor(ctr)
		out = out[:4]
		out = l.keys.tx.Seal(out, n[:], frame, nil)
		binary.BigEndian.PutUint32(out[:4], uint32(len(out)-4))
		if l.obf {
			maskLen(l.keys.maskTx, ctr, out[:4])
		}
		l.conn.SetWriteDeadline(time.Now().Add(60 * time.Second))
		if _, err := l.conn.Write(out); err != nil {
			l.died("write: %v", err)
			return
		}
		atomic.AddUint64(&l.wireTx, uint64(len(out)))
		out = out[:0]
	}
}

// readReason turns a socket error into something worth reading at 4am. A
// timeout means nothing arrived and the peer may be fine; a reset means
// something actively tore the connection down, which on this path is usually
// not the peer.
func readReason(err error, idle time.Duration) string {
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		return fmt.Sprintf("nothing received for %s - the peer stopped sending, or the path dropped it", idle)
	}
	if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
		return "peer closed the connection"
	}
	if errors.Is(err, syscall.ECONNRESET) {
		return "connection reset - something on the path killed it, not the peer"
	}
	return "read: " + err.Error()
}

func (l *link) readLoop() {
	defer l.close()
	var hdr [4]byte
	ct := make([]byte, 0, maxFrame)
	plain := make([]byte, 0, maxPlain)
	idle := l.idleLimit()
	for {
		l.conn.SetReadDeadline(time.Now().Add(idle))
		if _, err := io.ReadFull(l.conn, hdr[:]); err != nil {
			l.died("%s", readReason(err, idle))
			return
		}
		if l.obf {
			maskLen(l.keys.maskRx, l.rxCtr, hdr[:]) // XOR is its own inverse
		}
		n := int(binary.BigEndian.Uint32(hdr[:]))
		if n < 16 || n > maxFrame {
			l.died("bad frame length %d - the two ends disagree or something rewrote the stream", n)
			return
		}
		if cap(ct) < n {
			ct = make([]byte, 0, n)
		}
		ct = ct[:n]
		if _, err := io.ReadFull(l.conn, ct); err != nil {
			l.died("%s", readReason(err, idle))
			return
		}
		atomic.AddUint64(&l.wireRx, uint64(len(hdr)+n))
		nc := nonceFor(l.rxCtr)
		l.rxCtr++
		p, err := l.keys.rx.Open(plain[:0], nc[:], ct, nil)
		if err != nil {
			l.died("authentication failed - the token does not match, or a middlebox altered the stream")
			return
		}
		plain = p[:0]
		atomic.StoreInt64(&l.lastRx, time.Now().UnixNano())
		if err := l.dispatch(p); err != nil {
			l.died("%v", err)
			return
		}
	}
}

func (l *link) dispatch(p []byte) error {
	for len(p) > 0 {
		if len(p) < recHdr {
			return fmt.Errorf("truncated record header")
		}
		cmd := p[0]
		id := binary.BigEndian.Uint32(p[1:5])
		n := int(binary.BigEndian.Uint32(p[5:9]))
		if n > maxRecord || len(p) < recHdr+n {
			return fmt.Errorf("truncated record body")
		}
		body := p[recHdr : recHdr+n]
		p = p[recHdr+n:]

		switch cmd {
		case cmdData:
			if s := l.getStream(id); s != nil {
				s.rb.push(body)
			}
		case cmdWND:
			if n == 4 {
				if s := l.getStream(id); s != nil {
					s.addWin(int32(binary.BigEndian.Uint32(body)))
				}
			}
		case cmdFIN:
			if s := l.getStream(id); s != nil {
				s.rb.closeEOF()
			}
		case cmdRST:
			if n > 0 {
				// Sent by the far side, which is the only end that knows why.
				logWarn("the other server refused a connection: %s", string(body))
			}
			if s := l.getStream(id); s != nil {
				s.reset()
			}
		case cmdPad:
			// deliberately ignored
		case cmdPing:
			// Never block the read loop: if the send queue is momentarily
			// full, drop the pong rather than risk both ends stalling on
			// each other's socket buffers.
			l.trySend(ctrlRec(cmdPong, 0, body))
		case cmdPong:
			if n == 8 {
				sent := int64(binary.BigEndian.Uint64(body))
				atomic.StoreInt64(&l.rttUS, (time.Now().UnixNano()-sent)/1000)
			}
		case cmdSYN, cmdUSYN, cmdUDP, cmdUFIN, cmdTUN:
			if h := l.pool.handler(); h != nil {
				h.onRecord(l, cmd, id, body)
			}
		default:
			logDebug("carrier %d: unknown cmd %d", l.idx, cmd)
		}
	}
	return nil
}

// idleLimit is how long a carrier waits before declaring the peer gone.
//
// It cannot simply be three of our own keepalives. Our keepalive says how
// often WE speak; what keeps this carrier alive is how often the PEER speaks,
// and the peer is configured separately, by hand, on another machine. A field
// tunnel built with "gaming" on one end and "balanced" on the other had one
// side hanging up every nine seconds while the other was still perfectly
// happy. The floor makes that impossible: however impatient this end is
// configured to be, it waits a full minute of real silence before giving up.
func (l *link) idleLimit() time.Duration {
	d := time.Duration(l.cfg.KeepaliveSec) * time.Second * 3
	if d < minIdle {
		return minIdle
	}
	return d
}

func (l *link) keepaliveLoop() {
	t := time.NewTicker(time.Duration(l.cfg.KeepaliveSec) * time.Second)
	defer t.Stop()
	idle := int64(l.idleLimit())
	for {
		select {
		case <-t.C:
			if time.Now().UnixNano()-atomic.LoadInt64(&l.lastRx) > idle {
				l.died("silent for %s - nothing came back from the peer", l.idleLimit())
				return
			}
			var b [8]byte
			binary.BigEndian.PutUint64(b[:], uint64(time.Now().UnixNano()))
			l.send(ctrlRec(cmdPing, 0, b[:]))
		case <-l.closed:
			return
		}
	}
}

func (l *link) close() {
	l.closeOnce.Do(func() {
		close(l.closed)
		l.conn.Close()
		l.mu.Lock()
		streams := make([]*stream, 0, len(l.streams))
		for _, s := range l.streams {
			streams = append(streams, s)
		}
		l.streams = make(map[uint32]*stream)
		why := l.downWhy
		l.mu.Unlock()
		for _, s := range streams {
			s.reset()
		}
		if l.pool != nil {
			if h := l.pool.handler(); h != nil {
				h.onLinkDown(l)
			}
		}
		if why == "" {
			why = "closed locally"
		}
		logInfo("carrier %d down: %s (up %s)", l.idx, why,
			time.Since(time.Unix(0, atomic.LoadInt64(&l.upSince))).Round(time.Second))
	})
}

// ---------------------------------------------------------------------------
// stream table
// ---------------------------------------------------------------------------

func (l *link) window() int32 { return int32(l.cfg.WindowKB) * 1024 }

func (l *link) newStream(local net.Conn) *stream {
	l.mu.Lock()
	id := l.nextID
	l.nextID += 2
	s := l.mkStream(id, local)
	l.streams[id] = s
	l.mu.Unlock()
	return s
}

func (l *link) acceptStream(id uint32, local net.Conn) *stream {
	l.mu.Lock()
	if _, dup := l.streams[id]; dup {
		l.mu.Unlock()
		return nil
	}
	s := l.mkStream(id, local)
	l.streams[id] = s
	l.mu.Unlock()
	return s
}

func (l *link) mkStream(id uint32, local net.Conn) *stream {
	return &stream{
		id:    id,
		l:     l,
		rb:    newRecvBuf(),
		win:   l.window(),
		winCh: make(chan struct{}, 1),
		done:  make(chan struct{}),
		local: local,
	}
}

func (l *link) getStream(id uint32) *stream {
	l.mu.Lock()
	s := l.streams[id]
	l.mu.Unlock()
	return s
}

func (l *link) removeStream(id uint32) {
	l.mu.Lock()
	delete(l.streams, id)
	l.mu.Unlock()
}

func (l *link) streamCount() int {
	l.mu.Lock()
	n := len(l.streams)
	l.mu.Unlock()
	return n
}

// ==========================================================================
// 6. forward mode - TCP/UDP port forwarding
// ==========================================================================

// forward mode: the edge owns the user-facing ports and the origin owns the
// real services. Everything in between rides the carrier pool.

const (
	udpIDBit    = 0x80000000
	udpIdleSec  = 90
	udpReadSize = 64 * 1024
)

type sessKey struct {
	l  *link
	id uint32
}

type udpSess struct {
	l   *link
	id  uint32
	pc  net.PacketConn
	cli net.Addr // edge side: where the client's datagrams came from
	key string   // edge side: map key

	// The origin dials the real service off the carrier's read loop, so that
	// a slow DNS lookup cannot stall every other stream on that carrier.
	// Datagrams that arrive while the dial is in flight wait here instead of
	// being dropped - losing the first packet of a UDP exchange would often
	// mean losing the whole exchange.
	mu      sync.Mutex
	uc      *net.UDPConn
	pending [][]byte
	dialed  bool

	last int64
}

const udpPendingMax = 8

// deliver hands one datagram to the real service, queueing it if the socket is
// not ready yet.
func (s *udpSess) deliver(b []byte) {
	s.mu.Lock()
	if s.uc != nil {
		uc := s.uc
		s.mu.Unlock()
		uc.Write(b)
		return
	}
	if !s.dialed && len(s.pending) < udpPendingMax {
		s.pending = append(s.pending, append([]byte(nil), b...))
	}
	s.mu.Unlock()
}

// ready installs the dialled socket and flushes whatever queued up.
func (s *udpSess) ready(uc *net.UDPConn) {
	s.mu.Lock()
	s.uc = uc
	s.dialed = true
	q := s.pending
	s.pending = nil
	s.mu.Unlock()
	for _, b := range q {
		uc.Write(b)
	}
}

func (s *udpSess) socket() *net.UDPConn {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.uc
}

type forwarder struct {
	cfg *Config
	p   *pool

	listeners []net.Listener
	packets   []net.PacketConn

	mu    sync.Mutex
	edge  map[string]*udpSess  // edge: "lport|clientaddr" -> session
	byID  map[sessKey]*udpSess // both sides: (carrier, id) -> session
	udpSq uint32

	allow  map[string]bool
	closed chan struct{}
	once   sync.Once
}

func startForward(cfg *Config, p *pool) (*forwarder, error) {
	f := &forwarder{
		cfg:    cfg,
		p:      p,
		edge:   make(map[string]*udpSess),
		byID:   make(map[sessKey]*udpSess),
		closed: make(chan struct{}),
	}
	if len(cfg.Allow) > 0 {
		f.allow = make(map[string]bool, len(cfg.Allow))
		for _, a := range cfg.Allow {
			f.allow[a] = true
		}
	}
	p.setHandler(f)

	if cfg.Role == "server" {
		for _, spec := range cfg.Forwards {
			rules, err := parseForward(spec)
			if err != nil {
				f.Close()
				return nil, err
			}
			for _, r := range rules {
				if err := f.bind(r); err != nil {
					f.Close()
					return nil, err
				}
			}
		}
	}
	go f.reapUDP()
	return f, nil
}

func (f *forwarder) bind(r fwdRule) error {
	addr := net.JoinHostPort(f.cfg.BindAddr, strconv.Itoa(r.lport))
	if r.proto == "udp" {
		pc, err := net.ListenPacket("udp", addr)
		if err != nil {
			return fmt.Errorf("listen udp %s: %v", addr, err)
		}
		f.packets = append(f.packets, pc)
		go f.serveUDP(pc, r)
		logInfo("forward udp %s -> %s", addr, r.target)
		return nil
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("listen tcp %s: %v", addr, err)
	}
	f.listeners = append(f.listeners, ln)
	go f.serveTCP(ln, r)
	logInfo("forward tcp %s -> %s", addr, r.target)
	return nil
}

// ---------------------------------------------------------------------------
// edge: TCP
// ---------------------------------------------------------------------------

func (f *forwarder) serveTCP(ln net.Listener, r fwdRule) {
	for {
		c, err := ln.Accept()
		if err != nil {
			select {
			case <-f.closed:
				return
			default:
			}
			logWarn("accept :%d: %v", r.lport, err)
			time.Sleep(100 * time.Millisecond)
			continue
		}
		go f.openStream(c, r)
	}
}

func (f *forwarder) openStream(c net.Conn, r fwdRule) {
	tuneSocket(c, f.cfg)
	l := f.p.pick()
	if l == nil {
		logWarn("no carrier up, dropping connection to :%d", r.lport)
		c.Close()
		return
	}
	s := l.newStream(c)
	if !l.send(ctrlRec(cmdSYN, s.id, []byte(r.target))) {
		s.reset()
		return
	}
	go s.pumpIn(c)
	s.pumpOut(c)
}

// ---------------------------------------------------------------------------
// edge: UDP
// ---------------------------------------------------------------------------

func (f *forwarder) serveUDP(pc net.PacketConn, r fwdRule) {
	buf := make([]byte, udpReadSize)
	for {
		n, addr, err := pc.ReadFrom(buf)
		if err != nil {
			select {
			case <-f.closed:
				return
			default:
			}
			logWarn("udp read :%d: %v", r.lport, err)
			return
		}
		if n > maxRecord {
			continue
		}
		key := strconv.Itoa(r.lport) + "|" + addr.String()
		f.mu.Lock()
		s := f.edge[key]
		if s == nil {
			l := f.p.pickHash(hash5([]byte(key)))
			if l == nil {
				f.mu.Unlock()
				continue
			}
			id := (atomic.AddUint32(&f.udpSq, 1) & 0x7fffffff) | udpIDBit
			s = &udpSess{l: l, id: id, pc: pc, cli: addr, key: key}
			f.edge[key] = s
			f.byID[sessKey{l, id}] = s
			f.mu.Unlock()
			l.send(ctrlRec(cmdUSYN, id, []byte(r.target)))
		} else {
			f.mu.Unlock()
		}
		atomic.StoreInt64(&s.last, time.Now().UnixNano())
		if !s.l.alive() {
			f.dropUDP(s)
			continue
		}
		atomic.AddUint64(&s.l.txBytes, uint64(n))
		s.l.send(ctrlRec(cmdUDP, s.id, buf[:n]))
	}
}

// ---------------------------------------------------------------------------
// origin: incoming records
// ---------------------------------------------------------------------------

func (f *forwarder) onRecord(l *link, cmd byte, id uint32, body []byte) {
	switch cmd {
	case cmdSYN:
		// Register before dialling: the data records for this stream are
		// usually already in flight behind the SYN.
		s := l.acceptStream(id, nil)
		if s == nil {
			return
		}
		go f.dialTCP(s, string(body))
	case cmdUSYN:
		f.openUDP(l, id, string(body))
	case cmdUDP:
		f.mu.Lock()
		s := f.byID[sessKey{l, id}]
		f.mu.Unlock()
		if s == nil {
			return
		}
		atomic.StoreInt64(&s.last, time.Now().UnixNano())
		atomic.AddUint64(&l.rxBytes, uint64(len(body)))
		if s.pc != nil {
			s.pc.WriteTo(body, s.cli) // edge -> the user
		} else {
			s.deliver(body) // origin -> the real service
		}
	case cmdUFIN:
		f.mu.Lock()
		s := f.byID[sessKey{l, id}]
		f.mu.Unlock()
		if s != nil {
			f.dropUDP(s)
		}
	}
}

func (f *forwarder) targetAllowed(target string) bool {
	if f.allow == nil {
		return true
	}
	return f.allow[target]
}

func (f *forwarder) dialTCP(s *stream, target string) {
	// The reason travels back with the reset. Without it the other server
	// closes the user's connection with nothing to say, and "the tunnel does
	// not work" is indistinguishable from "the service is not running here".
	refuse := func(why string) {
		logWarn("stream to %s: %s", target, why)
		s.l.send(ctrlRec(cmdRST, s.id, []byte(target+": "+why)))
		s.reset()
	}
	if !f.targetAllowed(target) {
		refuse("not in allow list")
		return
	}
	c, err := net.DialTimeout("tcp", target, time.Duration(f.cfg.DialTimeout)*time.Second)
	if err != nil {
		refuse(err.Error())
		return
	}
	tuneSocket(c, f.cfg)
	if !s.attach(c) {
		c.Close()
		return
	}
	go s.pumpIn(c)
	s.pumpOut(c)
}

// openUDP registers the session immediately - so datagrams following the USYN
// find it - and dials in the background.
func (f *forwarder) openUDP(l *link, id uint32, target string) {
	if !f.targetAllowed(target) {
		l.send(ctrlRec(cmdUFIN, id, nil))
		return
	}
	s := &udpSess{l: l, id: id}
	atomic.StoreInt64(&s.last, time.Now().UnixNano())
	f.mu.Lock()
	if old := f.byID[sessKey{l, id}]; old != nil {
		f.mu.Unlock()
		return
	}
	f.byID[sessKey{l, id}] = s
	f.mu.Unlock()

	go func() {
		ua, err := net.ResolveUDPAddr("udp", target)
		if err != nil {
			logWarn("resolve udp %s: %v", target, err)
			f.dropUDP(s)
			return
		}
		uc, err := net.DialUDP("udp", nil, ua)
		if err != nil {
			logWarn("dial udp %s: %v", target, err)
			f.dropUDP(s)
			return
		}
		s.ready(uc)

		buf := make([]byte, udpReadSize)
		for {
			uc.SetReadDeadline(time.Now().Add(udpIdleSec * time.Second))
			n, err := uc.Read(buf)
			if n > 0 && n <= maxRecord {
				atomic.StoreInt64(&s.last, time.Now().UnixNano())
				atomic.AddUint64(&l.txBytes, uint64(n))
				if !l.send(ctrlRec(cmdUDP, id, buf[:n])) {
					break
				}
			}
			if err != nil {
				break
			}
		}
		f.dropUDP(s)
	}()
}

func (f *forwarder) dropUDP(s *udpSess) {
	f.mu.Lock()
	if f.byID[sessKey{s.l, s.id}] != s {
		f.mu.Unlock()
		return
	}
	delete(f.byID, sessKey{s.l, s.id})
	if s.key != "" {
		delete(f.edge, s.key)
	}
	f.mu.Unlock()
	if uc := s.socket(); uc != nil {
		uc.Close()
	}
	if s.l.alive() {
		s.l.send(ctrlRec(cmdUFIN, s.id, nil))
	}
}

func (f *forwarder) reapUDP() {
	t := time.NewTicker(30 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-t.C:
		case <-f.closed:
			return
		}
		cut := time.Now().Add(-udpIdleSec * time.Second).UnixNano()
		var dead []*udpSess
		f.mu.Lock()
		for _, s := range f.byID {
			if atomic.LoadInt64(&s.last) < cut || !s.l.alive() {
				dead = append(dead, s)
			}
		}
		f.mu.Unlock()
		for _, s := range dead {
			f.dropUDP(s)
		}
	}
}

func (f *forwarder) onLinkDown(l *link) {
	var dead []*udpSess
	f.mu.Lock()
	for k, s := range f.byID {
		if k.l == l {
			dead = append(dead, s)
		}
	}
	f.mu.Unlock()
	for _, s := range dead {
		f.dropUDP(s)
	}
}

func (f *forwarder) Close() error {
	f.once.Do(func() {
		close(f.closed)
		for _, ln := range f.listeners {
			ln.Close()
		}
		for _, pc := range f.packets {
			pc.Close()
		}
	})
	return nil
}

// ==========================================================================
// 7. tun mode - layer 3
// ==========================================================================

// tun mode carries whole IP packets instead of individual TCP connections.
// It is the right choice when the far side must be reachable as a machine
// (routing, ICMP, any protocol) rather than as a list of ports.

type tunnel struct {
	cfg    *Config
	p      *pool
	queues []*os.File
	wrIdx  uint32
	closed chan struct{}
	once   sync.Once
}

func startTUN(cfg *Config, p *pool) (*tunnel, error) {
	t := &tunnel{cfg: cfg, p: p, closed: make(chan struct{})}
	n := cfg.Carriers
	if n < 1 {
		n = 1
	}
	if n > 8 {
		n = 8 // more queues than this stops helping and costs descriptors
	}
	for i := 0; i < n; i++ {
		f, err := openTUN(cfg.TUN.Name, n > 1)
		if err != nil {
			t.Close()
			return nil, fmt.Errorf("open %s queue %d: %v", cfg.TUN.Name, i, err)
		}
		t.queues = append(t.queues, f)
	}
	if err := configureTUN(cfg.TUN); err != nil {
		t.Close()
		return nil, err
	}
	p.setHandler(t)
	for i := range t.queues {
		go t.readQueue(t.queues[i])
	}
	logInfo("tun %s up: %s peer %s mtu %d, %d queues",
		cfg.TUN.Name, cfg.TUN.Local, cfg.TUN.Peer, cfg.TUN.MTU, len(t.queues))
	return t, nil
}

func configureTUN(c TUNConfig) error {
	run := func(args ...string) error {
		out, err := exec.Command("ip", args...).CombinedOutput()
		if err != nil {
			msg := strings.TrimSpace(string(out))
			// Re-adding an address after a restart is expected, not an error.
			if strings.Contains(msg, "File exists") {
				return nil
			}
			return fmt.Errorf("ip %s: %v: %s", strings.Join(args, " "), err, msg)
		}
		return nil
	}
	if err := run("link", "set", "dev", c.Name, "mtu", fmt.Sprint(c.MTU), "up"); err != nil {
		return err
	}
	if c.Local != "" {
		// The "peer" form is right for a point-to-point /30 or /32. On a
		// wider prefix both addresses live in the same subnet and a plain
		// address is what gives the kernel the route it needs.
		pfx := ""
		if i := strings.LastIndex(c.Local, "/"); i >= 0 {
			pfx = c.Local[i+1:]
		}
		ptp := c.Peer != "" && (pfx == "30" || pfx == "31" || pfx == "32")
		if ptp {
			peer := c.Peer
			if i := strings.Index(peer, "/"); i >= 0 {
				peer = peer[:i]
			}
			if err := run("addr", "add", c.Local, "peer", peer, "dev", c.Name); err != nil {
				return err
			}
		} else if err := run("addr", "add", c.Local, "dev", c.Name); err != nil {
			return err
		}
	}
	return nil
}

func (t *tunnel) readQueue(f *os.File) {
	for {
		r := getRec()
		n, err := f.Read(r.body())
		if n > 0 {
			r.seal(cmdTUN, 0, n)
			l := t.p.pickHash(flowHash(r.body()[:n]))
			if l == nil {
				putRec(r)
			} else {
				atomic.AddUint64(&l.txBytes, uint64(n))
				l.send(r)
			}
		} else {
			putRec(r)
		}
		if err != nil {
			select {
			case <-t.closed:
			default:
				logWarn("tun read: %v", err)
			}
			return
		}
	}
}

func (t *tunnel) onRecord(l *link, cmd byte, id uint32, body []byte) {
	if cmd != cmdTUN || len(t.queues) == 0 {
		return
	}
	atomic.AddUint64(&l.rxBytes, uint64(len(body)))
	q := t.queues[int(atomic.AddUint32(&t.wrIdx, 1))%len(t.queues)]
	if _, err := q.Write(body); err != nil {
		logDebug("tun write: %v", err)
	}
}

func (t *tunnel) onLinkDown(*link) {}

// bothHandler runs a private layer-3 link and port forwarding over the same
// carriers. Raw IP packets go to the tun device, everything else to the
// forwarder, so one tunnel can give you a private network between the two
// servers and forwarded ports at the same time.
type bothHandler struct {
	f *forwarder
	t *tunnel
}

func (b *bothHandler) onRecord(l *link, cmd byte, id uint32, body []byte) {
	if cmd == cmdTUN {
		b.t.onRecord(l, cmd, id, body)
		return
	}
	b.f.onRecord(l, cmd, id, body)
}

func (b *bothHandler) onLinkDown(l *link) {
	b.f.onLinkDown(l)
	b.t.onLinkDown(l)
}

func (b *bothHandler) Close() error {
	b.f.Close()
	b.t.Close()
	return nil
}

func (t *tunnel) Close() error {
	t.once.Do(func() {
		close(t.closed)
		for _, f := range t.queues {
			f.Close()
		}
	})
	return nil
}

// flowHash folds the 5-tuple of an IP packet into one number. Every packet of
// a given inner connection lands on the same carrier, so the inner TCP never
// sees the reordering that unequal carrier latency would otherwise create.
func flowHash(pkt []byte) uint32 {
	h := uint32(2166136261)
	mix := func(b []byte) {
		for _, c := range b {
			h ^= uint32(c)
			h *= 16777619
		}
	}
	if len(pkt) < 20 {
		return 0
	}
	switch pkt[0] >> 4 {
	case 4:
		ihl := int(pkt[0]&0x0f) * 4
		if ihl < 20 || len(pkt) < ihl {
			return 0
		}
		mix(pkt[12:20]) // src + dst
		proto := pkt[9]
		mix([]byte{proto})
		if (proto == 6 || proto == 17) && len(pkt) >= ihl+4 {
			mix(pkt[ihl : ihl+4]) // src + dst port
		}
	case 6:
		if len(pkt) < 40 {
			return 0
		}
		mix(pkt[8:40])
		nh := pkt[6]
		mix([]byte{nh})
		if (nh == 6 || nh == 17) && len(pkt) >= 44 {
			mix(pkt[40:44])
		}
	}
	return h
}

// ==========================================================================
// 8. socket tuning and forward specs
// ==========================================================================

// tuneSocket applies the settings that actually move the needle on a
// long-haul, lossy Iran<->Kharej path: no Nagle delay on the carrier, and
// socket buffers big enough to hold a full bandwidth-delay product.
func tuneSocket(c net.Conn, cfg *Config) {
	tc, ok := c.(*net.TCPConn)
	if !ok {
		return
	}
	tc.SetNoDelay(true)
	tc.SetKeepAlive(true)
	tc.SetKeepAlivePeriod(30e9)
	if cfg.SndBufKB > 0 {
		tc.SetWriteBuffer(cfg.SndBufKB * 1024)
	}
	if cfg.RcvBufKB > 0 {
		tc.SetReadBuffer(cfg.RcvBufKB * 1024)
	}
}

// ---------------------------------------------------------------------------
// forward specs
//
//	443                      tcp :443        -> 127.0.0.1:443
//	443=8443                 tcp :443        -> 127.0.0.1:8443
//	443=10.0.0.5:8443        tcp :443        -> 10.0.0.5:8443
//	8000-8010                tcp :8000..8010 -> 127.0.0.1:same
//	8000-8010=9000           tcp :8000..8010 -> 127.0.0.1:9000..9010
//	udp:500=500              udp :500        -> 127.0.0.1:500
// ---------------------------------------------------------------------------

type fwdRule struct {
	proto  string // "tcp" or "udp"
	lport  int
	target string // "host:port"
}

func parseForward(spec string) ([]fwdRule, error) {
	s := strings.TrimSpace(spec)
	if s == "" {
		return nil, fmt.Errorf("empty forward")
	}
	proto := "tcp"
	if i := strings.Index(s, ":"); i >= 0 {
		switch strings.ToLower(s[:i]) {
		case "tcp":
			proto, s = "tcp", s[i+1:]
		case "udp":
			proto, s = "udp", s[i+1:]
		}
	}

	local, remote := s, ""
	if i := strings.Index(s, "="); i >= 0 {
		local, remote = s[:i], s[i+1:]
	}

	lo, hi, err := parsePortRange(local)
	if err != nil {
		return nil, fmt.Errorf("%q: %v", spec, err)
	}

	host := "127.0.0.1"
	rbase := 0
	if remote != "" {
		rp := remote
		if i := strings.LastIndex(remote, ":"); i >= 0 {
			host, rp = remote[:i], remote[i+1:]
			if host == "" {
				host = "127.0.0.1"
			}
		}
		if rp != "" {
			rbase, err = strconv.Atoi(rp)
			if err != nil || rbase < 1 || rbase > 65535 {
				return nil, fmt.Errorf("%q: bad target port %q", spec, rp)
			}
		}
	}

	out := make([]fwdRule, 0, hi-lo+1)
	for pt := lo; pt <= hi; pt++ {
		rp := pt
		if rbase > 0 {
			rp = rbase + (pt - lo)
			if rp > 65535 {
				return nil, fmt.Errorf("%q: target port range overflows", spec)
			}
		}
		out = append(out, fwdRule{
			proto:  proto,
			lport:  pt,
			target: net.JoinHostPort(host, strconv.Itoa(rp)),
		})
	}
	return out, nil
}

func parsePortRange(s string) (int, int, error) {
	if i := strings.Index(s, "-"); i >= 0 {
		lo, e1 := strconv.Atoi(strings.TrimSpace(s[:i]))
		hi, e2 := strconv.Atoi(strings.TrimSpace(s[i+1:]))
		if e1 != nil || e2 != nil || lo < 1 || hi > 65535 || lo > hi {
			return 0, 0, fmt.Errorf("bad port range %q", s)
		}
		if hi-lo > 512 {
			return 0, 0, fmt.Errorf("port range %q is wider than 512 ports", s)
		}
		return lo, hi, nil
	}
	p, err := strconv.Atoi(strings.TrimSpace(s))
	if err != nil || p < 1 || p > 65535 {
		return 0, 0, fmt.Errorf("bad port %q", s)
	}
	return p, p, nil
}

// hash5 is a FNV-1a over the fields that identify one inner flow. It is what
// keeps a flow glued to a single carrier.
func hash5(b []byte) uint32 {
	h := uint32(2166136261)
	for _, c := range b {
		h ^= uint32(c)
		h *= 16777619
	}
	return h
}

// ==========================================================================
// 9. status endpoint
// ==========================================================================

// A tiny loopback-only status endpoint. The manager script reads it for the
// health check, so the check reflects what the engine actually sees rather
// than merely whether the process exists.

type carrierStatus struct {
	Index   int     `json:"index"`
	Up      bool    `json:"up"`
	Streams int     `json:"streams"`
	TxBytes uint64  `json:"tx_bytes"`
	RxBytes uint64  `json:"rx_bytes"`
	WireTx  uint64  `json:"wire_tx_bytes"`
	WireRx  uint64  `json:"wire_rx_bytes"`
	RTTms   float64 `json:"rtt_ms"`
	UptimeS int64   `json:"uptime_s"`
}

type statusDoc struct {
	Name      string          `json:"name"`
	Version   string          `json:"version"`
	Role      string          `json:"role"`
	Mode      string          `json:"mode"`
	Transport string          `json:"transport"`
	Peer      string          `json:"peer"`
	Healthy   bool            `json:"healthy"`
	Carriers  int             `json:"carriers_configured"`
	Up        int             `json:"carriers_up"`
	Streams   int             `json:"streams"`
	TxBytes   uint64          `json:"tx_bytes"`
	RxBytes   uint64          `json:"rx_bytes"`
	WireTx    uint64          `json:"wire_tx_bytes"`
	WireRx    uint64          `json:"wire_rx_bytes"`
	RTTms     float64         `json:"rtt_ms"`
	UptimeS   int64           `json:"uptime_s"`
	Detail    []carrierStatus `json:"detail"`
}

func startStatusServer(addr string, cfg *Config, p *pool) {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		logWarn("status endpoint %s: %v", addr, err)
		return
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/status", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(snapshot(cfg, p))
	})
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		if snapshot(cfg, p).Healthy {
			w.WriteHeader(http.StatusOK)
			w.Write([]byte("ok\n"))
			return
		}
		w.WriteHeader(http.StatusServiceUnavailable)
		w.Write([]byte("no carrier\n"))
	})
	srv := &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go srv.Serve(ln)
	logInfo("status endpoint on http://%s/status", addr)
}

func snapshot(cfg *Config, p *pool) statusDoc {
	d := statusDoc{
		Name:      cfg.Name,
		Version:   version,
		Role:      cfg.Role,
		Mode:      cfg.Mode,
		Transport: cfg.Transport,
		Peer:      cfg.Connect,
		Carriers:  cfg.Carriers,
		UptimeS:   int64(time.Since(p.startedAt).Seconds()),
	}
	if d.Peer == "" {
		d.Peer = "listen " + cfg.Listen
	}
	now := time.Now().UnixNano()
	for _, l := range p.liveLinks() {
		cs := carrierStatus{
			Index:   l.idx,
			Up:      l.alive(),
			Streams: l.streamCount(),
			TxBytes: atomic.LoadUint64(&l.txBytes),
			RxBytes: atomic.LoadUint64(&l.rxBytes),
			WireTx:  atomic.LoadUint64(&l.wireTx),
			WireRx:  atomic.LoadUint64(&l.wireRx),
			RTTms:   float64(atomic.LoadInt64(&l.rttUS)) / 1000,
			UptimeS: (now - atomic.LoadInt64(&l.upSince)) / int64(time.Second),
		}
		if cs.Up {
			d.Up++
			d.Streams += cs.Streams
			if cs.RTTms > d.RTTms {
				d.RTTms = cs.RTTms
			}
		}
		d.TxBytes += cs.TxBytes
		d.RxBytes += cs.RxBytes
		d.WireTx += cs.WireTx
		d.WireRx += cs.WireRx
		d.Detail = append(d.Detail, cs)
	}
	d.Healthy = d.Up > 0
	return d
}

// ---------------------------------------------------------------------------
// client side of the status endpoint: keeps the manager script free of any
// JSON tooling, so it needs nothing beyond bash and systemd.
// ---------------------------------------------------------------------------

func fetchStatus(addr string) (*statusDoc, error) {
	c := &http.Client{Timeout: 3 * time.Second}
	resp, err := c.Get("http://" + addr + "/status")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var d statusDoc
	if err := json.NewDecoder(resp.Body).Decode(&d); err != nil {
		return nil, err
	}
	if !d.Healthy {
		return &d, fmt.Errorf("no carrier is up")
	}
	return &d, nil
}

func humanBytes(n uint64) string {
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	div, exp := uint64(unit), 0
	for v := n / unit; v >= unit && exp < 4; v /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(n)/float64(div), "KMGTP"[exp])
}

func humanDuration(sec int64) string {
	d := time.Duration(sec) * time.Second
	switch {
	case d >= 24*time.Hour:
		return fmt.Sprintf("%dd %dh", sec/86400, (sec%86400)/3600)
	case d >= time.Hour:
		return fmt.Sprintf("%dh %dm", sec/3600, (sec%3600)/60)
	case d >= time.Minute:
		return fmt.Sprintf("%dm %ds", sec/60, sec%60)
	}
	return fmt.Sprintf("%ds", sec)
}

// printStatus renders the status endpoint. It returns the process exit code so
// that scripts can branch on tunnel health without parsing anything.
func printStatus(addr string, brief bool) int {
	d, err := fetchStatus(addr)
	if d == nil {
		if brief {
			fmt.Println("down 0 0 0.0 0 0")
		} else {
			fmt.Printf("unreachable: %v\n", err)
		}
		return 1
	}
	if brief {
		state := "down"
		if d.Healthy {
			state = "up"
		}
		// state carriers_up carriers_total rtt_ms streams uptime_s
		fmt.Printf("%s %d %d %.1f %d %d\n", state, d.Up, d.Carriers, d.RTTms, d.Streams, d.UptimeS)
		if d.Healthy {
			return 0
		}
		return 1
	}

	state := "DOWN"
	if d.Healthy {
		state = "UP"
	}
	fmt.Printf("  tunnel     %s  (%s, %s, %s)\n", d.Name, d.Role, d.Mode, d.Transport)
	fmt.Printf("  state      %s  -  %d of %d carriers\n", state, d.Up, d.Carriers)
	fmt.Printf("  peer       %s\n", d.Peer)
	fmt.Printf("  rtt        %.1f ms\n", d.RTTms)
	fmt.Printf("  streams    %d open\n", d.Streams)
	fmt.Printf("  traffic    tx %s / rx %s   (payload)\n", humanBytes(d.TxBytes), humanBytes(d.RxBytes))
	fmt.Printf("  on the wire tx %s / rx %s   (everything, keepalives included)\n",
		humanBytes(d.WireTx), humanBytes(d.WireRx))
	if d.WireTx > 0 && d.WireRx == 0 {
		fmt.Printf("  %s\n", "NOTE: this server is sending and receiving nothing at all.")
		fmt.Printf("  %s\n", "      Check the same two numbers on the other server. If it is also")
		fmt.Printf("  %s\n", "      sending with nothing arriving, the bytes are leaving both")
		fmt.Printf("  %s\n", "      machines and dying on the path between them.")
	}
	fmt.Printf("  uptime     %s\n", humanDuration(d.UptimeS))
	if len(d.Detail) > 0 {
		fmt.Printf("\n  %-4s %-6s %-8s %-9s %-12s %-12s %-12s %-12s\n",
			"#", "state", "streams", "rtt", "tx", "rx", "wire tx", "wire rx")
		for _, c := range d.Detail {
			cs := "down"
			if c.Up {
				cs = "up"
			}
			fmt.Printf("  %-4d %-6s %-8d %-9s %-12s %-12s %-12s %-12s\n",
				c.Index, cs, c.Streams, fmt.Sprintf("%.1f ms", c.RTTms),
				humanBytes(c.TxBytes), humanBytes(c.RxBytes),
				humanBytes(c.WireTx), humanBytes(c.WireRx))
		}
	}
	if d.Healthy {
		return 0
	}
	return 1
}
