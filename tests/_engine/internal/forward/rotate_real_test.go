package forward

import (
	"bytes"
	"io"
	"net"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"pingify/internal/carrier"
	"pingify/internal/config"
)

// countingProxy passes TCP connections through to target and counts them: the
// connections a dialling carrier makes, renewals included.
func countingProxy(t *testing.T, target string) (addr string, made *atomic.Int32) {
	t.Helper()
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	made = &atomic.Int32{}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			s, err := net.Dial("tcp4", target)
			if err != nil {
				c.Close()
				continue
			}
			made.Add(1)
			go func() { io.Copy(s, c); s.Close(); c.Close() }()
			go func() { io.Copy(c, s); s.Close(); c.Close() }()
		}
	}()
	return ln.Addr().String(), made
}

// realEnd is one end of a forward tunnel on a real TCP carrier, from a file
// as the core would read it.
func realEnd(t *testing.T, doc string, rotateSec int) (*Forwarder, carrier.Full) {
	t.Helper()
	p := filepath.Join(t.TempDir(), "t.toml")
	if err := os.WriteFile(p, []byte(doc), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := config.Load(p)
	if err != nil {
		t.Fatal(err)
	}
	// Seconds rather than minutes, which the file itself would refuse.
	cfg.Transport.RotateSec = rotateSec
	car, err := carrier.Open(cfg)
	if err != nil {
		t.Fatal(err)
	}
	f, err := New(cfg, car)
	if err != nil {
		t.Fatal(err)
	}
	f.pingGap = 50 * time.Millisecond // the hellos cross at once
	if err := f.Start(); err != nil {
		t.Fatal(err)
	}
	go car.Run()
	t.Cleanup(func() { f.Close(); car.Close() })
	return f, car
}

// Connections renewed every second or so under a transfer both ways, on real
// TCP: every byte arrives, once, in order. The renewal closes a connection
// with bytes in flight on it, and those are what the streams riding it carry
// on from - so this is the renewal and the resume together.
func TestStreamsCrossConnectionsThatAreRenewedUnderThem(t *testing.T) {
	port, _ := echoService(t)
	carrierPort := freePort(t)
	userPort := freePort(t)
	proxy, made := countingProxy(t, "127.0.0.1:"+carrierPort)
	_, proxyPort, _ := net.SplitHostPort(proxy)

	common := `
[transport]
type = "tcp"
connections = 4
dials = "kharej"
keepalive_sec = 10
kharej = "127.0.0.1"
`
	realEnd(t, `
[tunnel]
side = "iran"
mode = "forward"`+common+`
iran = "127.0.0.1"
port = `+carrierPort+`
[security]
token = "renewals under a transfer"
[forward]
ports = ["`+userPort+`=127.0.0.1:`+port+`"]
bind_addr = "127.0.0.1"
[status]
port = 0
health_port = -1
`, 0)
	realEnd(t, `
[tunnel]
side = "kharej"
mode = "forward"`+common+`
iran = "127.0.0.1"
port = `+proxyPort+`
[security]
token = "renewals under a transfer"
[status]
port = 0
health_port = -1
`, 1)

	var user net.Conn
	waitForT(t, "the tunnel up", 5*time.Second, func() bool {
		c, err := net.Dial("tcp", "127.0.0.1:"+userPort)
		if err != nil {
			return false
		}
		_ = c.SetDeadline(time.Now().Add(time.Second))
		if _, err := c.Write([]byte("x")); err != nil {
			c.Close()
			return false
		}
		b := make([]byte, 1)
		if _, err := io.ReadFull(c, b); err != nil {
			c.Close()
			return false
		}
		_ = c.SetDeadline(time.Time{})
		user = c
		return true
	})
	defer user.Close()
	time.Sleep(200 * time.Millisecond) // past the first hellos
	before := made.Load()

	// Eight megabytes each way over about four seconds, paced so the
	// transfer outlives several renewals of every connection.
	const total = 8 << 20
	want := make([]byte, total)
	for i := range want {
		want[i] = byte(i*7 + i/1000)
	}
	errs := make(chan error, 1)
	go func() {
		for off := 0; off < total; off += 16 << 10 {
			if _, err := user.Write(want[off : off+16<<10]); err != nil {
				errs <- err
				return
			}
			time.Sleep(8 * time.Millisecond)
		}
		errs <- nil
	}()
	_ = user.SetReadDeadline(time.Now().Add(30 * time.Second))
	got := make([]byte, total)
	if _, err := io.ReadFull(user, got); err != nil {
		t.Fatalf("the echo stopped after renewals: %v (connections made %d)", err, made.Load())
	}
	if err := <-errs; err != nil {
		t.Fatalf("the write failed: %v", err)
	}
	if !bytes.Equal(got, want) {
		for i := range got {
			if got[i] != want[i] {
				t.Fatalf("byte %d of %d is wrong: a renewal lost or repeated something", i, total)
			}
		}
	}
	if renewed := made.Load() - before; renewed < 4 {
		t.Fatalf("only %d connections were renewed during the transfer; the test proves nothing", renewed)
	}
}

// waitForT polls until ok or the time runs out.
func waitForT(t *testing.T, what string, within time.Duration, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(within)
	for time.Now().Before(deadline) {
		if ok() {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}
