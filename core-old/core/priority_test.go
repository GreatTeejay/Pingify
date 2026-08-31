package main

import (
	"testing"
	"time"
)

// A keepalive must not queue behind somebody's download.
//
// sendQ holds 128 records of up to 32 KiB, so a ping handed to it could sit
// behind four megabytes - a third of a second on a hundred-megabit path,
// before the wire has seen it. That delay is what the tunnel reports as its
// round-trip time, and what a video stutters on while a file copies.
func TestControlDoesNotQueueBehindBulk(t *testing.T) {
	l := &link{
		idx:    0,
		closed: make(chan struct{}),
		sendQ:  make(chan *recBuf, 4),
		priQ:   make(chan *recBuf, 4),
	}
	defer close(l.closed)

	// Fill the bulk queue to the brim, the way a transfer does.
	for i := 0; i < cap(l.sendQ); i++ {
		if !l.send(ctrlRec(cmdData, 1, []byte("payload"))) {
			t.Fatal("could not fill the bulk queue")
		}
	}
	if len(l.sendQ) != cap(l.sendQ) {
		t.Fatalf("bulk queue holds %d of %d", len(l.sendQ), cap(l.sendQ))
	}

	// A ping offered now must not block, and must not be behind those.
	done := make(chan bool, 1)
	go func() { done <- l.send(ctrlRec(cmdPing, 0, make([]byte, 8))) }()
	select {
	case ok := <-done:
		if !ok {
			t.Fatal("the ping was refused")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("the ping blocked behind a full bulk queue - the thing this exists to prevent")
	}
	if len(l.priQ) != 1 {
		t.Fatalf("the ping went to the bulk queue, not past it")
	}
}

// Which records may go first, and which must keep their place.
func TestOnlyPositionlessRecordsJumpTheQueue(t *testing.T) {
	for _, c := range []struct {
		cmd  byte
		name string
		jump bool
		why  string
	}{
		{cmdPing, "ping", true, "means the same whenever it arrives"},
		{cmdPong, "pong", true, "answers a ping and carries nothing else"},
		{cmdWND, "window credit", true, "a total, not a position - a later one supersedes it"},
		{cmdData, "data", false, "has a place in its stream"},
		{cmdSYN, "open", false, "everything in that stream follows it"},
		{cmdFIN, "close", false, "overtaking data would truncate the stream"},
		{cmdRST, "reset", false, "kept with its stream for the same reason"},
		{cmdTUN, "a tun packet", false, "ordered like any other payload"},
	} {
		t.Run(c.name, func(t *testing.T) {
			if got := jumpsQueue(c.cmd); got != c.jump {
				t.Fatalf("jumpsQueue(%s) = %v, want %v - %s", c.name, got, c.jump, c.why)
			}
		})
	}
}

// A link built without the second queue still sends. Blocking for ever on a
// nil channel is not a failure any caller here is prepared for.
func TestALinkWithoutThePriorityQueueStillSends(t *testing.T) {
	l := &link{idx: 0, closed: make(chan struct{}), sendQ: make(chan *recBuf, 2)}
	defer close(l.closed)

	done := make(chan bool, 1)
	go func() { done <- l.send(ctrlRec(cmdPing, 0, make([]byte, 8))) }()
	select {
	case ok := <-done:
		if !ok {
			t.Fatal("refused")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("a link with no priority queue blocked on it")
	}
	if len(l.sendQ) != 1 {
		t.Fatal("the ping did not fall back to the ordinary queue")
	}
}
