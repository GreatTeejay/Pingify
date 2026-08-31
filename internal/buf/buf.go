package buf

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

// Put hands a buffer back. It is a function rather than the pool itself so
// that nothing outside can reach past it.
func Put(bp *[]byte) { pool.Put(bp) }

var pool = sync.Pool{
	New: func() any {
		b := make([]byte, bufSize)
		return &b
	},
}

// Take returns a buffer with room for a packet of n bytes behind head bytes
// of headroom, already sliced to the full length.
func Take(head, n int) *[]byte {
	bp := pool.Get().(*[]byte)
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
	ReplayDepth = 4096
	replayWords = ReplayDepth / 64
)

type ReplayWindow struct {
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

func NewReplayWindow() *ReplayWindow { return &ReplayWindow{empty: true} }

// Lost is what the far end sent that never arrived, what arrived behind
// something newer, and how many separate runs the missing packets came in.
//
// The last of those is the one that matters. Losses spread one at a time are
// noise a congestion window shrugs off; the same number arriving in runs is a
// window halved once per run.
func (w *ReplayWindow) Lost() (missing, late, gaps uint64) {
	return w.skipped, w.late, w.gaps
}

// Fresh reports whether this counter is one we have not already delivered,
// and records it. It is called from one goroutine only.
func (w *ReplayWindow) Fresh(seq uint32) bool {
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
		if back >= ReplayDepth {
			return false // older than the window remembers; treat as replay
		}
		if w.get(back) {
			return false
		}
		w.set(back)
		return true
	}
}

func (w *ReplayWindow) get(back uint32) bool {
	return w.bits[back/64]&(1<<(back%64)) != 0
}

func (w *ReplayWindow) set(back uint32) {
	w.bits[back/64] |= 1 << (back % 64)
}

// shift moves every bit up by n places, which is what "the newest packet is
// now this one" means when the newest is the top of the window.
func (w *ReplayWindow) shift(n uint32) {
	if n >= ReplayDepth {
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
