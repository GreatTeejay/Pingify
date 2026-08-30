//go:build !linux

package main

import "net"

// Only Linux has TCP_USER_TIMEOUT. Elsewhere the carrier keeps the kernel's
// default behaviour, which is what the tests on a development machine see.
func setUserTimeout(net.Conn) {}
