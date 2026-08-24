package main

import (
	"bytes"
	"encoding/binary"
	"net"
	"testing"
)

func TestPCKEnvelopeAuthenticatesCarrierAndPayload(t *testing.T) {
	key := []byte("a packet key that is deliberately long")
	want := []byte("one KCP datagram")
	pkt := pckEnvelope(key, 17, want)
	carrier, got, ok := openPCKEnvelope(key, pkt)
	if !ok || carrier != 17 || !bytes.Equal(got, want) {
		t.Fatalf("round trip failed: carrier=%d ok=%v payload=%q", carrier, ok, got)
	}
	pkt[len(pkt)-1] ^= 1
	if _, _, ok := openPCKEnvelope(key, pkt); ok {
		t.Fatal("a changed payload passed the PCK prefilter")
	}
}

func TestPCKFrameLooksLikeEstablishedTCPAndParses(t *testing.T) {
	route := pckRoute{
		ifindex: 2,
		localIP: net.IPv4(192, 0, 2, 10),
		srcMAC:  net.HardwareAddr{0, 1, 2, 3, 4, 5},
		dstMAC:  net.HardwareAddr{6, 7, 8, 9, 10, 11},
	}
	payload := []byte("encrypted kcp packet")
	frame := buildPCKFrame(route, 443, 443, 1000, 9000, 0x18, 123, 7, payload)
	if !finishPCKFrame(frame, net.IPv4(198, 51, 100, 20)) {
		t.Fatal("could not finish an IPv4 frame")
	}
	ip := frame[pckEtherLen : pckEtherLen+pckIPLen]
	if checksum16(ip) != 0 {
		t.Fatal("invalid IPv4 checksum")
	}
	tcp := frame[pckEtherLen+pckIPLen:]
	if tcpChecksum(ip[12:16], ip[16:20], tcp) != 0 {
		t.Fatal("invalid TCP checksum")
	}
	if tcp[12]>>4 != pckTCPLen/4 || tcp[13] != 0x18 || binary.BigEndian.Uint16(tcp[14:16]) != pckWindow {
		t.Fatal("TCP header is not the requested established PA segment")
	}
	seg, ok := parsePCKFrame(frame, 443)
	if !ok || !seg.srcIP.Equal(route.localIP) || !seg.dstIP.Equal(net.IPv4(198, 51, 100, 20)) ||
		seg.srcPort != 443 || seg.dstPort != 443 || seg.seq != 1000 || !bytes.Equal(seg.payload, payload) {
		t.Fatalf("parsed segment differs: %+v ok=%v", seg, ok)
	}
	if _, ok := parsePCKFrame(frame, 8443); ok {
		t.Fatal("a frame for a different port was accepted")
	}
}

func TestPCKFlagsRejectResetAndNonsense(t *testing.T) {
	if got, err := parsePCKFlags("PA"); err != nil || got != 0x18 {
		t.Fatalf("PA: got=%02x err=%v", got, err)
	}
	for _, bad := range []string{"R", "P", "AX"} {
		if _, err := parsePCKFlags(bad); err == nil {
			t.Fatalf("%q should have been rejected", bad)
		}
	}
}

func TestPCKStableSourcePortMatchesManager(t *testing.T) {
	cfg := &Config{Token: "a shared secret phrase"}
	if got := pckStableSourcePort(cfg, 443); got != 28817 {
		t.Fatalf("stable PCK source port = %d, want 28817", got)
	}
	if got := pckStableSourcePort(cfg, 28817); got != 28818 {
		t.Fatalf("collision-safe PCK source port = %d, want 28818", got)
	}
}
