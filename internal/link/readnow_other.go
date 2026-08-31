//go:build !linux

package link

import (
	"os"
	"syscall"
)

// Everywhere that is not Linux: never take a second packet without waiting,
// which leaves batches of one and is correct if slower.

func rawOf(f *os.File) syscall.RawConn { return nil }

func readNow(rc syscall.RawConn, b []byte) (int, bool) { return 0, false }
