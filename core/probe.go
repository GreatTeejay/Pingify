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
func runProbe(cfg *Config) int {
	if cfg.Role != "server" {
		fmt.Println("Run this on the IRAN server: that is the end with the ports.")
		return 2
	}
	if cfg.StatusAddr != "" {
		d, err := fetchStatus(cfg.StatusAddr)
		if err != nil {
			fmt.Printf("No carrier is up (%v). Nothing can cross the tunnel yet.\n", err)
			return 1
		}
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
			if !probeOne(r) {
				bad++
			}
		}
	}
	if bad > 0 {
		fmt.Println("\nA port that failed is one the other server could not reach.")
		fmt.Println("Check that the service is listening there on the address after")
		fmt.Println("the arrow, and read that server's log for the reason.")
		return 1
	}
	fmt.Println("\nEvery port reached the service on the other server.")
	return 0
}

func probeOne(r fwdRule) bool {
	label := fmt.Sprintf(":%d -> %s", r.lport, r.target)
	c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", r.lport), 5*time.Second)
	if err != nil {
		fmt.Printf("  %-30s nothing listening on this server: %v\n", label, err)
		return false
	}
	defer c.Close()

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
	fmt.Printf("  %-30s the other server could not reach it (%v)\n", label, err)
	return false
}
