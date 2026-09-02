package forward

import (
	"bytes"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"pingify/internal/buf"
	"pingify/internal/carrier"
	"pingify/internal/config"
)

// Two carriers joined back to back in memory: what one sends, the other
// receives, in order, on a goroutine of its own - which is what a stream
// carrier does across a wire.
type pipeCarrier struct {
	head int
	peer *pipeCarrier
	on   atomic.Pointer[func([]byte)]
	q    chan []byte
	sent uint64
}

func pipePair() (*pipeCarrier, *pipeCarrier) {
	a := &pipeCarrier{head: 12, q: make(chan []byte, 4096)}
	b := &pipeCarrier{head: 12, q: make(chan []byte, 4096)}
	a.peer, b.peer = b, a
	go a.run()
	go b.run()
	return a, b
}

func (p *pipeCarrier) run() {
	for b := range p.q {
		if f := p.on.Load(); f != nil {
			(*f)(b)
		}
	}
}

func (p *pipeCarrier) Headroom() int                    { return p.head }
func (p *pipeCarrier) MaxPayload() int                  { return 1400 }
func (p *pipeCarrier) Burst() int                       { return 1 }
func (p *pipeCarrier) Up() bool                         { return true }
func (p *pipeCarrier) Close() error                     { return nil }
func (p *pipeCarrier) Run()                             {}
func (p *pipeCarrier) Keepalive(time.Duration)          {}
func (p *pipeCarrier) Counters() (a, b, c, d, e uint64) { return }
func (p *pipeCarrier) Lost() (a, b, c uint64)           { return }
func (p *pipeCarrier) OnPacket(f func([]byte))          { p.on.Store(&f) }
func (p *pipeCarrier) NewSender() carrier.Sender        { return carrierSender{p} }

type carrierSender struct{ p *pipeCarrier }

func (s carrierSender) Send(bps []*[]byte) {
	for _, bp := range bps {
		_ = s.p.Send(bp)
	}
}

func (p *pipeCarrier) Send(bp *[]byte) error {
	b := (*bp)[p.head:]
	c := make([]byte, len(b))
	copy(c, b)
	buf.Put(bp)
	atomic.AddUint64(&p.sent, 1)
	p.peer.q <- c
	return nil
}

func (p *pipeCarrier) SendFlow(_ uint32, bp *[]byte) error { return p.Send(bp) }

func pair(t *testing.T, ports []string) (*Forwarder, *Forwarder) {
	t.Helper()
	ca, cb := pipePair()
	edge := &config.Config{Side: config.SideIran}
	edge.Transport.Type = "tcp"
	edge.Forward.Ports = ports
	edge.Forward.BindAddr = "127.0.0.1"
	origin := &config.Config{Side: config.SideKharej}
	origin.Transport.Type = "tcp"
	e, err := New(edge, ca)
	if err != nil {
		t.Fatal(err)
	}
	o, err := New(origin, cb)
	if err != nil {
		t.Fatal(err)
	}
	if err := e.Start(); err != nil {
		t.Fatal(err)
	}
	if err := o.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { e.Close(); o.Close() })
	return e, o
}

// A real service on the far side, a real user on the near side, and every
// byte through the tunnel in both directions.
func TestATCPConnectionCrossesAndComesBack(t *testing.T) {
	svc, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer svc.Close()
	go func() {
		for {
			c, err := svc.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				// Echo, uppercased, so the reply is provably the far end's.
				b := make([]byte, 4096)
				for {
					n, err := c.Read(b)
					if n > 0 {
						_, _ = c.Write(bytes.ToUpper(b[:n]))
					}
					if err != nil {
						return
					}
				}
			}()
		}
	}()
	_, svcPort, _ := net.SplitHostPort(svc.Addr().String())

	userPort := freePort(t)
	pair(t, []string{userPort + "=127.0.0.1:" + svcPort})

	c, err := net.DialTimeout("tcp", "127.0.0.1:"+userPort, 3*time.Second)
	if err != nil {
		t.Fatalf("the forwarded port does not answer: %v", err)
	}
	defer c.Close()
	msg := bytes.Repeat([]byte("the quick brown fox "), 50000) // a megabyte, past the window
	go func() {
		_, _ = c.Write(msg)
		_ = c.(*net.TCPConn).CloseWrite()
	}()
	_ = c.SetReadDeadline(time.Now().Add(20 * time.Second))
	got, err := io.ReadAll(c)
	if err != nil {
		t.Fatalf("reading the reply: %v after %d bytes", err, len(got))
	}
	if !bytes.Equal(got, bytes.ToUpper(msg)) {
		t.Fatalf("got %d bytes back, wanted %d, and they differ", len(got), len(msg))
	}
}

// A receive-only service - one that reads the upload and never sends a byte
// back, half-closing its own write side at once, which is what socat -u and
// many sinks do. The upload must still cross in full: the far end saying "I
// have nothing to send you" is not the far end saying "stop sending to me".
func TestAnUploadSurvivesTheServiceHalfClosing(t *testing.T) {
	svc, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer svc.Close()
	got := make(chan int, 1)
	go func() {
		c, err := svc.Accept()
		if err != nil {
			return
		}
		_ = c.(*net.TCPConn).CloseWrite() // "I will send you nothing" - up front
		n := 0
		b := make([]byte, 65536)
		for {
			m, err := c.Read(b)
			n += m
			if err != nil {
				break
			}
		}
		_ = c.Close()
		got <- n
	}()
	_, svcPort, _ := net.SplitHostPort(svc.Addr().String())
	userPort := freePort(t)
	pair(t, []string{userPort + "=127.0.0.1:" + svcPort})

	c, err := net.DialTimeout("tcp", "127.0.0.1:"+userPort, 3*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	msg := bytes.Repeat([]byte("upload me "), 200000) // 2 MB, well past the window
	go func() {
		_, _ = c.Write(msg)
		_ = c.(*net.TCPConn).CloseWrite()
	}()
	select {
	case n := <-got:
		if n != len(msg) {
			t.Fatalf("the service received %d bytes of %d", n, len(msg))
		}
	case <-time.After(20 * time.Second):
		t.Fatal("the upload never finished - the service half-closing killed it")
	}
	_ = c.Close()
}

// A target the origin will not dial ends the stream cleanly at the edge - the
// user sees the connection close, not hang.
func TestARefusedTargetClosesTheUsersConnection(t *testing.T) {
	userPort := freePort(t)
	pair(t, []string{userPort + "=127.0.0.1:1"}) // nothing listens on port 1
	c, err := net.DialTimeout("tcp", "127.0.0.1:"+userPort, 3*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_ = c.SetReadDeadline(time.Now().Add(15 * time.Second))
	if _, err := c.Read(make([]byte, 1)); err == nil {
		t.Fatal("the connection stayed open with nothing behind it")
	}
}

// UDP: one datagram in, its answer out, through a session the tunnel keeps.
func TestAUDPDatagramCrossesAndComesBack(t *testing.T) {
	svc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer svc.Close()
	go func() {
		b := make([]byte, 2048)
		for {
			n, from, err := svc.ReadFrom(b)
			if err != nil {
				return
			}
			_, _ = svc.WriteTo(append([]byte("echo:"), b[:n]...), from)
		}
	}()
	_, svcPort, _ := net.SplitHostPort(svc.LocalAddr().String())
	userPort := freePort(t)
	pair(t, []string{"udp:" + userPort + "=127.0.0.1:" + svcPort})

	u, err := net.Dial("udp", "127.0.0.1:"+userPort)
	if err != nil {
		t.Fatal(err)
	}
	defer u.Close()
	for i := 0; i < 3; i++ {
		if _, err := u.Write([]byte("ping")); err != nil {
			t.Fatal(err)
		}
		_ = u.SetReadDeadline(time.Now().Add(5 * time.Second))
		b := make([]byte, 64)
		n, err := u.Read(b)
		if err != nil {
			t.Fatalf("datagram %d: no answer: %v", i, err)
		}
		if string(b[:n]) != "echo:ping" {
			t.Fatalf("datagram %d: got %q", i, b[:n])
		}
	}
}

// Rules are the Ports screen's spelling, and every form of it has to parse
// to what it says.
func TestRulesSayWhatTheyMean(t *testing.T) {
	cases := map[string][]Rule{
		"443":                {{"tcp", 443, "127.0.0.1:443"}},
		"udp:500":            {{"udp", 500, "127.0.0.1:500"}},
		"443=8443":           {{"tcp", 443, "127.0.0.1:8443"}},
		"443=10.99.10.5:443": {{"tcp", 443, "10.99.10.5:443"}},
		"8000-8002":          {{"tcp", 8000, "127.0.0.1:8000"}, {"tcp", 8001, "127.0.0.1:8001"}, {"tcp", 8002, "127.0.0.1:8002"}},
		"8000-8001=9000":     {{"tcp", 8000, "127.0.0.1:9000"}, {"tcp", 8001, "127.0.0.1:9001"}},
	}
	for spec, want := range cases {
		got, err := Parse(spec)
		if err != nil {
			t.Errorf("%q: %v", spec, err)
			continue
		}
		if len(got) != len(want) {
			t.Errorf("%q: %d rules, wanted %d", spec, len(got), len(want))
			continue
		}
		for i := range want {
			if got[i] != want[i] {
				t.Errorf("%q: rule %d is %+v, wanted %+v", spec, i, got[i], want[i])
			}
		}
	}
	for _, bad := range []string{"", "0", "70000", "80-70", "1-9999", "443=", "443=:x:y", "sctp:9"} {
		if _, err := Parse(bad); err == nil {
			t.Errorf("%q was accepted", bad)
		}
	}
}

func freePort(t *testing.T) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	_, p, _ := net.SplitHostPort(l.Addr().String())
	_ = l.Close()
	return p
}

var _ = sync.Mutex{}
