//go:build linux

package main

import (
	"bufio"
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"net"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	kcp "github.com/xtaci/kcp-go/v5"
	"golang.org/x/sys/unix"
)

const pckEtherTypeIPv4 = 0x0800

type pckDatagram struct {
	b    []byte
	addr pckAddress
}

type pckFlow struct {
	route pckRoute
	seq   uint32
	ack   uint32
	ts    uint32
	id    uint16
}

// pckHub owns one AF_PACKET socket for the whole carrier pool. A tiny keyed
// envelope contains the carrier id, so all KCP sessions may share the same
// real source/destination port without racing each other for raw packets.
type pckHub struct {
	fd      int
	rawFD   int
	port    uint16
	key     []byte
	flags   byte
	initial *pckRoute

	mu      sync.Mutex
	flows   map[string]*pckFlow
	clients map[uint16]chan pckDatagram
	server  chan pckDatagram
	closed  bool
	done    chan struct{}
	once    sync.Once
}

func networkUint16(v uint16) int { return int(v<<8 | v>>8) }

func newPCKHub(port uint16, key []byte, flags byte, peer net.IP, cfg *Config) (*pckHub, error) {
	fd, err := unix.Socket(unix.AF_PACKET, unix.SOCK_RAW|unix.SOCK_CLOEXEC, networkUint16(pckEtherTypeIPv4))
	if err != nil {
		return nil, fmt.Errorf("pck packet socket: %v (Linux and CAP_NET_RAW/root are required)", err)
	}
	if err := attachPCKFilter(fd, port); err != nil {
		unix.Close(fd)
		return nil, fmt.Errorf("pck packet filter: %v", err)
	}
	// The PCK hub is the packet transport's one real socket. Without these,
	// the large buffers selected by the packet presets stopped at the config
	// file and a burst could be dropped before KCP/FEC saw it.
	if cfg.RcvBufKB > 0 {
		_ = unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_RCVBUF, cfg.RcvBufKB*1024)
	}
	if cfg.SndBufKB > 0 {
		_ = unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_SNDBUF, cfg.SndBufKB*1024)
	}
	h := &pckHub{
		fd: fd, rawFD: -1, port: port, key: key, flags: flags,
		flows: make(map[string]*pckFlow), clients: make(map[uint16]chan pckDatagram),
		server: make(chan pckDatagram, 4096), done: make(chan struct{}),
	}
	if peer != nil {
		route, err := discoverPCKRoute(peer)
		if err != nil {
			unix.Close(fd)
			return nil, err
		}
		h.initial = route
	}
	workers, _ := packetReadTuning(cfg.Profile)
	for i := 0; i < workers; i++ {
		go h.readLoop()
	}
	logInfo("PCK packet I/O: %d receive workers on one filtered AF_PACKET socket", workers)
	return h, nil
}

// Keep unrelated traffic out of userspace. This classic BPF program accepts
// only unfragmented IPv4/TCP frames whose destination port is this tunnel's;
// the keyed HMAC envelope remains the second, cryptographic filter.
func attachPCKFilter(fd int, port uint16) error {
	filter := []unix.SockFilter{
		{Code: unix.BPF_LD | unix.BPF_H | unix.BPF_ABS, K: 12},
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, Jf: 8, K: pckEtherTypeIPv4},
		{Code: unix.BPF_LD | unix.BPF_B | unix.BPF_ABS, K: 23},
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, Jf: 6, K: unix.IPPROTO_TCP},
		{Code: unix.BPF_LD | unix.BPF_H | unix.BPF_ABS, K: 20},
		{Code: unix.BPF_JMP | unix.BPF_JSET | unix.BPF_K, Jt: 4, K: 0x1fff},
		{Code: unix.BPF_LDX | unix.BPF_B | unix.BPF_MSH, K: 14},
		{Code: unix.BPF_LD | unix.BPF_H | unix.BPF_IND, K: 16},
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, Jf: 1, K: uint32(port)},
		{Code: unix.BPF_RET | unix.BPF_K, K: 65535},
		{Code: unix.BPF_RET | unix.BPF_K, K: 0},
	}
	prog := &unix.SockFprog{Len: uint16(len(filter)), Filter: &filter[0]}
	return unix.SetsockoptSockFprog(fd, unix.SOL_SOCKET, unix.SO_ATTACH_FILTER, prog)
}

func (h *pckHub) readLoop() {
	buf := make([]byte, 65536)
	for {
		n, from, err := unix.Recvfrom(h.fd, buf, 0)
		if err != nil {
			select {
			case <-h.done:
				return
			default:
				continue
			}
		}
		ll, ok := from.(*unix.SockaddrLinklayer)
		if !ok || ll.Pkttype == unix.PACKET_OUTGOING {
			continue
		}
		seg, ok := parsePCKFrame(buf[:n], h.port)
		if !ok {
			continue
		}
		carrier, body, ok := openPCKEnvelope(h.key, seg.payload)
		if !ok {
			continue
		}
		addr := pckAddress{IP: seg.srcIP, Port: seg.srcPort, Carrier: carrier}
		key := addr.String()

		h.mu.Lock()
		flow := h.flows[key]
		if flow == nil {
			flow = &pckFlow{seq: pckRandom32(), id: uint16(pckRandom32())}
			h.flows[key] = flow
		}
		// A reply follows the exact L2 path the valid inbound frame used. This
		// works behind VPS NAT too: the destination IP seen here is the actual
		// local address, even when the configured address is public.
		flow.route = pckRoute{
			ifindex: ll.Ifindex, localIP: seg.dstIP,
			srcMAC: seg.dstMAC, dstMAC: seg.srcMAC,
		}
		flow.ack = seg.seq + uint32(len(seg.payload))
		flow.ts = seg.ts
		ch := h.clients[carrier]
		closed := h.closed
		h.mu.Unlock()
		if closed {
			return
		}

		pkt := pckDatagram{b: append([]byte(nil), body...), addr: addr}
		if ch != nil {
			select {
			case ch <- pkt:
			default: // packet loss is preferable to wedging every carrier.
			}
		} else {
			select {
			case h.server <- pkt:
			default:
			}
		}
	}
}

func pckRandom32() uint32 {
	var b [4]byte
	if _, err := rand.Read(b[:]); err == nil {
		return binary.BigEndian.Uint32(b[:])
	}
	return uint32(time.Now().UnixNano())
}

func (h *pckHub) send(addr pckAddress, carrier uint16, payload []byte) error {
	envelope := pckEnvelope(h.key, carrier, payload)
	key := addr.String()

	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return net.ErrClosed
	}
	flow := h.flows[key]
	if flow == nil {
		flow = &pckFlow{seq: pckRandom32(), id: uint16(pckRandom32())}
		if h.initial != nil {
			flow.route = *h.initial
		}
		h.flows[key] = flow
	}
	route, seq, ack, ts, id := flow.route, flow.seq, flow.ack, flow.ts, flow.id
	flow.seq += uint32(len(envelope))
	flow.id++
	h.mu.Unlock()

	if route.localIP == nil {
		return fmt.Errorf("pck: no route learned for %s", addr.IP)
	}
	frame := buildPCKFrame(route, h.port, addr.Port, seq, ack, h.flags, ts, id, envelope)
	if !finishPCKFrame(frame, addr.IP) {
		return fmt.Errorf("pck: invalid IPv4 peer %s", addr.IP)
	}
	if len(route.srcMAC) == 6 && len(route.dstMAC) == 6 && route.ifindex > 0 {
		var mac [8]uint8
		copy(mac[:], route.dstMAC)
		return unix.Sendto(h.fd, frame, 0, &unix.SockaddrLinklayer{
			Protocol: uint16(networkUint16(pckEtherTypeIPv4)), Ifindex: route.ifindex,
			Halen: 6, Addr: mac,
		})
	}
	return h.sendRawIP(frame[pckEtherLen:], addr.IP)
}

func (h *pckHub) sendRawIP(packet []byte, peer net.IP) error {
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return net.ErrClosed
	}
	if h.rawFD < 0 {
		fd, err := unix.Socket(unix.AF_INET, unix.SOCK_RAW|unix.SOCK_CLOEXEC, unix.IPPROTO_RAW)
		if err != nil {
			h.mu.Unlock()
			return err
		}
		if err := unix.SetsockoptInt(fd, unix.IPPROTO_IP, unix.IP_HDRINCL, 1); err != nil {
			unix.Close(fd)
			h.mu.Unlock()
			return err
		}
		h.rawFD = fd
	}
	fd := h.rawFD
	h.mu.Unlock()
	ip4 := peer.To4()
	if ip4 == nil {
		return fmt.Errorf("pck supports IPv4 only")
	}
	return unix.Sendto(fd, packet, 0, &unix.SockaddrInet4{Addr: [4]byte{ip4[0], ip4[1], ip4[2], ip4[3]}})
}

func (h *pckHub) register(carrier uint16) (*pckVirtualPacketConn, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.closed {
		return nil, net.ErrClosed
	}
	if _, exists := h.clients[carrier]; exists {
		return nil, fmt.Errorf("pck carrier %d already exists", carrier)
	}
	ch := make(chan pckDatagram, 1024)
	h.clients[carrier] = ch
	return &pckVirtualPacketConn{hub: h, carrier: carrier, in: ch, done: make(chan struct{})}, nil
}

func (h *pckHub) unregister(carrier uint16) {
	h.mu.Lock()
	delete(h.clients, carrier)
	h.mu.Unlock()
}

func (h *pckHub) Close() error {
	h.once.Do(func() {
		h.mu.Lock()
		h.closed = true
		close(h.done)
		fd, raw := h.fd, h.rawFD
		h.mu.Unlock()
		_ = unix.Close(fd)
		if raw >= 0 {
			_ = unix.Close(raw)
		}
	})
	return nil
}

type pckServerPacketConn struct{ hub *pckHub }

func (c *pckServerPacketConn) ReadFrom(b []byte) (int, net.Addr, error) {
	select {
	case p := <-c.hub.server:
		return copy(b, p.b), p.addr, nil
	case <-c.hub.done:
		return 0, nil, net.ErrClosed
	}
}
func (c *pckServerPacketConn) WriteTo(b []byte, addr net.Addr) (int, error) {
	a, ok := addr.(pckAddress)
	if !ok {
		return 0, fmt.Errorf("pck: bad peer address %T", addr)
	}
	if err := c.hub.send(a, a.Carrier, b); err != nil {
		return 0, err
	}
	return len(b), nil
}
func (c *pckServerPacketConn) Close() error                     { return c.hub.Close() }
func (c *pckServerPacketConn) LocalAddr() net.Addr              { return pckAddress{Port: c.hub.port} }
func (c *pckServerPacketConn) SetDeadline(time.Time) error      { return nil }
func (c *pckServerPacketConn) SetReadDeadline(time.Time) error  { return nil }
func (c *pckServerPacketConn) SetWriteDeadline(time.Time) error { return nil }

type pckVirtualPacketConn struct {
	hub     *pckHub
	peer    pckAddress
	carrier uint16
	in      chan pckDatagram
	done    chan struct{}
	once    sync.Once
}

func (c *pckVirtualPacketConn) ReadFrom(b []byte) (int, net.Addr, error) {
	select {
	case p := <-c.in:
		return copy(b, p.b), p.addr, nil
	case <-c.done:
		return 0, nil, net.ErrClosed
	case <-c.hub.done:
		return 0, nil, net.ErrClosed
	}
}
func (c *pckVirtualPacketConn) WriteTo(b []byte, _ net.Addr) (int, error) {
	if err := c.hub.send(c.peer, c.carrier, b); err != nil {
		return 0, err
	}
	return len(b), nil
}
func (c *pckVirtualPacketConn) Close() error {
	c.once.Do(func() {
		c.hub.unregister(c.carrier)
		close(c.done)
	})
	return nil
}
func (c *pckVirtualPacketConn) LocalAddr() net.Addr {
	return pckAddress{Port: c.hub.port, Carrier: c.carrier}
}
func (c *pckVirtualPacketConn) SetDeadline(time.Time) error      { return nil }
func (c *pckVirtualPacketConn) SetReadDeadline(time.Time) error  { return nil }
func (c *pckVirtualPacketConn) SetWriteDeadline(time.Time) error { return nil }

type pckSessionConn struct {
	net.Conn
	pc   *pckVirtualPacketConn
	once sync.Once
}

func (c *pckSessionConn) Close() error {
	var err error
	c.once.Do(func() {
		err = c.Conn.Close()
		_ = c.pc.Close()
	})
	return err
}

type pckTransport struct {
	cfg   *Config
	block kcp.BlockCrypt
	hub   *pckHub
	ln    *kcp.Listener
	peer  pckAddress
	guard *pckGuard
}

func newPCKTransport(cfg *Config) (*pckTransport, error) {
	endpoint := cfg.Listen
	if cfg.Connect != "" {
		endpoint = cfg.Connect
	}
	host, portText, err := net.SplitHostPort(endpoint)
	if err != nil {
		return nil, fmt.Errorf("pck endpoint %q: %v", endpoint, err)
	}
	port64, err := strconv.ParseUint(portText, 10, 16)
	if err != nil || port64 == 0 {
		return nil, fmt.Errorf("pck endpoint has an invalid port")
	}
	port := uint16(port64)
	localPort := port
	if cfg.Connect != "" {
		localPort = pckStableSourcePort(cfg, port)
	}
	flags, err := parsePCKFlags(cfg.PCKFlags)
	if err != nil {
		return nil, err
	}
	packetRoot := hkdfExtract([]byte("pingify/v4 pck"), cfg.key())
	cipherKey := hkdfExpand(packetRoot, []byte("kcp packet cipher"), 32)
	envelopeKey := hkdfExpand(packetRoot, []byte("carrier envelope"), 32)
	block, err := kcp.NewAESBlockCrypt(cipherKey)
	if err != nil {
		return nil, err
	}
	var peerIP net.IP
	if cfg.Connect != "" {
		ips, err := net.LookupIP(host)
		if err != nil {
			return nil, fmt.Errorf("pck resolve %s: %v", host, err)
		}
		for _, ip := range ips {
			if ip4 := ip.To4(); ip4 != nil {
				peerIP = ip4
				break
			}
		}
		if peerIP == nil {
			return nil, fmt.Errorf("pck supports IPv4 peers only")
		}
	}
	hub, err := newPCKHub(localPort, envelopeKey, flags, peerIP, cfg)
	if err != nil {
		return nil, err
	}
	t := &pckTransport{cfg: cfg, block: block, hub: hub, guard: installPCKGuard(localPort)}
	if peerIP != nil {
		t.peer = pckAddress{IP: peerIP, Port: port}
		logInfo("pck uses stable local TCP source port %d toward %d", localPort, port)
	} else {
		ln, err := kcp.ServeConn(block, cfg.FECData, cfg.FECParity, &pckServerPacketConn{hub: hub})
		if err != nil {
			t.Close()
			return nil, err
		}
		t.ln = ln
	}
	if t.guard == nil || !t.guard.complete {
		logWarn("pck: the narrow RST/NOTRACK firewall rules could not all be installed; install iptables and run as root")
	}
	return t, nil
}

func (t *pckTransport) Dial(idx int) (net.Conn, error) {
	carrier := uint16(idx)
	pc, err := t.hub.register(carrier)
	if err != nil {
		return nil, err
	}
	peer := t.peer
	peer.Carrier = carrier
	pc.peer = peer
	s, err := kcp.NewConn3(pckRandom32(), peer, t.block, t.cfg.FECData, t.cfg.FECParity, pc)
	if err != nil {
		pc.Close()
		return nil, err
	}
	tuneKCPSession(s, t.cfg)
	return &pckSessionConn{Conn: s, pc: pc}, nil
}

func (t *pckTransport) Accept() (net.Conn, error) {
	if t.ln == nil {
		return nil, fmt.Errorf("pck: this end dials, it does not accept")
	}
	s, err := t.ln.AcceptKCP()
	if err != nil {
		return nil, err
	}
	tuneKCPSession(s, t.cfg)
	return s, nil
}

func (t *pckTransport) Close() error {
	if t.ln != nil {
		_ = t.ln.Close()
	}
	if t.hub != nil {
		_ = t.hub.Close()
	}
	if t.guard != nil {
		t.guard.remove()
	}
	return nil
}

func (t *pckTransport) Name() string { return "tcp+pck" }

// Route discovery is only needed for the first client packet. Once either end
// receives a valid frame, the exact interface and next-hop MAC are learned
// from that frame and replace this bootstrap route.
func discoverPCKRoute(peer net.IP) (*pckRoute, error) {
	peer = peer.To4()
	if peer == nil {
		return nil, fmt.Errorf("pck supports IPv4 only")
	}
	ifaceName, gateway, err := pckRouteToward(peer)
	if err != nil {
		return nil, err
	}
	iface, err := net.InterfaceByName(ifaceName)
	if err != nil {
		return nil, err
	}
	local := pckLocalSource(peer)
	if local == nil {
		return nil, fmt.Errorf("pck: cannot determine the local address toward %s", peer)
	}
	r := &pckRoute{ifindex: iface.Index, localIP: local, srcMAC: append(net.HardwareAddr(nil), iface.HardwareAddr...)}
	if len(r.srcMAC) != 6 {
		return r, nil // raw-IP fallback for point-to-point devices.
	}
	target := gateway
	if target == nil {
		target = peer
	}
	r.dstMAC = pckARP(iface.Name, target)
	if r.dstMAC == nil {
		// Prime the neighbour table once, then retry before using raw IP.
		if c, e := net.DialTimeout("udp4", net.JoinHostPort(peer.String(), "9"), time.Second); e == nil {
			_, _ = c.Write([]byte{0})
			_ = c.Close()
		}
		for i := 0; i < 20 && r.dstMAC == nil; i++ {
			time.Sleep(25 * time.Millisecond)
			r.dstMAC = pckARP(iface.Name, target)
		}
	}
	return r, nil
}

func pckLocalSource(peer net.IP) net.IP {
	c, err := net.DialUDP("udp4", nil, &net.UDPAddr{IP: peer, Port: 9})
	if err != nil {
		return nil
	}
	defer c.Close()
	return append(net.IP(nil), c.LocalAddr().(*net.UDPAddr).IP.To4()...)
}

func pckRouteToward(dst net.IP) (string, net.IP, error) {
	f, err := os.Open("/proc/net/route")
	if err != nil {
		return "", nil, err
	}
	defer f.Close()
	want := binary.BigEndian.Uint32(dst.To4())
	best, bestBits := "", -1
	var bestGW net.IP
	sc := bufio.NewScanner(f)
	_ = sc.Scan()
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) < 8 {
			continue
		}
		netv, ok1 := pckHexLE(fields[1])
		gw, ok2 := pckHexLE(fields[2])
		mask, ok3 := pckHexLE(fields[7])
		if !ok1 || !ok2 || !ok3 || want&mask != netv {
			continue
		}
		bits := 0
		for i := 31; i >= 0 && mask&(1<<uint(i)) != 0; i-- {
			bits++
		}
		if bits > bestBits {
			best, bestBits = fields[0], bits
			if gw == 0 {
				bestGW = nil
			} else {
				bestGW = make(net.IP, 4)
				binary.BigEndian.PutUint32(bestGW, gw)
			}
		}
	}
	if best == "" {
		return "", nil, fmt.Errorf("pck: no route to %s", dst)
	}
	return best, bestGW, nil
}

func pckHexLE(s string) (uint32, bool) {
	v, err := strconv.ParseUint(s, 16, 32)
	if err != nil {
		return 0, false
	}
	var b [4]byte
	binary.LittleEndian.PutUint32(b[:], uint32(v))
	return binary.BigEndian.Uint32(b[:]), true
}

func pckARP(iface string, ip net.IP) net.HardwareAddr {
	f, err := os.Open("/proc/net/arp")
	if err != nil {
		return nil
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	_ = sc.Scan()
	for sc.Scan() {
		v := strings.Fields(sc.Text())
		if len(v) < 6 || v[0] != ip.String() || v[5] != iface || v[2] != "0x2" {
			continue
		}
		mac, err := net.ParseMAC(v[3])
		if err == nil && len(mac) == 6 {
			return mac
		}
	}
	return nil
}

type pckGuard struct {
	port     uint16
	rules    [][]string
	added    [][]string
	complete bool
	once     sync.Once
}

func pckRules(port uint16) [][]string {
	p := strconv.Itoa(int(port))
	comment := "pingify-pck-" + p
	return [][]string{
		{"filter", "OUTPUT", "-p", "tcp", "--sport", p, "--tcp-flags", "RST", "RST", "-m", "comment", "--comment", comment, "-j", "DROP"},
		{"raw", "PREROUTING", "-p", "tcp", "--dport", p, "-m", "comment", "--comment", comment, "-j", "NOTRACK"},
		{"raw", "OUTPUT", "-p", "tcp", "--sport", p, "-m", "comment", "--comment", comment, "-j", "NOTRACK"},
	}
}

func installPCKGuard(port uint16) *pckGuard {
	if _, err := exec.LookPath("iptables"); err != nil {
		return &pckGuard{port: port}
	}
	g := &pckGuard{port: port, rules: pckRules(port)}
	for _, rule := range g.rules {
		table, chain, body := rule[0], rule[1], rule[2:]
		for i := 0; i < 64; i++ {
			args := append([]string{"-t", table, "-D", chain}, body...)
			if exec.Command("iptables", args...).Run() != nil {
				break
			}
		}
		args := append([]string{"-t", table, "-I", chain}, body...)
		if exec.Command("iptables", args...).Run() == nil {
			g.added = append(g.added, rule)
		}
	}
	g.complete = len(g.added) == len(g.rules)
	return g
}

func (g *pckGuard) remove() {
	if g == nil {
		return
	}
	g.once.Do(func() {
		for _, rule := range g.added {
			table, chain, body := rule[0], rule[1], rule[2:]
			args := append([]string{"-t", table, "-D", chain}, body...)
			_ = exec.Command("iptables", args...).Run()
		}
	})
}

var _ net.PacketConn = (*pckServerPacketConn)(nil)
var _ net.PacketConn = (*pckVirtualPacketConn)(nil)
