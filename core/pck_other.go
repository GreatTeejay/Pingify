//go:build !linux

package main

import (
	"fmt"
	"net"
)

type pckTransport struct{}

func newPCKTransport(*Config) (*pckTransport, error) {
	return nil, fmt.Errorf("tcp+pck is available on Linux only and needs CAP_NET_RAW/root")
}

func (t *pckTransport) Dial(int) (net.Conn, error) { return nil, fmt.Errorf("tcp+pck is Linux only") }
func (t *pckTransport) Accept() (net.Conn, error)  { return nil, fmt.Errorf("tcp+pck is Linux only") }
func (t *pckTransport) Close() error               { return nil }
func (t *pckTransport) Name() string               { return "tcp+pck" }
