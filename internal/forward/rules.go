package forward

import (
	"fmt"
	"net"
	"strconv"
	"strings"
)

// One user-facing port on the IRAN server, and where on the KHAREJ server it
// goes. The spelling is the one the Ports screen has always taken:
//
//	443                  tcp 443 here to 127.0.0.1:443 there
//	8000-8010            a range, port for port
//	udp:500              the same for udp
//	443=8443             a different port there
//	443=10.99.10.5:443   a different host there
type Rule struct {
	Proto  string // tcp | udp
	Port   int    // the port bound here
	Target string // host:port dialled there
}

// Parse turns one spec into its rules - one per port of a range.
func Parse(spec string) ([]Rule, error) {
	s := strings.TrimSpace(spec)
	if s == "" {
		return nil, fmt.Errorf("an empty forward")
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
		if strings.TrimSpace(remote) == "" {
			return nil, fmt.Errorf("%q: there is nothing after the =", spec)
		}
	}
	lo, hi, err := portRange(local)
	if err != nil {
		return nil, fmt.Errorf("%q: %v", spec, err)
	}
	host, base := "127.0.0.1", 0
	if remote != "" {
		rp := remote
		if i := strings.LastIndex(remote, ":"); i >= 0 {
			host, rp = remote[:i], remote[i+1:]
			if host == "" {
				host = "127.0.0.1"
			}
		}
		if rp != "" {
			if base, err = strconv.Atoi(rp); err != nil || base < 1 || base > 65535 {
				return nil, fmt.Errorf("%q: %q is not a port", spec, rp)
			}
		}
		if net.ParseIP(host) == nil && !validHost(host) {
			return nil, fmt.Errorf("%q: %q is not an address", spec, host)
		}
	}
	var out []Rule
	for p := lo; p <= hi; p++ {
		t := p
		if base > 0 {
			t = base + (p - lo)
			if t > 65535 {
				return nil, fmt.Errorf("%q: the far ports run past 65535", spec)
			}
		}
		out = append(out, Rule{Proto: proto, Port: p, Target: net.JoinHostPort(host, strconv.Itoa(t))})
	}
	return out, nil
}

// ParseAll is Parse over every spec in a config, with the first fault named.
func ParseAll(specs []string) ([]Rule, error) {
	var out []Rule
	for _, s := range specs {
		r, err := Parse(s)
		if err != nil {
			return nil, err
		}
		out = append(out, r...)
	}
	return out, nil
}

func portRange(s string) (int, int, error) {
	if i := strings.Index(s, "-"); i >= 0 {
		lo, e1 := strconv.Atoi(strings.TrimSpace(s[:i]))
		hi, e2 := strconv.Atoi(strings.TrimSpace(s[i+1:]))
		if e1 != nil || e2 != nil || lo < 1 || hi > 65535 || lo > hi {
			return 0, 0, fmt.Errorf("not a port range")
		}
		if hi-lo > 512 {
			return 0, 0, fmt.Errorf("a range wider than 512 ports")
		}
		return lo, hi, nil
	}
	p, err := strconv.Atoi(strings.TrimSpace(s))
	if err != nil || p < 1 || p > 65535 {
		return 0, 0, fmt.Errorf("not a port")
	}
	return p, p, nil
}

func validHost(s string) bool {
	if len(s) == 0 || len(s) > 253 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		case c == '-' || c == '.' || c == '_':
		default:
			return false
		}
	}
	return true
}
