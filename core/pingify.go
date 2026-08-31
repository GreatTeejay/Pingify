// Pingify engine - one encrypted tunnel between an Iran server and a server
// abroad, carried over several parallel TCP connections.
//
// The rule this file was written under still holds: an Iranian server
// frequently cannot reach proxy.golang.org, so the engine must compile with
// GOPROXY=off and no module download of any kind.
//
// It is no longer standard-library only. KCP, its Reed-Solomon parity and the
// raw-packet transport brought real dependencies, and they are vendored under
// core/vendor and shipped inside Pingify.sh - which is how the rule is kept
// rather than broken: nothing is ever fetched, it is already there. Everything
// hand-rolled here that a module could have provided stays hand-rolled,
// because replacing working code with a dependency buys nothing.
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
	"encoding/base64"
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
	"runtime"
	"sort"
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

const version = "1.2.0"

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

	// CarriersAsked remembers a carrier count a transport would not honour,
	// so the startup line can say the setting was not used rather than
	// quietly running something else. Never read from a config file.
	CarriersAsked int `json:"-"`
	WindowKB      int `json:"window_kb"`

	// forward mode: "443", "443=8443", "443=10.0.0.5:8443", "udp:500=500",
	// "8000-8010" (range, same port on the far side).
	Forwards []string `json:"forwards,omitempty"`

	// BindAddr is the address the forwarded ports listen on. Empty means every
	// interface, which is what an Iran server wants: clients arrive from
	// outside. Setting it to 127.0.0.1 keeps the ports off the network, which
	// is what the tests want and what a host firewall stops asking about.
	BindAddr string `json:"bind_addr,omitempty"`

	// A real certificate for the WSS transport, when there is one. Without
	// them a self-signed one is generated - the tunnel trusts its token
	// rather than the certificate, so this is about looking ordinary to
	// anything that opens the page, not about proving who we are.
	CertFile string `json:"cert_file,omitempty"`
	KeyFile  string `json:"key_file,omitempty"`

	// WSHost is the name a ws or wss carrier presents: the TLS SNI and the
	// HTTP Host header. Empty means take it from the address being dialled,
	// which is what a tunnel that goes straight to the server wants.
	//
	// The name and the address are separate because a CDN routes on the name
	// and never looks at the address. That is the whole trick: dial an edge
	// that is cheap or unfiltered where the client is, present the domain the
	// CDN knows, and the address dialled never names the server at all.
	WSHost string `json:"ws_host,omitempty"`
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
	// It must be the same on both servers. Nil means off.
	//
	// Off is the default because on did not survive the field. A tunnel
	// between Iran and Europe carried its opening frames - the padded ones -
	// and then stopped, in both directions, within seconds of the padding
	// running out. That is the moment every frame on an idle carrier becomes
	// exactly the same size on exactly the same schedule across eight
	// connections at once. Whatever removed that traffic, masking the lengths
	// did not help, and v2.1.1 without any of it worked on the same path.
	Obfuscate *bool `json:"obfuscate,omitempty"`

	// Encrypt seals every frame with AES-256-GCM. A pointer so leaving it out
	// means yes: a config written before the setting existed keeps what it had.
	//
	// Turning it off is a real choice, not a free one. GCM is what proves a
	// frame came from the other server unaltered, so without it anything that
	// can put a packet on the carrier can put data into the tunnel - and the
	// shape of our framing is on the wire for anything that looks, which is
	// what the WebSocket transports exist to avoid.
	//
	// What it is not is expensive. Measured here it seals around 8.8 GB/s and
	// opens at 9.5; a hundred-megabit tunnel is 12.5 MB/s, so the cipher is
	// roughly a tenth of one percent of one core. If a tunnel feels heavy,
	// this is not where the weight is.
	Encrypt     *bool `json:"encrypt,omitempty"`
	DialTimeout int   `json:"dial_timeout_sec,omitempty"`
	SndBufKB    int   `json:"sndbuf_kb,omitempty"`
	RcvBufKB    int   `json:"rcvbuf_kb,omitempty"`
	// Profile selects latency/throughput trade-offs that are not expressible
	// as a socket buffer alone, notably packet receive batch size and worker
	// count. Old configs leave it empty and receive the balanced defaults.
	Profile string `json:"profile,omitempty"`

	// Packet transports use the same low-latency KCP/FEC shape. Keeping the
	// values in the config makes both ends explicit and lets a lossy route be
	// tuned without recompiling the core.
	FECData     int    `json:"fec_data,omitempty"`
	FECParity   int    `json:"fec_parity,omitempty"`
	PacketMTU   int    `json:"packet_mtu,omitempty"`
	KCPInterval int    `json:"kcp_interval_ms,omitempty"`
	PCKFlags    string `json:"pck_flags,omitempty"`
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
	websocket := c.Transport == "ws" || c.Transport == "wss"
	if c.Carriers == 0 {
		if websocket {
			c.Carriers = wsConnsDefault
		} else {
			c.Carriers = 4
		}
	}
	// ws and wss multiplex, so they need very few connections and must not be
	// allowed many.
	//
	// Twenty WebSockets opened at once from one address is the most
	// recognisable thing a tunnel can do, and a carrier here is already a
	// multiplexer - streams by id, with a credit window each - so a couple of
	// them is not a couple of streams, it is every stream shared over two
	// connections.
	//
	// Two rather than one. One is the quietest shape there is and it is also
	// a tunnel with no spare: the moment that connection goes, every stream
	// on it goes with it and nothing crosses until it is back. The field
	// report that read "it still drops" was exactly that. A second connection
	// costs nothing anybody is looking for - a browser holds two or three
	// open all day - and it turns a cut into a hiccup. Four is the ceiling,
	// because twenty was the shape that got noticed.
	//
	// What the config asked for is kept, so that startup can say the setting
	// was cut rather than quietly running something else.
	if websocket && c.Carriers > wsMaxConns {
		c.CarriersAsked = c.Carriers
		c.Carriers = wsMaxConns
	}
	if c.WindowKB == 0 {
		// 512 KiB per stream is roughly 50 Mbit/s on an 80 ms path, and it
		// bounds what one stalled connection can hold in memory. Raise it for
		// a very fat link; every open stream can buffer this much.
		c.WindowKB = 512
	}
	if c.KeepaliveSec == 0 {
		c.KeepaliveSec = 10
	}
	if c.DialTimeout == 0 {
		c.DialTimeout = 10
	}
	// The receive buffer is where a packet transport's delay lives, and it is
	// deliberately not large.
	//
	// Until these were asked for without the kernel's clamp, whatever was
	// written here was cut to net.core.rmem_max - 208 KiB on an ordinary
	// server - and nothing said so. That was costing packets: a raw socket
	// that small overflows in bursts, the kernel throws them away before any
	// of this code is reached, and the TCP inside reads it as congestion.
	//
	// Lifting the clamp fixed that and then went too far the other way. A
	// buffer that never overflows does not stop queueing - it queues instead
	// of dropping, and delay does not show up in a drop counter. Swept on a
	// real 68 ms path with sixteen streams pushing, measuring the round trip
	// across the link while they ran:
	//
	//	2 MiB    p50  77 ms   p90  90 ms   350 Mbit/s
	//	3 MiB    p50  82 ms   p90  96 ms   415 Mbit/s
	//	4 MiB    p50 110 ms   p90 123 ms   424 Mbit/s
	//	6 MiB    p50 132 ms   p90 176 ms   432 Mbit/s
	//
	// Three is where the curve turns. Below it the buffer is too small to
	// absorb a burst and throughput falls away; above it every megabyte buys
	// a few more bits per second with tens of milliseconds of delay. At three
	// a burst still has somewhere to go and a standing queue does not - it is
	// well under a round trip of packets, so the sender inside learns about
	// congestion from a drop rather than from a queue it cannot see.
	//
	// The send side is not the same problem - nothing waits behind it on this
	// machine - so it keeps room for a burst.
	if c.SndBufKB == 0 {
		c.SndBufKB = 16384
	}
	if c.RcvBufKB == 0 {
		c.RcvBufKB = 3072
	}
	c.Profile = strings.ToLower(strings.TrimSpace(c.Profile))
	if c.Profile == "" {
		c.Profile = "balanced"
	}
	// 5.29 briefly wrote this label instead of a real profile. Preserve those
	// configs while making every new/other unknown value a validation error.
	if c.Profile == "from token" {
		c.Profile = "custom"
	}
	if c.FECData == 0 {
		c.FECData = 10
	}
	if c.FECParity == 0 {
		c.FECParity = 3
	}
	if c.PacketMTU == 0 {
		c.PacketMTU = 1200
	}
	if c.KCPInterval == 0 {
		c.KCPInterval = 10
	}
	if c.PCKFlags == "" {
		c.PCKFlags = "PA"
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
	case "tcp", "icmp", "udp", "kcp", "pck", "ws", "wss", "mirage":
	default:
		return fmt.Errorf("transport %q is not available in this build", c.Transport)
	}
	if c.Carriers < 1 || c.Carriers > 64 {
		return fmt.Errorf("carriers must be between 1 and 64")
	}
	if c.WindowKB < 64 || c.WindowKB > 65536 {
		return fmt.Errorf("window_kb must be between 64 and 65536")
	}
	// Packet engines count a bounded 4096 segments internally. With the
	// configured MTUs, 4096 KiB stays below that bound; accepting a larger
	// number would put it in the file and then silently run a smaller window.
	switch c.Transport {
	case "icmp", "udp", "kcp", "pck":
		if c.WindowKB > 4096 {
			return fmt.Errorf("window_kb for %s must be between 64 and 4096", c.Transport)
		}
	}
	if c.KeepaliveSec < 1 || c.KeepaliveSec > 300 {
		return fmt.Errorf("keepalive_sec must be between 1 and 300")
	}
	if c.DialTimeout < 1 || c.DialTimeout > 300 {
		return fmt.Errorf("dial_timeout_sec must be between 1 and 300")
	}
	if c.SndBufKB < 64 || c.SndBufKB > 65536 || c.RcvBufKB < 64 || c.RcvBufKB > 65536 {
		return fmt.Errorf("sndbuf_kb and rcvbuf_kb must be between 64 and 65536")
	}
	switch c.Profile {
	case "gaming", "latency", "balanced", "throughput", "extreme", "custom":
	default:
		return fmt.Errorf("tuning profile %q is not valid", c.Profile)
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
	if c.FECData < 1 || c.FECData > 64 || c.FECParity < 1 || c.FECParity > 32 || c.FECData+c.FECParity > 96 {
		return fmt.Errorf("KCP FEC shards must be data 1..64, parity 1..32, total at most 96")
	}
	if c.PacketMTU < 576 || c.PacketMTU > 1400 {
		return fmt.Errorf("packet_mtu must be between 576 and 1400")
	}
	if c.KCPInterval < 5 || c.KCPInterval > 100 {
		return fmt.Errorf("kcp_interval_ms must be between 5 and 100")
	}
	if _, err := parsePCKFlags(c.PCKFlags); err != nil {
		return err
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
// Off unless asked for: see the note on Config.Obfuscate.
func (c *Config) obfuscated() bool { return c.Obfuscate != nil && *c.Obfuscate }

// encrypted is true unless the config says otherwise, so every tunnel that
// predates the setting keeps its cipher.
// carriesPackets says this tunnel puts whole IP packets on the wire with
// nothing underneath them to put the order back. See startPacketReaders.
func (c *Config) carriesPackets() bool {
	return c.Mode == "tun" || c.Mode == "both"
}

// encrypted says whether every frame and every private-link packet is sealed.
//
// It is off unless the config asks for it. The handshake is authenticated
// either way and the token still has to match, so nobody without it can build
// a tunnel here - but what crosses the wire afterwards is readable by anything
// on the path, and more distinguishable for it.
//
// That is a deliberate trade and it was asked for. On a server abroad without
// the PCLMULQDQ instruction - which is what a cheap VPS is - a third of the
// processor went into GCM's authenticator, and turning it off raised what the
// pair carried by half and dropped the tail under load from 380 ms to 82.
// Where the traffic inside is already TLS, which is nearly all of it, this
// seals nothing that was not already sealed.
//
// Set encrypt = true on both servers to have it back.
func (c *Config) encrypted() bool { return c.Encrypt != nil && *c.Encrypt }

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
		derive  = flag.String("derivekey", "", "print the keys a kernel tunnel derives from a security token, and exit")
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
	// GRE and AmneziaWG are carried by the kernel, so the security token
	// cannot protect them the way it protects our own transports - the kernel
	// has never heard of it. What it can do is be turned into the one secret
	// each of them does understand, so that answering the token question
	// still means something on both:
	//
	//	the base64 pre-shared key WireGuard mixes into every handshake
	//	the 32-bit key GRE stamps on every packet
	//
	// Both are derived, not stored, so the two servers reach the same values
	// from the same token without either one carrying them across.
	if *derive != "" {
		sum := sha256.Sum256([]byte("pingify-kernel-tunnel\x00" + *derive))
		greKey := binary.BigEndian.Uint32(sum[:4])
		fmt.Printf("%s %d\n", base64.StdEncoding.EncodeToString(sum[:]), greKey)
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
	logInfo("tuning applied: profile=%s window=%dKiB socket=%d/%dKiB",
		cfg.Profile, cfg.WindowKB, cfg.SndBufKB, cfg.RcvBufKB)
	if cfg.CarriersAsked > 0 {
		logInfo("%s multiplexes every stream onto each connection, so the %d configured were cut to %d",
			strings.ToUpper(cfg.Transport), cfg.CarriersAsked, cfg.Carriers)
	}
	if cfg.Transport == "kcp" || cfg.Transport == "pck" {
		logInfo("packet engine: KCP fast mode %dms, Reed-Solomon FEC %d+%d, MTU %d",
			cfg.KCPInterval, cfg.FECData, cfg.FECParity, cfg.PacketMTU)
	}
	if !cfg.obfuscated() {
		logInfo("traffic shaping is off: frame lengths are in the clear, and both servers must agree")
	}
	if !cfg.encrypted() {
		logWarn("frames are NOT encrypted: both servers must agree, and anything on the")
		logWarn("path can read and alter what crosses - only sound when what you carry")
		logWarn("is already encrypted, which Xray and the like are")
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
		_ = startStatusServer(cfg.StatusAddr, cfg, p) // a tunnel runs without it
	}

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	s := <-sig
	logInfo("received %s, shutting down", s)
	if top != nil {
		top.Close()
	}
	p.close()
	logFlush()
}

// ==========================================================================
// 2. logging
// ==========================================================================

// Five levels, not seven. panic and fatal say how a program died rather than
// how bad the news is, and both come out of this one as an error followed by
// the process ending - so they would only ever have been two more words for
// the same line. trace is worth its own level: it is the one that prints per
// packet, and mixing that into debug makes debug unusable.
//
//	error   something is broken and stays broken
//	warn    something is wrong but the tunnel carried on
//	info    the things worth knowing on a healthy tunnel
//	debug   why a carrier or a stream did what it did
//	trace   every packet - loud enough to slow a busy tunnel down
const (
	lvlError = 0
	lvlWarn  = 1
	lvlInfo  = 2
	lvlDebug = 3
	lvlTrace = 4
)

var logLevel int32 = lvlInfo

// logNames maps a level to what it is called, both ways round, so the manager
// and the core cannot drift on the spelling.
var logNames = []string{"error", "warn", "info", "debug", "trace"}

func setLogLevel(s string) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "error", "err", "fatal", "panic":
		atomic.StoreInt32(&logLevel, lvlError)
	case "warn", "warning":
		atomic.StoreInt32(&logLevel, lvlWarn)
	case "debug":
		atomic.StoreInt32(&logLevel, lvlDebug)
	case "trace":
		atomic.StoreInt32(&logLevel, lvlTrace)
	default:
		atomic.StoreInt32(&logLevel, lvlInfo)
	}
}

// logSink is where a formatted line goes. Only the tests replace it, so they
// can assert on what an operator would actually have seen - but they replace
// it while the tunnel they are watching is still running, and every goroutine
// in the process reads it. A plain assignment there is a data race, and the
// race detector is right about it, so the swap goes through atomic.Value.
var logSink atomic.Value // holds a func(string)

// stderrSink is where a line goes when nothing has replaced the sink, and
// under systemd that is a pipe to journald. A pipe blocks when it is full,
// and journald fills it whenever it is rate limiting, or the disk is busy, or
// the machine is small. So every log call was a place this process could
// stop - including the ones a carrier's read loop makes for the records it
// dispatches, while the socket it was reading went unread behind it.
//
// That is how a target being down became a tunnel being down. The far end
// refuses every connection there is, sends a record saying so for each one,
// and this end stopped to write a warning about each one. Behind the stalled
// reader the peer's send buffer filled, its keepalives never left the queue,
// and the carrier died of a minute of silence that was ours - then
// reconnected, and the flood started again.
//
// A log line is never worth a carrier. Lines go on a queue and a writer
// drains it; when the queue is full the line is dropped and counted, and the
// count goes out with the next line that fits. Logging that cannot keep up
// now costs log lines, which is the only thing it should ever have cost.
func stderrSink(line string) { stderrLog.write(line) }

var stderrLog = newAsyncWriter(os.Stderr)

// How many lines may be waiting before new ones are dropped. Large enough
// that an ordinary burst - every carrier in a braid reporting at once - is
// never lost, small enough that a wedged journald costs a few hundred
// kilobytes rather than the heap.
const logQueue = 4096

type asyncWriter struct {
	q       chan string
	dropped uint64
}

func newAsyncWriter(w io.Writer) *asyncWriter {
	a := &asyncWriter{q: make(chan string, logQueue)}
	go a.pump(w)
	return a
}

func (a *asyncWriter) write(line string) {
	select {
	case a.q <- line:
	default:
		atomic.AddUint64(&a.dropped, 1)
	}
}

func (a *asyncWriter) pump(w io.Writer) {
	for line := range a.q {
		// Said before the line that made room for it, so the gap is marked
		// where it happened rather than at the end of the burst.
		if d := atomic.SwapUint64(&a.dropped, 0); d > 0 {
			fmt.Fprintln(w, logLine(lvlWarn, fmt.Sprintf(
				"%d log lines dropped - the log could not keep up, and the tunnel did not wait for it", d)))
		}
		fmt.Fprintln(w, line)
	}
}

// flush gives the queue a moment to empty, so that the reason a tunnel
// stopped is not still sitting in a channel when the process ends.
func (a *asyncWriter) flush(d time.Duration) {
	deadline := time.Now().Add(d)
	for len(a.q) > 0 && time.Now().Before(deadline) {
		time.Sleep(2 * time.Millisecond)
	}
}

func logFlush() { stderrLog.flush(2 * time.Second) }

func currentSink() func(string) {
	if f, ok := logSink.Load().(func(string)); ok && f != nil {
		return f
	}
	return stderrSink
}

// setLogSink installs a sink and hands back the one it replaced, so a caller
// can put that one back when it is done listening.
func setLogSink(f func(string)) func(string) {
	prev := currentSink()
	logSink.Store(f)
	return prev
}

// Colour is decided once. journalctl keeps the escapes and renders them; a
// file or a pipe gets none, so a log that is grepped later stays clean.
var logColour = func() bool {
	if os.Getenv("NO_COLOR") != "" || os.Getenv("TERM") == "dumb" {
		return false
	}
	fi, err := os.Stderr.Stat()
	if err != nil {
		return false
	}
	return fi.Mode()&os.ModeCharDevice != 0
}()

// A log line is three fixed columns and then the message, so a screenful of
// them reads down rather than across:
//
//	2026-08-22 14:31:07.482  INFO   carrier 3 up to 2.26.26.37:9443
//	2026-08-22 14:31:07.913  WARN   no carrier up, dropping connection to :6526
//	2026-08-22 14:32:07.914  ERROR  carrier 3 down: nothing received for 30s
//
// Milliseconds are worth the three characters: carriers come up and die in
// bursts, and whole seconds put four events on the same timestamp with no way
// to tell what happened first.
//
// Red for what is broken, yellow for what is wrong but survivable, cyan for
// what a healthy tunnel does, grey for the two levels that are only ever read
// while chasing something. Journald keeps the escapes and renders them; a file
// or a pipe gets none, so a log that is grepped later stays clean.
var logTags = [5]struct{ plain, coloured string }{
	{"ERROR", "\033[1;31mERROR\033[0m"},
	{"WARN ", "\033[1;33mWARN \033[0m"},
	{"INFO ", "\033[36mINFO \033[0m"},
	{"DEBUG", "\033[90mDEBUG\033[0m"},
	{"TRACE", "\033[90mTRACE\033[0m"},
}

const logStamp = "2006-01-02 15:04:05.000"

func logLine(lvl int32, msg string) string {
	tag := logTags[lvl].plain
	stamp := time.Now().Format(logStamp)
	if logColour {
		tag = logTags[lvl].coloured
		stamp = "\033[90m" + stamp + "\033[0m"
	}
	return fmt.Sprintf("%s  %s  %s", stamp, tag, msg)
}

func logAt(lvl int32, format string, args ...interface{}) {
	if atomic.LoadInt32(&logLevel) < lvl {
		return
	}
	currentSink()(logLine(lvl, fmt.Sprintf(format, args...)))
}

func logError(f string, a ...interface{}) { logAt(lvlError, f, a...) }
func logWarn(f string, a ...interface{})  { logAt(lvlWarn, f, a...) }
func logInfo(f string, a ...interface{})  { logAt(lvlInfo, f, a...) }
func logDebug(f string, a ...interface{}) { logAt(lvlDebug, f, a...) }
func logTrace(f string, a ...interface{}) { logAt(lvlTrace, f, a...) }

// ==========================================================================
// 3. key derivation
// ==========================================================================

// HKDF (RFC 5869) over HMAC-SHA256, hand-rolled on crypto/hmac because
// hand-rolled rather than taken from golang.org/x/crypto, which is thirty
// lines against a dependency in the one part of the engine that must never
// surprise anybody. It predates the vendored modules and has no reason to
// change now that they exist.

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

// The wire a tunnel speaks is one decision, not two. Obfuscation used to
// govern only the frame lengths while the handshake stayed on v3 regardless -
// a shape that had never been run anywhere. Now off means the whole v2.1.1
// wire, the one with field evidence behind it, and on means the whole v3 one.
func clientHandshakeFor(cfg *Config, conn net.Conn, carrier int) (*sessionKeys, error) {
	if !cfg.obfuscated() {
		return clientHandshakeV2(conn, cfg, carrier)
	}
	return clientHandshake(conn, cfg, carrier)
}

func serverHandshakeFor(cfg *Config, conn net.Conn, g *replayGuard) (*sessionKeys, int, error) {
	if !cfg.obfuscated() {
		return serverHandshakeV2(conn, cfg, g)
	}
	return serverHandshake(conn, cfg, g)
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

	// Whatever carries the carriers. The pool asks it for three things and
	// knows nothing else about it.
	tr        carrierTransport
	guard     *replayGuard
	closed    chan struct{}
	closeOnce sync.Once

	// what the log was last told the strength was, so it can be told again
	// only when that changed
	reported int

	// why the most recent carrier died. Sixteen carriers dropping together
	// wrote sixteen identical reasons, so the reason was moved to debug - and
	// then the log said "1 went down" sixteen times and never once said why,
	// which is the only thing anybody reads a log for. It is kept here
	// instead, and reported once with the count.
	lastDown string

	// How many times the far end has told us it could not reach a target.
	// A stream that ends because the service on the other server hung up and
	// a stream that ends because there was no service to hang up both arrive
	// here as a closed socket; this counter is the only thing that separates
	// them, and the probe needs that distinction badly.
	refusals uint64
	// The version the other server reported, for the status endpoint and for
	// saying so once when it differs. See link.peerVersion.
	peerVer atomic.Value
	// What refusals had reached the last time the log said so, so that the
	// line can carry the number it stood in for.
	refusalsSaid uint64

	// when each kind of failure was last written down. Every carrier fails
	// the same way at the same moment, so without this the log is the same
	// sentence twenty-four times a second and the reader learns nothing.
	errMu   sync.Mutex
	errSeen map[string]time.Time

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

// start brings the transport up and then either dials the carriers or waits
// for them. Which transport it is stops mattering here: it answers Dial,
// Accept and Close, and this function asks for nothing else.
func (p *pool) start() error {
	// The decoy answers requests from an http.Handler that has no config, so
	// give it the key here, once, before anything can be asked.
	decoyPSK = p.cfg.key()

	t, err := newTransport(p.cfg)
	if err != nil {
		return err
	}
	p.tr = t

	if p.cfg.Connect != "" {
		for i := 0; i < p.cfg.Carriers; i++ {
			go p.dialLoop(i)
		}
		logInfo("opening %d %s carriers to %s", p.cfg.Carriers, t.Name(), p.cfg.Connect)
		return nil
	}
	// validate insists on exactly one of listen and connect, so reaching here
	// means listen is set - there is no second case to write.
	go p.acceptLoop()
	logInfo("waiting for %s carriers on %s", t.Name(), p.cfg.Listen)
	return nil
}

// dialCarrier opens one carrier with whichever transport is configured.
func (p *pool) dialCarrier(idx int) (net.Conn, error) { return p.tr.Dial(idx) }

func (p *pool) acceptLoop() {
	for {
		conn, err := p.tr.Accept()
		if err != nil {
			select {
			case <-p.closed:
				return
			default:
			}
			// A raw socket transport ends its accept loop by returning an
			// error and has nothing to retry; a listener can hit a transient
			// one. Backing off covers both without either needing to say
			// which it is.
			logWarn("accept: %v", err)
			time.Sleep(200 * time.Millisecond)
			continue
		}
		go p.serveInbound(conn)
	}
}

func (p *pool) serveInbound(conn net.Conn) {
	tuneSocket(conn, p.cfg)
	keys, idx, err := serverHandshakeFor(p.cfg, conn, p.guard)
	if err != nil {
		// Stay quiet on the wire: a probe should learn nothing from timing
		// or content. The local log is a different audience entirely - an
		// operator whose two servers disagree about the token could read it
		// all day and find nothing, because this is the only place that
		// knows the other end is knocking and being turned away.
		ra := conn.RemoteAddr()
		time.Sleep(time.Duration(200+mrand.Intn(600)) * time.Millisecond)
		conn.Close()
		logDebug("rejected %s: %v", ra, err)
		if p.firstIn("rejected", time.Minute) {
			// Nothing arrived is not the same as something wrong arrived. A
			// handshake that times out here is almost always a peer still
			// retransmitting to a session already torn down - and saying
			// "your tokens differ" to that, once a minute, on a tunnel that
			// is carrying gigabytes, sends the reader to check the one thing
			// that was never wrong.
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				logWarn("a connection from %s went quiet before it said anything: %v", ra, err)
				logWarn("usually a peer retransmitting to a carrier that has already gone -")
				logWarn("only worth chasing when no carrier is up at all")
			} else {
				logWarn("turned away a connection from %s: %v", ra, err)
				logWarn("if that address is the other server, the two security tokens differ")
			}
		}
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
	logDebug("carrier %d up from %s", idx, conn.RemoteAddr())
	p.noteStrength()
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
			if p.firstIn("dial", time.Minute) {
				logWarn("cannot reach the other server at %s: %v", p.cfg.Connect, err)
				logWarn("nothing is listening on that port there, or a firewall is dropping it")
			}
			logDebug("carrier %d dial %s: %v", idx, p.cfg.Connect, err)
			p.sleepBackoff(&backoff)
			continue
		}
		tuneSocket(conn, p.cfg)
		keys, err := clientHandshakeFor(p.cfg, conn, idx)
		if err != nil {
			conn.Close()
			if p.firstIn("handshake", time.Minute) {
				// A handshake that is refused and a handshake that is never
				// answered are different faults on different machines, and
				// saying "different token" for both sends the reader to check
				// something that was right all along. Nothing came back means
				// nothing could disagree.
				var ne net.Error
				if errors.As(err, &ne) && ne.Timeout() {
					logWarn("reached %s but nothing came back: %v", p.cfg.Connect, err)
					logWarn("the far end is not answering on this transport - check it is")
					logWarn("running, on the same transport, and that nothing is dropping it")
				} else {
					logWarn("reached %s but the handshake failed: %v", p.cfg.Connect, err)
					logWarn("the two servers disagree - almost always a different security token")
				}
			}
			logDebug("carrier %d handshake: %v", idx, err)
			p.sleepBackoff(&backoff)
			continue
		}
		backoff = 500 * time.Millisecond
		l := newLink(idx, p.cfg, conn, keys, p)
		p.install(idx, l)
		logDebug("carrier %d up to %s", idx, p.cfg.Connect)
		p.noteStrength()
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

// A 24-carrier tunnel used to write 24 near-identical lines every time it
// came up, and the same again every time the far end restarted, which buried
// the one line a reader was looking for. Report the strength instead, and
// only when it changes something worth acting on.
// firstIn reports whether this kind of failure is worth a line right now:
// the first one, and then at most one a minute.
func (p *pool) firstIn(kind string, every time.Duration) bool {
	p.errMu.Lock()
	defer p.errMu.Unlock()
	if p.errSeen == nil {
		p.errSeen = make(map[string]time.Time)
	}
	now := time.Now()
	if last, ok := p.errSeen[kind]; ok && now.Sub(last) < every {
		return false
	}
	p.errSeen[kind] = now
	return true
}

func (p *pool) noteStrength() {
	select {
	case <-p.closed:
		// stopping on purpose: the strength going to zero is the point,
		// not news
		return
	default:
	}
	p.mu.Lock()
	n := 0
	for _, l := range p.links {
		if l != nil && l.alive() {
			n++
		}
	}
	was := p.reported
	p.reported = n
	why := p.lastDown
	p.mu.Unlock()

	switch {
	case was == n:
		// nothing a reader would act on
	case was == 0 && n > 0:
		logInfo("tunnel up: %d of %d carriers", n, p.cfg.Carriers)
	case n >= p.cfg.Carriers:
		logInfo("all %d carriers up", n)
	case n == 0:
		logWarn("every carrier is down: nothing can cross the tunnel now")
		if why != "" {
			logWarn("the last one went because: %s", why)
		}
	case n < was:
		logWarn("%d of %d carriers up, %d went down", n, p.cfg.Carriers, was-n)
		if why != "" {
			logWarn("  because: %s", why)
		}
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
		// The transport owns whatever it opened - a listener, a raw socket -
		// and closing it is what ends the accept loop.
		if p.tr != nil {
			p.tr.Close()
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

// stats summarises the pool. The round trip is the median of the carriers
// that have one, not the largest.
//
// It used to be the largest, and a carrier's figure is a last value that
// nothing ever clears - so one slow sample on one carrier of sixteen became
// the number shown for the whole tunnel, and stayed there. A tunnel whose
// path pings at 75 ms would report 2777, which is true of one carrier at one
// moment and of nothing else. The per-carrier table still shows every one, so
// the worst is a line away when it is wanted.
func (p *pool) stats() (up int, tx, rx uint64, rttUS int64) {
	var seen []int64
	for _, l := range p.liveLinks() {
		if !l.alive() {
			continue
		}
		up++
		tx += atomic.LoadUint64(&l.txBytes)
		rx += atomic.LoadUint64(&l.rxBytes)
		if r := atomic.LoadInt64(&l.rttUS); r > 0 {
			seen = append(seen, r)
		}
	}
	return up, tx, rx, medianRTT(seen)
}

// medianRTT is the middle sample, or zero when nothing has been measured.
func medianRTT(v []int64) int64 {
	if len(v) == 0 {
		return 0
	}
	sort.Slice(v, func(i, j int) bool { return v[i] < v[j] })
	return v[len(v)/2]
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
	// cmdVer carries this end's version string, once, when a carrier comes up.
	//
	// It is a record rather than a handshake field on purpose. The handshake
	// is a fixed length that both ends agree on before they have exchanged
	// anything, so a field added there is a tunnel that will not come up
	// against a peer running yesterday's build. A record an older peer does
	// not know falls to the default arm of dispatch, which logs it at debug
	// and carries on - so this is invisible to one and useful to the other.
	cmdVer = 13
)

var errLinkClosed = errors.New("carrier closed")

// ---------------------------------------------------------------------------
// pooled records
// ---------------------------------------------------------------------------

type recBuf struct {
	a   []byte
	n   int
	big bool

	// When this was put on a carrier's queue, for records that are worth less
	// the longer they wait. Zero means it waits however long it takes: a
	// handshake, a window credit or a forwarded byte has to arrive.
	enq int64
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
	r.enq = 0
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

// buffered says how much is waiting, so a reader can tell whether its next
// call would block. See pumpIn: that is the moment credit has to go back.
func (r *recvBuf) buffered() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.buf.Len()
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

	// Credit goes back in as few records as the sender can afford to wait for.
	//
	// One record per read is one control record for every 32 KiB consumed -
	// hundreds a second on a busy stream, and dozens of streams do it at once.
	// Each one is a frame to seal, a wakeup for the writer, and a place in the
	// queue ahead of data that is actually going somewhere. Under load that is
	// where the jitter comes from: real traffic waiting behind bookkeeping.
	//
	// So it accumulates, and goes out when it is worth a record - or the
	// moment there is nothing left to read, because the next call blocks there
	// and credit held past that point is credit the sender is waiting on. An
	// idle stream therefore still returns its window immediately, and a busy
	// one returns it in one record instead of sixteen.
	flushAt := s.l.window() / 2
	if flushAt < int32(len(buf)) {
		flushAt = int32(len(buf))
	}
	var pending int32
	give := func() {
		if pending <= 0 {
			return
		}
		var c [4]byte
		binary.BigEndian.PutUint32(c[:], uint32(pending))
		s.l.send(ctrlRec(cmdWND, s.id, c[:]))
		pending = 0
	}

	for {
		n, err := s.rb.Read(buf)
		if n > 0 {
			if _, werr := local.Write(buf[:n]); werr != nil {
				s.reset()
				return
			}
			atomic.AddUint64(&s.l.rxBytes, uint64(n))
			pending += int32(n)
			if pending >= flushAt || s.rb.buffered() == 0 {
				give()
			}
		}
		if err != nil {
			give()
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

	sendQ chan *recBuf
	// Control that must not queue behind bulk.
	//
	// sendQ holds up to 128 records of up to 32 KiB, so a keepalive handed to
	// it can sit behind four megabytes of somebody's download - a third of a
	// second on a hundred-megabit path, before the ARQ or the wire have seen
	// it at all. That is measured as round-trip time, and felt as a video
	// that stutters while a file copies.
	//
	// Only records that carry no stream position go here: a ping, a pong, a
	// window credit. Those mean the same thing whenever they arrive, so
	// letting them past the queue costs nothing. An open, a close or a byte
	// of data has a place in its stream and keeps it.
	priQ      chan *recBuf
	closed    chan struct{}
	closeOnce sync.Once

	mu      sync.Mutex
	streams map[uint32]*stream
	nextID  uint32

	obf     bool   // mask frame lengths and pad the opening frames
	plain   bool   // frames go out unsealed - see Config.Encrypt
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
		plain:   !cfg.encrypted(),
		keys:    k,
		sendQ:   make(chan *recBuf, sendQueue),
		priQ:    make(chan *recBuf, sendQueue),
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
	// Say which build this is, once. See cmdVer, and peerVersion below for
	// why the answer is worth having.
	l.trySend(ctrlRec(cmdVer, 0, []byte(version)))
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

// How long a private-link packet may wait before dropping it beats sending it.
//
// The queue is 128 records deep per carrier - at a carrier's share of a
// hundred megabits, about seventy milliseconds of packets. Idle, the link
// measures 40 ms. With sixteen streams pushing through it and no shedding at
// all, the same ping averaged 270 ms and peaked at 896, with 244 ms of
// jitter. The bytes were not lost, they were queued, and no sender inside
// could tell: a queue that deep hides the congestion signal that would have
// made them slow down.
//
// CoDel was tried here, properly - target 5 ms, interval 100 ms, drop rate
// rising with the square root of a persisting queue - and it lost on both
// counts: 191 ms under the same load against this rule's 63 ms, and 173
// Mbit/s against 202. Its interval is the reason. CoDel waits a hundred
// milliseconds to be sure a queue is standing rather than bursting, and on
// this path the queue is built and hurting long before that.
//
// So the rule is the plain one: a packet that has waited longer than this is
// one the TCP inside has already counted as lost and resent, and sending it
// now adds delay for a copy nobody wants. Dropping is not damage on a link
// that carries IP - it is the signal, and it is the signal that a deep queue
// was preventing. Shedding is also what makes it FASTER under load, because
// the retransmit storms that bufferbloat causes cost more than the drops do.
const tunMaxSojourn = 6 * time.Millisecond

// staleTUN reports a private-link packet the queue should shed, and returns
// its buffer. Records with no timestamp - handshakes, window credits,
// forwarded bytes - are never shed: those have to arrive.
func (l *link) staleTUN(r *recBuf) bool {
	if r.enq == 0 || time.Now().UnixNano()-r.enq <= int64(tunMaxSojourn) {
		return false
	}
	putRec(r)
	return true
}

// jumpsQueue is true for the records that carry no position in any stream, so
// nothing is reordered by letting them go first.
func jumpsQueue(cmd byte) bool {
	return cmd == cmdPing || cmd == cmdPong || cmd == cmdWND
}

func (l *link) queueFor(r *recBuf) chan *recBuf {
	// A link without the second queue - one built by hand in a test - still
	// has to send. A nil channel blocks for ever, which is not a failure any
	// caller here is prepared for.
	if l.priQ == nil {
		return l.sendQ
	}
	if b := r.bytes(); len(b) > 0 && jumpsQueue(b[0]) {
		return l.priQ
	}
	return l.sendQ
}

func (l *link) send(r *recBuf) bool {
	q := l.queueFor(r)
	select {
	case q <- r:
		return true
	case <-l.closed:
		putRec(r)
		return false
	}
}

func (l *link) trySend(r *recBuf) bool {
	q := l.queueFor(r)
	select {
	case q <- r:
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
		case r = <-l.priQ:
		case <-l.closed:
			return
		default:
			select {
			case r = <-l.priQ:
			case r = <-l.sendQ:
			case <-l.closed:
				return
			}
		}
		if l.staleTUN(r) {
			continue
		}
		frame = append(frame[:0], r.bytes()...)
		putRec(r)
	drain:
		for len(frame) <= maxPlain-recHdr-maxRecord {
			var r2 *recBuf
			select {
			case r2 = <-l.priQ:
			default:
				select {
				case r2 = <-l.sendQ:
				default:
					break drain
				}
			}
			if l.staleTUN(r2) {
				continue
			}
			frame = append(frame, r2.bytes()...)
			putRec(r2)
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
		if l.plain {
			// Length-prefixed and nothing else. The nonce is still counted so
			// that length masking, which uses it, behaves the same either way.
			out = append(out, frame...)
		} else {
			out = l.keys.tx.Seal(out, n[:], frame, nil)
		}
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
		logTrace("carrier %d tx frame %d: %d bytes on the wire, %d of records",
			l.idx, ctr, len(out), len(frame))
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
			l.died("%s%s", readReason(err, idle), l.rxSummary())
			return
		}
		if l.obf {
			maskLen(l.keys.maskRx, l.rxCtr, hdr[:]) // XOR is its own inverse
		}
		n := int(binary.BigEndian.Uint32(hdr[:]))
		// A sealed frame always carries at least a sixteen-byte GCM tag, so
		// anything shorter was impossible and worth refusing. An unsealed one
		// has no tag: the smallest thing it can hold is a single record
		// header, and a keepalive is exactly that. Judging both by the sealed
		// minimum killed every carrier on its first ping.
		least := 16
		if l.plain {
			least = recHdr
		}
		if n < least || n > maxFrame {
			l.died("bad frame length %d - the two ends disagree or something rewrote the stream", n)
			return
		}
		if cap(ct) < n {
			ct = make([]byte, 0, n)
		}
		ct = ct[:n]
		if _, err := io.ReadFull(l.conn, ct); err != nil {
			l.died("%s%s", readReason(err, idle), l.rxSummary())
			return
		}
		atomic.AddUint64(&l.wireRx, uint64(len(hdr)+n))
		logTrace("carrier %d rx frame %d: %d bytes on the wire", l.idx, l.rxCtr, len(hdr)+n)
		nc := nonceFor(l.rxCtr)
		l.rxCtr++
		var p []byte
		if l.plain {
			p = ct
		} else {
			var err error
			p, err = l.keys.rx.Open(plain[:0], nc[:], ct, nil)
			if err != nil {
				// One end sealing and the other not looks exactly like this,
				// so the message has to name it: the tokens can be identical
				// and the tunnel still fail here.
				l.died("could not read a frame - the token does not match, one end " +
					"has encryption off while the other has it on, or a middlebox altered the stream")
				return
			}
			// Keep whatever capacity Open grew it to. Not in plain mode: p is
			// the frame buffer there, and pointing the cipher's scratch at it
			// would quietly make one buffer out of two.
			plain = p[:0]
		}
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
				l.refused(string(body))
			}
			if s := l.getStream(id); s != nil {
				s.reset()
			}
		case cmdPad:
			logTrace("carrier %d rx pad %d bytes", l.idx, n)
		case cmdPing:
			logTrace("carrier %d rx ping, answering", l.idx)
			// Never block the read loop: if the send queue is momentarily
			// full, drop the pong rather than risk both ends stalling on
			// each other's socket buffers.
			l.trySend(ctrlRec(cmdPong, 0, body))
		case cmdPong:
			logTrace("carrier %d rx pong", l.idx)
			if n == 8 {
				sent := int64(binary.BigEndian.Uint64(body))
				atomic.StoreInt64(&l.rttUS, (time.Now().UnixNano()-sent)/1000)
			}
		case cmdVer:
			l.peerVersion(string(body))
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
// rxSummary says whether this carrier ever heard anything and how long ago,
// which is the difference between "the peer went away" and "the peer was never
// able to reach us at all".
func (l *link) rxSummary() string {
	n := atomic.LoadUint64(&l.wireRx)
	if n == 0 {
		return " (nothing was EVER received on this carrier)"
	}
	last := time.Since(time.Unix(0, atomic.LoadInt64(&l.lastRx))).Round(time.Second)
	return fmt.Sprintf(" (received %s in all, last %s ago)", humanBytes(n), last)
}

// refused reports what the far end said about a connection it would not make.
//
// One line a minute, with a count of the ones it stood for. The far side
// sends one of these per refused connection, and a target that is down
// refuses every connection there is - so a dead port on one server used to
// write a line per record here, out of the carrier's read loop, on a socket
// that went unread for as long as the write took. Under systemd that write is
// to a pipe journald can stop draining, and the tunnel stopped with it.
//
// Both halves of that are fixed: the sink no longer waits for anybody, and
// this no longer speaks per record. The volume follows the clock, which is
// the rule the carrier count already keeps.
func (l *link) refused(why string) {
	p := l.pool
	if p == nil {
		logWarn("the other server refused a connection: %s", why)
		return
	}
	n := atomic.AddUint64(&p.refusals, 1)
	if !p.firstIn("refused", time.Minute) {
		return
	}
	// How many arrived since the last time this said anything - which is the
	// number an operator wants, and the one a per-record line never gave.
	quiet := n - atomic.SwapUint64(&p.refusalsSaid, n)
	if quiet > 1 {
		logWarn("the other server refused a connection: %s (and %d more since the last time this said so)",
			why, quiet-1)
		return
	}
	logWarn("the other server refused a connection: %s", why)
}

// peerVersion says so when the two servers are not running the same build.
//
// This is the single thing that has cost the most time in the field, and it is
// invisible from either end on its own. The presets, the token format and the
// wire records move together, so two builds disagree quietly: the far end
// dials the carrier count ITS table says, and this end reports "20 of 8
// carriers up" against a config that asked for eight. Nothing in that line
// says why, and both servers look healthy from where they are standing.
//
// A peer running a build older than this one never sends its version at all,
// which is itself the answer - so silence is reported too, once the carrier
// has been up long enough that the record would have arrived.
func (l *link) peerVersion(v string) {
	if v == "" || l.pool == nil {
		return
	}
	if prev := l.pool.peerVer.Swap(v); prev == v {
		return // already said, and nothing has changed
	}
	if v == version {
		logDebug("the other server runs %s, the same as this one", v)
		return
	}
	if !l.pool.firstIn("peer-version", 10*time.Minute) {
		return
	}
	logWarn("the other server runs %s and this one runs %s", v, version)
	logWarn("update both ends: presets, token format and wire records move together")
	logWarn("a mismatch shows up as the two ends disagreeing about how many carriers there are")
}

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
				l.died("silent for %s - nothing came back from the peer%s",
					l.idleLimit(), l.rxSummary())
				return
			}
			var b [8]byte
			binary.BigEndian.PutUint64(b[:], uint64(time.Now().UnixNano()))
			logTrace("carrier %d tx ping (last heard %s ago)", l.idx,
				time.Since(time.Unix(0, atomic.LoadInt64(&l.lastRx))).Round(time.Millisecond))
			// Never wait for room. send() blocks until the queue drains or
			// the carrier closes, and on a carrier whose peer has gone the
			// queue never drains: the writer is stuck in a Write nobody is
			// acknowledging, so the queue fills, and the keepalive blocks in
			// send() and never reaches the idle check above again.
			//
			// That is the one check that would have noticed. A carrier could
			// therefore sit "up" forever with a dead peer on the other end -
			// on the accepting side, holding that peer's address and its slot
			// in the count, which is how one server came to report twenty
			// carriers up against a config that asked for eight.
			//
			// A ping that cannot be queued is not worth waiting for anyway: a
			// full queue already means the writer is behind, and the ping is
			// the least valuable thing in it. Drop it, and let the next tick
			// reach the idle check.
			l.trySend(ctrlRec(cmdPing, 0, b[:]))
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
		// The reason belongs in the log every time - it is the only place
		// that says *why* - but at debug, because noteStrength below turns a
		// whole braid dropping at once into one line instead of twenty-four.
		logDebug("carrier %d down: %s (up %s)", l.idx, why,
			time.Since(time.Unix(0, atomic.LoadInt64(&l.upSince))).Round(time.Second))
		if l.pool != nil {
			l.pool.mu.Lock()
			l.pool.lastDown = why
			l.pool.mu.Unlock()
			l.pool.noteStrength()
		}
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

	// Refused streams, and how many of those the log had reported the last
	// time it said anything. See noteRefusal.
	refused     uint64
	refusedSaid uint64

	// The same, for connections dropped because nothing was up to carry
	// them. See noteNoCarrier.
	dropped     uint64
	droppedSaid uint64
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
		f.noteNoCarrier(r.lport)
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

// noteRefusal says a stream could not be made, at most once a minute, with a
// count of the ones it stood for.
//
// The reason still travels back to the other server on every single one -
// that is what tells an operator over there that the service is down rather
// than the tunnel. What is rationed is this server's own log, because a
// target that is down refuses every connection there is, and a line per
// connection is thousands a minute into a journal that then stops keeping up
// with anything else.
// noteNoCarrier says the tunnel is down and connections are being dropped, at
// most once a minute, with a count of the ones it stood for.
//
// A tunnel that is down is precisely the state a client retries hardest in, so
// the line that appears thousands of times a minute is the one that says
// nothing - and it lands on top of the handful that say WHY it went down,
// which are the only ones worth reading when it is down. Field logs came back
// as page after page of this with the reason nowhere in them. The volume has
// to follow the clock, which is the rule the carrier count and the refusals
// below already keep.
func (f *forwarder) noteNoCarrier(lport int) {
	if f.p == nil {
		logWarn("no carrier up, dropping connection to :%d", lport)
		return
	}
	n := atomic.AddUint64(&f.dropped, 1)
	if !f.p.firstIn("no-carrier", time.Minute) {
		return
	}
	quiet := n - atomic.SwapUint64(&f.droppedSaid, n)
	if quiet > 1 {
		logWarn("no carrier up, dropping connection to :%d (and %d more since the last time this said so)",
			lport, quiet-1)
		return
	}
	logWarn("no carrier up, dropping connection to :%d", lport)
}

func (f *forwarder) noteRefusal(target, why string) {
	if f.p == nil {
		logWarn("stream to %s: %s", target, why)
		return
	}
	n := atomic.AddUint64(&f.refused, 1)
	if !f.p.firstIn("stream-refused", time.Minute) {
		return
	}
	quiet := n - atomic.SwapUint64(&f.refusedSaid, n)
	if quiet > 1 {
		logWarn("stream to %s: %s (and %d more since the last time this said so)", target, why, quiet-1)
		return
	}
	logWarn("stream to %s: %s", target, why)
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
		f.noteRefusal(target, why)
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
	closed chan struct{}
	once   sync.Once

	// When the transport can carry a whole packet with no session under it,
	// this is how the private link travels: one packet, one datagram, no
	// reliability layer. See tunfast.go for why that is the right shape for
	// something carrying IP.
	fast *tunFast
}

// packetCarrier is a transport that can put one whole packet on the wire
// without a session underneath it.
type packetCarrier interface {
	// Headroom is how many bytes the transport needs in front of the payload
	// for its own header. The private link leaves that much room when it
	// builds a packet, so the transport fills it in place instead of taking a
	// second buffer and copying the payload into it - which is what it used
	// to do, once per packet, for every packet.
	Headroom() int

	// SendPacket puts one packet on the wire. (*buf)[:Headroom()] belongs to
	// the transport to fill; the rest is the payload, already built and not
	// copied anywhere. The buffer goes with it: the wire may be written from
	// another thread, so the transport is what returns it to the pool.
	SendPacket(buf *[]byte) error

	SetPacketHandler(func([]byte), *net.IPAddr)
}

func startTUN(cfg *Config, p *pool) (*tunnel, error) {
	t := &tunnel{cfg: cfg, p: p, closed: make(chan struct{})}
	// How many device queues, and so how many threads read the device.
	//
	// This used to be the carrier count, which has nothing to do with it. A
	// carrier is a path across the wire; a queue is a thread competing for
	// this machine's processors, and eight of them on a server with one
	// processor do not read the device eight times faster - they take turns,
	// and everything else on that processor takes its turn behind them.
	//
	// Measured on a one-processor server abroad, a single stream through an
	// ICMP tunnel:
	//
	//	one queue      213 Mbit/s
	//	two queues     270 Mbit/s, and the sender dropped nothing
	//	four queues    262 Mbit/s, sender dropped 227 packets
	//	eight queues   216 Mbit/s
	//
	// At eight the threads reading the device starved the one putting packets
	// on the wire, its queue filled, and it threw away three thousand packets
	// - which the TCP inside read as congestion and answered by halving its
	// window. The machine was not short of work to do. It was short of turns.
	//
	// So the count follows the processors, with two as a floor because one
	// queue cannot overlap a read with anything, and eight as a ceiling
	// because past that the descriptors cost more than the parallelism pays.
	n := runtime.GOMAXPROCS(0)
	if n < 2 {
		n = 2
	}
	if n > 8 {
		n = 8
	}
	if cfg.Carriers > 0 && n > cfg.Carriers {
		n = cfg.Carriers
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

	// One writer per device queue: the queues are what make parallel writes
	// worth anything, and a writer with no queue of its own would only queue
	// behind another.
	t.startFast()
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
			if t.fast != nil {
				// Straight onto the wire. No braid, no window, no ordering -
				// the packet is its own datagram and arrives or does not,
				// which is what IP has always promised the layers above it.
				if e := t.fast.Send(r.body()[:n]); e != nil {
					logDebug("tun send: %v", e)
				}
				putRec(r)
			} else {
				r.seal(cmdTUN, 0, n)
				r.enq = time.Now().UnixNano()
				l := t.p.pickHash(flowHash(r.body()[:n]))
				if l == nil {
					putRec(r)
				} else {
					atomic.AddUint64(&l.txBytes, uint64(n))
					l.send(r)
				}
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
	t.toDevice(body)
}

// startFast puts the private link on the direct path when the transport can
// carry a whole packet on its own.
//
// Only the packet transports can: a stream transport has no packet boundaries
// to put one in, and TCP is already reliable and ordered whatever we do, so
// there is nothing to gain there anyway.
func (t *tunnel) startFast() {
	pc, ok := t.p.tr.(packetCarrier)
	if !ok {
		return
	}

	// Its own keys, and a different label from anything the braid derives, so
	// the two paths cannot be confused for one another even in principle.
	var tx, rx cipher.AEAD
	if t.cfg.encrypted() {
		prk := hkdfExtract([]byte("pingify/v3 tun packets"), t.cfg.key())
		out := hkdfExpand(prk, []byte("iran to kharej"), 32)
		in := hkdfExpand(prk, []byte("kharej to iran"), 32)
		if t.cfg.Role != "server" {
			out, in = in, out
		}
		tx, rx = aeadFrom(out), aeadFrom(in)
	}

	var peer *net.IPAddr
	if host := t.cfg.Connect; host != "" {
		if h, _, err := net.SplitHostPort(host); err == nil {
			host = h
		}
		if ip, err := net.ResolveIPAddr("ip4", host); err == nil {
			peer = ip
		}
	}

	t.fast = newTunFast(tx, rx, pc.Headroom(), pc.SendPacket, t.toDevice)
	pc.SetPacketHandler(t.fast.Deliver, peer)

	how := "encrypted"
	if !t.cfg.encrypted() {
		how = "in the clear"
	}
	logInfo("private link goes straight onto the wire, %s: one packet per datagram,"+
		" nothing ordering or resending them", how)
}

// toDevice writes one IP packet to the interface, whichever path brought it.
// toDevice writes one received packet to the device.
//
// The reader that took it off the socket writes it, here, with nothing in
// between. That is worth saying because it was not always so: a layer of
// per-flow writers and batched handovers sat here for a while, on the
// reasoning that one thread doing every write would serialise them.
//
// It did, and it was still faster. Measured once the kernel's receive buffer
// was no longer being silently clamped - which was the real reason the reader
// could not keep up - with sixteen streams pushing through the link:
//
//	               p50      p90      p99    throughput
//	batched      160 ms   179 ms   561 ms   427 Mbit/s
//	written here 113 ms   133 ms   146 ms   444 Mbit/s
//
// Better on every one of them. The handovers cost more in wakeups than the
// writes cost in waiting, and the queue in front of them was one more place
// for delay to hide. What made the batching look necessary was a bug
// somewhere else.
func (t *tunnel) toDevice(pkt []byte) {
	if len(t.queues) == 0 {
		return
	}
	// The queue is chosen by the flow, never round-robin.
	//
	// Round-robin here quietly destroyed the thing the send side had been
	// careful to preserve. A flow is pinned to one carrier so its packets stay
	// in order on the wire, and then every packet that arrived was handed to
	// the next device queue in turn. Several queues drain at once, so one
	// flow's packets reached the kernel in whatever order the queues happened
	// to run, and the TCP inside saw its own segments shuffled.
	//
	// Measured on a real 37 ms path: the inner connection reported 1071
	// reordering events, retransmitted 400 KB it had never lost, and its round
	// trip rose from 37 ms to 187 ms. Hashing the flow to a queue costs one
	// pass over the header and keeps every flow on one queue, in order.
	q := t.queues[flowHash(pkt)%uint32(len(t.queues))]
	if _, err := q.Write(pkt); err != nil {
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
	// FNV leaves its weakest bits at the bottom, and a modulus takes exactly
	// those. It happens to spread runs of ephemeral source ports well enough,
	// but only by luck of the multiplier - the guarantee is worth having when
	// the cost is four instructions once per flow, and it is what keeps the
	// carrier and the device queue from ever agreeing to cluster.
	h ^= h >> 16
	h *= 0x85ebca6b
	h ^= h >> 13
	h *= 0xc2b2ae35
	h ^= h >> 16
	return h
}

// ==========================================================================
// 8. socket tuning and forward specs
// ==========================================================================

// tuneSocket applies the settings that actually move the needle on a
// long-haul, lossy Iran<->Kharej path: no Nagle delay on the carrier, and
// socket buffers big enough to hold a full bandwidth-delay product.
// baseTCP walks down to the socket under whatever is wrapping it.
//
// A carrier is not always a bare socket. A ws carrier is framing over a
// socket; a wss carrier is framing over TLS over a socket. A plain type
// assert saw neither, so every ws and wss carrier ran with Nagle on - up to
// forty milliseconds of hesitation before a small write leaves - with no
// keepalive and with the tuning's socket buffers silently ignored, while the
// tcp transport got all three.
func baseTCP(c net.Conn) *net.TCPConn {
	for i := 0; i < 4 && c != nil; i++ {
		if tc, ok := c.(*net.TCPConn); ok {
			return tc
		}
		switch v := c.(type) {
		case interface{ netConn() net.Conn }: // our own framing
			c = v.netConn()
		case interface{ NetConn() net.Conn }: // *tls.Conn
			c = v.NetConn()
		default:
			return nil
		}
	}
	return nil
}

func tuneSocket(c net.Conn, cfg *Config) {
	tc := baseTCP(c)
	if tc == nil {
		return
	}
	tc.SetNoDelay(true)
	tc.SetKeepAlive(true)
	tc.SetKeepAlivePeriod(30e9)
	// The one that matters on this route: bound how long the kernel will
	// retransmit into a blackhole before admitting the socket is gone.
	setUserTimeout(c)
	// The socket buffers are deliberately not set here.
	//
	// SetReadBuffer and SetWriteBuffer ask for SO_RCVBUF and SO_SNDBUF, and on
	// a TCP socket that does two things, both of them bad. The kernel clamps
	// the value to net.core.rmem_max - 212992 bytes on an ordinary server -
	// and asking at all switches off the receive-buffer autotuning that would
	// otherwise have grown the socket to net.ipv4.tcp_rmem's ceiling, six
	// megabytes on the same machine.
	//
	// So a carrier that was given "sixteen megabytes" in the config ran with
	// two hundred and eight kilobytes and no ability to grow. Over a 68 ms
	// path that is twenty-four megabits a carrier, and eight of them measured
	// 113 Mbit/s where the pair could carry far more.
	//
	// Autotuning is better than any number that could be written here: it
	// grows to what the path turns out to need and gives the memory back when
	// it does not. The packet transports still set theirs explicitly, because
	// a raw socket has no autotuning to leave alone - see sockbuf_linux.go.
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
	PeerVer   string          `json:"peer_version,omitempty"`
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
	Refusals  uint64          `json:"refusals"`
	Detail    []carrierStatus `json:"detail"`
}

// startStatusServer binds the status endpoint. The error is returned as well
// as logged: a tunnel carries on perfectly well without it, so run() only says
// so and keeps going - but a test that is about to ask the endpoint a question
// needs to fail on the spot, naming the port it could not have, rather than
// timing out later against something that was never listening.
func startStatusServer(addr string, cfg *Config, p *pool) error {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		logWarn("status endpoint %s: %v", addr, err)
		return err
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
	return nil
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
		// The accepting end has no configured peer: it is told nothing about
		// the other server, which simply arrives. But it does know who
		// arrived, and that is the only place that address exists on this
		// machine - so report it rather than the address we listen on, which
		// is our own and useless to anyone asking.
		for _, l := range p.liveLinks() {
			if l.alive() && l.conn != nil {
				if ra := l.conn.RemoteAddr(); ra != nil {
					host := ra.String()
					if h, _, err := net.SplitHostPort(host); err == nil {
						host = h
					}
					d.Peer = host
					break
				}
			}
		}
	}
	if d.Peer == "" {
		d.Peer = "listen " + cfg.Listen
	}
	now := time.Now().UnixNano()
	// Collected and taken the middle of, rather than kept as a running
	// maximum: one slow sample on one carrier is not the tunnel's round trip.
	var rtts []int64
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
			if cs.RTTms > 0 {
				rtts = append(rtts, int64(cs.RTTms*1000))
			}
		}
		d.TxBytes += cs.TxBytes
		d.RxBytes += cs.RxBytes
		d.WireTx += cs.WireTx
		d.WireRx += cs.WireRx
		d.Detail = append(d.Detail, cs)
	}
	d.RTTms = float64(medianRTT(rtts)) / 1000
	d.Refusals = atomic.LoadUint64(&p.refusals)
	if v, ok := p.peerVer.Load().(string); ok {
		d.PeerVer = v
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
	if d.PeerVer != "" && d.PeerVer != d.Version {
		fmt.Printf("  versions   this end %s, the other end %s  -  UPDATE BOTH ENDS\n", d.Version, d.PeerVer)
	}
	fmt.Printf("  state      %s  -  %d of %d carriers\n", state, d.Up, d.Carriers)
	if d.Up == 0 {
		// The usual reason, by a wide margin, is that only one of the two
		// servers has been set up so far. Saying so beats leaving DOWN on
		// screen looking like a fault.
		if d.Role == "server" {
			fmt.Println("             nothing has connected yet - set the tunnel up on KHAREJ too")
		} else {
			fmt.Println("             cannot reach IRAN yet - check it is set up, and the port is open")
		}
	}
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
