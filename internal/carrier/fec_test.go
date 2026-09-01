package carrier

import (
	"time"

	"bytes"
	"pingify/internal/buf"
	"testing"
)

// The parity as the sending side builds it: every payload folded in with its
// length in front of it.
func parityOf(pkts [][]byte) []byte {
	var acc []byte
	for _, p := range pkts {
		foldInto(&acc, p)
	}
	return acc
}

func TestAMissingPacketComesBackFromTheParity(t *testing.T) {
	pkts := [][]byte{
		[]byte("the first one"),
		bytes.Repeat([]byte{0xAB}, 300),
		[]byte("short"),
		bytes.Repeat([]byte{0x11, 0x22}, 600),
	}
	par := parityOf(pkts)

	// Every packet in turn is the one that goes missing.
	for drop := range pkts {
		r := newFECRecovery()
		for i, p := range pkts {
			if i == drop {
				continue
			}
			r.data(7, uint8(i), p)
		}
		got := r.parity(7, uint8(len(pkts)), par)
		if !bytes.Equal(got, pkts[drop]) {
			t.Fatalf("packet %d: rebuilt %d bytes, wanted %d", drop, len(got), len(pkts[drop]))
		}
	}
}

func TestNothingIsRebuiltWhenNothingIsMissing(t *testing.T) {
	pkts := [][]byte{[]byte("a"), []byte("bb"), []byte("ccc"), []byte("dddd")}
	r := newFECRecovery()
	for i, p := range pkts {
		r.data(1, uint8(i), p)
	}
	if got := r.parity(1, uint8(len(pkts)), parityOf(pkts)); got != nil {
		t.Fatalf("rebuilt %q when the group was complete", got)
	}
}

// One parity packet repairs one loss. Two is what TCP is for, and pretending
// otherwise would hand the link a packet made of two half packets.
func TestTwoMissingIsNotRepaired(t *testing.T) {
	pkts := [][]byte{[]byte("a"), []byte("bb"), []byte("ccc"), []byte("dddd")}
	r := newFECRecovery()
	r.data(2, 0, pkts[0])
	r.data(2, 1, pkts[1])
	if got := r.parity(2, uint8(len(pkts)), parityOf(pkts)); got != nil {
		t.Fatalf("rebuilt %q from a group missing two", got)
	}
}

// The parity for a group can arrive before some of its packets do, and a
// group nobody finished must not hold a slot for ever.
func TestOldGroupsAreGivenUp(t *testing.T) {
	r := newFECRecovery()
	for g := 0; g < fecGroups*3; g++ {
		r.data(uint16(g), 0, []byte("x"))
	}
	// The first group is long gone; asking about it must not find stale
	// state and must not rebuild anything from it.
	if got := r.parity(0, 4, []byte("whatever")); got != nil {
		t.Fatalf("rebuilt %q out of a group that had been given up", got)
	}
}

// A carrier that hands whatever is sent straight back to the receiver, so the
// wrapper's own send and receive paths meet each other.
type loopCarrier struct {
	head int
	on   func([]byte)
	sent [][]byte
	drop int // the nth packet is thrown away, 0 for none
	n    int
}

func (l *loopCarrier) Headroom() int                    { return l.head }
func (l *loopCarrier) MaxPayload() int                  { return 1400 }
func (l *loopCarrier) Burst() int                       { return 1 }
func (l *loopCarrier) Up() bool                         { return true }
func (l *loopCarrier) Close() error                     { return nil }
func (l *loopCarrier) Run()                             {}
func (l *loopCarrier) Keepalive(time.Duration)          {}
func (l *loopCarrier) Counters() (a, b, c, d, e uint64) { return }
func (l *loopCarrier) Lost() (a, b, c uint64)           { return }
func (l *loopCarrier) OnPacket(f func([]byte))          { l.on = f }
func (l *loopCarrier) NewSender() Sender                { return loopSender{l} }

func (l *loopCarrier) Send(bp *[]byte) error {
	b := *bp
	body := append([]byte(nil), b[l.head:]...)
	l.n++
	l.sent = append(l.sent, body)
	if l.n != l.drop && l.on != nil {
		l.on(body)
	}
	buf.Put(bp)
	return nil
}

type loopSender struct{ l *loopCarrier }

func (s loopSender) Send(bps []*[]byte) {
	for _, bp := range bps {
		_ = s.l.Send(bp)
	}
}

// The wrapper has to hand every packet upward untouched, and rebuild the one
// the carrier under it threw away.
func TestTheWrapperCarriesAndRepairs(t *testing.T) {
	for _, drop := range []int{0, 3} {
		lc := &loopCarrier{head: 12, drop: drop}
		f := WrapFEC(lc, 10, false)
		var got [][]byte
		f.OnPacket(func(b []byte) { got = append(got, append([]byte(nil), b...)) })

		var want [][]byte
		s := f.NewSender()
		for i := 0; i < 10; i++ {
			payload := bytes.Repeat([]byte{byte(i + 1)}, 40+i)
			want = append(want, payload)
			bp := buf.Take(f.Headroom(), len(payload))
			copy((*bp)[f.Headroom():], payload)
			s.Send([]*[]byte{bp})
		}
		if len(got) != len(want) {
			t.Fatalf("drop %d: %d packets arrived, wanted %d", drop, len(got), len(want))
		}
		// Order can differ when one was rebuilt from the parity, so compare
		// as a set of contents.
		for i := range want {
			found := false
			for j := range got {
				if bytes.Equal(want[i], got[j]) {
					found = true
					break
				}
			}
			if !found {
				t.Fatalf("drop %d: packet %d never arrived", drop, i)
			}
		}
	}
}
