//go:build !linux

package link

import (
	"errors"
	"os"
)

// Everywhere that is not Linux. The tunnel only ever runs on Linux servers;
// these exist so that the rest of the core still compiles and its tests still
// run on a laptop.
const (
	deviceQueuesMin = 2
	deviceQueuesMax = 8
)

var errNoTUN = errors.New("a tun device needs Linux")

func openTUN(name string, multi bool) (*os.File, error) { return nil, errNoTUN }

func configureDevice(name, addr string, mtu int) error { return errNoTUN }
