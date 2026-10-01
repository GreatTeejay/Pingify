package carrier

import (
	"math/rand/v2"
	"sync"
	"testing"
	"time"
)

// Four readers take batches off one socket in turn - the socket call is made
// one at a time, as the runtime makes it - and then check them for different
// lengths of time. Whatever the order they finish their checks in, what they
// hand over comes out in the order it was taken.
func TestBatchesAreHandedOverInTheOrderTheyWereTaken(t *testing.T) {
	o := newInOrder()
	var socket sync.Mutex // the runtime's one-at-a-time socket read
	var mu sync.Mutex
	var out []uint64
	const batches = 2000
	var wg sync.WaitGroup
	taken := make(chan struct{}, batches)
	for r := 0; r < 4; r++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				socket.Lock()
				if len(taken) == batches {
					socket.Unlock()
					return
				}
				tk := o.ticket()
				taken <- struct{}{}
				socket.Unlock()
				// The checks: a different time for every batch.
				time.Sleep(time.Duration(rand.IntN(200)) * time.Microsecond)
				o.wait(tk)
				mu.Lock()
				out = append(out, tk)
				mu.Unlock()
				o.done()
			}
		}()
	}
	wg.Wait()
	if len(out) != batches {
		t.Fatalf("%d batches handed over of %d", len(out), batches)
	}
	for i, tk := range out {
		if tk != uint64(i) {
			t.Fatalf("batch %d was handed over %dth: out of the order it was taken", tk, i)
		}
	}
}

// open is verify and then admit, and admit keeps the replay window: the same
// frame twice is taken once.
func TestVerifyAndAdmitAreOpenInTwoSteps(t *testing.T) {
	tx := newFramer("a token typed on both servers", "pingify icmp v1")
	rx := newFramer("a token typed on both servers", "pingify icmp v1")
	b := make([]byte, frameLen+5)
	copy(b[frameLen:], "hello")
	tx.seal(b)
	seq, body, ok := rx.verify(b)
	if !ok || string(body) != "hello" {
		t.Fatalf("a good frame did not verify: %v %q", ok, body)
	}
	if !rx.admit(seq) {
		t.Fatal("a fresh frame was not admitted")
	}
	if rx.admit(seq) {
		t.Fatal("the same frame was admitted twice")
	}
	b[frameLen] ^= 1
	if _, _, ok := rx.verify(b); ok {
		t.Fatal("a frame changed on the way verified")
	}
}
