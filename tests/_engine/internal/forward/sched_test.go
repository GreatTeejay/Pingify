package forward

import (
	"bytes"
	"io"
	"net"
	"sync/atomic"
	"testing"
	"time"
)

func rec1(id uint32, tag byte) outRec {
	b := []byte{tag}
	return outRec{id: id, bp: &b}
}

func tagOf(r outRec) byte { return (*r.bp)[0] }

// Control leaves before any data; a stream that has just come to life leaves
// before the ones that have been sending; the busy ones take turns.
func TestTheSchedulerOrder(t *testing.T) {
	s := newSched()
	closing := make(chan struct{})
	// Stream 7 is a download with four records waiting, stream 9 another.
	for i := 0; i < 4; i++ {
		s.data(rec1(7, 'd'), nil, closing)
	}
	for i := 0; i < 4; i++ {
		s.data(rec1(9, 'e'), nil, closing)
	}
	r, _ := s.next(closing) // 7 was fresh: its first record
	if tagOf(r) != 'd' {
		t.Fatalf("first out %q", tagOf(r))
	}
	r, _ = s.next(closing) // 9 was fresh too
	if tagOf(r) != 'e' {
		t.Fatalf("second out %q, expected the other fresh stream", tagOf(r))
	}
	// Now a keystroke on stream 11, and an acknowledgement.
	s.data(rec1(11, 'k'), nil, closing)
	s.control(rec1(0, 'a'), false)
	want := "akdede" // control, the fresh keystroke, then the two busy ones in turn
	got := ""
	for i := 0; i < len(want); i++ {
		r, _ := s.next(closing)
		got += string(tagOf(r))
	}
	if got != want {
		t.Fatalf("left in the order %q, expected %q", got, want)
	}
}

// A stream with flowDepth records waiting holds up its own pump and no one
// else's.
func TestAFullStreamWaitsAlone(t *testing.T) {
	s := newSched()
	closing := make(chan struct{})
	for i := 0; i < flowDepth; i++ {
		if !s.data(rec1(7, 'd'), nil, closing) {
			t.Fatal("refused a record below flowDepth")
		}
	}
	blocked := make(chan bool, 1)
	go func() { blocked <- s.data(rec1(7, 'd'), nil, closing) }()
	select {
	case <-blocked:
		t.Fatal("a stream past flowDepth was not made to wait")
	case <-time.After(50 * time.Millisecond):
	}
	done := make(chan bool, 1)
	go func() { done <- s.data(rec1(9, 'e'), nil, closing) }()
	select {
	case ok := <-done:
		if !ok {
			t.Fatal("another stream was refused")
		}
	case <-time.After(time.Second):
		t.Fatal("another stream waited behind a full one")
	}
	s.next(closing) // room for 7 again
	select {
	case ok := <-blocked:
		if !ok {
			t.Fatal("the waiting record was refused")
		}
	case <-time.After(time.Second):
		t.Fatal("the waiting stream did not go on when a record left")
	}
}

// speaksWindow is both ends having said capResume and capWindow.
func speaksWindow(e, o *Forwarder) {
	e.farCaps.Store(capResume | capWindow)
	o.farCaps.Store(capResume | capWindow)
}

// With the window, one user who stops reading slows their own stream and
// nobody else's, is not reset for it, and costs this end no more than the
// window of memory. Every stream here rides one connection.
func TestASlowReaderUnderTheWindowSlowsOnlyItself(t *testing.T) {
	svc, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer svc.Close()
	go func() {
		chunk := make([]byte, 64<<10)
		for {
			c, err := svc.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				for {
					if _, err := c.Write(chunk); err != nil {
						return
					}
				}
			}()
		}
	}()
	userPort := freePort(t)
	e, o := pair(t, []string{userPort + "=127.0.0.1:" + itoa(svc.Addr().(*net.TCPAddr).Port)})
	speaksWindow(e, o)

	slow, err := net.Dial("tcp", "127.0.0.1:"+userPort)
	if err != nil {
		t.Fatal(err)
	}
	defer slow.Close()
	slow.Write([]byte("x"))
	time.Sleep(300 * time.Millisecond)

	fast, err := net.Dial("tcp", "127.0.0.1:"+userPort)
	if err != nil {
		t.Fatal(err)
	}
	defer fast.Close()
	fast.Write([]byte("x"))
	var got atomic.Int64
	go func() {
		b := make([]byte, 256<<10)
		for {
			n, err := fast.Read(b)
			got.Add(int64(n))
			if err != nil {
				return
			}
		}
	}()
	peak := 0
	deadline := time.Now().Add(10 * time.Second)
	for got.Load() < 64<<20 && time.Now().Before(deadline) {
		e.mu.Lock()
		for _, s := range e.streams {
			if h := s.in.held(); h > peak {
				peak = h
			}
		}
		e.mu.Unlock()
		time.Sleep(20 * time.Millisecond)
	}
	if n := got.Load(); n < 64<<20 {
		t.Fatalf("the reading user got %d KB in ten seconds beside one who stopped", n>>10)
	}
	if n := atomic.LoadUint64(&e.slowReset); n != 0 {
		t.Fatalf("%d streams reset for being slow; with the window nobody should be", n)
	}
	if peak > window+e.maxBody() {
		t.Fatalf("a stream's inbox held %d bytes, more than the window of %d", peak, window)
	}
	// And the slow one is still there, and gets its bytes when it reads.
	_ = slow.SetReadDeadline(time.Now().Add(5 * time.Second))
	b := make([]byte, 1<<20)
	if _, err := io.ReadAtLeast(slow, b, 1<<20); err != nil {
		t.Fatalf("the slow user's stream is gone: %v", err)
	}
}

// A stream carried across a dying connection under the window arrives whole,
// both the resend and the window's accounting surviving the cut.
func TestAStreamOutlivesItsConnectionUnderTheWindow(t *testing.T) {
	const total = 16 << 20
	got := make(chan []byte, 1)
	started := make(chan struct{})
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
		signalled := false
		for {
			n, err := c.Read(b)
			all = append(all, b[:n]...)
			if !signalled && len(all) > 2<<20 {
				signalled = true
				close(started)
			}
			if err != nil {
				break
			}
		}
		got <- all
	}()
	userPort := freePort(t)
	e, o := pairQ(t, []string{userPort + "=127.0.0.1:" + itoa(svc.Addr().(*net.TCPAddr).Port)}, 128)
	speaksWindow(e, o)
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
		time.Sleep(20 * time.Millisecond)
		ca.cut(0, 30*time.Millisecond)
	}()
	go func() {
		user.Write(want)
		if cw, ok := user.(*net.TCPConn); ok {
			cw.CloseWrite()
		}
	}()
	select {
	case b := <-got:
		if n := atomic.LoadUint64(&ca.lost) + atomic.LoadUint64(&ca.peer.lost); n == 0 {
			t.Fatal("the cuts swallowed nothing, so this proves nothing")
		}
		if !bytes.Equal(b, want) {
			t.Fatalf("the far end got %d bytes of %d, or not the same ones", len(b), total)
		}
	case <-time.After(30 * time.Second):
		t.Fatal("the stream never finished across two cuts under the window: a window that never reopened")
	}
}
