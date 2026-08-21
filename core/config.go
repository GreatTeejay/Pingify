package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
)

// ---------------------------------------------------------------------------
// configuration files
//
// TOML is what people expect for this kind of tool, so that is what Pingify
// writes. What it reads back is a deliberately small subset: bare `key = value`
// at the top level, one `[tun]` table, string arrays, integers and strings.
// Pingify generates these files, so a full TOML implementation would be a
// dependency bought for nothing - and a dependency is exactly what the offline
// build path cannot afford.
//
// JSON is still accepted so that configs written by 3.2 and earlier keep
// working without anyone having to convert them.
// ---------------------------------------------------------------------------

func loadConfig(path string) (*Config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config: %v", err)
	}
	var cfg Config
	if strings.HasPrefix(strings.TrimSpace(string(raw)), "{") {
		if err := json.Unmarshal(raw, &cfg); err != nil {
			return nil, fmt.Errorf("parse config: %v", err)
		}
		return &cfg, nil
	}
	if err := parseTOML(string(raw), &cfg); err != nil {
		return nil, fmt.Errorf("parse config: %v", err)
	}
	return &cfg, nil
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
				return fmt.Errorf("line %d: unterminated table header", line)
			}
			section = strings.Trim(s[1:len(s)-1], " \t\"")
			continue
		}
		eq := strings.Index(s, "=")
		if eq < 0 {
			return fmt.Errorf("line %d: expected key = value", line)
		}
		key := strings.TrimSpace(s[:eq])
		val := strings.TrimSpace(s[eq+1:])
		if err := assign(c, section, key, val); err != nil {
			return fmt.Errorf("line %d: %v", line, err)
		}
	}
	return sc.Err()
}

// stripComment removes a trailing # comment, leaving anything inside quotes
// alone so a value may contain a hash.
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

// parseArray reads ["a", "b"] into its elements.
func parseArray(s string) ([]string, error) {
	s = strings.TrimSpace(s)
	if !strings.HasPrefix(s, "[") || !strings.HasSuffix(s, "]") {
		return nil, fmt.Errorf("expected a [...] array")
	}
	body := strings.TrimSpace(s[1 : len(s)-1])
	if body == "" {
		return nil, nil
	}
	var out []string
	for _, part := range splitTop(body) {
		part = unquote(part)
		if part != "" {
			out = append(out, part)
		}
	}
	return out, nil
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

func atoi(key, s string) (int, error) {
	// TOML allows 10_000 as a readability separator.
	n, err := strconv.Atoi(strings.ReplaceAll(strings.TrimSpace(s), "_", ""))
	if err != nil {
		return 0, fmt.Errorf("%s: %q is not a number", key, s)
	}
	return n, nil
}

// assign maps one key onto the Config. Sections group what belongs together;
// a key with no section is the flat layout Pingify wrote before 3.4 and is
// still accepted so an existing file keeps working.
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
			c.Forwards, err = parseArray(val)
		case "allow":
			c.Allow, err = parseArray(val)
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

	if section == "tun" {
		switch key {
		case "name":
			c.TUN.Name = unquote(val)
		case "local", "local_addr":
			c.TUN.Local = unquote(val)
		case "peer", "remote_addr":
			c.TUN.Peer = unquote(val)
		case "mtu":
			err = num(&c.TUN.MTU)
		}
	}

	// Anything unrecognised is ignored on purpose: a config written by a newer
	// Pingify should not stop an older core from starting.
	return err
}
