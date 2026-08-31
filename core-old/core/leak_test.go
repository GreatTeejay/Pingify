package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"fmt"
	"net"
	"runtime"
	"sync/atomic"
	"testing"
	"time"
)

// What a stray used to cost, and must not any more.
//
// Every unknown session that arrived built an ARQ connection: a map entry, a
// slot in a channel nobody would ever read, and a goroutine on a ticker. None
// of the three was ever released, because the reaper only removed what had
// closed or failed and a session nobody accepts does neither. On a server left
// running for days that is "Consumed 32min CPU, 194.8M memory peak" for a
// tunnel that carried nothing.
//
// Counting goroutines is the honest measure here: the map could be emptied and
// the tickers would still be running.
func TestStraysLeaveNothingBehind(t *testing.T) {
	setLogLevel("error")
	psk := []byte(testPSK(t))

	settle := func() int {
		for i := 0; i < 40; i++ {
			runtime.Gosched()
			time.Sleep(25 * time.Millisecond)
			runtime.GC()
		}
		return runtime.NumGoroutine()
	}

	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Skip("no loopback udp:", err)
	}
	defer pc.Close()

	base := settle()

	// The end that dials: it never accepts, so none of these can be real and
	// none of them should cost anything at all.
	dialling := &udpTransport{
		pc: pc, psk: psk, window: 64, dials: true,
		sessions: make(map[sessionKey]*arqConn),
		inbound:  make(chan net.Conn, 64),
		done:     make(chan struct{}),
	}
	// what newUDPTransport sets up; Close emits a final datagram and needs it
	dialling.tagHash.New = func() interface{} { return hmac.New(sha256.New, psk) }

	peer := &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 9}
	for i := 1; i <= 500; i++ {
		dialling.dispatch(peer, udpStray(psk, uint32(0x5A000000+i)))
	}
	close(dialling.done)

	if after := settle(); after > base+4 {
		t.Fatalf("500 strays on the dialling end left %d goroutines behind", after-base)
	}

	// The end that accepts does build them - a real carrier arrives that way -
	// but a session that goes quiet has to be let go of, goroutine and all.
	accepting := &udpTransport{
		pc: pc, psk: psk, window: 64, dials: false,
		sessions: make(map[sessionKey]*arqConn),
		inbound:  make(chan net.Conn, 512),
		done:     make(chan struct{}),
	}
	// what newUDPTransport sets up; Close emits a final datagram and needs it
	accepting.tagHash.New = func() interface{} { return hmac.New(sha256.New, psk) }

	const n = 200
	for i := 1; i <= n; i++ {
		accepting.dispatch(peer, udpStray(psk, uint32(0x5B000000+i)))
	}
	accepting.mu.Lock()
	built := len(accepting.sessions)
	for _, c := range accepting.sessions {
		atomic.StoreInt64(&c.lastRx, time.Now().Add(-2*arqSessionIdle).UnixNano())
	}
	accepting.mu.Unlock()
	if built != n {
		t.Fatalf("the accepting end built %d of %d sessions", built, n)
	}
	held := settle()
	if held <= base {
		t.Skip("this build does not start a goroutine per session; nothing to leak")
	}

	// one sweep, the same one the reaper runs on its ticker
	var closing []*arqConn
	now := time.Now().UnixNano()
	accepting.mu.Lock()
	for k, c := range accepting.sessions {
		if now-atomic.LoadInt64(&c.lastRx) > int64(arqSessionIdle) {
			closing = append(closing, c)
			delete(accepting.sessions, k)
		}
	}
	accepting.mu.Unlock()
	for _, c := range closing {
		c.Close()
	}
	close(accepting.done)

	if after := settle(); after > base+4 {
		t.Fatalf("after the sweep, %d goroutines are still running (%d before, %d at the peak)",
			after-base, base, held)
	}
	t.Log(fmt.Sprintf("%d strays came and went and left nothing", 500+n))
}
