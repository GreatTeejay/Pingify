//go:build linux

package main

import (
	"testing"
	"unsafe"
)

// The kernel reads these two structs by offset, so their shape is a contract,
// not a detail. sock_filter is 8 bytes on every architecture; sock_fprog is a
// short and a pointer with whatever padding that architecture needs, which is
// the compiler's job and not ours to spell out.
func TestTheFilterStructsMatchWhatTheKernelReads(t *testing.T) {
	if got := unsafe.Sizeof(sockFilter{}); got != 8 {
		t.Fatalf("sock_filter is %d bytes, the kernel reads 8", got)
	}
	var f sockFilter
	if o := unsafe.Offsetof(f.jt); o != 2 {
		t.Fatalf("jt is at %d, the kernel reads 2", o)
	}
	if o := unsafe.Offsetof(f.k); o != 4 {
		t.Fatalf("k is at %d, the kernel reads 4", o)
	}

	var p sockFprog
	if o := unsafe.Offsetof(p.filter); o != unsafe.Alignof(p.filter) {
		t.Fatalf("the filter pointer is at %d, not on its own alignment (%d)",
			o, unsafe.Alignof(p.filter))
	}
	want := unsafe.Alignof(p.filter) + unsafe.Sizeof(p.filter)
	if got := unsafe.Sizeof(p); got != want {
		t.Fatalf("sock_fprog is %d bytes, want %d on this architecture", got, want)
	}
}
