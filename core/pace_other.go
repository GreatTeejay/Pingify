//go:build !linux

package main

import "net"

// Everywhere that is not Linux. There is no fq to ask for and no socket to
// pace; the tunnel only ever runs on Linux servers.

func smoothTheWire(cfg *Config) {}

func pace(pc net.PacketConn, cfg *Config, done <-chan struct{}, sent func() uint64) {}
