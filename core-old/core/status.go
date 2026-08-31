package main

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"sync/atomic"
	"time"
)

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
