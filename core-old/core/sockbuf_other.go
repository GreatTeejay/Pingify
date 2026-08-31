//go:build !linux

package main

import "net"

// Only Linux has the privileged form. Elsewhere the ordinary SetReadBuffer
// and SetWriteBuffer in tunePacketSocket are all there is.
func forceSocketBuffer(net.PacketConn, int, int) (int, int) { return 0, 0 }
