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
bash <(wget -qO- https://github.com/GreatTeejay/Pingify/releases/latest/download/Pingify.sh)
```

Or with curl:

```bash
bash <(curl -fsSL https://github.com/GreatTeejay/Pingify/releases/latest/download/Pingify.sh)
```

The script installs the `pingify` command, builds the core and writes the systemd units. It carries its own Go sources and vendored modules, so the build works on a server that cannot reach `proxy.golang.org` — which is most Iranian servers. Only the Go toolchain itself has to be fetched, and the script offers to do that when it is missing.

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

By default **IRAN opens the connection** (Direct). Choose **Reverse** when a CDN sits in front of Iran or Iran is behind NAT, and Kharej connects in instead. Users and ports stay on Iran either way.

## Transports

Twelve of them, in two groups. They carry the same traffic and differ in what they put on the wire — and so in speed, in how they survive a hostile path, and in what they need from the machine.

The config stores the short slug (`tcp`, `ws`, `wss`, `utls`, `fallback`, `kcp`, `icmp`, `gre`, `grefou`, `udp`, `rawtcp`, `awg`), so a tunnel keeps working across updates.

### Forwarding — your ports, carried over a connection

| Transport | What it is | Reach for it when | Costs |
|---|---|---|---|
| **TCP MUX** | Eight plain TCP connections with every stream multiplexed across them by id. A stall on one does not hold up the rest. | The route is clean and you want the fewest moving parts. **Start here.** | TCP inside TCP on a lossy link: both stacks retransmit the same loss. |
| **WS MUX** | An HTTP request that becomes a WebSocket, then RFC 6455 frames. Usually port 80, so a CDN can front it. | Only HTTP crosses, or something in front already terminates TLS. | No TLS of its own. Proxy idle limits apply. |
| **WSS MUX** | The same inside TLS, with the tunnel's domain in SNI, Host and Origin. Behind Cloudflare the origin address never appears on the wire. | You have a domain, or you want to sit behind a CDN. | TLS and CDN overhead, and whatever the CDN's policy allows. |
| **Chrome TLS MUX** | TLS whose handshake is shaped like Chrome's, so a fingerprint check sees a browser. | Plain TCP is throttled or reset, and TLS still passes. | A little more setup on the wire; nothing on the host. |
| **Decoy TLS MUX** | Chrome TLS MUX, and a real website served to anyone who probes the port instead of speaking the protocol. | The port will be scanned and you want it to look like a website. | The same as Chrome TLS MUX. |
| **KCP MUX** | The same streams as TCP MUX, over eight [KCP](https://github.com/xtaci/kcp-go) sessions on UDP: reliable and ordered, with a retransmit timer of its own instead of the kernel's. | TCP is throttled or reset and UDP still crosses. | UDP must pass. More CPU and memory than TCP; on a clean path TCP MUX with BBR is faster. |

### TUN — a private link the kernel routes over

| Transport | What it is | Reach for it when | Costs |
|---|---|---|---|
| **ICMP** | Packets carried inside pings. No port exists at all; each tunnel takes a session tag from its token, so several can share a host. | TCP and UDP are filtered but ping still answers. | **The server stops answering ordinary pings while it runs**, and ICMP rate limits apply on the path. |
| **GRE** | The kernel's own tunnel, IP protocol 47. The lightest thing here. | Protocol 47 still passes and you want raw speed on a path you trust. | **No disguise at all.** Anything watching sees exactly what it is. |
| **UDP** | Plain UDP on one port. | UDP crosses cleanly in both directions. | Many Iranian lines drop or throttle inbound UDP. |
| **Fake TCP** | TCP-shaped packets built and read on the device itself, above conntrack and every netfilter chain. There is no kernel socket to throttle. | A plain TCP tunnel connects and then stalls or dies for no reason the logs explain. | Linux, IPv4 and root on **both** ends. Installs a narrow RST-drop rule and removes it again. |
| **AmneziaWG** | Obfuscated WireGuard: kernel speed, encrypted, and deliberately shaped not to look like WireGuard. | You want a full encrypted link with kernel performance. | The AmneziaWG tooling must install, and UDP must pass. |
| **GRE FOU** | The kernel's own GRE device wrapped in UDP (Linux FOU), so nothing on the path sees protocol 47 — and nothing reaches a process: the kernel carries it and the core only watches. Measured at 933 Mbit/s where our own GRE carried 396. | Protocol 47 is dropped, UDP passes, and you want kernel speed on a path you trust. | **No token on the wire**: anything that forges the far address and knows the port is inside. Turns generic receive offload off on the server's interface while it runs — everything else there pays a little — and back on when the tunnel is deleted. |

### Choosing one

No table knows your route. Start with **TCP MUX**: it needs nothing and works on most paths. If the port is scanned or reset, move to **Chrome TLS MUX** or **Decoy TLS MUX**. If only web traffic crosses, use **WSS MUX** with a domain, and **WS MUX** on port 80 only when TLS is genuinely unavailable. If TCP is throttled in a way no log explains, try **Fake TCP**, or **KCP MUX** when UDP crosses; if everything but ping is filtered, **ICMP**. If protocol 47 is dropped and raw speed matters more than a token on the wire, **GRE FOU**.

Measure the same pair at the same hour and compare throughput, loss and jitter — not average ping alone. Numbers from real pairs are in [what was measured](docs/measured.md).

### What the carrier count means

A carrier is a multiplexer, not a user connection: streams are opened, fed and closed on it by id, dozens at a time. Eight is the default because one TCP flow on a shaped path is policed and eight together are not — on the pair this was built for, one flow carried 0.39 Mbit/s where sixteen carried 743.

So the number is not "how many connections the traffic needs". It is how many places the tunnel can be cut at once and carry on, and how finely a shaper's per-flow limit is divided. It is editable per tunnel from **Manage ▸ Tuning**, between 1 and 32, and **both servers must use the same number**.

## Failover

A forward tunnel can be given backups: other forwarding transports to move to, by itself, when the one it runs on stops carrying — and to move back from once the first has been healthy again for a while. Choose them in the wizard's **Backups** step, or later under **Manage ▸ Tuning ▸ Failover**, in the order to try them.

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

| Preset | Goal | What it changes |
|---|---|---|
| **Gaming** | Lowest delay under load | Queue 600 packets, 256 KB receive buffer |
| **Balanced** | Daily use — the one to pick if unsure | Queue 900 packets, 256 KB receive buffer |
| **Download** | Most throughput for many streams | Queue 1500 packets, 3 MB receive buffer |

Every setting the core reads is written into the `.toml` as a number, so what the file says is what the tunnel runs. The Tuning screen edits them in place: profile, queue depth, MTU, carrier count, keepalive, direction, log level, status and health ports.

Under a few hundred users on a TUN transport, **Download** is the one to choose: on a link that loses packets it cut stalls and lost packets by roughly four to one against Balanced. On the forwarding transports the preset made no measurable difference.

**Optimize** is separate and changes the whole machine: socket ceilings, backlog, scheduler budget, MTU probing, and BBR with the `fq` queue discipline. Apply it once on each server.

## WS, WSS and Cloudflare

**WS MUX** is a plain WebSocket for a direct path or a proxy that already handles `Upgrade: websocket`. **WSS MUX** adds TLS and suits a domain or a CDN.

| Origin certificate | Cloudflare proxy | SSL/TLS mode | WebSockets |
|---|---|---|---|
| Valid trusted or origin cert | Orange cloud if desired | **Full (strict)** | Enabled |
| Self-signed cert | Orange cloud if desired | **Full** | Enabled |

Behind Cloudflare, the fronted side listens on **80** and the CDN's edges connect to it, so the wizard asks for the domain rather than an address on that side. Use a Cloudflare-supported HTTPS port on the other end, normally 443. **DNS only** is for a direct path or for diagnosing the proxy. Occasional TLS scanner errors in the log are harmless while the carrier is healthy.

## Operations

```bash
pingify                      # the menu
pingify --status             # every tunnel, one line each
pingify --check iran-tcp-8443   # a full health check; exits 0, 1 or 2
pingify --json --status      # the same, machine readable
journalctl -u pingify@iran-tcp-8443 -n 100 --no-pager
```

A timer runs the health check every 30 seconds and restarts a tunnel that has stopped hearing from the far end three times in a row. The menu also carries live logs, the ports screen, tuning, diagnostics, the blocking rules, update and uninstall.

- **Carrier up but nothing answers** — the tunnel carried the probe and the far service refused it. Check that something is really listening on that port on Kharej.
- **Ports changed and traffic vanished** — run **Apply firewall**. A stale redirect swallows every packet for that port and looks exactly like a broken tunnel.
- **A TUN tunnel is up but ping does not work** — that is deliberate for ICMP: the kernel must not answer echoes while the tunnel uses them. Use `pingify --check`, not `ping`, to test.

## Security

Read this before deciding what to run through it.

**The tunnel does not encrypt.** Every record carries an authentication tag derived from the tunnel's token, and a replayed packet is rejected, so nothing that does not hold the token can inject or replay traffic. What it does not do is hide the bytes: what crosses is expected to be TLS already, which is what a panel's traffic is.

Where encryption does exist, it comes from a layer around the tunnel: **WSS MUX** adds TLS, **AmneziaWG** is an encrypted kernel tunnel of its own. **GRE, GRE FOU, ICMP, UDP, KCP MUX, Fake TCP and TCP MUX are not encrypted and not disguised.** GRE FOU carries no authentication tag either: the kernel moves its packets and the core never sees them.

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
