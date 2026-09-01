package status

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"strings"
	"sync/atomic"
	"time"

	"pingify/internal/config"
	"pingify/internal/logging"
)

// What the tunnel will tell you about itself.
//
// A manager script needs to answer three questions and it should not have to
// read a log to do it: is the tunnel up, is it carrying anything, and is the
// path taking packets away from it. The last one is the reason this exists at
// all - nothing else on either machine can see it, and a person looking at a
// tunnel that feels slow has no other way to find out that four hundred
// packets a minute are being dropped somewhere between Tehran and Frankfurt.
//
// It listens on the loopback address only. There is nothing secret in here,
// but there is nothing here anybody else needs either, and a port open on a
// public address is a port somebody will knock on.

// Source is what the tunnel gives this package to report on. It is an
// interface so that status depends on nothing: the carrier and the link do not
// know it exists, and cannot be made slower by it.
type Source interface {
	Counters() (rx, tx, bad, replay, errs uint64)
	Lost() (missing, late, gaps uint64)
	Up() bool
}

// Link is the little the report needs from the private link.
type Link interface {
	Dropped() uint64
	Packets() (toWire, toDevice uint64)
}

// Repairer is a carrier that can put a lost packet back together. Only the
// ones wrapped in parity can, so it is asked for rather than required.
type Repairer interface{ Repaired() uint64 }

type Report struct {
	Version string `json:"version"`
	Name    string `json:"name"`
	Side    string `json:"side"`
	Mode    string `json:"mode"`
	Profile string `json:"profile"`

	Transport string `json:"transport"`
	Up        bool   `json:"up"`
	UptimeSec int64  `json:"uptime_sec"`

	InMbit  float64 `json:"in_mbit"`
	OutMbit float64 `json:"out_mbit"`
	InBytes uint64  `json:"in_bytes"`
	OutByte uint64  `json:"out_bytes"`

	// What the path took. Counted from gaps in a sequence number that is
	// consecutive at the sender, which is the only place it is visible.
	PathLost      uint64 `json:"path_lost"`
	PathReordered uint64 `json:"path_reordered"`
	PathGaps      uint64 `json:"path_gaps"`

	NotOurs    uint64 `json:"not_ours"`
	AlreadySee uint64 `json:"already_seen"`
	SendErrors uint64 `json:"send_errors"`

	ToWire   uint64 `json:"to_wire"`
	ToDevice uint64 `json:"to_device"`
	Dropped  uint64 `json:"dropped"`

	// How many packets came back from parity rather than from the wire. It is
	// the one number that says whether the parity is earning its bandwidth,
	// and it is absent on a transport that has none.
	Repaired uint64 `json:"fec_repaired"`
}

type Server struct {
	cfg   *config.Config
	car   Source
	link  Link
	start time.Time
	ver   string

	lastRx, lastTx uint64
	lastAt         time.Time
	inRate, outRA  uint64 // most recent rates, in bytes per second
}

func New(cfg *config.Config, ver string, car Source, l Link) *Server {
	return &Server{cfg: cfg, car: car, link: l, start: time.Now(), ver: ver, lastAt: time.Now()}
}

// Serve answers on the loopback address until the process ends. A port that
// cannot be opened is not fatal: the tunnel's job is to carry traffic, and it
// carries it just as well with nobody watching.
func (s *Server) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		_ = enc.Encode(s.Report())
	})
	// Something for a shell script to test without parsing anything: up is 200
	// and down is 503, and that is the whole protocol.
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		if !s.car.Up() {
			http.Error(w, "down", http.StatusServiceUnavailable)
			return
		}
		fmt.Fprintln(w, "up")
	})
	return mux
}

// Serve answers on two addresses, and they are not the same audience.
//
// The loopback port is for this machine: the manager reads it every time it
// draws a screen, and nothing outside can reach it.
//
// The link port is for the server at the other end, on this tunnel's own
// private address. It exists because an ICMP tunnel cannot be pinged - the
// carrier stops both kernels answering echo, on purpose - so a port that
// answers is the only thing left that can say what the round trip across the
// link is, or whether there is anybody at the other end of it at all. What it
// serves is what loopback serves, so the far server can also see this one's
// version and profile, which is how a mismatched pair is found without
// logging into both.
//
// It is bound to the tun address alone. That address is reachable through
// this tunnel and nowhere else, so what is open here is open to one server.
func (s *Server) Serve(port, linkPort int) {
	go s.sample()
	h := s.handler()
	if port > 0 {
		go serveOn(fmt.Sprintf("127.0.0.1:%d", port), h, "status")
	}
	if linkPort > 0 {
		mine, _ := s.cfg.Mine()
		if ip, _, ok := strings.Cut(mine, "/"); ok && ip != "" {
			go serveOn(fmt.Sprintf("%s:%d", ip, linkPort), h, "health")
		}
	}
}

// serveOn binds and answers, and waits a little for the address to exist.
//
// The link listener is bound to the tun device's address, and the device is
// brought up moments earlier by another goroutine. Two seconds of retrying
// costs nothing and removes a race that would otherwise show up as "no health
// port" on a tunnel that is working perfectly well.
func serveOn(addr string, h http.Handler, what string) {
	var ln net.Listener
	var err error
	for i := 0; i < 10; i++ {
		if ln, err = net.Listen("tcp", addr); err == nil {
			break
		}
		time.Sleep(200 * time.Millisecond)
	}
	if err != nil {
		logging.Warn("no %s on %s (%v) - the tunnel runs either way", what, addr, err)
		return
	}
	logging.Info("%s on http://%s", what, addr)
	srv := &http.Server{Handler: h, ReadHeaderTimeout: 5 * time.Second}
	_ = srv.Serve(ln)
}

// sample turns the counters into a rate once a second, because a byte total is
// not what anybody wants to know and dividing it by uptime is a lie about the
// last hour.
func (s *Server) sample() {
	tk := time.NewTicker(time.Second)
	defer tk.Stop()
	for range tk.C {
		rx, tx, _, _, _ := s.car.Counters()
		now := time.Now()
		if secs := now.Sub(s.lastAt).Seconds(); secs > 0 {
			atomic.StoreUint64(&s.inRate, uint64(float64(rx-s.lastRx)/secs))
			atomic.StoreUint64(&s.outRA, uint64(float64(tx-s.lastTx)/secs))
		}
		s.lastRx, s.lastTx, s.lastAt = rx, tx, now
	}
}

func (s *Server) Report() Report {
	rx, tx, bad, replay, errs := s.car.Counters()
	missing, late, gaps := s.car.Lost()
	toWire, toDevice := s.link.Packets()
	return Report{
		Version:       s.ver,
		Name:          s.cfg.Name,
		Side:          s.cfg.Side,
		Mode:          s.cfg.Mode,
		Profile:       s.cfg.Tuning.Profile,
		Transport:     s.cfg.Transport.Type,
		Up:            s.car.Up(),
		UptimeSec:     int64(time.Since(s.start).Seconds()),
		InMbit:        float64(atomic.LoadUint64(&s.inRate)) * 8 / 1e6,
		OutMbit:       float64(atomic.LoadUint64(&s.outRA)) * 8 / 1e6,
		InBytes:       rx,
		OutByte:       tx,
		PathLost:      missing,
		PathReordered: late,
		PathGaps:      gaps,
		NotOurs:       bad,
		AlreadySee:    replay,
		SendErrors:    errs,
		ToWire:        toWire,
		ToDevice:      toDevice,
		Dropped:       s.link.Dropped(),
		Repaired:      s.repaired(),
	}
}

// Fetch reads a report from a running tunnel.
func Fetch(addr string) (*Report, error) {
	if !strings.Contains(addr, ":") {
		addr = "127.0.0.1:" + addr
	}
	c := &http.Client{Timeout: 4 * time.Second}
	resp, err := c.Get("http://" + addr + "/")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("the tunnel answered %s", resp.Status)
	}
	var r Report
	if err := json.NewDecoder(resp.Body).Decode(&r); err != nil {
		return nil, err
	}
	return &r, nil
}

// Print writes a report the way a person reads one. The manager script draws
// its own; this is for someone at a prompt with no manager in front of them.
func Print(r *Report) {
	up := "down"
	if r.Up {
		up = "up"
	}
	fmt.Printf("%s %s, %s side, %s over %s, %s profile\n",
		r.Name, r.Version, r.Side, r.Mode, r.Transport, r.Profile)
	fmt.Printf("  %s for %s\n", up, dur(r.UptimeSec))
	fmt.Printf("  carrying %.1f Mbit/s in, %.1f Mbit/s out\n", r.InMbit, r.OutMbit)
	fmt.Printf("  %s in, %s out since it started\n", size(r.InBytes), size(r.OutByte))
	if r.PathLost > 0 {
		per := float64(r.PathLost) / float64(max(r.PathGaps, 1))
		fmt.Printf("  the path has taken %d packets in %d runs, %.0f at a time\n",
			r.PathLost, r.PathGaps, per)
	} else {
		fmt.Printf("  the path has taken nothing\n")
	}
	if r.Dropped > 0 {
		fmt.Printf("  %d packets could not be put on the wire\n", r.Dropped)
	}
}

func dur(sec int64) string {
	switch {
	case sec < 60:
		return fmt.Sprintf("%ds", sec)
	case sec < 3600:
		return fmt.Sprintf("%dm", sec/60)
	case sec < 86400:
		return fmt.Sprintf("%dh %dm", sec/3600, (sec%3600)/60)
	}
	return fmt.Sprintf("%dd %dh", sec/86400, (sec%86400)/3600)
}

func size(b uint64) string {
	const k = 1024
	switch {
	case b < k:
		return fmt.Sprintf("%d B", b)
	case b < k*k:
		return fmt.Sprintf("%.1f KB", float64(b)/k)
	case b < k*k*k:
		return fmt.Sprintf("%.1f MB", float64(b)/(k*k))
	}
	return fmt.Sprintf("%.2f GB", float64(b)/(k*k*k))
}

func max(a, b uint64) uint64 {
	if a > b {
		return a
	}
	return b
}

// repaired is what the carrier put back together from parity, or zero when it
// has no parity to put anything back together with.
func (s *Server) repaired() uint64 {
	if r, ok := s.car.(Repairer); ok {
		return r.Repaired()
	}
	return 0
}
