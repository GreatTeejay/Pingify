package forward

import (
	"bytes"
	"encoding/binary"
	"io"
	"net"
	"strconv"
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
	head       int
	peer       *pipeCarrier
	on         atomic.Pointer[func([]byte)]
	q          chan []byte
	sent       uint64
	down       atomic.Bool  // the carrier away, as a test sees fit
	lose       atomic.Bool  // and swallowing what is handed to it, as one does
	lost       uint64       // how many records that swallowed
	dropOver   atomic.Int64 // a filter: a record longer than this vanishes
	slots      int          // carrier connections, as the forwarder counts them
	stalled    [64]atomic.Bool
	bigFlow    atomic.Int64 // 1 + the flow of the last record over dropOver
	onLinkDown atomic.Pointer[func(int)]
}

// cut is a connection dying the way a real one does: what was handed over and
// not yet delivered is gone, and then both ends are told the connection ended.
func (p *pipeCarrier) cut(slot int, d time.Duration) {
	p.lose.Store(true)
	p.peer.lose.Store(true)
	time.Sleep(d)
	p.lose.Store(false)
	p.peer.lose.Store(false)
	if f := p.onLinkDown.Load(); f != nil {
		(*f)(slot)
	}
	if f := p.peer.onLinkDown.Load(); f != nil {
		(*f)(slot)
	}
}

func (p *pipeCarrier) OnLinkDown(f func(int)) { p.onLinkDown.Store(&f) }

func pipePair() (*pipeCarrier, *pipeCarrier) { return pipePairQ(4096) }

// pipePairQ is the same with a chosen depth. The depth is how much the wire
// holds: a test about what is lost when a connection dies wants that to be a
// real path's worth and not five megabytes of free buffer, or the sender runs
// so far ahead of the far end that nothing could insure it.
func pipePairQ(depth int) (*pipeCarrier, *pipeCarrier) {
	a := &pipeCarrier{head: 12, q: make(chan []byte, depth)}
	b := &pipeCarrier{head: 12, q: make(chan []byte, depth)}
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
func (p *pipeCarrier) Up() bool                         { return !p.down.Load() }
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
	if p.lose.Load() {
		// A socket whose route has stopped answering does not swallow at
		// infinite speed: its buffer fills and the writer waits. Waiting is
		// the part that matters - without it the sender races a whole
		// transfer into a connection that is already dead, which no amount
		// of holding could insure and no real path would allow.
		for p.lose.Load() {
			time.Sleep(time.Millisecond)
		}
		atomic.AddUint64(&p.lost, 1)
		return nil // taken by the kernel, and lost with the socket
	}
	atomic.AddUint64(&p.sent, 1)
	p.peer.q <- c
	return nil
}

func (p *pipeCarrier) SendFlow(flow uint32, bp *[]byte) error {
	if p.down.Load() {
		buf.Put(bp)
		return carrier.ErrNoPeer
	}
	if d := p.dropOver.Load(); d > 0 {
		slot := 0
		if p.slots > 1 {
			slot = int(flow % uint32(p.slots))
		}
		n := int64(len(*bp) - p.head)
		if n > d {
			p.bigFlow.Store(int64(flow) + 1)
		}
		// Every stream carrier delivers in order. Once a record on a
		// connection is stopped, nothing queued behind it on that
		// connection arrives either, whatever its size - which is what the
		// first version of this filter left out, and with it the one bug
		// that mattered: a probe sharing the heartbeat's connection.
		if n > d || p.stalled[slot].Load() {
			p.stalled[slot].Store(true)
			buf.Put(bp)
			atomic.AddUint64(&p.lost, 1)
			return nil
		}
	}
	return p.Send(bp)
}

// pairConns is a pair on n carrier connections, which is what the probe
// needs: it rides a connection other than the heartbeat's.
func pairConns(t *testing.T, n int, opts ...func(*Forwarder)) (*Forwarder, *Forwarder) {
	t.Helper()
	ca, cb := pipePairQ(4096)
	ca.slots, cb.slots = n, n
	edge := &config.Config{Side: config.SideIran}
	edge.Transport.Type = "tcp"
	edge.Transport.Connections = n
	edge.Forward.BindAddr = "127.0.0.1"
	origin := &config.Config{Side: config.SideKharej}
	origin.Transport.Type = "tcp"
	origin.Transport.Connections = n
	e, err := New(edge, ca)
	if err != nil {
		t.Fatal(err)
	}
	o, err := New(origin, cb)
	if err != nil {
		t.Fatal(err)
	}
	for _, opt := range opts {
		opt(e)
		opt(o)
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

func pair(t *testing.T, ports []string, opts ...func(*Forwarder)) (*Forwarder, *Forwarder) {
	t.Helper()
	return pairQ(t, ports, 4096, opts...)
}

func pairQ(t *testing.T, ports []string, depth int, opts ...func(*Forwarder)) (*Forwarder, *Forwarder) {
	t.Helper()
	ca, cb := pipePairQ(depth)
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
	for _, opt := range opts {
		opt(e)
		opt(o)
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

// A carrier that goes away and comes back within the grace loses nothing:
// the writer waits in front of it, the pumps wait behind the writer, and the
// user's program waits behind the pumps.
func TestACarrierThatComesBackLosesNothing(t *testing.T) {
	svc, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer svc.Close()
	var got bytes.Buffer
	var done = make(chan struct{})
	go func() {
		c, err := svc.Accept()
		if err != nil {
			return
		}
		io.Copy(&got, c)
		c.Close()
		close(done)
	}()
	port := svc.Addr().(*net.TCPAddr).Port
	userPort := freePort(t)
	e, _ := pair(t, []string{userPort + "=127.0.0.1:" + itoa(port)})
	ca := e.car.(*pipeCarrier)

	user, err := net.Dial("tcp", "127.0.0.1:"+userPort)
	if err != nil {
		t.Fatal(err)
	}
	payload := bytes.Repeat([]byte("the carrier went away and came back "), 60000) // ~2 MB
	ca.down.Store(true)
	go func() {
		time.Sleep(400 * time.Millisecond)
		ca.down.Store(false)
	}()
	if _, err := user.Write(payload); err != nil {
		t.Fatalf("the user's write failed while the carrier was merely away: %v", err)
	}
	user.Close()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("the far end never saw the end of the stream")
	}
	if !bytes.Equal(got.Bytes(), payload) {
		t.Fatalf("the far end got %d bytes of %d, and not the same ones", got.Len(), len(payload))
	}
}

// A carrier away past the grace resets the user's connection, so the program
// behind it learns at once instead of waiting on a stream that will never
// move again.
func TestACarrierAwayTooLongResetsTheConnection(t *testing.T) {
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
			go io.Copy(io.Discard, c)
		}
	}()
	port := svc.Addr().(*net.TCPAddr).Port
	userPort := freePort(t)
	e, _ := pair(t, []string{userPort + "=127.0.0.1:" + itoa(port)},
		func(f *Forwarder) { f.grace = 300 * time.Millisecond })
	ca := e.car.(*pipeCarrier)

	user, err := net.Dial("tcp", "127.0.0.1:"+userPort)
	if err != nil {
		t.Fatal(err)
	}
	defer user.Close()
	// One record through first, so the stream exists on both ends and its
	// records are what the writer holds when the carrier goes.
	if _, err := user.Write([]byte("hello")); err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond)
	ca.down.Store(true)
	chunk := bytes.Repeat([]byte("x"), 64*1024)
	deadline := time.Now().Add(5 * time.Second)
	_ = user.SetDeadline(deadline)
	var werr error
	for time.Now().Before(deadline) {
		if _, werr = user.Write(chunk); werr != nil {
			break
		}
	}
	if werr == nil {
		t.Fatal("the user's connection was never reset; its writes were accepted for five seconds into a carrier that was not there")
	}
}

// Data for a stream this end has never heard of gets a reset back, so the
// far end's program stops writing into nothing.
func TestDataForAStreamNobodyHasIsRefused(t *testing.T) {
	e, o := pair(t, nil)
	_ = o
	ca := e.car.(*pipeCarrier)
	cb := ca.peer
	saw := make(chan struct{}, 1)
	prev := cb.on.Load()
	cb.OnPacket(func(b []byte) {
		if len(b) >= hdrLen && b[0] == cmdRST && binary.BigEndian.Uint32(b[1:5]) == 4242 {
			select {
			case saw <- struct{}{}:
			default:
			}
		}
		(*prev)(b)
	})
	// A data record for stream 4242, which the edge has no record of. Its
	// body begins with the offset every data record carries.
	rec := make([]byte, hdrLen+offLen+5)
	rec[0] = cmdData
	binary.BigEndian.PutUint32(rec[1:5], 4242)
	binary.BigEndian.PutUint64(rec[hdrLen:hdrLen+offLen], 0)
	copy(rec[hdrLen+offLen:], "hello")
	ca.q <- rec
	select {
	case <-saw:
	case <-time.After(3 * time.Second):
		t.Fatal("no reset came back for a stream nobody has")
	}
}

func itoa(n int) string { return strconv.Itoa(n) }

// A stream the far end has never acknowledged is one that may be talking to an
// older build, which would take a resent record as a new one. That stream is
// still reset when its connection dies, because carrying it on could corrupt
// it - and a reset the program can see beats bytes it cannot trust.
func TestAStreamNobodyAcknowledgedIsStillReset(t *testing.T) {
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
			go io.Copy(io.Discard, c)
		}
	}()
	port := svc.Addr().(*net.TCPAddr).Port
	userPort := freePort(t)
	e, _ := pair(t, []string{userPort + "=127.0.0.1:" + itoa(port)})
	ca := e.car.(*pipeCarrier)

	user, err := net.Dial("tcp", "127.0.0.1:"+userPort)
	if err != nil {
		t.Fatal(err)
	}
	defer user.Close()
	if _, err := user.Write([]byte("hello")); err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond)

	// Silence every acknowledgement, as a build that does not send them
	// would, and take away what this end is holding.
	e.mu.Lock()
	for _, s := range e.streams {
		s.out.mu.Lock()
		s.out.seen = false
		s.out.gap = true
		s.out.mu.Unlock()
	}
	e.mu.Unlock()

	(*ca.onLinkDown.Load())(0)

	_ = user.SetDeadline(time.Now().Add(3 * time.Second))
	b := make([]byte, 1)
	if _, err := user.Read(b); err == nil {
		t.Fatal("the user's connection is still open after the carrier connection under it ended")
	} else if ne, ok := err.(net.Error); ok && ne.Timeout() {
		t.Fatal("the user's connection was left waiting, not reset")
	}
}

// A carrier connection that dies mid-transfer used to take every stream on it
// with it. Now the stream moves to whatever is alive and carries on from the
// last byte the far end acknowledged - so what arrives is what was sent, once
// each and in order, across a cut that really did lose records in flight.
func TestAStreamOutlivesTheConnectionItWasRiding(t *testing.T) {
	const total = 16 << 20

	started := make(chan struct{})
	got := make(chan []byte, 1)
	svc, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer svc.Close()
	go func() {
		c, err := svc.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		var all []byte
		b := make([]byte, 32<<10)
		once := sync.Once{}
		for {
			n, err := c.Read(b)
			if n > 0 {
				all = append(all, b[:n]...)
				if len(all) > 2<<20 {
					once.Do(func() { close(started) })
				}
			}
			if err != nil {
				break
			}
		}
		got <- all
	}()

	port := svc.Addr().(*net.TCPAddr).Port
	userPort := freePort(t)
	e, _ := pairQ(t, []string{userPort + "=127.0.0.1:" + itoa(port)}, 128)
	ca := e.car.(*pipeCarrier)

	user, err := net.Dial("tcp", "127.0.0.1:"+userPort)
	if err != nil {
		t.Fatal(err)
	}
	want := make([]byte, total)
	for i := range want {
		want[i] = byte(i % 251)
	}

	go func() {
		select {
		case <-started:
		case <-time.After(10 * time.Second):
		}
		ca.cut(0, 30*time.Millisecond)
	}()

	done := make(chan error, 1)
	go func() {
		_, err := user.Write(want)
		if cw, ok := user.(*net.TCPConn); ok {
			_ = cw.CloseWrite()
		}
		done <- err
	}()

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("the user's write failed across the cut: %v", err)
		}
	case <-time.After(30 * time.Second):
		t.Fatal("the write never finished")
	}

	select {
	case b := <-got:
		if n := atomic.LoadUint64(&ca.lost) + atomic.LoadUint64(&ca.peer.lost); n == 0 {
			t.Fatal("the cut swallowed nothing, so this proves nothing")
		}
		if len(b) != total {
			t.Fatalf("the far end got %d bytes of %d - the stream did not survive the cut", len(b), total)
		}
		if !bytes.Equal(b, want) {
			for i := range b {
				if b[i] != want[i] {
					t.Fatalf("byte %d of %d is wrong: the resend overlapped or left a hole", i, total)
				}
			}
		}
	case <-time.After(30 * time.Second):
		t.Fatal("the far end never saw the end of the stream")
	}
}

// fastPings is a forwarder whose heartbeat, and so its probe, comes every
// twenty milliseconds instead of every ten seconds.
func fastPings(f *Forwarder) { f.pingGap = 20 * time.Millisecond }

// What Iran did to the Turkey server on 2026-09-26: the tunnel connected, the
// heartbeat came and went, and anything the size of data was stopped. The
// health check said nothing was wrong. The probe has to say it - on a wire
// that holds up a connection behind whatever it stopped, as a real one does.
func TestAPathThatPassesOnlyTheHeartbeatIsCalledBlocked(t *testing.T) {
	e, o := pairConns(t, 2, fastPings)
	e.car.(*pipeCarrier).dropOver.Store(200)
	o.car.(*pipeCarrier).dropOver.Store(200)
	deadline := time.Now().Add(5 * time.Second)
	for !e.DataBlocked() && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if !e.DataBlocked() {
		t.Fatal("probes vanished and the heartbeat did not, and nothing was said")
	}
	if seen := e.FarSeen(); seen.IsZero() || time.Since(seen) > time.Second {
		t.Fatalf("the heartbeat should still be crossing: last heard %v", seen)
	}
}

// The probe's own connection is not the heartbeat's. On one they shared, a
// stopped probe held the heartbeat up behind it, the far end went quiet, and
// the tunnel read as silent - the very misreading this is here to end.
func TestTheProbeNeverRidesTheHeartbeatsConnection(t *testing.T) {
	e, _ := pairConns(t, 4, fastPings)
	ca := e.car.(*pipeCarrier)
	ca.dropOver.Store(200)
	deadline := time.Now().Add(2 * time.Second)
	for ca.bigFlow.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	flow := ca.bigFlow.Load() - 1
	if flow < 0 {
		t.Fatal("no probe was ever sent")
	}
	if flow%4 == 0 {
		t.Fatalf("the probe went on flow %d, the heartbeat's connection", flow)
	}
	if ca.stalled[0].Load() {
		t.Fatal("the heartbeat's connection was held up behind a probe")
	}
}

// And the other side of it: a path that carries everything never says so,
// and says when a probe last came back.
func TestAHealthyTunnelIsNeverCalledBlocked(t *testing.T) {
	e, _ := pairConns(t, 2, fastPings)
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if e.DataBlocked() {
			t.Fatal("a tunnel that answers its probes was called blocked")
		}
		time.Sleep(20 * time.Millisecond)
	}
	if e.ProbeSeen().IsZero() {
		t.Fatal("no probe ever came back on a path that loses nothing")
	}
}

// With one connection there is nowhere to put a probe but in front of the
// heartbeat, so there is none.
func TestAOneConnectionTunnelIsNotProbed(t *testing.T) {
	e, _ := pair(t, nil, fastPings)
	ca := e.car.(*pipeCarrier)
	ca.dropOver.Store(200)
	time.Sleep(400 * time.Millisecond)
	if ca.bigFlow.Load() != 0 {
		t.Fatal("a probe went out on a tunnel of one connection")
	}
	if e.DataBlocked() {
		t.Fatal("a tunnel that was never probed was called blocked")
	}
}

// A probe is missed when its period is up without it, not when it leaves.
// Counting at the send called the tunnel blocked the moment the third probe
// went out, before it could possibly have come back.
func TestAProbeIsMissedOnlyWhenItsPeriodIsUp(t *testing.T) {
	e, _ := pairConns(t, 2)
	e.car.(*pipeCarrier).dropOver.Store(200)
	atomic.StoreInt64(&e.farSeen, time.Now().UnixNano())
	for i := 0; i < probeMisses; i++ {
		e.probe(1000)
	}
	if got := e.probeMissed.Load(); got != probeMisses-1 {
		t.Fatalf("%d probes out, the last one still in its period: %d missed, expected %d",
			probeMisses, got, probeMisses-1)
	}
	if e.DataBlocked() {
		t.Fatal("called blocked while the last probe could still come back")
	}
	e.probe(1000)
	if !e.DataBlocked() {
		t.Fatalf("%d whole periods without a probe back, and not blocked", probeMisses)
	}
}

// A busy tunnel can lose a probe's answer to a full queue. If data is
// arriving, it is not blocked, however many answers went missing.
func TestDataArrivingMeansNotBlocked(t *testing.T) {
	e, _ := pairConns(t, 2)
	atomic.StoreInt64(&e.farSeen, time.Now().UnixNano())
	e.probeMissed.Store(probeMisses + 2)
	e.dataAtProbe.Store(0)
	e.dataIn.Store(probeDataMin * 4)
	if e.DataBlocked() {
		t.Fatal("a tunnel receiving data was called blocked")
	}
	e.dataIn.Store(probeDataMin / 8)
	if !e.DataBlocked() {
		t.Fatal("missed probes, a live heartbeat and no data should be blocked")
	}
	atomic.StoreInt64(&e.farSeen, time.Now().Add(-time.Hour).UnixNano())
	if e.DataBlocked() {
		t.Fatal("a far end that has gone silent is the silence check's, not this one's")
	}
}

// Forwarded datagrams are data as much as a stream's bytes are: a tunnel
// carrying nothing but a WireGuard session must not read as blocked because
// the far end's full queue dropped a probe's echo.
func TestADatagramCountsAsData(t *testing.T) {
	e, _ := pairConns(t, 2)
	rec := make([]byte, hdrLen+1000)
	rec[0] = cmdUDP
	binary.BigEndian.PutUint32(rec[1:5], udpIDBit|7)
	before := e.dataIn.Load()
	e.onRecord(rec)
	if got := e.dataIn.Load() - before; got != 1000 {
		t.Fatalf("a 1000-byte datagram added %d to what has arrived", got)
	}
}

// No stream is ever given the probe's id. A record with a stream's id marks
// that stream as having ridden its connection, so a probe sharing one would
// have a stream that never sent a byte reset when that connection died.
func TestNoStreamIsGivenTheProbesID(t *testing.T) {
	e, _ := pairConns(t, 2)
	for i := 0; i < 5; i++ {
		if id := e.freshID(); id == 0 || id == probeID {
			t.Fatalf("stream id %d handed out: it belongs to the heartbeat or the probe", id)
		}
	}
}
