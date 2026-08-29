package main

import (
	"encoding/binary"
	"errors"
	"runtime"
)

// errNoFilter means the kernel would not sort our packets for us, so Go still
// has to. Not an error anybody needs to act on - see attachICMPFilter.
var errNoFilter = errors.New("icmp: no socket filter on this platform")

// icmpIDFor is the identifier both ends put in every echo they send.
//
// It used to be the low half of a random session number, which meant every
// carrier used a different one and nothing outside this process could tell our
// echoes from anybody else's. Derived from the token instead, it is the same
// on both servers and different on every tunnel - so the kernel can be told
// exactly what to keep, and two tunnels between the same pair of servers still
// do not collect each other's packets.
//
// Zero is stepped over: plenty of tools send pings with an identifier of zero,
// and matching them all back would defeat the point.
func icmpIDFor(psk []byte) uint16 {
	k := hkdfExpand(hkdfExtract([]byte("pingify/v3 icmp id"), psk), []byte("id"), 2)
	id := binary.BigEndian.Uint16(k)
	if id == 0 {
		id = 1
	}
	return id
}

// runtimeKeepAlive is runtime.KeepAlive under a name that says why it is here.
func runtimeKeepAlive(v interface{}) { runtime.KeepAlive(v) }
