package forward

import (
	"io"
	"net"
	"sync/atomic"
	"testing"
	"time"
)

// One user who stops reading must not hold up the others on the same
// carrier connection for longer than slowReaderWait. Here every stream rides
// one connection, the service sends without end, one user never reads and
// another reads as fast as it can: the reader keeps getting data, and the one
// who stopped is let go.
func TestOneSlowUserDoesNotHoldUpTheOthers(t *testing.T) {
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
	e, _ := pair(t, []string{userPort + "=127.0.0.1:" + itoa(svc.Addr().(*net.TCPAddr).Port)})

	slow, err := net.Dial("tcp", "127.0.0.1:"+userPort)
	if err != nil {
		t.Fatal(err)
	}
	defer slow.Close()
	if _, err := slow.Write([]byte("x")); err != nil { // so the service is dialled
		t.Fatal(err)
	}
	time.Sleep(300 * time.Millisecond) // it falls behind: nothing reads it

	fast, err := net.Dial("tcp", "127.0.0.1:"+userPort)
	if err != nil {
		t.Fatal(err)
	}
	defer fast.Close()
	if _, err := fast.Write([]byte("x")); err != nil {
		t.Fatal(err)
	}
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

	deadline := time.Now().Add(10 * time.Second)
	for got.Load() < 32<<20 && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	if n := got.Load(); n < 32<<20 {
		t.Fatalf("the reading user got %d KB in ten seconds while another stopped reading", n>>10)
	}
	if atomic.LoadUint64(&e.slowReset) == 0 {
		t.Fatal("the user who stopped reading was never given up")
	}
	// Its connection is over, one way or the other, and not left open.
	_ = slow.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := io.Copy(io.Discard, slow); err != nil {
		if ne, ok := err.(net.Error); ok && ne.Timeout() {
			t.Fatal("the slow user's connection is still open")
		}
	}
}
