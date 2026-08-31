//go:build linux

package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"unsafe"
)

// The device, opened the only way Linux offers: /dev/net/tun and one ioctl.
const (
	tunsetiff       = 0x400454ca
	iffTun          = 0x0001
	iffNoPI         = 0x1000
	iffMultiQueue   = 0x0100
	ifNameSize      = 16
	ifreqSize       = 40
	deviceQueuesMin = 2
	deviceQueuesMax = 8
)

// openTUN attaches one queue to the named device, creating it if this is the
// first. Every queue after the first must ask for multi-queue too, and so must
// the first, which is why the flag is not conditional on the count here.
func openTUN(name string, multi bool) (*os.File, error) {
	f, err := os.OpenFile("/dev/net/tun", os.O_RDWR, 0)
	if err != nil {
		return nil, fmt.Errorf("open /dev/net/tun: %v (is the tun module loaded?)", err)
	}
	if len(name) >= ifNameSize {
		f.Close()
		return nil, fmt.Errorf("device name %q is too long", name)
	}

	var req [ifreqSize]byte
	copy(req[:ifNameSize-1], name)
	flags := uint16(iffTun | iffNoPI)
	if multi {
		flags |= iffMultiQueue
	}
	*(*uint16)(unsafe.Pointer(&req[ifNameSize])) = flags

	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(), tunsetiff,
		uintptr(unsafe.Pointer(&req[0]))); e != 0 {
		f.Close()
		return nil, fmt.Errorf("attach to %s: %v", name, e)
	}
	return f, nil
}

// configureDevice gives the interface its address and brings it up, by asking
// iproute2 rather than by opening a netlink socket. It runs once at startup,
// where a fork costs nothing and a hand-rolled netlink implementation would
// cost several hundred lines that only ever run once.
func configureDevice(name, addr string, mtu int) error {
	run := func(args ...string) error {
		out, err := exec.Command("ip", args...).CombinedOutput()
		if err != nil {
			return fmt.Errorf("ip %s: %v: %s",
				strings.Join(args, " "), err, strings.TrimSpace(string(out)))
		}
		return nil
	}
	if err := run("link", "set", "dev", name, "mtu", fmt.Sprint(mtu), "up"); err != nil {
		return err
	}
	return run("addr", "add", addr, "dev", name)
}
