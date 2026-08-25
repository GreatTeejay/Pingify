# TCP MUX

Several plain TCP connections between the two servers, with every forwarded stream multiplexed across them by id and given its own credit window.

**Config slug:** `tcp` · **Needs:** nothing · **Group:** FORWARDING

## What it is

The plain case, and the one to start with. The carriers are ordinary TCP connections — nothing to install, no privileges, no port to open beyond the one the tunnel listens on.

Streams are spread across the carriers so a stall on one does not hold up the rest, and each stream stays pinned to the carrier it started on so its bytes arrive in order. A carrier that dies is replaced without the tunnel going down, because the others keep carrying while it reconnects.

## When to use it

Start here. On a clean route it is as fast as anything in Pingify, and most tunnels should never need to move.

Move on when the path gives you a reason:

- **Slow on a lossy link** — see [KCP FEC](kcp-fec.md). TCP inside TCP means both stacks retransmit the same loss and back off against each other, which is a real cost on a route that drops packets.
- **Connects and then dies for no reason the log explains** — see [TCP PCK](tcp-pck.md).
- **Only web traffic crosses** — see [WSS MUX](wss-mux.md).

## Setting it up

On Iran: **Create tunnel → TCP MUX**, choose the carrier port, the forwarded ports, and a preset. Copy the token, paste it on Kharej. That is all.

### Link direction

TCP is the one transport that asks which end opens the connection:

| | |
|---|---|
| **Reverse** (default) | Kharej connects to Iran. The usual arrangement. |
| **Direct** | Iran connects to Kharej. Use when inbound connections to the Iran server will not hold. |

Ports live on Iran either way, and users always arrive there. This only decides who dials.

## Tuning

The presets give 8 to 24 carriers with windows from 256 KB to 4096 KB. See [Tuning](../tuning.md).

More carriers are not automatically faster. Each one is another congestion window, another set of timers, and another place for reordering to happen. If load causes latency or collapse, try **fewer** carriers before adding more.

## Trade-off

TCP inside TCP. When the outer connection retransmits a segment, the inner stream's own reliability is retransmitting too, and the two back off against each other. On a clean link this costs nothing measurable. On a lossy one it is the reason KCP exists.
