package main

// A carrier moves whole messages between the two servers.
//
// There are two kinds and the difference is not a detail. A packet carrier -
// UDP, and ICMP after it - can lose a message and can deliver two out of
// order. A stream carrier - TCP, and the things dressed up as TCP - can do
// neither, and pays for that in head-of-line blocking.
//
// Which one is underneath decides what has to ride on top, so the choice is
// made here, once, and is not rediscovered in every layer above. That was the
// structural mistake in the old core: the private link was built on a stream
// multiplexer it never needed, and the path that skips the multiplexer had to
// be bolted on beside it afterwards.
//
// The private link wants a packet carrier and nothing else. One IP packet is
// one datagram; if it is lost, the TCP inside it will notice long before we
// could, and if it arrives out of order, that is what IP has always been
// allowed to do.
type packetCarrier interface {
	// Headroom is how many bytes at the front of a buffer belong to the
	// carrier. The layer above builds its packet after them, so that a packet
	// is written once and never shifted along to make room for a header.
	Headroom() int

	// MaxPayload is the largest packet this carrier will take, after the
	// headroom has been subtracted.
	MaxPayload() int

	// Send puts one datagram on the wire, on its own. It takes ownership of
	// the buffer: after Send returns the caller must not look at it again,
	// whatever the error says. This is for keepalives and nothing else - the
	// data path uses a sender.
	Send(bp *[]byte) error

	// NewSender returns somewhere to send batches from. One per goroutine
	// that sends, because a sender holds the arrays the kernel is handed and
	// two goroutines sharing them would hand it each other's packets.
	//
	// Batching used to live behind a channel here, with one goroutine draining
	// it. That is the obvious design and it is wrong: one flow is read by one
	// device queue, so every packet of it crossed the channel and waited to be
	// scheduled on the other side. Sixteen streams did not care - there was
	// always something to batch - but a single stream fell from 245 Mbit/s to
	// 164, because a single stream is exactly the case where the queue is
	// always empty and the handoff is pure cost.
	//
	// So the goroutine that read the packets sends them. Nothing is handed
	// over and nothing is woken.
	NewSender() packetSender

	// OnPacket registers what to do with each datagram that arrives. It is
	// called on the goroutine that read the datagram off the socket, and the
	// slice it is given stops being valid when it returns.
	OnPacket(func(b []byte))

	// Up reports whether the carrier knows where to send. On the side that
	// dials this is true from the start; on the side that waits it becomes
	// true when the first datagram carrying the right tag arrives.
	Up() bool

	Close() error
}

// A packetSender puts a batch of packets on the wire in one crossing into the
// kernel. It belongs to one goroutine and is not safe for two.
type packetSender interface {
	// send takes ownership of every buffer in the batch, and returns them to
	// the pool however it goes.
	send(bps []*[]byte)
}
