package main

import (
	"fmt"
	"io"
	"net"
	"testing"
	"time"
)

// bringPair wires an IRAN end (listens for carriers, owns the ports) to a
// KHAREJ end (dials), the way the two servers are actually wired, and waits
// for the carriers. It returns the IRAN config, which is what runProbe reads.
func bringPair(t *testing.T, forwards []string) *Config {
	t.Helper()
	psk := testPSK(t)
	port := freePort(t)

	// A status endpoint, because the probe needs one to tell a far end that
	// refused a connection from a service that accepted and hung up.
	statusPort := freePort(t)
	iran := &Config{
		Role: "server", Mode: "forward",
		Listen: fmt.Sprintf("127.0.0.1:%d", port),
		Token:  psk, Carriers: 2, Forwards: forwards, BindAddr: "127.0.0.1",
		StatusAddr: fmt.Sprintf("127.0.0.1:%d", statusPort),
	}
	kharej := &Config{
		Role: "client", Mode: "forward",
		Connect: fmt.Sprintf("127.0.0.1:%d", port),
		Token:   psk, Carriers: 2,
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
	startStatusServer(iran.StatusAddr, iran, ip)
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

// A proxy that hangs up on a probe is a working proxy. Xray, and most things
// worth putting in a tunnel, close a connection the instant it does not speak
// their protocol - and a bare CRLF does not. The probe used to read that close
// as "the other server could not reach it" and report a failed port on a
// tunnel that was carrying real traffic perfectly well, which sent its owner
// looking for a fault on the far server that was not there.
//
// The two ends of that ambiguity are only distinguishable by asking the far
// side, which says so when it cannot reach a target and says nothing when the
// service itself hung up.
func TestAServiceThatHangsUpIsReportedReachable(t *testing.T) {
	setLogLevel("error")

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			c.Close() // "that is not my protocol"
		}
	}()
	hangup := ln.Addr().(*net.TCPAddr).Port

	local := freePort(t)
	cfg := bringPair(t, []string{fmt.Sprintf("%d=%d", local, hangup)})
	if got := runProbe(cfg); got != 0 {
		t.Errorf("probe returned %d for a service that accepted and closed, want 0", got)
	}
}

// And the counter it relies on has to actually move when the far end refuses,
// or the check above would call every failure healthy.
func TestARefusalIsCounted(t *testing.T) {
	setLogLevel("error")
	dead := freePort(t) // nothing ever listens here
	local := freePort(t)
	cfg := bringPair(t, []string{fmt.Sprintf("%d=%d", local, dead)})

	before, ok := refusalCount(cfg.StatusAddr)
	if !ok {
		t.Fatal("the status endpoint would not answer")
	}
	c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", local), 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	c.Write([]byte("\r\n"))
	c.SetDeadline(time.Now().Add(5 * time.Second))
	io.Copy(io.Discard, c)
	c.Close()

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if after, _ := refusalCount(cfg.StatusAddr); after > before {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Error("the far end could not reach the target and nothing counted the refusal")
}
