package main

import (
	"net"
	"testing"
)

// What a stream says on its way out, and when.
//
// reset is the ordinary end of a stream as well as an unhappy one - halfDone
// calls it once both directions have finished - so it must say nothing. A
// record sent from there arrives after the data still in flight and cuts it
// off, which is exactly what happened when this was got wrong: every forwarded
// round trip ended in "unexpected EOF".
//
// resetPeer is for the other case, where this end failed and the far end is
// still working for a stream that no longer exists. Without a word from here
// it reads the real service, sends data nobody will take, gets no window
// credit back, and after one window its writer waits for good - holding a
// goroutine, a connection to that service, and the window's memory, until the
// carrier itself dies.
func TestOnlyAFailedStreamTellsThePeer(t *testing.T) {
	mk := func() (*link, *stream) {
		cfg := &Config{Role: "server", Transport: "tcp", Token: "a token for the test"}
		cfg.applyDefaults()
		l := &link{
			idx:     0,
			cfg:     cfg,
			closed:  make(chan struct{}),
			sendQ:   make(chan *recBuf, 8),
			priQ:    make(chan *recBuf, 8),
			streams: make(map[uint32]*stream),
		}
		a, b := net.Pipe()
		t.Cleanup(func() { a.Close(); b.Close() })
		s := l.newStream(a)
		return l, s
	}

	// what it queued, whichever queue it used
	sent := func(l *link) []byte {
		var cmds []byte
		for {
			select {
			case r := <-l.priQ:
				cmds = append(cmds, r.bytes()[0])
			case r := <-l.sendQ:
				cmds = append(cmds, r.bytes()[0])
			default:
				return cmds
			}
		}
	}

	l, s := mk()
	s.reset()
	if got := sent(l); len(got) != 0 {
		t.Errorf("an ordinary reset sent %v - it must say nothing, or it cuts off "+
			"the data still in flight behind it", got)
	}

	l, s = mk()
	s.resetPeer()
	got := sent(l)
	if len(got) != 1 || got[0] != cmdRST {
		t.Errorf("a failed stream sent %v, want one reset - without it the far "+
			"end waits for credit that is never coming", got)
	}

	// And a carrier already gone is not written to at all.
	l, s = mk()
	close(l.closed)
	s.resetPeer()
	if got := sent(l); len(got) != 0 {
		t.Errorf("wrote %v to a carrier that is already down", got)
	}
}

// A reset must keep its place in the stream it names. Sent ahead of the data
// still queued, it would arrive first and truncate exactly what it was meant
// to tidy up after.
func TestAResetKeepsItsPlace(t *testing.T) {
	if jumpsQueue(cmdRST) {
		t.Error("a reset was allowed to overtake its own stream's data")
	}
}
