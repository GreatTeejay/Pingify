<p align="center"><img src="assets/pingify-cover.png" alt="Pingify high-performance multi-transport tunnel" width="100%"></p>

<h1 align="center">Pingify</h1>
<p align="center">An encrypted, high-performance multi-transport tunnel manager for difficult and unstable network paths.</p>
<p align="center"><a href="README.md"><b>English</b></a> · <a href="README_FA.md">فارسی</a></p>
<p align="center">
  <a href="https://github.com/GreatTeejay/Pingify/releases/latest"><img src="https://img.shields.io/github/v/release/GreatTeejay/Pingify?style=flat-square" alt="release"></a>
  <a href="https://github.com/GreatTeejay/Pingify/actions/workflows/release.yml"><img src="https://img.shields.io/github/actions/workflow/status/GreatTeejay/Pingify/release.yml?style=flat-square&label=build" alt="build"></a>
  <a href="https://github.com/GreatTeejay/Pingify/releases"><img src="https://img.shields.io/github/downloads/GreatTeejay/Pingify/total?style=flat-square" alt="downloads"></a>
</p>

Pingify connects an **Iran server** to a **Kharej server** and carries TCP services through a selectable transport. It targets high throughput for video and browsing, low and stable latency for games, automatic recovery, and a simple Iran-first setup flow.

Pingify is built for speed. Transport-specific batching, MUX, bounded queues, socket tuning, optional FEC and five workload presets can provide excellent throughput when the transport matches the route. Results still depend on the servers, congestion, loss, MTU, routing and filtering; no tunnel can guarantee one number on every network.

> **Owner:** [GreatTeejay](https://github.com/GreatTeejay) · Source-available under a custom license. Only attributed GitHub forks are permitted; see [LICENSE](LICENSE).

## How it works

The standard deployment uses reverse establishment: Kharej opens the carrier to Iran, while users connect to forwarded ports on Iran.

```text
User → Iran :8010  ══ encrypted TCP/UDP/KCP/PCK/ICMP/WS/WSS carrier ══  Kharej → 127.0.0.1:8010
```

Each incoming TCP connection becomes a logical stream. Pingify multiplexes streams on the active carrier set, protects records, reconstructs them at the far end and reconnects failed carriers automatically. Available modes are **Forward** (port mapping), **TUN** (private routed link) and, where supported, **Both**.

## Highlights

- Nine managed transports: TCP, UDP ARQ, KCP + FEC, PCK, ICMP, WS, WSS, GRE and AmneziaWG.
- AES-256-GCM core records, authenticated setup, key derivation and replay controls.
- MUX, keepalive, carrier health, reconnect, status endpoint and systemd supervision.
- Iran-first `p5` setup token that mirrors the complete configuration on Kharej.
- Five workload presets and expert custom settings.
- Independent stream, packet and WebSocket tuning—settings do not leak between transports.
- Optional frame-length shaping, firewall automation, live logs and paired health checks.
- Linux amd64/arm64 release binaries.

## Transport guide

| Transport | Best use | Strength | Trade-off |
|---|---|---|---|
| **KCP + FEC** | Lossy UDP routes, video/downloads | Fast recovery and high throughput | FEC/CPU overhead; UDP required |
| **PCK** | Routes that throttle long-lived TCP | Raw TCP-like packets, no kernel TCP session | Linux, IPv4 and root/CAP_NET_RAW |
| **ICMP** | Restricted routes where ICMP is stable | No carrier port; resilient fallback | Often rate-limited; route-dependent ceiling |
| **UDP ARQ** | Low-latency packet transport | Responsive with loss recovery | UDP filtering/reordering |
| **TCP MUX** | Clean, compatible routes | Multiple carrier braid | TCP-over-TCP on lossy links |
| **WS** | Direct HTTP/proxy paths | One WebSocket with logical MUX | No outer TLS; proxy idle limits |
| **WSS** | Domain, TLS or CDN path | TLS outer layer and WS MUX | TLS/CDN overhead and policy |
| **GRE** | Simple kernel link | Very low encapsulation overhead | No encryption; IP protocol 47 required |
| **AmneziaWG** | Encrypted kernel link | Kernel performance and encryption | AmneziaWG and UDP required |

Suggested test order for difficult routes: **KCP + FEC → PCK → ICMP → WSS**, then TCP/UDP/WS. There is no universal winner: benchmark the same servers at the same hour and compare throughput, loss and jitter—not only average ping.

### MUX behavior

- TCP may braid several physical carriers; a stream stays pinned to preserve ordering.
- WS/WSS use exactly one physical WebSocket and multiplex logical streams inside it.
- Packet transports use small carrier sets, bounded batches and session-aware delivery.
- More carriers are not automatically faster. Start with a preset and measure before increasing them.

## Installation

Requirements: root, systemd-based Linux, and connectivity between both servers. Install on **Iran and Kharej**.

```bash
bash <(wget -qO- https://github.com/GreatTeejay/Pingify/releases/latest/download/Pingify.sh)
```

Or:

```bash
bash <(curl -fsSL https://github.com/GreatTeejay/Pingify/releases/latest/download/Pingify.sh)
```

The manager installs `pingify`, the correct core binary, and systemd services. Go is needed only if a prebuilt core is unavailable and a fallback build is required.

## Quick start and setup token

1. Run `sudo pingify` on **Iran** and choose **Create tunnel**.
2. Choose transport, Iran role, mode, ports and preset.
3. Copy the complete generated **setup token**.
4. Run `sudo pingify` on **Kharej**, create the same transport and choose **Paste setup token**.
5. Paste the token, then run Health Check on both servers.

The `p5` token includes transport, peer relationship, endpoint, carriers, keepalive, MUX window, buffers, mappings, transport options, shaping and key material. It has an integrity checksum and strict validation. Keep it secret and never tune only one side afterward. Older `p2`–`p4` tokens remain compatible. Names are side-first, such as `iran-kcp-443` and `kharej-kcp-443`.

Carrier and service ports are separate. Example: WSS can listen on `443`, forward `:8010 → 127.0.0.1:8010`, and the user's VLESS TCP endpoint remains Iran port `8010`.

## Presets and tuning

| Preset | Goal | Behavior |
|---|---|---|
| **Gaming** | Minimum queueing | Small queues/windows and conservative batches |
| **Low latency** | Interactive traffic | Low delay with more headroom |
| **Balanced** | Daily use | Browsing, social media, video and games |
| **Throughput** | Video/large transfers | Larger windows, buffers and batches |
| **Extreme** | Strong hosts/high-BDP paths | Maximum concurrency; measurement required |

The same preset intentionally produces different parameters:

- **WS/WSS:** one carrier, larger MUX window and record buffers.
- **KCP/PCK:** small carrier set, packet buffers, MTU near 1280, short flush; KCP adds FEC.
- **ICMP/UDP:** packet-aware workers and batches, without stream-only knobs.
- **TCP:** multiple carriers and moderate windows to control head-of-line amplification.

Start with **Balanced**. For games compare Gaming and Low latency using jitter/loss. For video try Throughput before Extreme. Increase KCP FEC only with measured loss. If load causes latency or collapse, test fewer queues/carriers before adding more.

Per-tunnel tuning is stored in each config and mirrored by the token. **Host Tuning** is separate and globally changes Linux socket ceilings, UDP minima, backlog, scheduler budget, MTU probing and related values using Gaming, Balanced or Throughput profiles. **BBR** is also separate. Host-wide changes should be applied deliberately.

## WS, WSS and Cloudflare

**WS** is plain HTTP WebSocket for direct paths or a proxy supporting `Upgrade: websocket`; port 80 is conventional, not mandatory. **WSS** adds TLS and is suitable for domain/CDN paths.

| Origin certificate | Cloudflare proxy | SSL/TLS mode | WebSockets |
|---|---|---|---|
| Valid trusted/origin cert | Orange cloud if desired | **Full (strict)** | Enabled |
| Self-signed cert | Orange cloud if desired | **Full** | Enabled |

Use a Cloudflare-supported HTTPS origin port, normally 443. Use **DNS only** for a direct connection or proxy diagnosis. Both ends must agree on hostname, path and validation policy. Random TLS scanner errors are harmless when the real carrier is healthy.

## Operations and troubleshooting

```bash
sudo pingify
systemctl status pingify@iran-kcp-443 --no-pager
journalctl -u pingify@iran-kcp-443 -n 100 --no-pager
curl -s http://127.0.0.1:9702/status
ss -ltnp
```

The menu includes live logs, validation, paired Health Check, remote forwarded-port probes, firewall rebuild, restart, edit, update and uninstall.

- **Carrier up, backend EOF/refused:** the tunnel carried the probe; verify the service listens on the Kharej target address/port.
- **Periodic reconnect:** compare versions and keepalive/shaping, then check firewall, NAT/CDN idle timeout, clock, proxy and MTU.
- **Stale forwarding rules:** run **Apply firewall** after changing/removing mappings; an old redirect can swallow traffic.

## Security

Core transports use authenticated AES-256-GCM records and HKDF-derived session material. WSS adds outer TLS. AmneziaWG uses its encrypted kernel tunnel and preshared material. **GRE is not encrypted**. Protect setup tokens, keys, configs and `/root/Pingify`; disable encryption only when the trust boundary is understood.

## Files and development

```text
/usr/local/bin/pingify        manager
/usr/local/bin/pingify-core   core
/root/Pingify/*.toml          tunnel configs
/root/Pingify/.state/         state
parts/                        ordered manager source
tests/                        test suites
build.sh                      assembles Pingify.sh
```

```bash
bash build.sh
bash tests/run.sh
```

Edit `parts/`, not generated embedded blocks in `Pingify.sh`, then rebuild.

## License

Copyright © 2026 **GreatTeejay**. All rights reserved except permissions in [LICENSE](LICENSE). An attributed GitHub fork with intact history, license and original link is permitted. Independent copying, mirroring, rebranding, redistribution, relicensing or selling is prohibited without written permission.

<p align="center">Built and maintained by <a href="https://github.com/GreatTeejay">GreatTeejay</a>.</p>
