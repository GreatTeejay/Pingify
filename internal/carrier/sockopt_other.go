//go:build !linux

package carrier

import (
	"net"
	"time"

	"pingify/internal/config"
)

// Everywhere that is not Linux. The tunnel only runs on Linux servers; these
// exist so the rest of the core still compiles and its tests still run on a
// laptop.

func tuneSocket(pc net.PacketConn, cfg *config.Config) {}

func attachICMPFilter(pc net.PacketConn, id uint16) error { return errNoFilter }

func setUserTimeout(tc *net.TCPConn, d time.Duration) {}
