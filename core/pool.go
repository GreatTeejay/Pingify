package main

import "sync"

// One buffer size, big enough for any datagram this tunnel sends, handed out
// and given back rather than allocated. At four hundred megabits the link
// moves something like forty thousand packets a second, and forty thousand
// allocations a second is work the collector then has to undo.
//
// A buffer always carries its carrier's headroom at the front. The layer above
// builds its packet after it, so a packet is written once and never shifted
// along to make room for a header that was known about all along.
const bufSize = 2048

var bufPool = sync.Pool{
	New: func() any {
		b := make([]byte, bufSize)
		return &b
	},
}

// takeBuf returns a buffer with room for a packet of n bytes behind head bytes
// of headroom, already sliced to the full length.
func takeBuf(head, n int) *[]byte {
	bp := bufPool.Get().(*[]byte)
	b := (*bp)[:cap(*bp)]
	if len(b) < head+n {
		b = make([]byte, head+n)
	}
	*bp = b[:head+n]
	return bp
}

// The replay window.
//
// A sliding bitmap, not a map swept once per packet. The counter of the
// newest packet seen sits at the top of the window, and each older one is a
// bit below it; a packet that arrives in order - which is nearly all of them -
// costs one shift and one bit set, and no allocation at all.
//
// The old core swept a map of counters on every packet to expire the ones
// that had fallen out of the window, which is O(window) per packet to learn
// something a shift already knows.
const (
	replayDepth = 4096
	replayWords = replayDepth / 64
)

type replayWindow struct {
	top   uint32 // the highest counter seen
	bits  [replayWords]uint64
	empty bool

	// What the far end sent that we did not get, and what arrived behind
	// something newer. The counter is consecutive at the sender, so a number
	// that is skipped is a packet the path lost - and that is not visible
	// anywhere else: not in a device counter, not in a qdisc, not in the
	// socket. It was found once by capturing at the far end and counting by
	// hand, and once was enough.
	skipped, late, gaps uint64
}

func newReplayWindow() *replayWindow { return &replayWindow{empty: true} }

// fresh reports whether this counter is one we have not already delivered,
// and records it. It is called from one goroutine only.
func (w *replayWindow) fresh(seq uint32) bool {
	if w.empty {
		w.empty = false
		w.top = seq
		w.set(0)
		return true
	}
	switch {
	case seq == w.top:
		return false
	case int32(seq-w.top) > 0:
		// Newer than anything seen. Drag the window forward, clearing the
		// bits that just fell off the bottom.
		if d := seq - w.top; d > 1 {
			w.skipped += uint64(d - 1)
			w.gaps++
		}
		w.shift(seq - w.top)
		w.top = seq
		w.set(0)
		return true
	default:
		w.late++
		back := w.top - seq
		if back >= replayDepth {
			return false // older than the window remembers; treat as replay
		}
		if w.get(back) {
			return false
		}
		w.set(back)
		return true
	}
}

func (w *replayWindow) get(back uint32) bool {
	return w.bits[back/64]&(1<<(back%64)) != 0
}

func (w *replayWindow) set(back uint32) {
	w.bits[back/64] |= 1 << (back % 64)
}

// shift moves every bit up by n places, which is what "the newest packet is
// now this one" means when the newest is the top of the window.
func (w *replayWindow) shift(n uint32) {
	if n >= replayDepth {
		w.bits = [replayWords]uint64{}
		return
	}
	words, bits := n/64, n%64
	if bits == 0 {
		for i := replayWords - 1; i >= 0; i-- {
			if uint32(i) >= words {
				w.bits[i] = w.bits[uint32(i)-words]
			} else {
				w.bits[i] = 0
			}
		}
		return
	}
	for i := replayWords - 1; i >= 0; i-- {
		var v uint64
		if uint32(i) >= words {
			v = w.bits[uint32(i)-words] << bits
			if uint32(i) > words {
				v |= w.bits[uint32(i)-words-1] >> (64 - bits)
			}
		}
		w.bits[i] = v
	}
}
