<h1 align="center">Pingify</h1>
<p align="center">A multi-transport tunnel manager for the Iran ⇄ Kharej path, built for throughput, low jitter and staying up.</p>
<p align="center"><a href="README.md"><b>English</b></a> · <a href="README_FA.md">فارسی</a></p>
<p align="center">
  <a href="https://github.com/GreatTeejay/Pingify/releases/latest"><img src="https://img.shields.io/github/v/release/GreatTeejay/Pingify?style=flat-square" alt="release"></a>
  <a href="https://github.com/GreatTeejay/Pingify/releases"><img src="https://img.shields.io/github/downloads/GreatTeejay/Pingify/total?style=flat-square" alt="downloads"></a>
</p>

## Installation

Requirements: root, a systemd Linux, and a route between the two servers. Install on **both** the Iran server and the Kharej one.

```bash
wget -O Pingify.sh https://github.com/GreatTeejay/Pingify/releases/latest/download/Pingify.sh && bash Pingify.sh
```

Or with curl:

```bash
curl -fsSLo Pingify.sh https://github.com/GreatTeejay/Pingify/releases/latest/download/Pingify.sh && bash Pingify.sh
```

The script installs the `pingify` command, builds the core and writes the systemd units. It carries its own Go sources and vendored modules, so the build works on a server that cannot reach `proxy.golang.org` — which is most Iranian servers. Only the Go toolchain itself has to be fetched, and the script offers to do that when it is missing.

If `go.dev` cannot be reached from the server, point the fetch at a mirror — `PINGIFY_GO_URL=https://<mirror>/dl bash Pingify.sh` — and the script prints the sha256 of what arrived, to check against go.dev from any machine that can see it. A server that cannot build at all, too small or cut off, takes the core from the other one:

```bash
pingify core export            # on the server that built it: the binary, and its hash beside it
pingify core import FILE       # on the other: hash, architecture and version checked, then installed
```

**Upgrading to 1.1.0 is a both-ends change.** A 1.0.x core refuses any record over 2 KB on TCP MUX, WS MUX, WSS MUX, Chrome TLS MUX and Decoy TLS MUX, and 1.1.0 sends up to 16 KB; KCP MUX packets are sealed and a 1.0.x core cannot read them. Upgrade the two servers of a pair within minutes of each other, the far end first, and expect the forwarding tunnels between them to be down in between. Private links (GRE, GRE FOU, UDP, AmneziaWG, Fake TCP, ICMP) carry across versions unchanged. A server that also has forwarding tunnels to a third server has to upgrade that one too, or keep its shared core at 1.0.x until it can.

Run `pingify` again at any time for the menu.

<p align="center"><img src="assets/pingify-cover.png" alt="Pingify multi-transport tunnel" width="100%"></p>

> **Owner:** [GreatTeejay](https://github.com/GreatTeejay) · Source-available under a custom license. Only attributed GitHub forks are permitted; see [LICENSE](LICENSE).

## How it works

Users connect to a port on the **Iran** server. That traffic crosses to the **Kharej** server over a transport you choose, and arrives at the same port there, where your panel is listening.

```text
User → IRAN :8003  ══ the carrier ══  KHAREJ → 127.0.0.1:8003
```

There are two ways it crosses, and the transport decides which:

- **Forward** — the core answers on the ports itself. Every user connection becomes a stream with its own id, multiplexed over a small set of carrier connections. Nothing is added to the routing table and no device is created.
- **TUN** — the two servers get a private network of their own (`10.x.10.1` and `10.x.10.2`), and the kernel forwards the ports over it with a NAT rule the manager writes and re-applies at boot.

By default **Kharej opens the connection** (Reverse) and Iran waits for it — which is also the only way a CDN can sit in front of Iran. **Direct** turns it round: Iran connects out to Kharej. Iran's lines disagree about which way works (one test pair blackholed connections into Iran, another stopped what Iran sent on connections it opened), so if one direction does not carry traffic, try the other; a server behind NAT has to be the one that connects. Users and ports stay on Iran either way. The kernel links and ICMP (GRE, GRE FOU, AmneziaWG, ICMP) are not asked: Iran sends first.

## Transports

Twelve of them, in two groups. They carry the same traffic and differ in what they put on the wire — and so in speed, in how they survive a hostile path, and in what they need from the machine.

The config stores the short slug (`tcp`, `ws`, `wss`, `utls`, `fallback`, `kcp`, `icmp`, `gre`, `grefou`, `udp`, `rawtcp`, `awg`), so a tunnel keeps working across updates.

### Forwarding — your ports, carried over a connection

| Transport | What it is | Reach for it when | Costs |
|---|---|---|---|
| **TCP MUX** | Sixteen plain TCP connections with every stream multiplexed across them by id. A stall on one does not hold up the rest. | The route is clean and you want the fewest moving parts. **Start here.** | TCP inside TCP on a lossy link: both stacks retransmit the same loss. |
| **WS MUX** | An HTTP request that becomes a WebSocket, then RFC 6455 frames. Usually port 80, so a CDN can front it. | Only HTTP crosses, or something in front already terminates TLS. | No TLS of its own. Proxy idle limits apply. |
| **WSS MUX** | The same inside TLS, with the tunnel's domain in SNI, Host and Origin. Behind Cloudflare the origin address never appears on the wire. | **Good for filtered Iran.** You have a domain, or you want to sit behind a CDN — and above all when Iran blocks the foreign server's address: with a Cloudflare domain fronting the Iran server, Iran only ever talks to Cloudflare. | TLS and CDN overhead, and whatever the CDN's policy allows. Through Cloudflare the round trip was 111 ms where the direct path is 40. |
| **Chrome TLS MUX** | TLS whose handshake is shaped like Chrome's, so a fingerprint check sees a browser. | Plain TCP is throttled or reset, and TLS still passes. | A little more setup on the wire; nothing on the host. |
| **Decoy TLS MUX** | Chrome TLS MUX, and a real website served to anyone who probes the port instead of speaking the protocol. | The port will be scanned and you want it to look like a website. | The same as Chrome TLS MUX. |
| **KCP MUX** | The same streams as TCP MUX, over sixteen [KCP](https://github.com/xtaci/kcp-go) sessions on UDP: reliable and ordered, with a retransmit timer of its own instead of the kernel's. Since 1.1.0 every packet is sealed under XChaCha20-Poly1305 keyed from the token, so nothing on the wire says KCP. | TCP is throttled or reset and UDP still crosses. | UDP must pass. More CPU and memory than TCP; on a clean path TCP MUX with BBR is faster. |

### TUN — a private link the kernel routes over

| Transport | What it is | Reach for it when | Costs |
|---|---|---|---|
| **GRE** | The kernel's own tunnel, IP protocol 47. The lightest thing here. | Protocol 47 still passes and you want raw speed on a path you trust. | **No disguise at all.** Anything watching sees exactly what it is. |
| **GRE FOU** | The kernel's own GRE device wrapped in UDP (Linux FOU), so nothing on the path sees protocol 47 — and nothing reaches a process: the kernel carries it and the core only watches. Measured at 933 Mbit/s where our own GRE carried 396. | Protocol 47 is dropped, UDP passes, and you want kernel speed on a path you trust. | **No token on the wire**: anything that forges the far address and knows the port is inside. Turns generic receive offload off on the server's interface while it runs — everything else there pays a little — and back on when the tunnel is deleted. |
| **UDP** | Plain UDP on one port. | UDP crosses cleanly in both directions. | Many Iranian lines drop or throttle inbound UDP. |
| **AmneziaWG** | Obfuscated WireGuard: kernel speed, encrypted, and deliberately shaped not to look like WireGuard. | You want a full encrypted link with kernel performance. | The AmneziaWG tooling must install, and UDP must pass. |
| **Fake TCP** | TCP-shaped packets built and read on the device itself, above conntrack and every netfilter chain. There is no kernel socket to throttle. | A plain TCP tunnel connects and then stalls or dies for no reason the logs explain. | Linux, IPv4 and root on **both** ends. Installs a narrow RST-drop rule and removes it again. |
| **ICMP** | Packets carried inside pings. No port exists at all; each tunnel takes a session tag from its token, so several can share a host. | TCP and UDP are filtered but ping still answers. When Iran blocked the Turkey server's address, it was the one direct transport that still carried. | **The server stops answering ordinary pings while it runs**, and ICMP rate limits apply on the path. |

### Choosing one

No table knows your route. Start with **TCP MUX**: it needs nothing and works on most paths. **If Iran blocks the foreign server's address** — tunnels that connect and say they are up carry nothing, and the health check says nothing the size of data crosses — use **WSS MUX** (or WS MUX) in the Reverse direction through a Cloudflare name that fronts the Iran server (see [When Iran filters the foreign server](#when-iran-filters-the-foreign-server)), or **ICMP**. On the day it happened those were the only ones that carried (measurements, section 43). If the port is scanned or reset, move to **Chrome TLS MUX** or **Decoy TLS MUX**. If only web traffic crosses, use **WSS MUX** with a domain, and **WS MUX** on port 80 only when TLS is genuinely unavailable. If TCP is throttled in a way no log explains, try **Fake TCP**, or **KCP MUX** when UDP crosses; if everything but ping is filtered, **ICMP**. If protocol 47 is dropped and raw speed matters more than a token on the wire, **GRE FOU**.

Measure the same pair at the same hour and compare throughput, loss and jitter — not average ping alone. Numbers from real pairs are in [what was measured](docs/measured.md).

### On the wire

What each transport shows to something reading the path. This is what the code sends, not a claim about what any filter does with it.

| Transport | What a watcher sees | Readable |
|---|---|---|
| **AmneziaWG** | UDP whose handshake is preceded by junk packets and padded, with WireGuard's message types rewritten; every packet encrypted by the kernel. | nothing |
| **Chrome TLS MUX**, **Decoy TLS MUX** | A TLS 1.3 session whose ClientHello is Chrome's, to the name you chose. The decoy serves a real website to anyone who probes the port. | the SNI and the certificate |
| **WSS MUX** | TLS to your domain. Behind a CDN the origin's address never appears. | the domain |
| **KCP MUX** | UDP packets sealed under XChaCha20-Poly1305 keyed from the token: no KCP header, no lengths, random bytes and their timing. | nothing |
| **TCP MUX** | Plain TCP: a four-byte hello, then two bytes of length in front of each record. The records are your panel's TLS. Not a known protocol, and not hidden. | the framing |
| **WS MUX** | An HTTP Upgrade with Host and Origin, then WebSocket frames. | the handshake and the framing |
| **UDP**, **ICMP**, **Fake TCP** | Twelve bytes of tag and counter, then the IP packet as it left the device: its addresses, ports and TCP headers in the clear. ICMP puts that in a ping; Fake TCP puts a TCP header in front of it. | the inner packet's headers |
| **GRE**, **GRE FOU** | The kernel's GRE, bare or inside UDP. GRE FOU carries no tag at all. | everything |

For a link that has to survive inspection rather than throttling, take them in this order: **AmneziaWG** where UDP passes; **Chrome TLS MUX** or **Decoy TLS MUX** where it does not; **WSS MUX** behind a CDN where only web traffic crosses; **KCP MUX** where UDP passes but the AmneziaWG tooling will not install. The rest are for paths that are throttled rather than read: they are the fastest things here (GRE FOU measured 933 Mbit/s) and they hide nothing. Plain UDP is also policed by packet count on many Iranian lines whatever it carries (measurements, section 15). Two things no transport changes: the volume and timing of the traffic, and the fact that one address in Iran exchanges a great deal with one abroad.

### What the carrier count means

A carrier is a multiplexer, not a user connection: streams are opened, fed and closed on it by id, dozens at a time. More than one because one TCP flow on a shaped path is policed and many together are not — on the pair this was built for, one flow carried 0.39 Mbit/s where sixteen carried 743.

Sixteen, not eight, since 1.1.0, and for a different reason: every stream is pinned to one connection, so eight downloads on eight connections leave none free, and a small request that lands beside a download waits behind it. Measured under eight saturating streams, a small request answered in about 160 ms with sixteen connections and stalled for seconds with eight ([docs/measured.md](docs/measured.md), section 39). Sixteen is what eight busy streams cannot fill.

So the number is not "how many connections the traffic needs". It is how many places the tunnel can be cut at once and carry on, how finely a shaper's per-flow limit is divided, and how many connections are left free for what is small. It is editable per tunnel from **Manage ▸ Tuning**, between 1 and 32, and **both servers must use the same number**.

## Failover

A forward tunnel can be given backups: other forwarding transports to move to, by itself, when the one it runs on stops carrying — and to move back from once the first has been healthy again for a while. Choose them in the wizard's **Backups** step, or later under **Manage ▸ Tuning ▸ Failover**, in the order to try them. Behind a Cloudflare domain the wizard offers none: a backup dials the same domain on a port of its own, and Cloudflare would not carry it.

```toml
[failover]
backups = ["kcp:8443", "utls:8444"]   # the members after the primary
enabled = true                        # false keeps the list and runs the primary alone
prefer = "order"                      # or "fastest": the least round trip among those that answer
switch_after_sec = 25                 # silence before moving on
return_after_sec = 120                # a better member must answer this long to be moved back to; 0 never
```

The server that waits listens on every member at once and simply answers on whichever one records arrive on, so the two servers never have to agree on anything. The server that dials decides: after `switch_after_sec` with nothing arriving it tries every other member at once and takes the best that answers - the first in your list, or with `prefer = "fastest"` the one with the least round trip - and while it is on a lesser member it keeps probing the better ones and moves back to the best that has stayed healthy. **Tuning ▸ Failover** switches it on or off without losing the list. Connections move with the tunnel, from the last byte the far end acknowledged; a single stream running flat out, with more in flight than a stream may hold, is reset instead so its program reconnects.

Measured on the pair this was built for, with the primary's port blocked mid-transfer: the tunnel moved to KCP in fifteen seconds and back thirty seconds after the block lifted, and a 16 Mbit/s stream carried on across both moves. Details in [docs/failover.md](docs/failover.md). Private-link (TUN) transports cannot be backups.

## Quick start and the setup token

1. Run `pingify` on **Iran** and choose **New tunnel**, then **IRAN**.
2. Answer the wizard: transport, direction, the two addresses, the tunnel port, the ports your users connect to, and a preset.
3. Copy the whole **setup token** it prints.
4. Run `pingify` on **Kharej**, choose **New tunnel ▸ Paste a token**, and paste it.

The token begins with `PFY3.` and carries the whole configuration, including the security token, so there is nothing left to answer on the second server. Treat it like a password. Tokens from the previous format (`PFY2.`) are still accepted. Tunnels are named side first: `iran-tcp-8443`, `kharej-icmp-1`.

The tunnel's own port and the ports your users connect to are separate things. A WSS tunnel can meet on 443 and still carry `8003 → 127.0.0.1:8003`.

## Presets and tuning

| Preset | For | Receive queue (private links) | Unsent bound (TCP carriers) | Connections | Parity |
|---|---|---|---|---|---|
| **gaming** | lowest lag for a small packet | 256 KB | 64 KB | 16 | off |
| **stable** | a path that loses packets | 256 KB | 64 KB | 24 | 1 in 10 |
| **balanced** | sensible mix — the one to pick, and the default | 256 KB | 128 KB | 16 | off |
| **throughput** | many streams at once | 3 MB | 128 KB | 16 | off |
| **max** | a server with many users | 3 MB | 128 KB | 32 | off |

Every one of these numbers was measured on the reference pair (sections 35 to 41 of the measurements). The receive queue reaches the private links, the unsent bound the five TCP carriers, parity the transports that can rebuild a lost packet from it (UDP, ICMP, Fake TCP, AmneziaWG, KCP). Pick balanced unless one of the other four describes your situation exactly. A file from 1.0.x that says `download` is read as throughput and rewritten at upgrade.

The presets used to set three queue depths as well. In September 2026 that was measured on the reference pair and neither queue ever filled at any depth — sixteen streams at 621 Mbit/s put two million packets through with none dropped — so every preset now ships the same depth and the file says so. The whole of it is in [docs/measured.md](docs/measured.md), section 35.

Every setting the core reads is written into the `.toml` with the value it runs with, and only where something reads it: a TCP carrier's file carries no socket buffers, because naming one would turn off the kernel's window auto-tuning; a GRE FOU file carries no tuning at all, because the kernel moves it. `pingify-core -check` says which lines, if any, nothing reads. The Tuning screen edits the rest in place: profile, MTU, carrier count, keepalive, direction, log level, status and health ports.

GRE FOU is not shaped by the preset: the kernel carries it. KCP takes the connection count and parity from it, not a queue depth: its window is a ceiling on one stream's rate, not a queue to shorten.

**Optimize** changes the whole machine: socket ceilings, backlog, scheduler budget, MTU probing, and BBR with the `fq` queue discipline. The wizard offers it once, when the first tunnel is created on a server that still runs the distribution's settings; it is on the menu after that.

## WS, WSS and Cloudflare

**WS MUX** is a plain WebSocket for a direct path or a proxy that already handles `Upgrade: websocket`. **WSS MUX** adds TLS and suits a domain or a CDN.

| The fronted side | Listens on | Cloudflare SSL/TLS mode | WebSockets |
|---|---|---|---|
| No certificate — the default | 80, plain WebSocket | **Flexible** | Enabled |
| A self-signed certificate, and `listen_port = 443` | 443, TLS | **Full** | Enabled |
| A valid or Origin certificate, and `listen_port = 443` | 443, TLS | **Full (strict)** | Enabled |

Behind Cloudflare the fronted side has no certificate by default: it listens on **80** in plain WebSocket and the CDN's edges connect to it there, so Cloudflare's mode is **Flexible**, and the wizard asks for the domain rather than an address on that side. To encrypt the edge-to-origin leg as well, set a certificate under **Tuning ▸ Certificate** and `listen_port = 443` in the file; the mode is then Full, or Full (strict) with a certificate Cloudflare trusts. Use a Cloudflare-supported HTTPS port on the other end, normally 443. **DNS only** is for a direct path or for diagnosing the proxy. Occasional TLS scanner errors in the log are harmless while the carrier is healthy.

### When Iran filters the foreign server

Iran sometimes blocks a foreign server's address. Tunnels to it still connect and keep their heartbeat, but what the Iran server sends there over TCP stops, UDP flows die after a few packets, and connections opened from the foreign side carry nothing — while the same Iran server still reaches Cloudflare at full speed. Put the Iran server behind Cloudflare and let the foreign server come to it:

1. In Cloudflare, a DNS record for a name of yours pointing at the **Iran** server's address, **Proxied** (orange cloud), SSL/TLS mode **Flexible**, WebSockets on.
2. On the Iran server: **WSS MUX**, direction **Reverse**, this server's address = that name, the other = the foreign server's address, port **443**, and your ports.
3. Paste the token on the foreign server. It dials the name; Cloudflare carries it to the Iran server on port 80, and the Iran server never exchanges a packet with the blocked address.

Measured on 2026-09-26 with the Turkey server blocked: this carried 9.5 Mbit/s (the Turkey server's own ceiling) and dropped no carrier connection in its first minute and a half, where every direct transport but ICMP carried nothing.

## Operations

```bash
pingify                      # the menu
pingify --status             # every tunnel, one line each
pingify --check iran-tcp-8443   # a full health check; exits 0, 1 or 2
pingify --json --status      # the same, machine readable
journalctl -u pingify@iran-tcp-8443 -n 100 --no-pager
```

A timer runs the health check every 30 seconds and restarts a tunnel that has stopped hearing from the far end three times in a row. The menu also carries live logs, the ports screen, tuning, diagnostics, the blocking rules, update and uninstall.

- **Up, heard, and carrying nothing** — the check says the other server answers the heartbeat and nothing the size of data crosses. Something on the path lets small packets through and stops full-size ones: a filter on the foreign server's address (see [When Iran filters the foreign server](#when-iran-filters-the-foreign-server)), or a path smaller than the interface, which MTU probing under **Optimize** fixes.
- **Carrier up but nothing answers** — the tunnel carried the probe and the far service refused it. Check that something is really listening on that port on Kharej.
- **Ports changed and traffic vanished** — run **Apply firewall**. A stale redirect swallows every packet for that port and looks exactly like a broken tunnel.
- **A TUN tunnel is up but ping does not work** — that is deliberate for ICMP: the kernel must not answer echoes while the tunnel uses them. Use `pingify --check`, not `ping`, to test.

## Security

Read this before deciding what to run through it.

**The tunnel does not encrypt.** Every record carries an authentication tag derived from the tunnel's token, and a replayed packet is rejected, so nothing that does not hold the token can inject or replay traffic. What it does not do is hide the bytes: what crosses is expected to be TLS already, which is what a panel's traffic is.

Where encryption does exist, it comes from a layer around the tunnel: **WSS MUX**, **Chrome TLS MUX** and **Decoy TLS MUX** add TLS, **KCP MUX** seals every packet under XChaCha20-Poly1305 keyed from the token (since 1.1.0), and **AmneziaWG** is an encrypted kernel tunnel of its own. **GRE, GRE FOU, ICMP, UDP, Fake TCP, WS MUX and TCP MUX are not encrypted and not disguised.** GRE FOU carries no authentication tag either: the kernel moves its packets and the core never sees them. What each one shows the path is in [On the wire](#on-the-wire).

Protect the setup token, the `.toml` files and `/root/pingify`; the configs are written `rw-------` and the token never appears in a log.

## Files and development

```text
/usr/local/bin/pingify        the manager
/root/pingify/*.toml          one file per tunnel
/root/pingify/core/           the core binary and its sources
/root/pingify/state/          state the manager keeps
/etc/systemd/system/pingify@.service
parts/                        the manager, in order
tests/                        the test suites
build.sh                      assembles Pingify.sh
```

The engine's Go sources are not a second copy in this repository. `Pingify.sh` carries every one of them, which is how a server with no route to a Go proxy still builds the engine, and they come back out of it unchanged:

```bash
PINGIFY_NO_MAIN=1 bash -c '. ./Pingify.sh; write_core_sources .'
go test ./...
```

Edit `parts/` and the extracted Go tree, never the generated blocks inside `Pingify.sh`, then rebuild:

```bash
bash build.sh
bash tests/run.sh
```

`build.sh` refuses to write a script that does not parse, checks the sources come back out byte for byte, and proves they still compile offline for `linux/amd64` and `linux/arm64`.

## License

Copyright © 2026 **GreatTeejay**. All rights reserved except the permissions in [LICENSE](LICENSE). An attributed GitHub fork with intact history, license and original link is permitted. Independent copying, mirroring, rebranding, redistribution, relicensing or selling is prohibited without written permission.

<p align="center">Built and maintained by <a href="https://github.com/GreatTeejay">GreatTeejay</a>.</p>
