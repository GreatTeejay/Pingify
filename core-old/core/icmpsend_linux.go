//go:build linux

package main

import (
	"net"

	"golang.org/x/net/ipv4"
)

// ---------------------------------------------------------------------------
// putting several packets on the wire with one syscall
//
// The private link's direct path sends one packet per write, and on a busy
// link that is one syscall per packet in each direction. Profiled on a real
// server abroad carrying this tunnel, with the encryption off so nothing else
// could be blamed:
//
//	9.85%  finish_task_switch
//	8.64%  _raw_spin_unlock_irqrestore
//	2.30%  do_syscall_64
//
// No hot function of our own anywhere - the processor was going into the
// kernel and coming back, over and over, and switching threads while it did.
// A reference tunnel on the same path moved four times the packets for a third
// of the processor.
//
// sendmmsg is the answer to exactly that: hand the kernel a batch and cross
// once. The batch is opportunistic and never waits for one to fill - a sender
// takes whatever is queued at that instant, so a link with one packet on it
// sends one packet immediately and pays nothing, and a link under load sends
// sixty-four at a time and pays one crossing instead of sixty-four.
// ---------------------------------------------------------------------------

type icmpBatchWriter struct {
	pc *ipv4.PacketConn
	ms []ipv4.Message
}

func newICMPBatchWriter(pc net.PacketConn) *icmpBatchWriter {
	w := &icmpBatchWriter{
		pc: ipv4.NewPacketConn(pc),
		ms: make([]ipv4.Message, icmpSendBatch),
	}
	for i := range w.ms {
		w.ms[i].Buffers = make([][]byte, 1)
	}
	return w
}

// write sends up to len(pkts) packets to addr, and reports how many the kernel
// took. A short count is not an error: the caller keeps the rest for the next
// crossing rather than dropping them.
func (w *icmpBatchWriter) write(pkts [][]byte, addr net.Addr) (int, error) {
	n := len(pkts)
	if n > len(w.ms) {
		n = len(w.ms)
	}
	for i := 0; i < n; i++ {
		w.ms[i].Buffers[0] = pkts[i]
		w.ms[i].Addr = addr
	}
	return w.pc.WriteBatch(w.ms[:n], 0)
}
