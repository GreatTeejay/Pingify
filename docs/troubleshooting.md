# Troubleshooting

## Start here

```bash
sudo pingify        # → Health Check, on BOTH servers
```

It checks versions, the service, the config, carriers, round-trip time, forwarded ports, firewall rules and whether traffic actually crosses — and names the fix for anything it finds. Run it on both ends; half the failures only make sense from the other side.

```bash
systemctl status pingify@iran-kcp-443 --no-pager
journalctl -u pingify@iran-kcp-443 -n 100 --no-pager
curl -s http://127.0.0.1:9702/status
```

---

## The first thing to rule out

> **Both servers must run the same version.**

The presets, the token format and the wire records move together. A mismatch is genuinely hard to read from a log, and the classic sign is the two ends disagreeing about how many carriers exist:

```text
state    UP  -  20 of 8 carriers
```

Twenty up against a config asking for eight means the far end is dialling twenty — because its preset table says something different from this one's. Update both, restart both.

---

## Common cases

### "Carrier up, backend EOF or refused"

The tunnel did its job: the probe crossed and the far side tried to open the real connection. What failed is the service.

Check that it is actually listening on the Kharej target address and port. A service bound to `127.0.0.1` is reachable if the target is `127.0.0.1`, and not if the target is the LAN address.

### "no carrier up, dropping connection"

Nothing is up to carry the traffic. Look at the lines *around* it for the reason a carrier went down — those are the ones worth reading, and they are rate-limited so they are not buried.

### Carriers reconnecting on a cycle

In order:

1. **Versions on both ends.** Then keepalive and shaping settings.
2. **Firewall**, on both servers and anything between.
3. **Idle timeout** in a NAT, a proxy or a CDN. A carrier that dies on a regular period usually means something is expiring it.
4. **Clock skew.** The handshake refuses a timestamp too far out.
5. **MTU.** Try the MTU probe in the menu.

### "nothing arrived for 45s, this end gave up on the path"

A WebSocket carrier gave up because *no frame of any kind* arrived — not payload, not even an answer to a ping. That is this end deciding, on purpose, and it is followed by a reconnect.

If it repeats, something is carrying the connection but not the traffic. See [WS MUX](transports/ws-mux.md) and consider moving to port 80, or to [WSS MUX](transports/wss-mux.md) behind a CDN.

### "use of closed network connection"

Someone in this process closed the socket. Since 1.0.2 the tunnel says what for instead of reporting this. If you still see it, the core is older than the manager — check the versions.

### Stale forwarding rules

```text
! 2 forwarding rules are installed but this tunnel does not use them
```

A leftover redirect pointing at an address that has gone **swallows every packet for that port**, and it looks exactly like a broken tunnel. Run **Apply firewall** from the menu, or:

```bash
pingify --apply-firewall
```

This happens after changing or removing mappings by hand, or after deleting a tunnel outside the menu.

### The token will not import

The token is checksummed and validated field by field, and it says which field is wrong. The usual causes are a truncated copy — it is long, and it must be copied whole — or a version mismatch between the two servers.

### AmneziaWG will not install

It needs the Amnezia PPA, which an Iran server often cannot reach. Install `amneziawg` and `amneziawg-tools` from a machine that can, or use [GRE](transports/gre.md) — after reading what GRE does not do.

### TLS errors on port 443

Public 443 collects old SSL, malformed ClientHellos and cipher probes all day. They are logged at debug and are not tunnel failures. If the carriers are up, ignore them.

---

## Reading the status endpoint

```bash
curl -s http://127.0.0.1:9702/status
```

| Field | What it tells you |
|---|---|
| `carriers_up` / `carriers_configured` | Up against expected. Up **exceeding** expected means a version mismatch. |
| `peer` | The address actually connected — read from the socket, not from the config. If it shows an address you changed, the old peer is still connected. |
| `wire_tx_bytes` / `wire_rx_bytes` | Everything on the wire, keepalives included. Sample twice and compare the two ends: bytes leaving one and not arriving at the other means the path is eating them. |
| `rtt_ms` | Round trip over the tunnel |
| `refusals` | Connections the far side would not make |
| `detail[]` | The same, per carrier |

That comparison — what one end sent against what the other received — is the measurement that settles "is it the tunnel or is it the path", and it needs no debug logging.

---

## Turning up the log

```bash
cd /root/Pingify
f=$(ls *.toml | head -1); sed -i 's/^level .*/level            = "debug"/' "$f"
systemctl restart "pingify@${f%.toml}"
```

`debug` gives carrier up/down with reasons. `trace` gives a line per frame — useful for a few seconds, overwhelming for longer. **Put it back to `info` afterwards.**

---

## When you are stuck

Collect, from **both** servers:

```bash
pingify --version
journalctl -u pingify@<name> -n 200 --no-pager
curl -s http://127.0.0.1:9702/status
```

Two versions, two logs and two status snapshots answer most questions that one of each cannot.
