package carrier

import (
	"net"
	"sync/atomic"
	"testing"
	"time"

	"pingify/internal/buf"
	"pingify/internal/config"
)

// tcpPairRotating is a waiting TCP carrier on loopback and a dialling one
// whose connections live about rotate each, with n connections, both running.
func tcpPairRotating(t *testing.T, n int, rotate time.Duration) (waiting, dialling *streamCarrier) {
	t.Helper()
	w := &config.Config{Side: config.SideIran, Mode: "forward", Token: "a rotation test"}
	w.Transport.Type = "tcp"
	w.Transport.Connections = n
	waiting, err := newTCPCarrier(w)
	if err != nil {
		t.Fatalf("waiting side: %v", err)
	}
	t.Cleanup(func() { _ = waiting.Close() })

	d := &config.Config{Side: config.SideKharej, Mode: "forward", Token: "a rotation test"}
	d.Transport.Type = "tcp"
	d.Transport.Connections = n
	d.Transport.Iran = "127.0.0.1"
	d.Transport.Port = waiting.ln.Addr().(*net.TCPAddr).Port
	dialling, err = newTCPCarrier(d)
	if err != nil {
		t.Fatalf("dialling side: %v", err)
	}
	dialling.rotate = rotate
	t.Cleanup(func() { _ = dialling.Close() })
	return waiting, dialling
}

// Connections that have lived their time are replaced, and the slot is never
// empty while it happens: the successor is in the table before the one it
// replaces is closed. Both ends are told each old one ended, which is what
// carries on whatever was riding it.
func TestConnectionsAreRenewedAndTheSlotNeverEmpties(t *testing.T) {
	w, d := tcpPairRotating(t, 4, 150*time.Millisecond)
	var downW, downD atomic.Int32
	w.OnLinkDown(func(int) { downW.Add(1) })
	d.OnLinkDown(func(int) { downD.Add(1) })
	var got atomic.Int64
	w.OnPacket(func([]byte) { got.Add(1) })
	go w.Run()
	go d.Run()
	waitFor(t, "every connection up", 5*time.Second, func() bool {
		for i := range d.links {
			if d.links[i].Load() == nil {
				return false
			}
		}
		return true
	})

	// Datagrams down every slot for a second and a half, while the table is
	// watched for a slot with nothing in it.
	var sent int64
	empty := 0
	stop := time.Now().Add(1500 * time.Millisecond)
	for i := uint32(0); time.Now().Before(stop); i++ {
		for s := range d.links {
			if d.links[s].Load() == nil {
				empty++
			}
		}
		bp := buf.Take(d.Headroom(), 200)
		if d.SendFlow(i, bp) == nil {
			sent++
		} else {
			buf.Put(bp)
		}
		time.Sleep(time.Millisecond)
	}
	time.Sleep(200 * time.Millisecond)

	renewed := d.renewed.Load()
	if renewed < 8 {
		t.Fatalf("%d connections renewed in 1.5 s at about 150 ms each; expected many more", renewed)
	}
	if empty != 0 {
		t.Errorf("a slot was found empty %d times while connections were being renewed", empty)
	}
	if n := downD.Load(); int(n) < int(renewed)-4 {
		t.Errorf("the dialling side was told of %d ended connections after %d renewals", n, renewed)
	}
	if n := downW.Load(); n == 0 {
		t.Error("the waiting side was never told a connection ended, so nothing it held would be carried on")
	}
	// A datagram in flight on a connection being closed can be lost - that
	// is what the forward layer resends - but nearly all of them arrive.
	if g := got.Load(); g < sent*9/10 {
		t.Errorf("%d of %d datagrams arrived across the renewals", g, sent)
	}
}

// Without rotate a connection that works is kept.
func TestWithoutRotateAWorkingConnectionIsKept(t *testing.T) {
	w, d := tcpPairRotating(t, 2, 0)
	go w.Run()
	go d.Run()
	waitFor(t, "both connections up", 5*time.Second, func() bool {
		return d.links[0].Load() != nil && d.links[1].Load() != nil
	})
	first := d.links[0].Load()
	time.Sleep(600 * time.Millisecond)
	if d.renewed.Load() != 0 || d.links[0].Load() != first {
		t.Fatal("a connection was replaced with rotate off")
	}
}

// A successor that cannot be dialled leaves the connection it was to replace
// carrying, rather than emptying the slot.
func TestARenewalThatCannotDialKeepsTheOldConnection(t *testing.T) {
	w, d := tcpPairRotating(t, 1, 150*time.Millisecond)
	// The far end stops taking new connections when told to; set before
	// anything runs, so the dial loop never races the test for the field.
	real := d.dial
	var refuse atomic.Bool
	var refused atomic.Int32
	d.dial = func() (net.Conn, framing, error) {
		if refuse.Load() {
			refused.Add(1)
			return nil, nil, net.ErrClosed
		}
		return real()
	}
	go w.Run()
	go d.Run()
	waitFor(t, "the connection up", 5*time.Second, func() bool { return d.links[0].Load() != nil })
	refuse.Store(true)
	time.Sleep(50 * time.Millisecond) // a dial already past the check lands first
	first := d.links[0].Load()
	waitFor(t, "a renewal attempted", 3*time.Second, func() bool { return refused.Load() > 0 })
	time.Sleep(100 * time.Millisecond)
	if d.links[0].Load() != first {
		t.Fatal("the slot lost its working connection to a successor that never came")
	}
	refuse.Store(false)
	waitFor(t, "renewed once the far end answers again", 3*time.Second, func() bool {
		return d.links[0].Load() != first && d.links[0].Load() != nil
	})
}

// The beat comes after a quiet of somewhere between half beatEvery and half
// as much again, drawn afresh each time - not on a clock.
func TestTheBeatKeepsNoClock(t *testing.T) {
	every := 500 * time.Millisecond
	l := &streamLink{}
	seen := map[time.Duration]bool{}
	for i := 0; i < 200; i++ {
		d := l.beatDue(every)
		if d != l.beatDue(every) {
			t.Fatal("the same connection was given two different waits before one beat")
		}
		if d < every/2 || d >= every*3/2 {
			t.Fatalf("a wait of %s, outside %s to %s", d, every/2, every*3/2)
		}
		seen[d] = true
		l.nextBeat.Store(0)
	}
	if len(seen) < 50 {
		t.Fatalf("only %d different waits in 200 draws", len(seen))
	}
}
