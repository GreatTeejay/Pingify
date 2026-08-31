//go:build !linux

package carrier

import (
	"net"

	"pingify/internal/config"
)

// Everywhere that is not Linux. There is no fq to ask for and no socket to
// pace; the tunnel only ever runs on Linux servers.

func smoothTheWire(cfg *config.Config) {}

func pace(pc net.PacketConn, cfg *config.Config, done <-chan struct{}, sent func() uint64) {}
