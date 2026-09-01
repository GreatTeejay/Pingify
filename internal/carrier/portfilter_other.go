//go:build !linux

package carrier

import "net"

func attachPortFilter(net.PacketConn, uint16) error { return errNoFilter }
