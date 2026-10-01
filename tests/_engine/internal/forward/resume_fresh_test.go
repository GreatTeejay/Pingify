package forward

import (
	"bytes"
	"encoding/binary"
	"io"
	"net"
	"sync/atomic"
	"testing"
	"time"
)

// speaksResume is both ends having said capResume in a hello, without
// waiting ten seconds for the first heartbeat to carry it.
func speaksResume(e, o *Forwarder) {
	e.farCaps.Store(capResume)
	o.farCaps.Store(capResume)
}

// rec is one record as it crosses: command, stream id, body.
func rec(cmd byte, id uint32, body []byte) []byte {
	b := make([]byte, hdrLen+len(body))
	b[0] = cmd
	binary.BigEndian.PutUint32(b[1:5], id)
	copy(b[hdrLen:], body)
	return b
}

func dataRec(id uint32, off uint64, payload string) []byte {
	body := make([]byte, offLen+len(payload))
	binary.BigEndian.PutUint64(body, off)
	copy(body[offLen:], payload)
	return rec(cmdData, id, body)
}

// echoService answers every connection with what it is sent, and counts
// the connections it took.
func echoService(t *testing.T) (port string, conns *atomic.Int32) {
	t.Helper()
	svc, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { svc.Close() })
	conns = &atomic.Int32{}
	go func() {
		for {
			c, err := svc.Accept()
			if err != nil {
				return
			}
			conns.Add(1)
			go func() { io.Copy(c, c); c.Close() }()
		}
	}()
	return itoa(svc.Addr().(*net.TCPAddr).Port), conns
}

// dies is a connection that has been swallowing what it was given being
// found dead, in the order a real one is: the writer that sat on it lets go
// (a real kernel took the records at once), whatever was queued behind it
// goes out on the connection that replaces it, and only then does the
// carrier say which connection ended.
func dies(p *pipeCarrier, slot int) {
	p.lose.Store(false)
	p.peer.lose.Store(false)
	time.Sleep(50 * time.Millisecond)
	if f := p.onLinkDown.Load(); f != nil {
		(*f)(slot)
	}
	if f := p.peer.onLinkDown.Load(); f != nil {
		(*f)(slot)
	}
}

// The streams the Iran 1 to Germany tunnel reset on 2026-09-30: opened just
// before, or during, the seconds a carrier connection was silent, so that
// their SYN and first bytes went into a connection that then died. Nothing
// of theirs had been acknowledged, and a stream nobody had acknowledged was
// one this end would not carry on. Now the SYN goes again, the bytes follow
// from the first, and the program behind it never knows.
func TestAStreamWhoseSYNDiedWithItsConnectionCarriesOn(t *testing.T) {
	port, conns := echoService(t)
	userPort := freePort(t)
	e, o := pair(t, []string{userPort + "=127.0.0.1:" + port})
	speaksResume(e, o)
	ca := e.car.(*pipeCarrier)

	// The connection stops delivering before the user arrives, so the SYN
	// and the first record are both lost with it.
	ca.lose.Store(true)
	ca.peer.lose.Store(true)
	user, err := net.Dial("tcp", "127.0.0.1:"+userPort)
	if err != nil {
		t.Fatal(err)
	}
	defer user.Close()
	msg := []byte("opened while the connection under it was dying")
	if _, err := user.Write(msg); err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond)
	dies(ca, 0)

	_ = user.SetDeadline(time.Now().Add(5 * time.Second))
	got := make([]byte, len(msg))
	if _, err := io.ReadFull(user, got); err != nil {
		t.Fatalf("the stream did not carry on after its SYN died with the connection: %v", err)
	}
	if !bytes.Equal(got, msg) {
		t.Fatalf("the service answered %q, expected %q back", got, msg)
	}
	if n := conns.Load(); n != 1 {
		t.Fatalf("the service was dialled %d times for one stream", n)
	}
	// Counted once the writer that sat on the dead connection has let go.
	if atomic.LoadUint64(&ca.lost) == 0 {
		t.Fatal("the cut swallowed nothing, so this proves nothing")
	}
}

// Without the far end having said it can, nothing changes: a stream nobody
// acknowledged is reset as before, because an older far end would take its
// SYN again as a second connection.
func TestAFarEndThatNeverSaidSoGetsNoSecondSYN(t *testing.T) {
	port, conns := echoService(t)
	userPort := freePort(t)
	e, _ := pair(t, []string{userPort + "=127.0.0.1:" + port})
	ca := e.car.(*pipeCarrier)

	ca.lose.Store(true)
	ca.peer.lose.Store(true)
	user, err := net.Dial("tcp", "127.0.0.1:"+userPort)
	if err != nil {
		t.Fatal(err)
	}
	defer user.Close()
	if _, err := user.Write([]byte("hello")); err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond)
	dies(ca, 0)

	_ = user.SetDeadline(time.Now().Add(3 * time.Second))
	b := make([]byte, 1)
	if _, err := user.Read(b); err == nil {
		t.Fatal("a stream was carried on over a far end that never said it could take that")
	} else if ne, ok := err.(net.Error); ok && ne.Timeout() {
		t.Fatal("the user's connection was left waiting, not reset")
	}
	if n := conns.Load(); n > 1 {
		t.Fatalf("the service was dialled %d times for one stream", n)
	}
}

// A SYN for a stream the origin already has is the edge naming it again, not
// knowing whether the first one arrived. It must not dial the service twice.
func TestASecondSYNForALiveStreamIsNotASecondConnection(t *testing.T) {
	port, conns := echoService(t)
	e, o := pair(t, nil)
	speaksResume(e, o)
	cb := o.car.(*pipeCarrier)
	target := []byte("127.0.0.1:" + port)

	cb.q <- rec(cmdSYN, 777, target)
	deadline := time.Now().Add(3 * time.Second)
	for conns.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	cb.q <- rec(cmdSYN, 777, target)
	cb.q <- dataRec(777, 0, "once")
	time.Sleep(300 * time.Millisecond)
	if n := conns.Load(); n != 1 {
		t.Fatalf("two SYNs for one live stream dialled the service %d times", n)
	}
}

// What was queued for a stream before its SYN was sent again arrives ahead
// of that SYN. It is dropped quietly - it comes again behind the SYN - and
// not answered with a reset that would kill the stream the SYN then opens.
// From an edge that never said capResume it is refused at once, as always.
func TestDataAheadOfItsSYNIsNotRefused(t *testing.T) {
	port, conns := echoService(t)
	e, o := pair(t, nil)
	cb := o.car.(*pipeCarrier)
	ca := e.car.(*pipeCarrier)
	rsts := make(chan uint32, 16)
	prev := ca.on.Load()
	ca.OnPacket(func(b []byte) {
		if len(b) >= hdrLen && b[0] == cmdRST {
			rsts <- binary.BigEndian.Uint32(b[1:5])
		}
		(*prev)(b)
	})

	// An old edge: refused at once.
	cb.q <- dataRec(801, 5, "early")
	select {
	case id := <-rsts:
		if id != 801 {
			t.Fatalf("a reset for stream %d, expected 801", id)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("an edge that never said capResume got no reset for data nobody has")
	}

	// An edge that did: quiet, then the SYN, then the bytes from the first.
	speaksResume(e, o)
	cb.q <- dataRec(802, 5, "early")
	cb.q <- rec(cmdSYN, 802, []byte("127.0.0.1:"+port))
	cb.q <- dataRec(802, 0, "hello")
	select {
	case id := <-rsts:
		t.Fatalf("stream %d was reset for data that arrived ahead of its SYN", id)
	case <-time.After(500 * time.Millisecond):
	}
	if n := conns.Load(); n != 1 {
		t.Fatalf("the service was dialled %d times", n)
	}
}

// Each end says what it can with every heartbeat, and in answer to the far
// end's.
func TestEachEndSaysItCanResume(t *testing.T) {
	e, o := pair(t, nil, fastPings)
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if e.farCaps.Load()&capResume != 0 && o.farCaps.Load()&capResume != 0 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("after three seconds of heartbeats: edge heard %d, origin heard %d", e.farCaps.Load(), o.farCaps.Load())
}
