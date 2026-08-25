# Installation

## Requirements

| | |
|---|---|
| **Both servers** | A systemd-based Linux with root access |
| **Architecture** | linux/amd64 or linux/arm64 (prebuilt); anything else builds from source |
| **Network** | The two servers must be able to reach each other on the transport's port |
| **Go** | Only if no prebuilt core can be downloaded — see [below](#when-go-is-needed) |

Some transports ask for more: [TCP PCK](transports/tcp-pck.md) and [ICMP](transports/icmp.md) need root and raw sockets, [AmneziaWG](transports/amneziawg.md) needs its own tooling, [GRE](transports/gre.md) needs kernel GRE support. Each transport page says so.

## Install

Run this on **both** servers:

```bash
bash <(wget -qO- https://github.com/GreatTeejay/Pingify/releases/latest/download/Pingify.sh)
```

Or with curl:

```bash
bash <(curl -fsSL https://github.com/GreatTeejay/Pingify/releases/latest/download/Pingify.sh)
```

The same command installs, updates and opens the menu. There is nothing else to download.

## What it puts where

```text
/usr/local/bin/pingify          the manager, on PATH
/usr/local/bin/pingify-core     the engine
/root/Pingify/                  everything this tool owns
/root/Pingify/*.toml            one config per tunnel
/root/Pingify/.state/           state it keeps between runs
/etc/systemd/system/pingify@.service
/etc/sysctl.d/99-pingify.conf   only if you use Host Tuning
```

One systemd template serves every tunnel: `pingify@<name>`. A tunnel called `iran-kcp-443` runs as `pingify@iran-kcp-443`.

## When Go is needed

The release carries prebuilt engines for linux/amd64 and linux/arm64, and the manager downloads the one that matches. Go is needed only when that download cannot happen — a different architecture, or a server that cannot reach GitHub's release files at all.

For that case the script carries its own engine sources **and every module they depend on**, compressed inside itself. An Iranian server frequently cannot reach `proxy.golang.org`, so the fallback build runs with `GOPROXY=off` and downloads nothing. If Go is not present, the manager installs it.

This is also why the script is a megabyte and a bit rather than a few hundred kilobytes. Sources for platforms it will never build are stripped out of that bundle, and the build itself compiles both release targets out of the extracted copy to prove nothing needed was removed.

## Updating

Run the install command again on **both servers**, then restart both tunnels.

```bash
bash <(wget -qO- https://github.com/GreatTeejay/Pingify/releases/latest/download/Pingify.sh)
```

The menu also has **Update**, which does the same thing.

> Keep the two servers on the same version. The presets, the token format and the wire records move together, and a mismatch is hard to read from the log: the usual sign is the two ends disagreeing about how many carriers there are.

## Removing

From the menu, **Remove** offers three levels:

| | |
|---|---|
| **Core only** | Tunnels and configs stay, the engine binary goes |
| **Every tunnel** | Configs, services and firewall rules go; the core stays |
| **Full uninstall** | Every tunnel, unit, rule and file it ever wrote |

Removing a tunnel takes its forwarding rules with it. If you delete one by hand instead, run **Apply firewall** afterwards — a leftover redirect pointing at an address that has gone will swallow every packet for that port, and it looks exactly like a broken tunnel.
