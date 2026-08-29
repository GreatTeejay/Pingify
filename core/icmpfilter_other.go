//go:build !linux

package main

import "net"

// Everywhere else the sorting stays in Go, which is where it was before this
// existed. Only Linux has the socket filter, and only Linux runs these tunnels.
func attachICMPFilter(pc net.PacketConn, id uint16) error { return errNoFilter }
