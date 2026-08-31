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
// Where things are. This file was once all of it - nine numbered sections in
// four thousand lines - and the sections are files now, cut on the lines it
// already drew:
//
//     main.go        configuration and the entry point
//     config.go      reading a config file
//     log.go         the log
//     keys.go        deriving keys from the token
//     pool.go        the handshake and the carrier pool
//     braid.go       framing, encryption and stream multiplexing
//     forward.go     forward mode - TCP and UDP port forwarding
//     tun.go         tun mode - the private layer-3 link
//     tunfast.go     the private link's direct path, with no braid under it
//     sockopt.go     socket tuning and the forward spec parser
//     status.go      the status endpoint
//
// and one file per transport beside them - transport.go for the chooser, then
// icmp.go, udp.go, ws.go, mirage.go, kcp_transport.go, pck_*.go - with arq.go
// under the two that carry datagrams.
//
// Nothing moved between files in that split. The compiler and the tests were
// the only judges of it, and both were green at every step.

package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
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
