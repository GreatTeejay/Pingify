package main

import (
	"fmt"
	"testing"
	"time"
)

// bringPair wires an IRAN end (listens for carriers, owns the ports) to a
// KHAREJ end (dials), the way the two servers are actually wired, and waits
// for the carriers. It returns the IRAN config, which is what runProbe reads.
func bringPair(t *testing.T, forwards []string) *Config {
	t.Helper()
	port := freePort(t)

	iran := &Config{
		Role: "server", Mode: "forward",
		Listen:   fmt.Sprintf("127.0.0.1:%d", port),
		BindAddr: "127.0.0.1",
		Carriers: 2,
		Forwards: forwards,
	}
	kharej := &Config{
		Role: "client", Mode: "forward",
		Connect:  fmt.Sprintf("127.0.0.1:%d", port),
		Carriers: 2,
	}
	for _, c := range []*Config{iran, kharej} {
		c.applyDefaults()
		if err := c.validate(); err != nil {
			t.Fatal(err)
		}
	}
	ip := newPool(iran)
	if err := ip.start(); err != nil {
		t.Fatal(err)
	}
	ifw, err := startForward(iran, ip)
	if err != nil {
		t.Fatal(err)
	}
	kp := newPool(kharej)
	if err := kp.start(); err != nil {
		t.Fatal(err)
	}
	kf, err := startForward(kharej, kp)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ifw.Close(); kf.Close(); kp.close(); ip.close() })

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if up, _, _, _ := ip.stats(); up >= 2 {
			return iran
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("carriers never came up")
	return nil
}

// The probe has to tell a path that reaches the service apart from one that
// does not. Connecting proves neither: the near server accepts before it has
// spoken to the tunnel at all, which is exactly why a plain connection test
// sent a real tunnel's owner hunting in the wrong place.
func TestProbeSeparatesAReachableServiceFromADeadOne(t *testing.T) {
	setLogLevel("error")

	t.Run("service is up", func(t *testing.T) {
		echo := echoServer(t)
		local := freePort(t)
		cfg := bringPair(t, []string{fmt.Sprintf("%d=%d", local, echo)})
		if got := runProbe(cfg); got != 0 {
			t.Errorf("probe returned %d for a reachable service, want 0", got)
		}
	})

	t.Run("service is down", func(t *testing.T) {
		dead := freePort(t) // nothing ever listens here
		local := freePort(t)
		cfg := bringPair(t, []string{fmt.Sprintf("%d=%d", local, dead)})
		if got := runProbe(cfg); got != 1 {
			t.Errorf("probe returned %d for an unreachable service, want 1", got)
		}
	})

	t.Run("run on the wrong server", func(t *testing.T) {
		cfg := &Config{Role: "client", Mode: "forward"}
		if got := runProbe(cfg); got != 2 {
			t.Errorf("probe returned %d on the KHAREJ end, want 2", got)
		}
	})
}

// A carrier dying under a probe resets its streams, and the near end sees EOF -
// the same thing it sees when the far end refuses. Blaming the far server for
// that sent a real investigation to the wrong machine for a day.
func TestCarrierRestartIsNotBlamedOnTheFarServer(t *testing.T) {
	up := func(idx int, uptime int64) carrierStatus {
		return carrierStatus{Index: idx, Up: true, UptimeS: uptime}
	}
	steady := &statusDoc{Up: 2, Detail: []carrierStatus{up(0, 30), up(1, 30)}}

	if carrierRestarted(steady, &statusDoc{Up: 2, Detail: []carrierStatus{up(0, 36), up(1, 36)}}) {
		t.Error("carriers that only got older were called a restart")
	}
	if !carrierRestarted(steady, &statusDoc{Up: 2, Detail: []carrierStatus{up(0, 2), up(1, 36)}}) {
		t.Error("carrier 0 went from 30s of uptime to 2s and that was not noticed")
	}
	if !carrierRestarted(steady, &statusDoc{Up: 1, Detail: []carrierStatus{up(0, 36)}}) {
		t.Error("losing a carrier outright was not noticed")
	}
}
