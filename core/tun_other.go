//go:build !linux

package main

import (
	"errors"
	"os"
)

// Kept so the package still compiles (and its tests still run) on a developer
// machine that is not Linux. tun mode itself is Linux-only by nature.
func openTUN(name string, multiqueue bool) (*os.File, error) {
	return nil, errors.New("tun mode is only available on Linux")
}
