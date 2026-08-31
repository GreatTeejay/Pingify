//go:build linux

package main

import (
	"net"
	"runtime"
	"syscall"
	"unsafe"
)

// Keeping other people's pings out of our socket.
//
// A raw ICMP socket receives every echo the host sees. Ours, everybody else's,
// every monitoring ping, every scanner - all of it arrives here and is sorted
// out in Go, one hash at a time. On a public address that is most of the work
// the transport does.
//
// The kernel will do the sorting for nothing. A socket filter runs before the
// packet is queued, so what does not match is never copied, never scheduled
// and never seen. This is the one thing flagtun did that the old core did not,
// and it is why its ICMP tunnel does not drown in the noise of its own
// address.
//
// Hand-assembled with the syscall package rather than written against a BPF
// library, because this core has no dependencies and is built from source on
// servers with no module proxy.
const (
	soAttachFilter = 26

	bpfLD   = 0x00
	bpfLDX  = 0x01
	bpfJMP  = 0x05
	bpfRET  = 0x06
	bpfB    = 0x10
	bpfH    = 0x08
	bpfIND  = 0x40
	bpfMSH  = 0xa0
	bpfJEQ  = 0x10
	bpfK    = 0x00
	bpfPass = 0xffffffff
)

type sockFilter struct {
	code uint16
	jt   uint8
	jf   uint8
	k    uint32
}

// Laid out to match the kernel's struct sock_fprog. The padding between the
// two fields is left to the compiler on purpose: Go aligns a struct the way C
// does, so this is right on every architecture, where writing the gap out by
// hand would be right on exactly the one it was written for.
type sockFprog struct {
	length uint16
	filter *sockFilter
}

// attachICMPFilter tells the kernel to deliver only echoes carrying our
// identifier, and to drop the rest before they arrive.
//
// Failing is not fatal: every check this replaces is still there in Go, and
// the filter only means they are reached far less often.
func attachICMPFilter(pc net.PacketConn, id uint16) error {
	sc, ok := pc.(syscall.Conn)
	if !ok {
		return errNoFilter
	}
	rc, err := sc.SyscallConn()
	if err != nil {
		return err
	}

	// The packet starts at the IP header, so the ICMP header's offset is the
	// header length the packet itself declares - not a guess at 20, which is
	// wrong the moment anything on the path adds an option.
	prog := []sockFilter{
		{code: bpfLDX | bpfB | bpfMSH, k: 0},        // X = IP header length
		{code: bpfLD | bpfB | bpfIND, k: 0},         // A = ICMP type
		{code: bpfJMP | bpfJEQ | bpfK, jt: 1, k: 0}, // echo reply? then check id
		{code: bpfJMP | bpfJEQ | bpfK, jf: 3, k: 8}, // echo request? else drop
		{code: bpfLD | bpfH | bpfIND, k: 4},         // A = ICMP identifier
		{code: bpfJMP | bpfJEQ | bpfK, jt: 1, k: uint32(id)},
		{code: bpfRET | bpfK, k: 0},       // not ours: drop
		{code: bpfRET | bpfK, k: bpfPass}, // ours: keep
	}
	fprog := sockFprog{length: uint16(len(prog)), filter: &prog[0]}

	var serr error
	if err := rc.Control(func(fd uintptr) {
		_, _, e := syscall.Syscall6(syscall.SYS_SETSOCKOPT, fd,
			uintptr(syscall.SOL_SOCKET), uintptr(soAttachFilter),
			uintptr(unsafe.Pointer(&fprog)), unsafe.Sizeof(fprog), 0)
		if e != 0 {
			serr = e
		}
	}); err != nil {
		return err
	}
	// prog must outlive the setsockopt call, and nothing after it refers to
	// the slice.
	runtime.KeepAlive(prog)
	return serr
}
