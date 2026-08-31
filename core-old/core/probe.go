package main

import (
	"errors"
	"fmt"
	"net"
	"time"
)

// runProbe answers the question a bare connection cannot.
//
// The near server accepts on a forwarded port before it has said a word to the
// tunnel, so "it connected" proves only that something is listening here. What
// separates a working path from a broken one is what happens next: if the far
// server cannot reach the service it sends back a reset and the connection
// dies within moments, and if it can, the connection simply stays open.
// What the probe exits with. The health check words its verdict from this,
// because "a port could not be reached" and "nothing at all is coming back"
// are different faults on different machines, and telling them apart is the
// whole reason this runs.
const (
	probeOK     = 0
	probeFailed = 1 // a forwarded port did not reach its service
	probeOneWay = 3 // the far server sent nothing at all while we asked
)

func runProbe(cfg *Config) int {
	if cfg.Role != "server" {
		fmt.Println("Run this on the IRAN server: that is the end with the ports.")
		return 2
	}
	var before *statusDoc
	if cfg.StatusAddr != "" {
		d, err := fetchStatus(cfg.StatusAddr)
		if err != nil {
			fmt.Printf("No carrier is up (%v). Nothing can cross the tunnel yet.\n", err)
			return 1
		}
		before = d
		fmt.Printf("%d of %d carriers up, %.0f ms to the other server.\n\n",
			d.Up, d.Carriers, d.RTTms)
	}

	bad := 0
	for _, spec := range cfg.Forwards {
		rules, err := parseForward(spec)
		if err != nil {
			fmt.Printf("  %-30s cannot be read: %v\n", spec, err)
			bad++
			continue
		}
		for _, r := range rules {
			if r.proto != "tcp" {
				fmt.Printf("  udp :%-25d not testable this way\n", r.lport)
				continue
			}
			if !probeOne(r, cfg.StatusAddr) {
				bad++
			}
		}
	}
	// A stream that is simply never answered looks identical to one the far
	// side accepted and had nothing to say about - both leave the connection
	// open. The only thing that tells them apart is whether the other server
	// sent us anything at all while we were asking.
	if before != nil {
		after, err := fetchStatus(cfg.StatusAddr)
		if err == nil {
			// A carrier that dies mid-test resets every stream on it, and the
			// near end cannot tell that apart from the far end refusing: both
			// arrive as EOF. Saying "the other server could not reach it" when
			// the carrier went out from under the test sends the reader to the
			// wrong machine, which is exactly what happened.
			if carrierRestarted(before, after) {
				fmt.Println("\nA carrier restarted while this was running, so every stream on")
				fmt.Println("it was reset. Any failure above may be that and not the service")
				fmt.Println("on the other server - fix the carriers dropping first, then test")
				fmt.Println("the ports again.")
				return 1
			}
			sent := after.WireTx - before.WireTx
			got := after.WireRx - before.WireRx
			fmt.Printf("\nDuring this test we sent %s and the other server sent back %s.\n",
				humanBytes(sent), humanBytes(got))
			if got == 0 {
				fmt.Println("\nNot one byte came back - no data, no window credit, no")
				fmt.Println("keepalive. The carriers all report themselves up, so the")
				fmt.Println("handshake crossed in both directions and then the return")
				fmt.Println("direction stopped.")
				fmt.Println("\nThat is not a service failing to answer: a service that is")
				fmt.Println("simply silent still leaves the keepalives flowing. Something")
				fmt.Println("between the two servers is carrying this direction and not")
				fmt.Println("the other.")
				fmt.Println("\nAn \"open\" above means only that no refusal arrived, which")
				fmt.Println("is also what a one-way path looks like.")
				return probeOneWay
			}
		}
	}

	if bad > 0 {
		fmt.Println("\nA port that failed is one the other server could not reach.")
		fmt.Println("Check that the service is listening there on the address after")
		fmt.Println("the arrow, and read that server's log for the reason.")
		return probeFailed
	}
	fmt.Println("\nEvery port reached the service on the other server.")
	return probeOK
}

// refusalCount reads how many times the far end has said it could not reach a
// target. Zero when there is no status endpoint to ask, which only costs the
// probe its ability to tell two failures apart.
func refusalCount(addr string) (uint64, bool) {
	if addr == "" {
		return 0, false
	}
	d, err := fetchStatus(addr)
	if err != nil {
		return 0, false
	}
	return d.Refusals, true
}

func probeOne(r fwdRule, statusAddr string) bool {
	label := fmt.Sprintf(":%d -> %s", r.lport, r.target)
	c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", r.lport), 5*time.Second)
	if err != nil {
		// These two look alike and mean opposite things. Refused is an empty
		// port: the tunnel is not listening. A timeout on loopback is not -
		// the kernel answers its own sockets instantly - so something between
		// the dial and the socket swallowed it, and on this tool that is
		// almost always a leftover DNAT rule from an iptables tunnel.
		var ne net.Error
		if errors.As(err, &ne) && ne.Timeout() {
			fmt.Printf("  %-30s no answer on loopback - something is intercepting this port\n", label)
			fmt.Printf("  %-30s   check:  iptables -t nat -S\n", "")
			return false
		}
		fmt.Printf("  %-30s nothing listening on this server: %v\n", label, err)
		return false
	}
	defer c.Close()

	// Counted before the write, so anything the far end refuses during this
	// one exchange shows up as an increase.
	refusedBefore, canAsk := refusalCount(statusAddr)

	// One harmless line, purely so the stream carries a byte and gives the far
	// side a reason either to answer or to hang up.
	c.SetDeadline(time.Now().Add(6 * time.Second))
	if _, err := c.Write([]byte("\r\n")); err != nil {
		fmt.Printf("  %-30s the other server refused it: %v\n", label, err)
		return false
	}

	buf := make([]byte, 256)
	n, err := c.Read(buf)
	if n > 0 {
		fmt.Printf("  %-30s open, and the service answered %d bytes\n", label, n)
		return true
	}
	if err == nil {
		fmt.Printf("  %-30s open\n", label)
		return true
	}

	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		// Held open for six seconds without a word. Plenty of services say
		// nothing until spoken to properly - the path is what was on trial.
		fmt.Printf("  %-30s open, service silent (normal for xray and the like)\n", label)
		return true
	}
	// Here is where this used to blame the wrong machine. The connection
	// ended, and there are two ways that happens: the far end had nothing
	// to connect to, or the far end connected fine and the service there
	// took one look at a bare CRLF, decided it was not the protocol it
	// speaks, and hung up. Xray, and most proxies worth tunnelling, do
	// exactly the second thing - so a healthy tunnel carrying a working
	// service reported a failed port.
	//
	// Both arrive here as a closed socket, and nothing about the socket
	// tells them apart. The far end does know: when it cannot reach a
	// target it sends a reset carrying the reason, and the tunnel counts
	// those. So ask whether one arrived while we were waiting.
	// With no endpoint to ask, or one that will not answer, there is nothing
	// to go on and the old pessimistic reading stands.
	refusedAfter, asked := refusalCount(statusAddr)
	if !canAsk || !asked || refusedAfter > refusedBefore {
		fmt.Printf("  %-30s the other server could not reach it (%v)\n", label, err)
		return false
	}
	fmt.Printf("  %-30s open, the service closed it (normal for xray and the like)\n", label)
	return true
}

// carrierRestarted reports whether any carrier went away and came back while
// the probe was running. A carrier's uptime only ever grows; a smaller number
// than before means that index is a different connection now, and every stream
// that was riding on the old one was reset when it closed.
func carrierRestarted(before, after *statusDoc) bool {
	if after.Up < before.Up {
		return true
	}
	was := make(map[int]int64, len(before.Detail))
	for _, c := range before.Detail {
		if c.Up {
			was[c.Index] = c.UptimeS
		}
	}
	for _, c := range after.Detail {
		if old, seen := was[c.Index]; seen && c.UptimeS < old {
			return true
		}
	}
	return false
}
