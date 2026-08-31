package main

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
	sideIran   = "iran"
	sideKharej = "kharej"
)

type Config struct {
	Name string
	Side string // iran | kharej
	Mode string // tun

	Transport struct {
		Type      string // udp
		Kharej    string // the abroad server's address
		Port      int
		Keepalive int // seconds
	}

	Token string

	Tuning struct {
		RcvBufKB  int
		SndBufKB  int
		SendBatch int  // packets per crossing into the kernel; 0 means choose
		Pace      bool // put fq on the way out, so bursts leave as a stream
		PaceMbit  int  // and cap the rate; unset means half the link speed

		paceSet     bool
		paceMbitSet bool
	}

	TUN struct {
		Name   string
		Iran   string
		Kharej string
		MTU    int
		Queues int // 0 means choose one
	}

	Level string
}

// dials reports whether this side is the one that opens the connection.
//
// Iran dials out, always. Connections into the Iran server are blackholed
// after about six exchanges - measured, repeatedly - so the side that owns the
// ports users connect to is not the side that waits for the tunnel. This is
// settled and nothing above needs to ask again.
func (c *Config) dials() bool { return c.Side == sideIran }

// mine returns this side's tun address, and theirs.
func (c *Config) mine() (string, string) {
	if c.Side == sideIran {
		return c.TUN.Iran, c.TUN.Kharej
	}
	return c.TUN.Kharej, c.TUN.Iran
}

func loadConfig(path string) (*Config, error) {
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
	case "transport.port":
		c.Transport.Port, err = num()
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
		c.Tuning.paceSet = true
	case "tuning.pace_mbit":
		c.Tuning.PaceMbit, err = num()
		c.Tuning.paceMbitSet = true

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

	default:
		return fmt.Errorf("unknown setting %q", table+"."+key)
	}
	return err
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
	if c.Side != sideIran && c.Side != sideKharej {
		return fmt.Errorf("tunnel.side must be %q or %q, not %q", sideIran, sideKharej, c.Side)
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
	if c.Transport.Type != "udp" && c.Transport.Type != "icmp" {
		return fmt.Errorf("transport.type %q: udp and icmp are what exist so far", c.Transport.Type)
	}
	// ICMP has no ports. There is nothing to listen on and nothing to
	// misconfigure, which is half of why it is the transport that survives.
	if c.Transport.Type != "icmp" && (c.Transport.Port <= 0 || c.Transport.Port > 65535) {
		return fmt.Errorf("transport.port %d is not a port", c.Transport.Port)
	}
	if c.dials() && c.Transport.Kharej == "" {
		return fmt.Errorf("transport.kharej: the Iran side needs the address it dials")
	}
	if c.Transport.Keepalive <= 0 {
		c.Transport.Keepalive = 10
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
	if c.Tuning.SendBatch == 0 {
		c.Tuning.SendBatch = defaultSendBatch
	}
	// On by default. It is a change to the whole interface, so it is logged
	// where anyone can see it, and one line of config turns it off.
	if !c.Tuning.paceSet {
		c.Tuning.Pace = true
	}
	if c.Tuning.PaceMbit < 0 {
		return fmt.Errorf("tuning.pace_mbit %d is not a rate", c.Tuning.PaceMbit)
	}
	if c.Tuning.SendBatch < 1 || c.Tuning.SendBatch > sendBatch {
		return fmt.Errorf("tuning.send_batch %d is outside 1..%d", c.Tuning.SendBatch, sendBatch)
	}
	return nil
}
