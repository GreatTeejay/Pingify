//go:build linux

package main

import (
	"net"
	"syscall"
	"unsafe"
)

// ---------------------------------------------------------------------------
// keeping other people's pings out of our socket
//
// A raw ICMP socket receives every echo the host sees. Ours, everybody else's,
// every monitoring ping, every scanner - all of it arrives here and is sorted
// out in Go, one HMAC at a time. On a public address that is most of the work
// the transport does, and it is worse than wasted: a stray for a session this
// end has already forgotten used to have a whole ARQ connection built for it,
// with a goroutine and a ten millisecond ticker, and nothing ever took it away.
//
// The kernel can do this sorting for nothing. A socket filter runs before the
// packet is ever queued, so what does not match is not copied, not scheduled,
// and not seen. This is the one thing flagtun does that we did not, and it is
// the reason its ICMP tunnel does not drown in the noise of its own address.
//
// Written with the syscall package and a hand-assembled program rather than a
// BPF library, because this core compiles from source on a server with no
// module proxy, and one dependency is one more thing that has to be there.
// ---------------------------------------------------------------------------

const (
	soAttachFilter = 26

	// classic BPF, the pieces this program needs
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
// two fields is left to the compiler on purpose: Go aligns a struct the same
// way C does, so this is right on every architecture, where writing the gap
// out by hand would be right on exactly the one it was written for.
type sockFprog struct {
	length uint16
	filter *sockFilter
}

// attachICMPFilter tells the kernel to deliver only echo requests and replies
// carrying our identifier, and to drop everything else before it arrives.
//
// Failing is not fatal. Every check this replaces is still there in Go - the
// filter only means they are reached far less often - so a kernel that will
// not take it costs performance and nothing else.
func attachICMPFilter(pc net.PacketConn, id uint16) error {
	raw, ok := pc.(interface {
		SyscallConn() (syscall.RawConn, error)
	})
	if !ok {
		return errNoFilter
	}
	rc, err := raw.SyscallConn()
	if err != nil {
		return err
	}

	// The packet starts at the IP header, so the ICMP header's offset is the
	// header length the packet itself declares - not a guess at 20, which is
	// wrong the moment anything on the path adds an option.
	prog := []sockFilter{
		{code: bpfLDX | bpfB | bpfMSH, k: 0},        // X = IP header length
		{code: bpfLD | bpfB | bpfIND, k: 0},         // A = ICMP type
		{code: bpfJMP | bpfJEQ | bpfK, jt: 1, k: 0}, // echo reply?
		{code: bpfJMP | bpfJEQ | bpfK, jf: 3, k: 8}, // echo request? else drop
		{code: bpfLD | bpfH | bpfIND, k: 4},         // A = ICMP identifier
		{code: bpfJMP | bpfJEQ | bpfK, jf: 1, k: uint32(id)},
		{code: bpfRET | bpfK, k: bpfPass},
		{code: bpfRET | bpfK, k: 0},
	}
	fprog := sockFprog{length: uint16(len(prog)), filter: &prog[0]}

	var serr error
	err = rc.Control(func(fd uintptr) {
		_, _, e := syscall.Syscall6(syscall.SYS_SETSOCKOPT, fd,
			uintptr(syscall.SOL_SOCKET), uintptr(soAttachFilter),
			uintptr(unsafe.Pointer(&fprog)), unsafe.Sizeof(fprog), 0)
		if e != 0 {
			serr = e
		}
	})
	if err != nil {
		return err
	}
	// prog must outlive the syscall; naming it here says so to the reader as
	// well as to the compiler.
	runtimeKeepAlive(prog)
	return serr
}
