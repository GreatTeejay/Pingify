//go:build !linux

package main

import "net"

// Only Linux has sendmmsg. Everywhere else each packet is its own write, which
// is what the tests on a development machine exercise.
type icmpBatchWriter struct{ pc net.PacketConn }

func newICMPBatchWriter(pc net.PacketConn) *icmpBatchWriter {
	return &icmpBatchWriter{pc: pc}
}

func (w *icmpBatchWriter) write(pkts [][]byte, addr net.Addr) (int, error) {
	for i, p := range pkts {
		if _, err := w.pc.WriteTo(p, addr); err != nil {
			return i, err
		}
	}
	return len(pkts), nil
}
