package carrier

import (
	"encoding/binary"
	"sync"
	"sync/atomic"

	"pingify/internal/buf"
	"pingify/internal/logging"
)

// Repairing a lost packet without asking for it again.
//
// Every datagram carrier here loses packets, because that is what a path does
// and none of them pretend otherwise: the TCP inside the tunnel notices a
// round trip later and asks again. On an eighty millisecond path, a third of a
// percent of loss is a third of a percent of every transfer waiting a sixth of
// a second for something it had already sent.
//
// This is the other answer. Every N packets, one more goes out that is the
// exclusive-or of those N. Lose any one of the N and the far end rebuilds it
// from the rest and the parity, at once, with nothing asked for and no round
// trip. Lose two out of the same N and the parity is no help, and TCP does
// what it would have done anyway.
//
// It costs one packet in N of bandwidth and nothing else.
//
// It is a wrapper around a carrier rather than a layer inside one, which is
// what keeps it away from the transports with no use for it: a stream carrier
// cannot lose a packet, so it is never wrapped.
const (
	// kind, group, index. Four bytes in front of every packet, and the group
	// is its own field rather than something worked out from the framer's
	// sequence number because this sits above the framer and cannot see it.
	fecHdr    = 4
	fecData   = 0
	fecParity = 1

	fecMinGroup = 4
	fecMaxGroup = 32

	// How many groups the receiver keeps at once. A packet and the parity for
	// its group can arrive a little apart, and this is how much reordering
	// that tolerates before the group is given up on.
	fecGroups = 8
)

type fecCarrier struct {
	Full
	n int

	// The sending side. The lock is not optional: a carrier may have one
	// sender per device queue, and two of them filling one group would fold
	// each other's packets into the same parity.
	mu     sync.Mutex
	parity []byte
	group  uint16
	index  uint8

	rx       *fecRecovery
	repaired uint64
	onPacket atomic.Pointer[func([]byte)]
}

// WrapFEC puts parity on a carrier, or returns it untouched when the transport
// cannot take it - see noParity, which is where the two reasons are written
// down.
func WrapFEC(c Full, n int, blocked bool) Full {
	if n <= 0 || blocked {
		return c
	}
	if n < fecMinGroup {
		n = fecMinGroup
	}
	if n > fecMaxGroup {
		n = fecMaxGroup
	}
	f := &fecCarrier{Full: c, n: n, rx: newFECRecovery()}
	c.OnPacket(f.fromWire)
	logging.Info("forward error correction: one parity packet per %d", n)
	return f
}

func (f *fecCarrier) Headroom() int   { return f.Full.Headroom() + fecHdr }
func (f *fecCarrier) MaxPayload() int { return f.Full.MaxPayload() - fecHdr }

func (f *fecCarrier) OnPacket(fn func([]byte)) { f.onPacket.Store(&fn) }

func (f *fecCarrier) Send(bp *[]byte) error {
	grp, n, par := f.stamp(*bp)
	err := f.Full.Send(bp)
	if par != nil {
		f.sendParity(grp, n, par)
	}
	return err
}

func (f *fecCarrier) NewSender() Sender {
	return &fecSender{f: f, inner: f.Full.NewSender()}
}

type fecSender struct {
	f     *fecCarrier
	inner Sender
}

// The parity goes out after the packets it covers, not before.
//
// It was sent from inside the stamping, which put it on the wire ahead of the
// last packet of its own group - so the far end saw a group one short, decided
// that one was lost, rebuilt it perfectly, delivered it, and then delivered
// the real one when it arrived a moment later. Every group, with no loss
// anywhere: a duplicate of every tenth packet.
func (s *fecSender) Send(bps []*[]byte) {
	type parcel struct {
		grp uint16
		n   uint8
		p   []byte
	}
	var out []parcel
	for _, bp := range bps {
		if grp, n, par := s.f.stamp(*bp); par != nil {
			out = append(out, parcel{grp, n, par})
		}
	}
	s.inner.Send(bps)
	for _, o := range out {
		s.f.sendParity(o.grp, o.n, o.p)
	}
}

// stamp writes this packet's header, folds it into the parity being built,
// and sends that parity when the group is full.
//
// The fold happens here rather than afterwards because the buffer goes back
// to the pool the moment the carrier below has written it: the parity has to
// be accumulated as the packets go past, not built from them later.
func (f *fecCarrier) stamp(b []byte) (uint16, uint8, []byte) {
	head := f.Full.Headroom()
	if len(b) < head+fecHdr {
		return 0, 0, nil
	}
	body := b[head+fecHdr:]

	f.mu.Lock()
	b[head] = fecData
	binary.BigEndian.PutUint16(b[head+1:head+3], f.group)
	b[head+3] = f.index

	f.foldIn(body)
	f.index++
	var out []byte
	var grp uint16
	var n uint8
	if int(f.index) >= f.n {
		out = append([]byte(nil), f.parity...)
		grp, n = f.group, f.index
		f.group++
		f.index = 0
		f.parity = f.parity[:0]
	}
	f.mu.Unlock()
	return grp, n, out
}

// foldIn folds one payload into the parity. Its length goes in with it, in two
// bytes at the front, because the packets in a group are not all the same size
// and the far end has to know how long the one it rebuilds was.
func (f *fecCarrier) foldIn(body []byte) {
	need := 2 + len(body)
	for len(f.parity) < need {
		f.parity = append(f.parity, 0)
	}
	var l [2]byte
	binary.BigEndian.PutUint16(l[:], uint16(len(body)))
	f.parity[0] ^= l[0]
	f.parity[1] ^= l[1]
	for i, c := range body {
		f.parity[2+i] ^= c
	}
}

func (f *fecCarrier) sendParity(group uint16, n uint8, p []byte) {
	head := f.Full.Headroom()
	bp := buf.Take(head, fecHdr+len(p))
	b := *bp
	b[head] = fecParity
	binary.BigEndian.PutUint16(b[head+1:head+3], group)
	b[head+3] = n
	copy(b[head+fecHdr:], p)
	_ = f.Full.Send(bp)
}

// fromWire is every datagram the carrier below received. It runs on that
// carrier's read goroutine, which is what lets the recovery state below have
// no lock on it.
func (f *fecCarrier) fromWire(b []byte) {
	if len(b) < fecHdr {
		return
	}
	kind := b[0]
	group := binary.BigEndian.Uint16(b[1:3])
	idx := b[3]
	body := b[fecHdr:]

	if kind == fecData {
		f.up(body)
		f.rx.data(group, idx, body)
		return
	}
	if rebuilt := f.rx.parity(group, idx, body); rebuilt != nil {
		atomic.AddUint64(&f.repaired, 1)
		f.up(rebuilt)
	}
}

func (f *fecCarrier) up(b []byte) {
	if fn := f.onPacket.Load(); fn != nil {
		(*fn)(b)
	}
}

// Repaired is how many packets came back from parity rather than from the
// wire, which is the one number that says whether this is earning its
// bandwidth.
func (f *fecCarrier) Repaired() uint64 { return atomic.LoadUint64(&f.repaired) }

// --------------------------------------------------------------------------
// the receiving side
// --------------------------------------------------------------------------

// One group being watched: what has arrived, folded together, and how much of
// it. A group is finished the moment its parity can be used or the moment its
// slot is needed for a newer one.
type fecGroup struct {
	id    uint16
	used  bool
	seen  uint8  // how many data packets of this group arrived
	want  uint8  // how many there are, once the parity says so
	acc   []byte // the exclusive-or of what arrived, lengths included
	done  bool
	scrap []byte
}

type fecRecovery struct {
	groups [fecGroups]fecGroup
}

func newFECRecovery() *fecRecovery { return &fecRecovery{} }

// slot finds the entry for a group, taking over the oldest if this is a group
// nothing has been seen of yet.
func (r *fecRecovery) slot(id uint16) *fecGroup {
	var free *fecGroup
	for i := range r.groups {
		g := &r.groups[i]
		if g.used && g.id == id {
			return g
		}
		if !g.used {
			free = g
		}
	}
	if free == nil {
		// The oldest, by the distance the group counter has moved since.
		oldest := &r.groups[0]
		for i := range r.groups {
			if int16(id-r.groups[i].id) > int16(id-oldest.id) {
				oldest = &r.groups[i]
			}
		}
		free = oldest
	}
	*free = fecGroup{id: id, used: true, acc: free.acc[:0], scrap: free.scrap}
	return free
}

func (r *fecRecovery) data(id uint16, _ uint8, body []byte) {
	g := r.slot(id)
	if g.done {
		return
	}
	foldInto(&g.acc, body)
	g.seen++
	// Nothing to do until the parity says how many there were.
}

// parity folds the parity in and, if exactly one packet of the group is
// missing, hands back what it was.
func (r *fecRecovery) parity(id uint16, n uint8, body []byte) []byte {
	g := r.slot(id)
	if g.done || n == 0 {
		return nil
	}
	g.want = n
	if g.seen != n-1 {
		// Either everything arrived - nothing to repair - or more than one is
		// missing, which one parity packet cannot recover.
		g.done = true
		return nil
	}
	// The accumulator holds the exclusive-or of the packets that arrived,
	// each with its length in front. Folding the parity in leaves exactly the
	// one that did not.
	acc := g.acc
	for len(acc) < len(body) {
		acc = append(acc, 0)
	}
	g.scrap = g.scrap[:0]
	for i := range acc {
		var c byte
		if i < len(body) {
			c = body[i]
		}
		g.scrap = append(g.scrap, acc[i]^c)
	}
	g.acc = acc
	g.done = true

	if len(g.scrap) < 2 {
		return nil
	}
	l := int(binary.BigEndian.Uint16(g.scrap[0:2]))
	if l <= 0 || l > len(g.scrap)-2 {
		return nil
	}
	return g.scrap[2 : 2+l]
}

func foldInto(acc *[]byte, body []byte) {
	need := 2 + len(body)
	for len(*acc) < need {
		*acc = append(*acc, 0)
	}
	a := *acc
	var l [2]byte
	binary.BigEndian.PutUint16(l[:], uint16(len(body)))
	a[0] ^= l[0]
	a[1] ^= l[1]
	for i, c := range body {
		a[2+i] ^= c
	}
}
