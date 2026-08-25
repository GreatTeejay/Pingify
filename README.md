<h1 align="center">Pingify</h1>
<p align="center">An encrypted, high-performance multi-transport tunnel manager for difficult and unstable network paths.</p>
<p align="center"><a href="README.md"><b>English</b></a> · <a href="README_FA.md">فارسی</a></p>
<p align="center">
  <a href="https://github.com/GreatTeejay/Pingify/releases/latest"><img src="https://img.shields.io/github/v/release/GreatTeejay/Pingify?style=flat-square" alt="release"></a>
  <a href="https://github.com/GreatTeejay/Pingify/actions/workflows/release.yml"><img src="https://img.shields.io/github/actions/workflow/status/GreatTeejay/Pingify/release.yml?style=flat-square&label=build" alt="build"></a>
  <a href="https://github.com/GreatTeejay/Pingify/releases"><img src="https://img.shields.io/github/downloads/GreatTeejay/Pingify/total?style=flat-square" alt="downloads"></a>
</p>

## Installation

Requirements: root, a systemd-based Linux, and connectivity between the two servers. Install on **both Iran and Kharej**.

```bash
bash <(wget -qO- https://github.com/GreatTeejay/Pingify/releases/latest/download/Pingify.sh)
```

Or with curl:

```bash
bash <(curl -fsSL https://github.com/GreatTeejay/Pingify/releases/latest/download/Pingify.sh)
```

The manager installs `pingify`, the matching core binary and the systemd units. Go is needed only when no prebuilt core can be reached and the engine has to be compiled locally — the script carries its own sources and vendored modules for exactly that case, so the build still works on a server that cannot reach `proxy.golang.org`.

Run it again at any time to update, edit or remove a tunnel.

<p align="center"><img src="assets/pingify-cover.png" alt="Pingify high-performance multi-transport tunnel" width="100%"></p>

Pingify connects an **Iran server** to a **Kharej server** and carries TCP services through a transport you choose. It aims at high throughput for video and browsing, low and stable latency for games, automatic recovery from a broken carrier, and a setup flow that starts on the Iran side.

Transport-specific batching, multiplexing, bounded queues, socket tuning, optional forward error correction and five workload presets can give excellent throughput when the transport matches the route. What you actually get still depends on the two servers, congestion, loss, MTU, routing and filtering. No tunnel can promise one number on every network.

> **Owner:** [GreatTeejay](https://github.com/GreatTeejay) · Source-available under a custom license. Only attributed GitHub forks are permitted; see [LICENSE](LICENSE).

## How it works

The standard deployment is reverse: Kharej opens the carrier to Iran, and users connect to forwarded ports on Iran.

```text
User → Iran :8010  ══ encrypted carrier ══  Kharej → 127.0.0.1:8010
```

Every incoming connection becomes a logical stream with an id and a credit window of its own. Pingify multiplexes those streams over the active carriers, authenticates every record, rebuilds them at the far end, and replaces a carrier that dies without dropping the tunnel. Modes are **Forward** (port mapping), **TUN** (a private routed link) and, where supported, **Both**.

## Transports

Nine transports in two groups. They all move the same traffic and differ only in what they put on the wire — and therefore in how fast they are, how well they survive a hostile path, and what they need from the machine.

The config always stores the short slug (`tcp`, `pck`, `kcp`, `udp`, `ws`, `wss`, `icmp`, `gre`, `awg`), so an existing tunnel keeps its name and keeps working across updates.

### Forwarding — your ports, carried over a connection

The engine is the only thing in the path. Nothing is added to the routing table and no kernel device is created.

| Transport | What it is | Reach for it when | Costs |
|---|---|---|---|
| **TCP MUX** | Several plain TCP connections, with every stream multiplexed across them by id. A stall on one carrier does not hold up the rest. | The route is clean and you want the fewest moving parts. **Start here.** | TCP inside TCP on a lossy link: both stacks retransmit the same loss. |
| **TCP PCK** | The KCP + FEC engine inside TCP packets this process builds and reads on the device itself, upstream of conntrack and every netfilter chain. Nothing is forged; what does not exist is the kernel connection. | A plain TCP tunnel connects and then stalls, dies or is throttled for no reason the logs explain. | Linux, IPv4 and root/CAP_NET_RAW on **both** ends. Installs narrow RST and NOTRACK rules, and removes them again. |
| **KCP FEC** | KCP over UDP on a 10 ms clock, with Reed-Solomon parity so a short loss burst is repaired immediately instead of waiting a full round trip for a resend. | The route loses packets: video, calls, games, anything where a stall hurts more than a little overhead. | UDP must pass. Parity is real bandwidth and real CPU. |
| **UDP ARQ** | Pingify's own reliability layer on raw datagrams — sequence numbers, cumulative acks, fast retransmit, a send window. One repair layer instead of two. | UDP is clean and you want reliability without TCP inside TCP. | UDP filtering, throttling and reordering. |
| **WS MUX** | An HTTP request that becomes a WebSocket, then RFC 6455 frames. A couple of connections, every stream multiplexed inside them. Anything that is not the tunnel gets a stock nginx page. | Only HTTP gets through, or something in front of you terminates TLS already. | Not encrypted by itself — the tunnel's own records are, the WebSocket around them is not. Proxy idle limits apply. Port 80 is the one to use. |
| **WSS MUX** | The same inside TLS, with the tunnel domain in SNI, Host and Origin. Behind a CDN the Kharej address never appears on the wire at all. | You have a domain, or you want to sit behind Cloudflare. | TLS and CDN overhead, and CDN policy. Certificate handling to arrange once. |

### TUN — a private link the kernel routes over

These build an interface. Forwarding can be done by the engine or by the kernel with iptables.

| Transport | What it is | Reach for it when | Costs |
|---|---|---|---|
| **ICMP** | The reliable transport carried inside ping packets. No port exists at all; each tunnel derives a session tag from its token so several can share one host. | TCP and UDP are filtered but ICMP still answers — because ping is how a network proves itself reachable. | The slowest thing here and subject to ICMP rate limits. A fallback, not a default. Linux and root. |
| **GRE** | The kernel's own tunnel, IP protocol 47. The fastest and lightest option by a distance. | The path still passes protocol 47 and you want raw speed on a link you already trust. | **No encryption and no disguise.** Anything watching the path can see exactly what it is. |
| **AmneziaWG** | Obfuscated WireGuard: kernel-speed, encrypted, and deliberately shaped not to look like WireGuard. | You want a full encrypted link with kernel performance and real resistance to fingerprinting. | The AmneziaWG tooling must install, and UDP must pass. |

### Choosing one

There is no universal winner, and a table cannot know your route. Start with **TCP MUX**: it needs nothing and it works on most paths. If it is slow on a lossy link, try **KCP FEC**. If it connects and then dies for no reason you can find in a log, that is what **TCP PCK** is for. If only web traffic crosses, use **WSS MUX** with a domain — and **WS MUX** on port 80 only when TLS is genuinely unavailable.

Benchmark the same two servers at the same hour and compare throughput, loss and jitter — not only average ping.

### What MUX means here

A carrier has always been a multiplexer: streams are opened, fed and closed on it by id, each with its own credit window, dozens at a time. So the carrier count is not "how many connections the traffic needs" — it is how many places the tunnel can be cut at once and carry on.

- **TCP** braids several carriers; a stream stays pinned to one so its ordering is preserved.
- **WS/WSS** hold two by default and four at most. Twenty WebSockets opened at once from one address is the most recognisable thing a tunnel can do; two is what a browser holds open all day.
- **Packet transports** use small carrier sets with bounded batches and session-aware delivery.
- More carriers are not automatically faster. Start with a preset and measure before raising anything.

## Quick start and setup token

1. Run `sudo pingify` on **Iran** and choose **Create tunnel**.
2. Choose the transport, the Iran role, mode, ports and preset.
3. Copy the whole generated **setup token**.
4. Run `sudo pingify` on **Kharej**, create the same transport and choose **Paste setup token**.
5. Paste it, then run Health Check on both servers.

The `p5` token carries the transport, the peer relationship, the endpoint, carriers, keepalive, MUX window, buffers, mappings, transport options, shaping and key material. It has an integrity checksum and strict validation. Keep it secret, and never tune only one side afterwards. Older `p2`–`p4` tokens still work. Names are side-first: `iran-kcp-443`, `kharej-kcp-443`.

Carrier ports and service ports are separate. WSS can listen on `443`, forward `:8010 → 127.0.0.1:8010`, and the user's endpoint stays Iran port `8010`.

## Presets and tuning

| Preset | Goal | Behaviour |
|---|---|---|
| **Gaming** | Minimum queueing | Small queues and windows, conservative batches |
| **Latency** | Interactive traffic | Low delay with a little more headroom |
| **Balanced** | Daily use | Browsing, social media, video and games |
| **Download** | Video and large transfers | Larger windows, buffers and batches |
| **Extreme** | Strong hosts, high-BDP paths | Maximum concurrency; measure before trusting it |

The same preset deliberately produces different numbers per transport, because the transports are not the same shape:

- **WS/WSS** — a couple of connections with a larger per-stream window and bigger record buffers, rather than pretending the eight to twenty-four carriers the TCP presets use exist here.
- **KCP/PCK** — a small session pool, packet buffers, MTU near 1280, a short flush interval; KCP adds parity on top.
- **ICMP/UDP** — packet-aware workers and batches, without the stream-only knobs.
- **TCP** — several carriers and moderate windows, to keep head-of-line amplification in check.

Every preset uses the **same keepalive**, on purpose. What keeps a carrier alive is how often the *peer* speaks, so two ends on different presets used to disagree about how long to wait — and the more impatient one hung up on a healthy tunnel.

Start with **Balanced**. For games, compare Gaming and Latency on jitter and loss. For video, try Download before Extreme. Raise KCP parity only against measured loss. If load causes latency or collapse, try *fewer* queues and carriers before adding more.

Per-tunnel tuning lives in each config and is mirrored by the token. **Host Tuning** is separate: it changes Linux socket ceilings, UDP minima, backlog, scheduler budget and MTU probing for the whole machine. **BBR** is separate again. Apply host-wide changes deliberately.

## WS, WSS and Cloudflare

**WS** is a plain HTTP WebSocket for a direct path, or for a proxy that already handles `Upgrade: websocket`. **WSS** adds TLS and suits a domain or CDN path.

| Origin certificate | Cloudflare proxy | SSL/TLS mode | WebSockets |
|---|---|---|---|
| Valid trusted/origin cert | Orange cloud if desired | **Full (strict)** | Enabled |
| Self-signed cert | Orange cloud if desired | **Full** | Enabled |

Use a Cloudflare-supported HTTPS origin port, normally 443. Use **DNS only** for a direct connection or to diagnose the proxy. Both ends must agree on hostname, path and validation policy. Occasional TLS scanner errors in the log are harmless while the real carrier is healthy.

## Operations and troubleshooting

```bash
sudo pingify
systemctl status pingify@iran-kcp-443 --no-pager
journalctl -u pingify@iran-kcp-443 -n 100 --no-pager
curl -s http://127.0.0.1:9702/status
ss -ltnp
```

The menu carries live logs, config validation, a paired Health Check, remote forwarded-port probes, firewall rebuild, restart, edit, update and uninstall.

- **Carrier up, backend EOF or refused** — the tunnel carried the probe. Check that the service is actually listening on the Kharej target address and port.
- **Periodic reconnects** — compare versions and keepalive on both ends, then firewall, NAT or CDN idle timeout, clock skew, proxy and MTU.
- **Stale forwarding rules** — run **Apply firewall** after changing or removing mappings. An old redirect pointing at an address that has gone will swallow every packet for that port, which looks exactly like a broken tunnel.

## Security

The core records are authenticated AES-256-GCM with HKDF-derived session material, and the token itself is never sent on the wire — each side proves it holds the token with an HMAC over a fresh nonce. WSS adds an outer TLS layer. AmneziaWG uses its own encrypted kernel tunnel. **GRE is not encrypted.**

Protect setup tokens, keys, configs and `/root/Pingify`. Turn shaping or encryption off only when you understand the trust boundary you are changing.

## Files and development

```text
/usr/local/bin/pingify        manager
/usr/local/bin/pingify-core   core
/root/Pingify/*.toml          tunnel configs
/root/Pingify/.state/         state
parts/                        ordered manager source
core/                         engine source and vendored modules
tests/                        test suites
build.sh                      assembles Pingify.sh
```

```bash
bash build.sh
bash tests/run.sh
```

Edit `parts/` and `core/`, never the generated blocks inside `Pingify.sh`, then rebuild. `build.sh` refuses to write a script that does not parse, and verifies that the embedded sources and vendored modules come back out byte for byte.

## License

Copyright © 2026 **GreatTeejay**. All rights reserved except the permissions in [LICENSE](LICENSE). An attributed GitHub fork with intact history, license and original link is permitted. Independent copying, mirroring, rebranding, redistribution, relicensing or selling is prohibited without written permission.

<p align="center">Built and maintained by <a href="https://github.com/GreatTeejay">GreatTeejay</a>.</p>
