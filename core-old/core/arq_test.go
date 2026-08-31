package main

import (
	"bytes"
	crand "crypto/rand"
	"io"
	mrand "math/rand"
	"sync"
	"testing"
	"time"
)

// lossyLink joins two arqConns through a path that misbehaves on purpose:
// it drops, delays, reorders and duplicates. Everything below is measured
// against that, not against a quiet loopback.
type lossyLink struct {
	mu       sync.Mutex
	rnd      *mrand.Rand
	loss     float64 // fraction dropped
	dupe     float64 // fraction delivered twice
	jitterMs int     // random delay before delivery
	closed   bool

	a, b   *arqConn
	sentAB int
	sentBA int
}

func (l *lossyLink) deliver(to **arqConn, buf []byte) {
	l.mu.Lock()
	if l.closed {
		l.mu.Unlock()
		return
	}
	drop := l.rnd.Float64() < l.loss
	dupe := l.rnd.Float64() < l.dupe
	delay := time.Duration(l.rnd.Intn(l.jitterMs+1)) * time.Millisecond
	l.mu.Unlock()

	if drop {
		return
	}
	cp := append([]byte(nil), buf...)
	fire := func() {
		if delay > 0 {
			time.Sleep(delay)
		}
		l.mu.Lock()
		peer := *to
		gone := l.closed
		l.mu.Unlock()
		if !gone && peer != nil {
			peer.onDatagram(cp)
		}
	}
	go fire()
	if dupe {
		go fire()
	}
}

func (l *lossyLink) close() {
	l.mu.Lock()
	l.closed = true
	l.mu.Unlock()
}

// newLossyPair wires two endpoints together over such a path.
func newLossyPair(loss, dupe float64, jitterMs int) (*arqConn, *arqConn, *lossyLink) {
	l := &lossyLink{rnd: mrand.New(mrand.NewSource(1)), loss: loss, dupe: dupe, jitterMs: jitterMs}
	psk := []byte("shared key for the arq layer only")
	a := newARQ(0x1234, 0, psk, icmpARQLabel, 1200, 64, func(b []byte) error {
		l.mu.Lock()
		l.sentAB++
		l.mu.Unlock()
		l.deliver(&l.b, b)
		return nil
	})
	b := newARQ(0x1234, 0, psk, icmpARQLabel, 1200, 64, func(buf []byte) error {
		l.mu.Lock()
		l.sentBA++
		l.mu.Unlock()
		l.deliver(&l.a, buf)
		return nil
	})
	l.mu.Lock()
	l.a, l.b = a, b
	l.mu.Unlock()
	return a, b, l
}

func transfer(t *testing.T, a, b *arqConn, payload []byte, timeout time.Duration) {
	t.Helper()
	done := make(chan error, 1)
	got := make([]byte, 0, len(payload))

	go func() {
		buf := make([]byte, 4096)
		for len(got) < len(payload) {
			n, err := b.Read(buf)
			got = append(got, buf[:n]...)
			if err != nil {
				done <- err
				return
			}
		}
		done <- nil
	}()

	go func() {
		if _, err := a.Write(payload); err != nil {
			t.Errorf("write: %v", err)
		}
	}()

	select {
	case err := <-done:
		if err != nil && err != io.EOF {
			t.Fatalf("read: %v", err)
		}
	case <-time.After(timeout):
		t.Fatalf("timed out with %d of %d bytes through", len(got), len(payload))
	}
	if !bytes.Equal(got, payload) {
		t.Fatalf("payload corrupted: got %d bytes, want %d", len(got), len(payload))
	}
}

func TestARQCleanPath(t *testing.T) {
	a, b, l := newLossyPair(0, 0, 0)
	defer l.close()
	defer a.Close()
	defer b.Close()

	payload := make([]byte, 256*1024)
	crand.Read(payload)
	transfer(t, a, b, payload, 30*time.Second)
}

// A fifth of the packets never arrive, some arrive twice, and they arrive out
// of order. Every byte still has to come out once, in the right order.
func TestARQSurvivesLossReorderAndDuplication(t *testing.T) {
	a, b, l := newLossyPair(0.20, 0.05, 8)
	defer l.close()
	defer a.Close()
	defer b.Close()

	payload := make([]byte, 128*1024)
	crand.Read(payload)
	transfer(t, a, b, payload, 60*time.Second)
}

func TestARQBothDirectionsAtOnce(t *testing.T) {
	a, b, l := newLossyPair(0.10, 0.02, 5)
	defer l.close()
	defer a.Close()
	defer b.Close()

	up := make([]byte, 64*1024)
	down := make([]byte, 64*1024)
	crand.Read(up)
	crand.Read(down)

	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); transfer(t, a, b, up, 60*time.Second) }()
	go func() { defer wg.Done(); transfer(t, b, a, down, 60*time.Second) }()
	wg.Wait()
}

func TestARQHeaderIsMaskedAndVaries(t *testing.T) {
	var captured [][]byte
	var mu sync.Mutex
	psk := []byte("shared key for the arq layer only")
	c := newARQ(0xAABBCCDD, 0, psk, icmpARQLabel, 1200, 64, func(b []byte) error {
		mu.Lock()
		captured = append(captured, append([]byte(nil), b...))
		mu.Unlock()
		return nil
	})
	defer c.Close()

	// The same one-byte payload, sent repeatedly.
	for i := 0; i < 8; i++ {
		if _, err := c.Write([]byte{0x41}); err != nil {
			t.Fatal(err)
		}
	}
	mu.Lock()
	defer mu.Unlock()
	if len(captured) < 8 {
		t.Fatalf("only %d datagrams captured", len(captured))
	}

	// The session id sits at a fixed offset in the header. If the mask were
	// not doing its job it would be identical in every datagram.
	for pos := 0; pos < arqOver; pos++ {
		same := true
		for _, d := range captured[1:8] {
			if d[pos] != captured[0][pos] {
				same = false
				break
			}
		}
		if same {
			t.Fatalf("byte %d is the same in every datagram - the header is not masked", pos)
		}
	}
}

func TestARQRetransmitsAndGivesUp(t *testing.T) {
	// Nothing ever arrives, so the sender must eventually stop rather than
	// retrying for ever.
	sent := 0
	var mu sync.Mutex
	c := newARQ(1, 0, []byte("k"), icmpARQLabel, 1200, 64, func(b []byte) error {
		mu.Lock()
		sent++
		mu.Unlock()
		return nil
	})
	c.rto = 20 * time.Millisecond
	c.maxRetries = 5

	go c.Write([]byte("hello"))

	deadline := time.Now().Add(30 * time.Second)
	for {
		c.mu.Lock()
		failed := c.err != nil
		c.mu.Unlock()
		if failed {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("a segment that never arrives should eventually fail the connection")
		}
		time.Sleep(50 * time.Millisecond)
	}
	mu.Lock()
	n := sent
	mu.Unlock()

	// Close() emits a FIN through the same callback, so the count has to be
	// read before the lock is handed back to it.
	c.Close()
	if n < 5 {
		t.Fatalf("only %d attempts before giving up", n)
	}
}
