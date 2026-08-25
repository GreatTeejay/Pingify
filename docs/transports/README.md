# Transports

Nine transports in two groups. They all move the same traffic and differ only in what they put on the wire — and therefore in how fast they are, how well they survive a hostile path, and what they need from the machine.

The config always stores a short slug (`tcp`, `pck`, `kcp`, `udp`, `ws`, `wss`, `icmp`, `gre`, `awg`), so a tunnel keeps its name and its service across updates and renames.

---

## FORWARDING — your ports, carried over a connection

The engine is the only thing in the path. Nothing is added to the routing table and no kernel device is created.

| Transport | One line | Needs | |
|---|---|---|---|
| **TCP MUX** | Several plain TCP connections, every stream shared across them | — | [→](tcp-mux.md) |
| **TCP PCK** | The same reliability inside TCP packets the kernel never sees | Linux, root | [→](tcp-pck.md) |
| **KCP FEC** | Repairs loss without waiting for a resend | UDP open | [→](kcp-fec.md) |
| **UDP ARQ** | Reliability in userspace, no TCP inside TCP | UDP open | [→](udp-arq.md) |
| **WS MUX** | An ordinary WebSocket — goes where HTTP goes | — | [→](ws-mux.md) |
| **WSS MUX** | The same inside TLS, and behind a CDN if you want | certificate | [→](wss-mux.md) |

## TUN — a private link the kernel routes over

These build an interface. Forwarding is done by the engine or by the kernel with iptables.

| Transport | One line | Needs | |
|---|---|---|---|
| **ICMP** | Inside ping packets — no port at all | Linux, root | [→](icmp.md) |
| **GRE** | The kernel's own tunnel: fastest, and plainly visible | kernel GRE | [→](gre.md) |
| **AmneziaWG** | Obfuscated WireGuard — encrypted, kernel speed | AmneziaWG, UDP | [→](amneziawg.md) |

---

## Choosing one

There is no universal winner and no table can know your route. The order below is what to try, not a ranking.

**Start with [TCP MUX](tcp-mux.md).** It needs nothing installed, nothing opened, and no privileges. On a clean route it is as fast as anything here. Most tunnels should stop at this step.

**If it is slow on a lossy link, try [KCP FEC](kcp-fec.md).** TCP inside TCP means both stacks retransmit the same loss and back off against each other. KCP repairs the common one-or-two-packet burst with parity, before anything above notices.

**If it connects and then dies for no reason you can find in a log, that is [TCP PCK](tcp-pck.md).** It does not use the kernel's TCP stack at all, so the machinery that resets or throttles a long-lived flow has no connection to act on.

**If only web traffic crosses, use [WSS MUX](wss-mux.md)** with a domain, and put it behind a CDN if you have one — then the Kharej address never appears on the wire. Use [WS MUX](ws-mux.md) on port 80 only when TLS is genuinely unavailable.

**If TCP and UDP are both filtered but ping still answers, [ICMP](icmp.md).** It is the slowest thing here and it is a fallback, not a default.

**If you want a full private link,** [AmneziaWG](amneziawg.md) for an encrypted one and [GRE](gre.md) for a fast, visible one on a path you already trust.

### Measuring, not guessing

Test the same two servers at the same hour, and compare **throughput, loss and jitter** — not only average ping. A transport that wins on idle ping and collapses under load is the wrong answer.

The status endpoint gives per-carrier numbers while traffic is running:

```bash
curl -s http://127.0.0.1:9702/status
```

---

## What MUX means here

A carrier has always been a multiplexer: streams are opened, fed and closed on it by id, each with its own credit window, dozens at a time. So the carrier count is not "how many connections the traffic needs" — it is **how many places the tunnel can be cut at once and carry on**.

- **TCP** braids several carriers, and a stream stays pinned to one so its ordering is preserved.
- **WS/WSS** hold two by default and four at most. Twenty WebSockets opened at once from one address is the most recognisable thing a tunnel can do; two is what a browser holds open all day.
- **Packet transports** use small carrier sets with bounded batches and session-aware delivery.

More carriers are not automatically faster. Past a certain point they only multiply acknowledgements, timers and reordering. Start with a preset and measure before raising anything — see [Tuning](../tuning.md).

## Encryption, per transport

Every transport carries the same authenticated AES-256-GCM records underneath, and **the security token is never sent on the wire** — each end proves it holds the token with an HMAC over a fresh nonce.

What differs is the outer layer:

| | Outer layer |
|---|---|
| TCP MUX, UDP ARQ, WS MUX | None — the inner records are the encryption |
| KCP FEC, TCP PCK, ICMP | A packet-layer cipher keyed from the token, which also hides the headers |
| WSS MUX | TLS |
| AmneziaWG | Its own encrypted kernel tunnel |
| **GRE** | **None at all — not even inner records. It is a plain kernel tunnel.** |

See [Security](../security.md).
