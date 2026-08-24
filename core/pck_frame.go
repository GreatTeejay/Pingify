package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"net"
	"strings"
	"time"
)

const (
	pckEtherLen = 14
	pckIPLen    = 20
	pckTCPLen   = 32 // 20-byte header + NOP,NOP,timestamp option.
	pckHdrLen   = 10 // carrier id + truncated HMAC.
	pckWindow   = 65535
)

type pckAddress struct {
	IP      net.IP
	Port    uint16
	Carrier uint16
}

func (a pckAddress) Network() string { return "pck" }
func (a pckAddress) String() string {
	return fmt.Sprintf("%s:%d/c%d", a.IP.String(), a.Port, a.Carrier)
}

type pckRoute struct {
	ifindex int
	localIP net.IP
	srcMAC  net.HardwareAddr
	dstMAC  net.HardwareAddr
}

// PCK does not ask the kernel for an ephemeral TCP source port, because it
// emits complete packets itself. Derive a stable unprivileged port from the
// shared secret so reconnects and firewall diagnostics always agree.
func pckStableSourcePort(cfg *Config, remote uint16) uint16 {
	secret := strings.TrimSpace(cfg.Token)
	if secret == "" {
		secret = strings.TrimSpace(cfg.PSK)
	}
	sum := sha256.Sum256([]byte(secret))
	port := uint16(20000 + binary.BigEndian.Uint16(sum[:2])%40000)
	if port == remote {
		port++
		if port >= 60000 {
			port = 20000
		}
	}
	return port
}

type pckSegment struct {
	srcIP, dstIP     net.IP
	srcPort, dstPort uint16
	seq, ts          uint32
	payload          []byte
	srcMAC, dstMAC   net.HardwareAddr
}

func parsePCKFlags(s string) (byte, error) {
	s = strings.ToUpper(strings.TrimSpace(s))
	if s == "" {
		s = "PA"
	}
	var out byte
	for _, r := range s {
		switch r {
		case 'F':
			out |= 0x01
		case 'S':
			out |= 0x02
		case 'P':
			out |= 0x08
		case 'A':
			out |= 0x10
		case 'U':
			out |= 0x20
		case 'E':
			out |= 0x40
		case 'C':
			out |= 0x80
		default:
			return 0, fmt.Errorf("pck flags %q: use F, S, P, A, U, E or C", s)
		}
	}
	if out&0x04 != 0 || out&(0x02|0x10) == 0 {
		return 0, fmt.Errorf("pck flags %q must contain ACK or SYN and cannot contain RST", s)
	}
	return out, nil
}

func pckEnvelope(key []byte, carrier uint16, payload []byte) []byte {
	out := make([]byte, pckHdrLen+len(payload))
	binary.BigEndian.PutUint16(out[:2], carrier)
	copy(out[pckHdrLen:], payload)
	m := hmac.New(sha256.New, key)
	m.Write(out[:2])
	m.Write(payload)
	copy(out[2:pckHdrLen], m.Sum(nil)[:pckHdrLen-2])
	return out
}

func openPCKEnvelope(key, packet []byte) (uint16, []byte, bool) {
	if len(packet) < pckHdrLen {
		return 0, nil, false
	}
	m := hmac.New(sha256.New, key)
	m.Write(packet[:2])
	m.Write(packet[pckHdrLen:])
	if !hmac.Equal(packet[2:pckHdrLen], m.Sum(nil)[:pckHdrLen-2]) {
		return 0, nil, false
	}
	return binary.BigEndian.Uint16(packet[:2]), packet[pckHdrLen:], true
}

func checksum16(b []byte) uint16 {
	var sum uint32
	for len(b) >= 2 {
		sum += uint32(binary.BigEndian.Uint16(b[:2]))
		b = b[2:]
	}
	if len(b) == 1 {
		sum += uint32(b[0]) << 8
	}
	for sum>>16 != 0 {
		sum = (sum & 0xffff) + sum>>16
	}
	return ^uint16(sum)
}

func tcpChecksum(src, dst net.IP, tcp []byte) uint16 {
	pseudo := make([]byte, 12+len(tcp))
	copy(pseudo[0:4], src.To4())
	copy(pseudo[4:8], dst.To4())
	pseudo[9] = 6
	binary.BigEndian.PutUint16(pseudo[10:12], uint16(len(tcp)))
	copy(pseudo[12:], tcp)
	return checksum16(pseudo)
}

func buildPCKFrame(route pckRoute, srcPort, dstPort uint16, seq, ack uint32, flags byte, tsEcho uint32, id uint16, payload []byte) []byte {
	total := pckEtherLen + pckIPLen + pckTCPLen + len(payload)
	b := make([]byte, total)
	copy(b[0:6], route.dstMAC)
	copy(b[6:12], route.srcMAC)
	binary.BigEndian.PutUint16(b[12:14], 0x0800)

	ip := b[pckEtherLen : pckEtherLen+pckIPLen]
	ip[0] = 0x45
	ip[1] = 46 << 2 // expedited-forwarding DSCP, no ECN.
	binary.BigEndian.PutUint16(ip[2:4], uint16(total-pckEtherLen))
	binary.BigEndian.PutUint16(ip[4:6], id)
	binary.BigEndian.PutUint16(ip[6:8], 0x4000) // don't fragment.
	ip[8], ip[9] = 64, 6
	copy(ip[12:16], route.localIP.To4())
	// The destination is supplied in dstMAC's route and patched by the caller.

	tcp := b[pckEtherLen+pckIPLen:]
	binary.BigEndian.PutUint16(tcp[0:2], srcPort)
	binary.BigEndian.PutUint16(tcp[2:4], dstPort)
	binary.BigEndian.PutUint32(tcp[4:8], seq)
	binary.BigEndian.PutUint32(tcp[8:12], ack)
	tcp[12], tcp[13] = (pckTCPLen/4)<<4, flags
	binary.BigEndian.PutUint16(tcp[14:16], pckWindow)
	// NOP, NOP, RFC 7323 timestamp.
	tcp[20], tcp[21], tcp[22], tcp[23] = 1, 1, 8, 10
	binary.BigEndian.PutUint32(tcp[24:28], uint32(time.Now().UnixMilli()))
	binary.BigEndian.PutUint32(tcp[28:32], tsEcho)
	copy(tcp[pckTCPLen:], payload)
	return b
}

// finishPCKFrame writes the destination IP and both checksums after the caller
// has selected a peer for the route.
func finishPCKFrame(frame []byte, dst net.IP) bool {
	if len(frame) < pckEtherLen+pckIPLen+pckTCPLen || dst.To4() == nil {
		return false
	}
	ip := frame[pckEtherLen : pckEtherLen+pckIPLen]
	copy(ip[16:20], dst.To4())
	ip[10], ip[11] = 0, 0
	binary.BigEndian.PutUint16(ip[10:12], checksum16(ip))
	tcp := frame[pckEtherLen+pckIPLen:]
	tcp[16], tcp[17] = 0, 0
	binary.BigEndian.PutUint16(tcp[16:18], tcpChecksum(ip[12:16], ip[16:20], tcp))
	return true
}

func parsePCKFrame(frame []byte, wantPort uint16) (pckSegment, bool) {
	var s pckSegment
	if len(frame) < pckEtherLen+pckIPLen+pckTCPLen || binary.BigEndian.Uint16(frame[12:14]) != 0x0800 {
		return s, false
	}
	ip := frame[pckEtherLen:]
	if ip[0]>>4 != 4 || ip[9] != 6 {
		return s, false
	}
	ihl := int(ip[0]&0x0f) * 4
	if ihl < pckIPLen || len(ip) < ihl+pckTCPLen || binary.BigEndian.Uint16(ip[6:8])&0x1fff != 0 {
		return s, false
	}
	total := int(binary.BigEndian.Uint16(ip[2:4]))
	if total < ihl+pckTCPLen || total > len(ip) {
		return s, false
	}
	tcp := ip[ihl:total]
	off := int(tcp[12]>>4) * 4
	if off < 20 || off > len(tcp) || binary.BigEndian.Uint16(tcp[2:4]) != wantPort {
		return s, false
	}
	s.srcIP = append(net.IP(nil), ip[12:16]...)
	s.dstIP = append(net.IP(nil), ip[16:20]...)
	s.srcPort = binary.BigEndian.Uint16(tcp[0:2])
	s.dstPort = binary.BigEndian.Uint16(tcp[2:4])
	s.seq = binary.BigEndian.Uint32(tcp[4:8])
	if off >= pckTCPLen && tcp[20] == 1 && tcp[21] == 1 && tcp[22] == 8 && tcp[23] == 10 {
		s.ts = binary.BigEndian.Uint32(tcp[24:28])
	}
	s.payload = tcp[off:]
	s.srcMAC = append(net.HardwareAddr(nil), frame[6:12]...)
	s.dstMAC = append(net.HardwareAddr(nil), frame[0:6]...)
	return s, true
}
