package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"io"
	mrand "math/rand"
	"net"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

// ==========================================================================
// 4. handshake and the carrier pool
// ==========================================================================

// ---------------------------------------------------------------------------
// handshake
//
//	dialer  -> listener : NONCE(16) SEALED(16) TAG(32) PAD(0..255)
//	listener -> dialer  : NONCE(16) TAG(32)     PAD(0..255)
//
// Not one byte of this is constant. There is no magic number and no plaintext
// version, role, carrier index or timestamp: those sixteen bytes are XORed
// with an AES block keyed by the pre-shared key and this connection's nonce,
// so two handshakes never share a byte. The length varies too, because the
// amount of trailing padding is read out of the tag - unpredictable to an
// observer, known to both ends.
//
// That matters more than it sounds. The previous revision opened every
// connection with the four ASCII bytes "PFY2", which is a one-line signature
// for anything doing deep packet inspection.
//
// A wrong key, a stale timestamp or a replayed nonce all end the same way: the
// socket closes after a random delay without a byte of reply, so a scanner
// cannot tell the port from a black hole.
// ---------------------------------------------------------------------------

const (
	hsVersion   = 3
	hsNonceLen  = 16
	hsSealedLen = 16
	hsTagLen    = 32
	hsClientLen = hsNonceLen + hsSealedLen + hsTagLen
	hsServerLen = hsNonceLen + hsTagLen
	hsSkew      = 180 * time.Second
)

var errHandshake = errors.New("handshake rejected")

func roleByte(role string) byte {
	if role == "server" {
		return 0
	}
	return 1
}

type replayGuard struct {
	mu   sync.Mutex
	seen map[[16]byte]int64
}

func newReplayGuard() *replayGuard {
	g := &replayGuard{seen: make(map[[16]byte]int64)}
	go func() {
		t := time.NewTicker(time.Minute)
		for range t.C {
			cut := time.Now().Add(-2 * hsSkew).UnixNano()
			g.mu.Lock()
			for k, v := range g.seen {
				if v < cut {
					delete(g.seen, k)
				}
			}
			g.mu.Unlock()
		}
	}()
	return g
}

func (g *replayGuard) accept(n [16]byte) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if _, dup := g.seen[n]; dup {
		return false
	}
	g.seen[n] = time.Now().UnixNano()
	return true
}

func aeadFrom(key []byte) cipher.AEAD {
	blk, err := aes.NewCipher(key)
	if err != nil {
		panic(err) // key length is fixed at 32 by deriveKeys
	}
	a, err := cipher.NewGCM(blk)
	if err != nil {
		panic(err)
	}
	return a
}

// headerPad XORs the 16 header bytes with a one-time AES block keyed by the
// pre-shared key and this connection's nonce. Both ends can compute it; nobody
// else can, and the result carries no recognisable structure.
func headerPad(psk, nonce []byte) [16]byte {
	k := hkdfExpand(hkdfExtract(nonce, psk), []byte("pingify/v3 header"), 32)
	blk, err := aes.NewCipher(k)
	if err != nil {
		panic(err)
	}
	var out [16]byte
	blk.Encrypt(out[:], nonce)
	return out
}

// writePadding appends the trailing random bytes. The count comes out of the
// tag, so the handshake is never the same length twice.
func writePadding(conn net.Conn, tag []byte) error {
	n := int(tag[0])
	if n == 0 {
		return nil
	}
	pad := make([]byte, n)
	if _, err := rand.Read(pad); err != nil {
		return err
	}
	_, err := conn.Write(pad)
	return err
}

func readPadding(conn net.Conn, tag []byte) error {
	n := int(tag[0])
	if n == 0 {
		return nil
	}
	_, err := io.CopyN(io.Discard, conn, int64(n))
	return err
}

// The wire a tunnel speaks is one decision, not two. Obfuscation used to
// govern only the frame lengths while the handshake stayed on v3 regardless -
// a shape that had never been run anywhere. Now off means the whole v2.1.1
// wire, the one with field evidence behind it, and on means the whole v3 one.
func clientHandshakeFor(cfg *Config, conn net.Conn, carrier int) (*sessionKeys, error) {
	if !cfg.obfuscated() {
		return clientHandshakeV2(conn, cfg, carrier)
	}
	return clientHandshake(conn, cfg, carrier)
}

func serverHandshakeFor(cfg *Config, conn net.Conn, g *replayGuard) (*sessionKeys, int, error) {
	if !cfg.obfuscated() {
		return serverHandshakeV2(conn, cfg, g)
	}
	return serverHandshake(conn, cfg, g)
}

// clientHandshake runs on the side that dials out.
func clientHandshake(conn net.Conn, cfg *Config, carrier int) (*sessionKeys, error) {
	psk := cfg.key()
	buf := make([]byte, hsClientLen)
	nonceC := buf[:hsNonceLen]
	sealed := buf[hsNonceLen : hsNonceLen+hsSealedLen]
	tag := buf[hsNonceLen+hsSealedLen:]

	if _, err := rand.Read(nonceC); err != nil {
		return nil, err
	}
	var hdr [16]byte
	hdr[0] = hsVersion
	hdr[1] = roleByte(cfg.Role)
	binary.BigEndian.PutUint16(hdr[2:4], uint16(carrier))
	binary.BigEndian.PutUint64(hdr[4:12], uint64(time.Now().Unix()))
	if _, err := rand.Read(hdr[12:]); err != nil { // filler, never inspected
		return nil, err
	}
	pad := headerPad(psk, nonceC)
	for i := range hdr {
		sealed[i] = hdr[i] ^ pad[i]
	}
	m := hmac.New(sha256.New, psk)
	m.Write(nonceC)
	m.Write(sealed)
	copy(tag, m.Sum(nil))

	conn.SetDeadline(time.Now().Add(15 * time.Second))
	if _, err := conn.Write(buf); err != nil {
		return nil, err
	}
	if err := writePadding(conn, tag); err != nil {
		return nil, err
	}

	resp := make([]byte, hsServerLen)
	if _, err := io.ReadFull(conn, resp); err != nil {
		return nil, err
	}
	m2 := hmac.New(sha256.New, psk)
	m2.Write([]byte("pingify/v3 server"))
	m2.Write(nonceC)
	m2.Write(resp[:hsNonceLen])
	if !hmac.Equal(m2.Sum(nil), resp[hsNonceLen:]) {
		return nil, errHandshake
	}
	if err := readPadding(conn, resp[hsNonceLen:]); err != nil {
		return nil, err
	}
	conn.SetDeadline(time.Time{})

	return deriveSession(psk, nonceC, resp[:hsNonceLen], uint16(carrier), true), nil
}

// serverHandshake runs on the side that listens.
func serverHandshake(conn net.Conn, cfg *Config, g *replayGuard) (*sessionKeys, int, error) {
	psk := cfg.key()
	buf := make([]byte, hsClientLen)
	conn.SetDeadline(time.Now().Add(15 * time.Second))
	if _, err := io.ReadFull(conn, buf); err != nil {
		return nil, 0, err
	}
	nonceC := buf[:hsNonceLen]
	sealed := buf[hsNonceLen : hsNonceLen+hsSealedLen]
	tag := buf[hsNonceLen+hsSealedLen:]

	// Authenticate before trusting a single field.
	m := hmac.New(sha256.New, psk)
	m.Write(nonceC)
	m.Write(sealed)
	if !hmac.Equal(m.Sum(nil), tag) {
		return nil, 0, errHandshake
	}
	var nc [16]byte
	copy(nc[:], nonceC)
	if !g.accept(nc) {
		return nil, 0, errHandshake
	}

	pad := headerPad(psk, nonceC)
	var hdr [16]byte
	for i := range hdr {
		hdr[i] = sealed[i] ^ pad[i]
	}
	if hdr[0] != hsVersion {
		return nil, 0, errHandshake
	}
	if hdr[1] == roleByte(cfg.Role) {
		return nil, 0, errHandshake // both ends configured with the same role
	}
	ts := int64(binary.BigEndian.Uint64(hdr[4:12]))
	if d := time.Since(time.Unix(ts, 0)); d > hsSkew || d < -hsSkew {
		return nil, 0, errHandshake
	}
	carrier := int(binary.BigEndian.Uint16(hdr[2:4]))

	if err := readPadding(conn, tag); err != nil {
		return nil, 0, err
	}

	resp := make([]byte, hsServerLen)
	if _, err := rand.Read(resp[:hsNonceLen]); err != nil {
		return nil, 0, err
	}
	m2 := hmac.New(sha256.New, psk)
	m2.Write([]byte("pingify/v3 server"))
	m2.Write(nonceC)
	m2.Write(resp[:hsNonceLen])
	copy(resp[hsNonceLen:], m2.Sum(nil))
	if _, err := conn.Write(resp); err != nil {
		return nil, 0, err
	}
	if err := writePadding(conn, resp[hsNonceLen:]); err != nil {
		return nil, 0, err
	}
	conn.SetDeadline(time.Time{})

	return deriveSession(psk, nonceC, resp[:hsNonceLen], uint16(carrier), false), carrier, nil
}

// ---------------------------------------------------------------------------
// carrier pool
// ---------------------------------------------------------------------------

const maxCarriers = 64

// No carrier is declared dead before this much true silence, whatever the
// local keepalive is set to. See link.idleLimit.
const minIdle = 60 * time.Second

type recordHandler interface {
	onRecord(l *link, cmd byte, id uint32, body []byte)
	onLinkDown(l *link)
}

type pool struct {
	cfg *Config

	mu    sync.RWMutex
	links [maxCarriers]*link
	h     recordHandler

	// Whatever carries the carriers. The pool asks it for three things and
	// knows nothing else about it.
	tr        carrierTransport
	guard     *replayGuard
	closed    chan struct{}
	closeOnce sync.Once

	// what the log was last told the strength was, so it can be told again
	// only when that changed
	reported int

	// why the most recent carrier died. Sixteen carriers dropping together
	// wrote sixteen identical reasons, so the reason was moved to debug - and
	// then the log said "1 went down" sixteen times and never once said why,
	// which is the only thing anybody reads a log for. It is kept here
	// instead, and reported once with the count.
	lastDown string

	// How many times the far end has told us it could not reach a target.
	// A stream that ends because the service on the other server hung up and
	// a stream that ends because there was no service to hang up both arrive
	// here as a closed socket; this counter is the only thing that separates
	// them, and the probe needs that distinction badly.
	refusals uint64
	// The version the other server reported, for the status endpoint and for
	// saying so once when it differs. See link.peerVersion.
	peerVer atomic.Value
	// What refusals had reached the last time the log said so, so that the
	// line can carry the number it stood in for.
	refusalsSaid uint64

	// when each kind of failure was last written down. Every carrier fails
	// the same way at the same moment, so without this the log is the same
	// sentence twenty-four times a second and the reader learns nothing.
	errMu   sync.Mutex
	errSeen map[string]time.Time

	startedAt time.Time
}

func newPool(cfg *Config) *pool {
	return &pool{cfg: cfg, guard: newReplayGuard(), closed: make(chan struct{}), startedAt: time.Now()}
}

func (p *pool) setHandler(h recordHandler) {
	p.mu.Lock()
	p.h = h
	p.mu.Unlock()
}

func (p *pool) handler() recordHandler {
	p.mu.RLock()
	h := p.h
	p.mu.RUnlock()
	return h
}

// start brings the transport up and then either dials the carriers or waits
// for them. Which transport it is stops mattering here: it answers Dial,
// Accept and Close, and this function asks for nothing else.
func (p *pool) start() error {
	// The decoy answers requests from an http.Handler that has no config, so
	// give it the key here, once, before anything can be asked.
	decoyPSK = p.cfg.key()

	t, err := newTransport(p.cfg)
	if err != nil {
		return err
	}
	p.tr = t

	if p.cfg.Connect != "" {
		for i := 0; i < p.cfg.Carriers; i++ {
			go p.dialLoop(i)
		}
		logInfo("opening %d %s carriers to %s", p.cfg.Carriers, t.Name(), p.cfg.Connect)
		return nil
	}
	// validate insists on exactly one of listen and connect, so reaching here
	// means listen is set - there is no second case to write.
	go p.acceptLoop()
	logInfo("waiting for %s carriers on %s", t.Name(), p.cfg.Listen)
	return nil
}

// dialCarrier opens one carrier with whichever transport is configured.
func (p *pool) dialCarrier(idx int) (net.Conn, error) { return p.tr.Dial(idx) }

func (p *pool) acceptLoop() {
	for {
		conn, err := p.tr.Accept()
		if err != nil {
			select {
			case <-p.closed:
				return
			default:
			}
			// A raw socket transport ends its accept loop by returning an
			// error and has nothing to retry; a listener can hit a transient
			// one. Backing off covers both without either needing to say
			// which it is.
			logWarn("accept: %v", err)
			time.Sleep(200 * time.Millisecond)
			continue
		}
		go p.serveInbound(conn)
	}
}

func (p *pool) serveInbound(conn net.Conn) {
	tuneSocket(conn, p.cfg)
	keys, idx, err := serverHandshakeFor(p.cfg, conn, p.guard)
	if err != nil {
		// Stay quiet on the wire: a probe should learn nothing from timing
		// or content. The local log is a different audience entirely - an
		// operator whose two servers disagree about the token could read it
		// all day and find nothing, because this is the only place that
		// knows the other end is knocking and being turned away.
		ra := conn.RemoteAddr()
		time.Sleep(time.Duration(200+mrand.Intn(600)) * time.Millisecond)
		conn.Close()
		logDebug("rejected %s: %v", ra, err)
		if p.firstIn("rejected", time.Minute) {
			// Nothing arrived is not the same as something wrong arrived. A
			// handshake that times out here is almost always a peer still
			// retransmitting to a session already torn down - and saying
			// "your tokens differ" to that, once a minute, on a tunnel that
			// is carrying gigabytes, sends the reader to check the one thing
			// that was never wrong.
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				logWarn("a connection from %s went quiet before it said anything: %v", ra, err)
				logWarn("usually a peer retransmitting to a carrier that has already gone -")
				logWarn("only worth chasing when no carrier is up at all")
			} else {
				logWarn("turned away a connection from %s: %v", ra, err)
				logWarn("if that address is the other server, the two security tokens differ")
			}
		}
		return
	}
	if idx < 0 || idx >= maxCarriers {
		conn.Close()
		return
	}
	if idx >= p.cfg.Carriers {
		// Not fatal - the pool holds it either way - but it means the two
		// configs were written with different tuning, and every setting that
		// has to match is now suspect.
		logWarn("carrier %d arrived but this side is configured for %d: the two ends disagree on [transport] carriers",
			idx, p.cfg.Carriers)
	}
	l := newLink(idx, p.cfg, conn, keys, p)
	p.install(idx, l)
	logDebug("carrier %d up from %s", idx, conn.RemoteAddr())
	p.noteStrength()
	l.run()
}

func (p *pool) dialLoop(idx int) {
	backoff := 500 * time.Millisecond
	for {
		select {
		case <-p.closed:
			return
		default:
		}
		conn, err := p.dialCarrier(idx)
		if err != nil {
			if p.firstIn("dial", time.Minute) {
				logWarn("cannot reach the other server at %s: %v", p.cfg.Connect, err)
				logWarn("nothing is listening on that port there, or a firewall is dropping it")
			}
			logDebug("carrier %d dial %s: %v", idx, p.cfg.Connect, err)
			p.sleepBackoff(&backoff)
			continue
		}
		tuneSocket(conn, p.cfg)
		keys, err := clientHandshakeFor(p.cfg, conn, idx)
		if err != nil {
			conn.Close()
			if p.firstIn("handshake", time.Minute) {
				// A handshake that is refused and a handshake that is never
				// answered are different faults on different machines, and
				// saying "different token" for both sends the reader to check
				// something that was right all along. Nothing came back means
				// nothing could disagree.
				var ne net.Error
				if errors.As(err, &ne) && ne.Timeout() {
					logWarn("reached %s but nothing came back: %v", p.cfg.Connect, err)
					logWarn("the far end is not answering on this transport - check it is")
					logWarn("running, on the same transport, and that nothing is dropping it")
				} else {
					logWarn("reached %s but the handshake failed: %v", p.cfg.Connect, err)
					logWarn("the two servers disagree - almost always a different security token")
				}
			}
			logDebug("carrier %d handshake: %v", idx, err)
			p.sleepBackoff(&backoff)
			continue
		}
		backoff = 500 * time.Millisecond
		l := newLink(idx, p.cfg, conn, keys, p)
		p.install(idx, l)
		logDebug("carrier %d up to %s", idx, p.cfg.Connect)
		p.noteStrength()
		l.run() // blocks until the carrier dies
		select {
		case <-p.closed:
			return
		case <-time.After(300 * time.Millisecond):
		}
	}
}

func (p *pool) sleepBackoff(b *time.Duration) {
	j := time.Duration(mrand.Int63n(int64(*b/2 + 1)))
	select {
	case <-time.After(*b + j):
	case <-p.closed:
	}
	if *b < 8*time.Second {
		*b *= 2
	}
}

// A 24-carrier tunnel used to write 24 near-identical lines every time it
// came up, and the same again every time the far end restarted, which buried
// the one line a reader was looking for. Report the strength instead, and
// only when it changes something worth acting on.
// firstIn reports whether this kind of failure is worth a line right now:
// the first one, and then at most one a minute.
func (p *pool) firstIn(kind string, every time.Duration) bool {
	p.errMu.Lock()
	defer p.errMu.Unlock()
	if p.errSeen == nil {
		p.errSeen = make(map[string]time.Time)
	}
	now := time.Now()
	if last, ok := p.errSeen[kind]; ok && now.Sub(last) < every {
		return false
	}
	p.errSeen[kind] = now
	return true
}

func (p *pool) noteStrength() {
	select {
	case <-p.closed:
		// stopping on purpose: the strength going to zero is the point,
		// not news
		return
	default:
	}
	p.mu.Lock()
	n := 0
	for _, l := range p.links {
		if l != nil && l.alive() {
			n++
		}
	}
	was := p.reported
	p.reported = n
	why := p.lastDown
	p.mu.Unlock()

	switch {
	case was == n:
		// nothing a reader would act on
	case was == 0 && n > 0:
		logInfo("tunnel up: %d of %d carriers", n, p.cfg.Carriers)
	case n >= p.cfg.Carriers:
		logInfo("all %d carriers up", n)
	case n == 0:
		logWarn("every carrier is down: nothing can cross the tunnel now")
		if why != "" {
			logWarn("the last one went because: %s", why)
		}
	case n < was:
		logWarn("%d of %d carriers up, %d went down", n, p.cfg.Carriers, was-n)
		if why != "" {
			logWarn("  because: %s", why)
		}
	}
}

func (p *pool) install(idx int, l *link) {
	p.mu.Lock()
	old := p.links[idx]
	p.links[idx] = l
	p.mu.Unlock()
	if old != nil && old != l {
		old.close()
	}
}

// pick returns the live carrier with the fewest open streams. Spreading
// streams this way keeps every carrier's congestion window busy, which is the
// whole point of running more than one.
func (p *pool) pick() *link {
	p.mu.RLock()
	defer p.mu.RUnlock()
	var best *link
	bestN := 1 << 30
	for _, l := range p.links {
		if l == nil || !l.alive() {
			continue
		}
		if n := l.streamCount(); n < bestN {
			best, bestN = l, n
		}
	}
	return best
}

// pickHash pins a flow to a carrier by hash so that packets of one inner
// connection always take the same path and never arrive out of order.
func (p *pool) pickHash(h uint32) *link {
	p.mu.RLock()
	defer p.mu.RUnlock()
	n := 0
	for _, l := range p.links {
		if l != nil && l.alive() {
			n++
		}
	}
	if n == 0 {
		return nil
	}
	// Two passes rather than building a slice: in tun mode this runs once per
	// packet, and an allocation there would show up as GC pressure.
	k := int(h % uint32(n))
	for _, l := range p.links {
		if l != nil && l.alive() {
			if k == 0 {
				return l
			}
			k--
		}
	}
	return nil
}

func (p *pool) liveLinks() []*link {
	p.mu.RLock()
	defer p.mu.RUnlock()
	out := make([]*link, 0, maxCarriers)
	for _, l := range p.links {
		if l != nil {
			out = append(out, l)
		}
	}
	return out
}

func (p *pool) close() {
	p.closeOnce.Do(func() {
		close(p.closed)
		// The transport owns whatever it opened - a listener, a raw socket -
		// and closing it is what ends the accept loop.
		if p.tr != nil {
			p.tr.Close()
		}
		p.mu.Lock()
		links := p.links
		p.links = [maxCarriers]*link{}
		p.mu.Unlock()
		for _, l := range links {
			if l != nil {
				l.close()
			}
		}
	})
}

// stats summarises the pool. The round trip is the median of the carriers
// that have one, not the largest.
//
// It used to be the largest, and a carrier's figure is a last value that
// nothing ever clears - so one slow sample on one carrier of sixteen became
// the number shown for the whole tunnel, and stayed there. A tunnel whose
// path pings at 75 ms would report 2777, which is true of one carrier at one
// moment and of nothing else. The per-carrier table still shows every one, so
// the worst is a line away when it is wanted.
func (p *pool) stats() (up int, tx, rx uint64, rttUS int64) {
	var seen []int64
	for _, l := range p.liveLinks() {
		if !l.alive() {
			continue
		}
		up++
		tx += atomic.LoadUint64(&l.txBytes)
		rx += atomic.LoadUint64(&l.rxBytes)
		if r := atomic.LoadInt64(&l.rttUS); r > 0 {
			seen = append(seen, r)
		}
	}
	return up, tx, rx, medianRTT(seen)
}

// medianRTT is the middle sample, or zero when nothing has been measured.
func medianRTT(v []int64) int64 {
	if len(v) == 0 {
		return 0
	}
	sort.Slice(v, func(i, j int) bool { return v[i] < v[j] })
	return v[len(v)/2]
}
