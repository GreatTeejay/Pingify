package carrier

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"hash"
	"sync"
	"sync/atomic"

	"pingify/internal/buf"
)

// What every packet carrier puts in front of a packet, and the only thing they
// share.
//
// Twelve bytes: eight of tag, four of counter.
//
//	0                 8                12
//	+-----------------+----------------+-----------------------------+
//	|  tag            |  counter       |  the IP packet              |
//	+-----------------+----------------+-----------------------------+
//
// The tag says a datagram is ours. Anyone can send to an open UDP port and
// anyone at all can send an echo request, so without it the first thing a
// scanner sends would be handed to the kernel as an IP packet.
//
// It is one hash over the counter and the first bytes of the packet - not the
// whole packet, which at four hundred megabits would mean hashing fifty
// megabytes a second to learn what the first thirty-two bytes already say. One
// hash per packet, not two: the old core built a second tag it then checked in
// a different order, and that was pure cost.
//
// There is no encryption and none is wanted. What travels through this tunnel
// is already TLS, and what is asked of the tunnel is speed, ping and stability.
const (
	tagLen   = 8
	seqLen   = 4
	frameLen = tagLen + seqLen
	tagOver  = 32 // how many bytes of the payload the tag covers
)

type framer struct {
	key  []byte
	hp   sync.Pool // hash.Hash, kept rather than made per packet
	seq  uint32
	seen *buf.ReplayWindow

	badTag, replayed uint64
}

// lost reports what the far end sent that never arrived, and what arrived out
// of order. Both are counted from the sequence number, which is consecutive at
// the sender - so a gap in it is the one measure of the path that no counter
// on either machine will show.
func (f *framer) lost() (missing, late, gaps uint64) {
	return f.seen.Lost()
}

// newFramer derives this carrier's key from the token the user typed.
//
// Each carrier passes its own label, so a datagram built for one can never be
// mistaken for a datagram built for another - which matters the moment two
// tunnels between the same pair of servers are given the same token.
func newFramer(token, label string) *framer {
	m := hmac.New(sha256.New, []byte(label))
	m.Write([]byte(token))
	f := &framer{key: m.Sum(nil), seen: buf.NewReplayWindow()}
	f.hp.New = func() any { return hmac.New(sha256.New, f.key) }
	return f
}

func (f *framer) headroom() int { return frameLen }

// covered is the part of a frame the tag is computed over: the counter, and as
// much of the packet as tagOver allows.
func covered(b []byte) []byte {
	if len(b) > frameLen+tagOver {
		return b[tagLen : frameLen+tagOver]
	}
	return b[tagLen:]
}

func (f *framer) tag(dst, over []byte) {
	m := f.hp.Get().(hash.Hash)
	m.Reset()
	m.Write(over)
	var sum [sha256.Size]byte
	copy(dst, m.Sum(sum[:0])[:tagLen])
	f.hp.Put(m)
}

// seal stamps a frame with the next counter and its tag. b starts at the tag,
// so a carrier with a header of its own passes the slice after that header.
func (f *framer) seal(b []byte) {
	binary.BigEndian.PutUint32(b[tagLen:frameLen], atomic.AddUint32(&f.seq, 1))
	f.tag(b[:tagLen], covered(b))
}

// open checks a frame and returns what was inside it. The second result is
// false for anything that is not ours or that has already been delivered.
//
// It is called from one goroutine, which is what lets the replay window be a
// plain sliding bitmap with no lock on it.
func (f *framer) open(b []byte) ([]byte, bool) {
	if len(b) < frameLen {
		return nil, false
	}
	var want [tagLen]byte
	f.tag(want[:], covered(b))
	if !hmac.Equal(want[:], b[:tagLen]) {
		f.badTag++
		return nil, false
	}
	if !f.seen.Fresh(binary.BigEndian.Uint32(b[tagLen:frameLen])) {
		f.replayed++
		return nil, false
	}
	return b[frameLen:], true
}
