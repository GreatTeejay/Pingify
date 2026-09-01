package config

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
)

// The configuration file, and the one line that differs between the two
// servers.
//
// The old core called the two ends "server" and "client", which was wrong in
// the way that costs support time: the Iran server was the "server" and it was
// also the side that dialled out, so the word predicted neither who listened
// nor who connected. Here they are called what they are. Everything else in
// the file is written from the point of view of both ends at once - the tun
// addresses are named `iran` and `kharej` rather than `local` and `remote` -
// so the same file is correct on both servers and only `side` changes.
//
// A file that is identical on both ends cannot drift on one of them, and
// drift between the two configs was the single most common way a tunnel came
// up carrying nothing.
//
//	[tunnel]
//	name = "b"
//	side = "iran"          # the only line that differs; "kharej" over there
//	mode = "tun"
//
//	[transport]
//	type   = "udp"
//	kharej = "46.247.109.83"   # the abroad server, which is the one that waits
//	port   = 8443
//
//	[security]
//	token = "a phrase typed on both servers"
//
//	[tun]
//	name   = "pfy0"
//	iran   = "10.99.1.1/24"
//	kharej = "10.99.1.2/24"
//	mtu    = 1320
//
//	[logging]
//	level = "info"

const (
	// MaxSendBatch is the largest burst any carrier will be asked for. The
	// value that is actually used comes from the carrier - see Carrier.Burst.
	MaxSendBatch = 64

	SideIran   = "iran"
	SideKharej = "kharej"

	// How many connections a stream carrier opens between the two servers.
	//
	// Not a tuning knob with a taste behind it. Measured on the Tehran to
	// Frankfurt path, with iperf3 and no tunnel anywhere near it:
	//
	//	one TCP connection      0.39 Mbit/s
	//	sixteen connections     743 Mbit/s
	//
	// A single flow is shaped to nothing and sixteen together are not shaped
	// at all, so a stream carrier that opens one connection carries 6 Mbit/s
	// on a path that will carry seven hundred. This is the whole reason the
	// old core had "carriers", and the number is what it is because that is
	// where the measurement stopped improving.
	DefaultConnections = 8

	// The port the far end is asked on, over the private link. Fixed rather
	// than configured, because both servers have to agree on it and there is
	// nothing for it to collide with: it is bound to this tunnel's own tun
	// address. Set status.health_port to -1 to turn it off.
	DefaultHealthPort = 19999
)

type Config struct {
	Name string
	Side string // iran | kharej
	Mode string // tun

	Transport struct {
		Type   string // udp
		Kharej string // the abroad server's address
		// The Iran server's address. Nothing here dials it - KHAREJ never
		// dials anything - so it is recorded rather than used: both files
		// carry it, so either server can say which pair it belongs to, and
		// the operator of one can see the other without logging into it.
		Iran string
		Port int

		// The path a WebSocket handshake asks for. Anything else that arrives
		// gets a 404, which is what a web server would have said.
		Path string

		// Which side opens the connection, when it is not the side the
		// addresses imply. Almost nothing sets this: see DialSide.
		Dials string

		// Where the side that waits binds, when that is not the port the
		// other side asks for. Behind a CDN it usually is not: the edge takes
		// the connection on one of its own ports and comes to the origin on
		// another.
		ListenPort int

		// A certificate for the side that waits, when nothing in front of it
		// is doing the TLS. Empty means something is - a CDN, or a proxy on
		// the same machine.
		Cert string
		Key  string

		// Whether the side that dials should accept a certificate nobody
		// vouches for. For a pair that made its own; never for a CDN, where
		// the whole point is that the name is one the internet trusts.
		Insecure bool

		// How many connections a stream carrier opens. One is not enough on a
		// path that shapes a single flow, and it is measured rather than
		// guessed - see the note on DefaultConnections.
		Connections int
		Keepalive   int // seconds
	}

	Token string

	Tuning struct {
		RcvBufKB  int
		SndBufKB  int
		SendBatch int    // packets per crossing into the kernel; 0 means choose
		Pace      bool   // put fq on the way out, so bursts leave as a stream
		PaceMbit  int    // and cap the rate; unset means the tunnel works it out
		Profile   string // gaming | balanced | download
		QueuePkts int    // how deep that queue may get; the profile sets it

		// One parity packet per this many, on a carrier that can lose one.
		// Zero is off, and off is the default: it is a tenth of the bandwidth
		// spent on a path that may not need it, and the health check says so
		// when it finds one that does.
		FEC int

		// Whether the file said anything, so a default can tell itself apart
		// from a deliberate zero.
		PaceSet     bool
		PaceMbitSet bool
	}

	TUN struct {
		Name   string
		Iran   string
		Kharej string
		MTU    int
		Queues int // 0 means choose one
	}

	Level string

	// AmneziaWG, when that is the transport.
	//
	// The core does not speak it and does not want to: it is obfuscated
	// WireGuard, it is somebody else's careful cryptography, and it is
	// installed from their own repository rather than reimplemented here.
	// What the core does is run over it - the carrier is ordinary UDP between
	// the two private addresses of the AmneziaWG link - so everything above
	// the carrier is unchanged and every number the manager shows is real.
	//
	// The rest of this table is the manager's: the keys and the obfuscation
	// parameters that awg-quick needs. They are carried here because one file
	// describes one tunnel, and both servers get the same file.
	AWG struct {
		Name   string // the interface, awg0 and so on
		Iran   string // its address on the link, with the prefix
		Kharej string
		MTU    int
		Port   int // where AmneziaWG itself listens

		IranKey    string
		IranPub    string
		KharejKey  string
		KharejPub  string
		Jc         int
		Jmin, Jmax int
		S1, S2     int
		H1, H2     int
		H3, H4     int
	}

	// Where to answer questions about itself. Loopback only, and zero turns
	// it off.
	StatusPort int

	// And the same answers on this tunnel's own private address, where the
	// server at the other end can reach them.
	//
	// It exists because an ICMP tunnel cannot be pinged: the carrier stops
	// both kernels answering echo, deliberately, so there is nothing left
	// that will tell you the round trip across the link or whether anything
	// at the far end is alive. A port that answers does both.
	//
	// The same number on both servers, and it needs to be: the address it is
	// bound to belongs to this tunnel and to nothing else on the machine, so
	// two tunnels can hold the same port without meeting. Zero turns it off.
	HealthPort int
}

// Dials reports whether this side is the one that opens the connection.
//
// Iran dials out, and that is the default because connections into the Iran
// server are blackholed after about six exchanges - measured, repeatedly - so
// the side that owns the ports users connect to is not the side that waits
// for the tunnel.
//
// The exception is a CDN. An edge answers on a name and connects inward to
// the origin it was given, so a domain in front of the Iran server can only
// be reached by dialling *into* it: the origin waits and the server abroad
// dials the edge. transport.dials says so when that is the arrangement.
func (c *Config) Dials() bool { return c.Side == c.DialSide() }

// DialSide is worked out from the two addresses rather than asked for.
//
// Iran dials out, and that is the default because connections into the Iran
// server are blackholed after about six exchanges - measured, repeatedly.
//
// The exception is a name. A CDN answers on a name and connects *inward* to
// the origin it was given, so a name can only ever front the side that waits:
// if the Iran server is named and the one abroad is an address, then Iran is
// the origin behind the edge, and the server abroad is the one that dials it.
// There is nothing to ask - the two addresses already say which it is.
func (c *Config) DialSide() string {
	switch c.Transport.Dials {
	case SideIran, SideKharej:
		return c.Transport.Dials
	}
	if isName(c.Transport.Iran) && !isName(c.Transport.Kharej) {
		return SideKharej
	}
	return SideIran
}

// isName is "this is a domain and not an address", which is the whole of what
// has to be told apart here: an address is digits and dots.
func isName(s string) bool {
	if s == "" {
		return false
	}
	return strings.ContainsFunc(s, func(r rune) bool {
		return (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z')
	})
}

// DialHost is what the side that dials connects to, which is the other
// server's address - and that address is the domain when somebody typed one.
//
// Over AmneziaWG it is neither: the carrier runs inside that link, so the
// far end is its address on the link and the public addresses are the
// business of awg-quick rather than of this.
func (c *Config) DialHost() string {
	if c.Transport.Type == "awg" {
		if c.DialSide() == SideIran {
			return addrOnly(c.AWG.Kharej)
		}
		return addrOnly(c.AWG.Iran)
	}
	if c.DialSide() == SideIran {
		return c.Transport.Kharej
	}
	return c.Transport.Iran
}

// addrOnly drops the prefix length from 10.9.0.1/24.
func addrOnly(s string) string {
	if i := strings.IndexByte(s, '/'); i >= 0 {
		return s[:i]
	}
	return s
}

// Path is what a WebSocket handshake asks for, and what the side that waits
// insists on before it will upgrade anything.
func (c *Config) Path() string {
	if c.Transport.Path == "" {
		return "/"
	}
	return c.Transport.Path
}

// ListenPort is where the side that waits binds, which behind a CDN is not
// the port the other side dialled.
//
// An edge takes the connection on one of its own ports and comes to the
// origin on another. Cloudflare's flexible mode - which is what somebody with
// no certificate on the origin is using, and that is nearly everybody putting
// a name in front of a server in Iran - terminates the TLS at the edge and
// arrives here in plain HTTP on 80. So a tunnel dialled on one of the HTTPS
// ports waits on 80 unless the file says otherwise.
func (c *Config) ListenPort() int {
	if c.Transport.ListenPort > 0 {
		return c.Transport.ListenPort
	}
	if isName(c.DialHost()) {
		switch c.Transport.Port {
		case 443, 2053, 2083, 2087, 2096, 8443:
			return 80
		}
	}
	return c.Transport.Port
}

// Mine returns this side's tun address, and theirs.
func (c *Config) Mine() (string, string) {
	if c.Side == SideIran {
		return c.TUN.Iran, c.TUN.Kharej
	}
	return c.TUN.Kharej, c.TUN.Iran
}

func Load(path string) (*Config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	c := &Config{}
	if err := parseTOML(string(raw), c); err != nil {
		return nil, err
	}
	return c, c.check()
}

// parseTOML reads the small subset of TOML this tool writes: `[table]`
// headers and bare `key = value` lines, with strings, integers and booleans.
// Pingify generates these files, so a full TOML implementation would be a
// dependency bought for nothing - and a dependency is what the offline build
// path in Iran cannot afford.
func parseTOML(text string, c *Config) error {
	sc := bufio.NewScanner(strings.NewReader(text))
	sc.Buffer(make([]byte, 0, 64*1024), 1<<20)
	table, line := "", 0

	for sc.Scan() {
		line++
		s := stripComment(sc.Text())
		if s == "" {
			continue
		}
		if strings.HasPrefix(s, "[") {
			if !strings.HasSuffix(s, "]") {
				return fmt.Errorf("line %d: unterminated table header", line)
			}
			table = strings.ToLower(strings.Trim(s[1:len(s)-1], " \t\""))
			continue
		}
		eq := strings.Index(s, "=")
		if eq < 0 {
			return fmt.Errorf("line %d: not a key = value", line)
		}
		key := strings.ToLower(strings.TrimSpace(s[:eq]))
		val := strings.TrimSpace(s[eq+1:])
		if err := assign(c, table, key, val); err != nil {
			return fmt.Errorf("line %d: %v", line, err)
		}
	}
	return sc.Err()
}

// assign puts one value where it belongs. An unknown key is an error rather
// than a shrug: a typo in a config file that is silently ignored is a tunnel
// that comes up with the wrong settings and no way to tell.
func assign(c *Config, table, key, raw string) error {
	str := func() (string, error) { return unquote(raw) }
	num := func() (int, error) { return strconv.Atoi(strings.Trim(raw, `"' `)) }

	var err error
	switch table + "." + key {
	case "tunnel.name":
		c.Name, err = str()
	case "tunnel.side":
		c.Side, err = str()
	case "tunnel.mode":
		c.Mode, err = str()

	case "transport.type":
		c.Transport.Type, err = str()
	case "transport.kharej":
		c.Transport.Kharej, err = str()
	case "transport.iran":
		c.Transport.Iran, err = str()
	case "transport.port":
		c.Transport.Port, err = num()
	case "transport.connections":
		c.Transport.Connections, err = num()
	case "transport.path":
		c.Transport.Path, err = str()
	case "transport.dials":
		c.Transport.Dials, err = str()
	case "transport.listen_port":
		c.Transport.ListenPort, err = num()
	case "transport.cert":
		c.Transport.Cert, err = str()
	case "transport.key":
		c.Transport.Key, err = str()
	case "transport.insecure":
		c.Transport.Insecure, err = boolean(raw)
	case "transport.keepalive_sec":
		c.Transport.Keepalive, err = num()

	case "security.token":
		c.Token, err = str()

	case "tuning.rcvbuf_kb":
		c.Tuning.RcvBufKB, err = num()
	case "tuning.sndbuf_kb":
		c.Tuning.SndBufKB, err = num()
	case "tuning.send_batch":
		c.Tuning.SendBatch, err = num()
	case "tuning.pace":
		c.Tuning.Pace, err = boolean(raw)
		c.Tuning.PaceSet = true
	case "tuning.pace_mbit":
		c.Tuning.PaceMbit, err = num()
		c.Tuning.PaceMbitSet = true
	case "tuning.profile":
		c.Tuning.Profile, err = str()
	case "tuning.queue_packets":
		c.Tuning.QueuePkts, err = num()
	case "tuning.fec":
		c.Tuning.FEC, err = num()

	case "tun.name":
		c.TUN.Name, err = str()
	case "tun.iran":
		c.TUN.Iran, err = str()
	case "tun.kharej":
		c.TUN.Kharej, err = str()
	case "tun.mtu":
		c.TUN.MTU, err = num()
	case "tun.queues":
		c.TUN.Queues, err = num()

	case "logging.level":
		c.Level, err = str()

	case "awg.name":
		c.AWG.Name, err = str()
	case "awg.iran":
		c.AWG.Iran, err = str()
	case "awg.kharej":
		c.AWG.Kharej, err = str()
	case "awg.mtu":
		c.AWG.MTU, err = num()
	case "awg.port":
		c.AWG.Port, err = num()
	case "awg.iran_key":
		c.AWG.IranKey, err = str()
	case "awg.iran_pub":
		c.AWG.IranPub, err = str()
	case "awg.kharej_key":
		c.AWG.KharejKey, err = str()
	case "awg.kharej_pub":
		c.AWG.KharejPub, err = str()
	case "awg.jc":
		c.AWG.Jc, err = num()
	case "awg.jmin":
		c.AWG.Jmin, err = num()
	case "awg.jmax":
		c.AWG.Jmax, err = num()
	case "awg.s1":
		c.AWG.S1, err = num()
	case "awg.s2":
		c.AWG.S2, err = num()
	case "awg.h1":
		c.AWG.H1, err = num()
	case "awg.h2":
		c.AWG.H2, err = num()
	case "awg.h3":
		c.AWG.H3, err = num()
	case "awg.h4":
		c.AWG.H4, err = num()

	case "status.port":
		c.StatusPort, err = num()
	case "status.health_port":
		c.HealthPort, err = num()

	default:
		return fmt.Errorf("unknown setting %q", table+"."+key)
	}
	return err
}

// The profiles, and the one number they move.
//
// Everything else this tunnel tunes was measured to have one right answer
// whatever it is carrying - the socket buffers, one packet per crossing into
// the kernel, a pacing rate it works out for itself - so a profile that
// changed those would be changing them for show.
//
// What genuinely trades is how deep a queue the kernel may hold for us. A deep
// one absorbs bursts and carries more; a shallow one is emptier when a small
// packet arrives, so that packet waits less. Measured on the real path,
// restarted fresh at each depth:
//
//	profile     queue    16 streams   one stream   under load
//	gaming        600     397 Mbit/s   167 Mbit/s   84.5 / 92.5 ms
//	balanced      900     448          254          93.3 / 106.5
//	download     1500     466          253         115.8 / 139.3
//
// Gaming gives up a third of a single stream for nine milliseconds at the
// median and fourteen at the ninetieth, which is the right trade when what
// crosses the link is a game and the wrong one when it is a film. Download
// buys eighteen megabits of aggregate for twenty-three milliseconds. Balanced
// is not the average of the other two: it carries a single stream faster than
// either and answers under load faster than flagtun does.
//
// The quiet round trip does not move at all - 81.0, 81.1, 81.2 - because an
// empty queue is an empty queue however deep it was allowed to get. What a
// profile changes is what happens when the link is busy, which is the only
// time any of it is felt.
const (
	ProfileGaming   = "gaming"
	ProfileBalanced = "balanced"
	ProfileDownload = "download"
)

func (c *Config) profile() error {
	depth := 0
	switch strings.ToLower(strings.TrimSpace(c.Tuning.Profile)) {
	case "":
		c.Tuning.Profile = ProfileBalanced
		depth = 900
	case ProfileGaming:
		depth = 600
	case ProfileBalanced:
		depth = 900
	case ProfileDownload:
		depth = 1500
	default:
		return fmt.Errorf("tuning.profile %q: it is %q, %q or %q",
			c.Tuning.Profile, ProfileGaming, ProfileBalanced, ProfileDownload)
	}

	// An explicit depth wins. The profiles are three points on a line, and
	// somebody measuring their own path may want a fourth.
	if c.Tuning.QueuePkts == 0 {
		c.Tuning.QueuePkts = depth
		return nil
	}
	if c.Tuning.QueuePkts < 200 {
		return fmt.Errorf("tuning.queue_packets %d: below two hundred the queue stops"+
			" smoothing bursts and starts refusing work the link could have carried"+
			" - one stream fell to 75 Mbit/s", c.Tuning.QueuePkts)
	}
	if c.Tuning.QueuePkts > 20000 {
		return fmt.Errorf("tuning.queue_packets %d: that is a quarter of a second of"+
			" queue and it behaves like one", c.Tuning.QueuePkts)
	}
	return nil
}

func boolean(raw string) (bool, error) {
	switch strings.ToLower(strings.Trim(raw, `"' `)) {
	case "true", "yes", "on", "1":
		return true, nil
	case "false", "no", "off", "0":
		return false, nil
	}
	return false, fmt.Errorf("%q is not true or false", raw)
}

func stripComment(s string) string {
	out, quoted := make([]byte, 0, len(s)), false
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '"':
			quoted = !quoted
		case '#':
			if !quoted {
				return strings.TrimSpace(string(out))
			}
		}
		out = append(out, s[i])
	}
	return strings.TrimSpace(string(out))
}

func unquote(s string) (string, error) {
	s = strings.TrimSpace(s)
	if len(s) >= 2 && s[0] == '"' && s[len(s)-1] == '"' {
		return s[1 : len(s)-1], nil
	}
	if len(s) >= 2 && s[0] == '\'' && s[len(s)-1] == '\'' {
		return s[1 : len(s)-1], nil
	}
	return s, nil
}

// check fills in what has a sensible default and refuses what does not. It
// runs before anything opens a socket, so a bad config fails at the moment
// the user can still read the message.
func (c *Config) check() error {
	if c.Side != SideIran && c.Side != SideKharej {
		return fmt.Errorf("tunnel.side must be %q or %q, not %q", SideIran, SideKharej, c.Side)
	}
	if c.Mode == "" {
		c.Mode = "tun"
	}
	if c.Mode != "tun" {
		return fmt.Errorf("tunnel.mode %q: only \"tun\" is built so far", c.Mode)
	}
	if c.Transport.Type == "" {
		c.Transport.Type = "udp"
	}
	switch c.Transport.Type {
	case "udp", "icmp", "tcp", "ws", "wss", "gre", "rawtcp", "utls", "fallback":
	case "awg":
		if c.AWG.Iran == "" || c.AWG.Kharej == "" {
			return fmt.Errorf("awg.iran and awg.kharej are both needed, on both servers")
		}
	default:
		return fmt.Errorf("transport.type %q: udp, tcp, ws, wss, gre, awg, rawtcp, utls, fallback and icmp are what exist so far",
			c.Transport.Type)
	}
	switch c.Transport.Dials {
	case "", SideIran, SideKharej:
	default:
		return fmt.Errorf("transport.dials %q must be %q or %q",
			c.Transport.Dials, SideIran, SideKharej)
	}
	if c.Transport.ListenPort < 0 || c.Transport.ListenPort > 65535 {
		return fmt.Errorf("transport.listen_port %d is not a port", c.Transport.ListenPort)
	}
	if c.Transport.Path != "" && !strings.HasPrefix(c.Transport.Path, "/") {
		return fmt.Errorf("transport.path %q has to start with a slash", c.Transport.Path)
	}
	// Two of them have no ports at all: one rides in echo requests and the
	// other is its own IP protocol. There is nothing to listen on and nothing
	// to misconfigure, which is half of why they are the ones that survive.
	switch c.Transport.Type {
	case "icmp", "gre":
	default:
		if c.Transport.Port <= 0 || c.Transport.Port > 65535 {
			return fmt.Errorf("transport.port %d is not a port", c.Transport.Port)
		}
	}
	if c.Dials() && c.DialHost() == "" {
		return fmt.Errorf("transport: the side that dials needs an address or a domain to dial")
	}
	if c.Transport.Keepalive <= 0 {
		c.Transport.Keepalive = 10
	}
	if c.Transport.Connections == 0 {
		c.Transport.Connections = DefaultConnections
	}
	if c.Transport.Connections < 1 || c.Transport.Connections > 32 {
		return fmt.Errorf("transport.connections %d: between 1 and 32", c.Transport.Connections)
	}
	if len(c.Token) < 8 {
		return fmt.Errorf("security.token is too short to be worth having")
	}
	if c.TUN.Name == "" {
		c.TUN.Name = "pfy0"
	}
	if c.TUN.Iran == "" || c.TUN.Kharej == "" {
		return fmt.Errorf("tun.iran and tun.kharej are both needed, on both servers")
	}
	if c.TUN.MTU == 0 {
		c.TUN.MTU = 1320
	}
	if c.TUN.MTU < 576 || c.TUN.MTU > 9000 {
		return fmt.Errorf("tun.mtu %d is outside anything that works", c.TUN.MTU)
	}
	if c.TUN.Queues < 0 || c.TUN.Queues > 16 {
		return fmt.Errorf("tun.queues %d is not a number of queues", c.TUN.Queues)
	}
	if c.Name == "" {
		c.Name = "pingify"
	}
	if c.Tuning.FEC != 0 && (c.Tuning.FEC < 4 || c.Tuning.FEC > 32) {
		return fmt.Errorf("tuning.fec %d: 0 turns it off, otherwise 4 to 32", c.Tuning.FEC)
	}
	if c.StatusPort < 0 || c.StatusPort > 65535 {
		return fmt.Errorf("status.port %d is not a port", c.StatusPort)
	}
	// Absent means the default, and a negative number is how the file says
	// "none" - because zero is already what an absent key looks like, and a
	// setting whose off switch cannot be told from its default is a setting
	// nobody can turn off.
	switch {
	case c.HealthPort == 0:
		c.HealthPort = DefaultHealthPort
	case c.HealthPort < 0:
		c.HealthPort = 0
	case c.HealthPort > 65535:
		return fmt.Errorf("status.health_port %d is not a port", c.HealthPort)
	}
	// Measured on the real path, sweeping the receive buffer against latency
	// and throughput: below about two megabytes the kernel drops packets the
	// process never sees, and above about six the queue is deep enough to be
	// felt as lag. Three is where both were good.
	if c.Tuning.RcvBufKB == 0 {
		c.Tuning.RcvBufKB = 3072
	}
	if c.Tuning.SndBufKB == 0 {
		c.Tuning.SndBufKB = 16384
	}
	// On by default. It is a change to the whole interface, so it is logged
	// where anyone can see it, and one line of config turns it off.
	if !c.Tuning.PaceSet {
		c.Tuning.Pace = true
	}
	if err := c.profile(); err != nil {
		return err
	}
	if c.Tuning.PaceMbit < 0 {
		return fmt.Errorf("tuning.pace_mbit %d is not a rate", c.Tuning.PaceMbit)
	}
	// Zero means "let the carrier choose", which is what happens: how many
	// packets fit in one crossing into the kernel is the carrier's business
	// and differs by platform, so the number is not decided here.
	if c.Tuning.SendBatch < 0 || c.Tuning.SendBatch > MaxSendBatch {
		return fmt.Errorf("tuning.send_batch %d is outside 0..%d", c.Tuning.SendBatch, MaxSendBatch)
	}
	return nil
}
