package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
)

// Configs are TOML, grouped into sections so that reading one tells you how a
// tunnel is put together rather than handing you thirty flat keys in the order
// somebody happened to add them.
//
//	[tunnel]     what this tunnel is and which end this is
//	[transport]  how the carriers travel
//	[security]   the shared secret
//	[forward]    the ports this end serves
//	[tun]        the private link, when there is one
//	[tuning]     numbers you may want to change
//	[status]     where to ask how it is doing
//	[logging]    how much to say
//
// JSON is still read, because that is what versions before this wrote and a
// config on a running server should not stop working because of a release.
//
// The parser is deliberately small: this is a config file written by our own
// manager, not a document from the internet. It handles sections, key = value,
// quoted strings, integers with _ separators, and arrays of strings. A key it
// does not know is skipped rather than refused, so a config from a newer
// Pingify still starts an older core instead of leaving a server with nothing.
func loadConfig(path string) (*Config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c Config
	if strings.HasPrefix(strings.TrimSpace(string(raw)), "{") {
		if err := json.Unmarshal(raw, &c); err != nil {
			return nil, fmt.Errorf("parse json config: %v", err)
		}
		return &c, nil
	}
	if err := parseTOML(string(raw), &c); err != nil {
		return nil, err
	}
	return &c, nil
}

func parseTOML(text string, c *Config) error {
	sc := bufio.NewScanner(strings.NewReader(text))
	sc.Buffer(make([]byte, 0, 64*1024), 1<<20)
	section := ""
	line := 0

	for sc.Scan() {
		line++
		s := stripComment(sc.Text())
		if s == "" {
			continue
		}
		if strings.HasPrefix(s, "[") {
			if !strings.HasSuffix(s, "]") {
				return fmt.Errorf("line %d: unterminated section header", line)
			}
			section = strings.Trim(s[1:len(s)-1], " \t\"'")
			continue
		}
		eq := strings.Index(s, "=")
		if eq < 0 {
			return fmt.Errorf("line %d: expected key = value", line)
		}
		key := strings.TrimSpace(s[:eq])
		val := strings.TrimSpace(s[eq+1:])
		if key == "" {
			return fmt.Errorf("line %d: empty key", line)
		}
		if err := assign(c, section, key, val); err != nil {
			return fmt.Errorf("line %d: %v", line, err)
		}
	}
	return sc.Err()
}

// stripComment drops a trailing # comment, unless the # is inside quotes -
// a password or a hostname is allowed to contain one.
func stripComment(s string) string {
	inQ := false
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '"':
			inQ = !inQ
		case '#':
			if !inQ {
				return strings.TrimSpace(s[:i])
			}
		}
	}
	return strings.TrimSpace(s)
}

func unquote(s string) string {
	s = strings.TrimSpace(s)
	if len(s) >= 2 && s[0] == '"' && s[len(s)-1] == '"' {
		if out, err := strconv.Unquote(s); err == nil {
			return out
		}
		return s[1 : len(s)-1]
	}
	return s
}

// atoi accepts 10_000 as well as 10000: the tuning numbers are big enough to
// be worth grouping, and a config is easier to check when they are.
func atoi(key, val string) (int, error) {
	v := strings.ReplaceAll(unquote(val), "_", "")
	n, err := strconv.Atoi(v)
	if err != nil {
		return 0, fmt.Errorf("%s must be a number, got %q", key, val)
	}
	return n, nil
}

// strList reads ["443", "udp:500"], and also a bare "443" so a single value
// does not need brackets.
func strList(val string) []string {
	v := strings.TrimSpace(val)
	if !strings.HasPrefix(v, "[") {
		if s := unquote(v); s != "" {
			return []string{s}
		}
		return nil
	}
	v = strings.TrimSuffix(strings.TrimPrefix(v, "["), "]")
	var out []string
	for _, part := range splitTop(v) {
		if s := unquote(part); s != "" {
			out = append(out, s)
		}
	}
	return out
}

// splitTop splits on commas that are not inside quotes.
func splitTop(s string) []string {
	var out []string
	inQ, start := false, 0
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '"':
			inQ = !inQ
		case ',':
			if !inQ {
				out = append(out, s[start:i])
				start = i + 1
			}
		}
	}
	return append(out, s[start:])
}

// assign maps one key onto the Config.
//
// Every section also accepts its keys with no section at all, which is what
// the flat JSON layout used. One table, both shapes, no second parser.
func assign(c *Config, section, key, val string) error {
	var err error
	num := func(dst *int) error {
		n, e := atoi(key, val)
		if e == nil {
			*dst = n
		}
		return e
	}

	switch section {
	case "", "tunnel":
		switch key {
		case "name":
			c.Name = unquote(val)
		case "role":
			c.Role = unquote(val)
		case "mode":
			c.Mode = unquote(val)
		}
	}

	switch section {
	case "", "transport":
		switch key {
		case "type", "transport":
			c.Transport = unquote(val)
		case "listen":
			c.Listen = unquote(val)
		case "connect":
			c.Connect = unquote(val)
		case "carriers":
			err = num(&c.Carriers)
		case "keepalive_sec":
			err = num(&c.KeepaliveSec)
		case "dial_timeout_sec":
			err = num(&c.DialTimeout)
		}
	}

	switch section {
	case "", "security":
		if key == "psk" {
			c.PSK = unquote(val)
		}
	}

	switch section {
	case "", "forward":
		switch key {
		case "ports", "forwards":
			c.Forwards = strList(val)
		case "allow":
			c.Allow = strList(val)
		}
	}

	switch section {
	case "tun":
		switch key {
		case "name", "device":
			c.TUN.Name = unquote(val)
		case "local_addr", "local":
			c.TUN.Local = unquote(val)
		case "remote_addr", "peer":
			c.TUN.Peer = unquote(val)
		case "mtu":
			err = num(&c.TUN.MTU)
		}
	}

	switch section {
	case "", "tuning":
		switch key {
		case "window_kb":
			err = num(&c.WindowKB)
		case "sndbuf_kb":
			err = num(&c.SndBufKB)
		case "rcvbuf_kb":
			err = num(&c.RcvBufKB)
		}
	}

	switch section {
	case "", "status":
		if key == "addr" || key == "status_addr" {
			c.StatusAddr = unquote(val)
		}
	}

	switch section {
	case "", "logging":
		if key == "level" || key == "log_level" {
			c.LogLevel = unquote(val)
		}
	}

	return err
}
