# WSS MUX

[WS MUX](ws-mux.md) inside TLS, with the tunnel domain in SNI, Host and Origin — and behind a CDN if you want one.

**Config slug:** `wss` · **Needs:** a certificate (self-signed is fine) · **Group:** FORWARDING

## What it is

The same WebSocket framing and the same multiplexing, wrapped in TLS. On the wire it is an HTTPS connection to a hostname.

Behind a CDN it is more than camouflage: the tunnel connects to the edge, so **the Kharej server's address never appears on the wire at all**. Blocking one address does not end the tunnel.

Everything not on the secret path gets the same nginx decoy the plain transport serves, over HTTPS.

## When to use it

You have a domain, or you want to sit behind Cloudflare. On an untrusted path this is the WebSocket to use — [WS MUX](ws-mux.md) sends its handshake in the clear.

## Setting it up

**Create tunnel → WSS MUX.** You will be asked for the domain and, on the dialling end, optionally an edge address to connect to instead of the origin.

Port **443** is the natural choice.

### Certificates

| | |
|---|---|
| **Automatic** | An ephemeral self-signed origin certificate. Works with Cloudflare **Full**. |
| **Certificate files** | A stable trusted or origin pair. Required for Cloudflare **Full (strict)**. |

The certificate is not verified by the tunnel — what proves the far end is the token, in the handshake that runs immediately after the upgrade. TLS here is camouflage and transport encryption, not the trust boundary. See [Security](../security.md).

### Cloudflare

| Origin certificate | Proxy | SSL/TLS mode | WebSockets |
|---|---|---|---|
| Valid trusted/origin cert | Orange cloud | **Full (strict)** | Enabled |
| Self-signed | Orange cloud | **Full** | Enabled |

Use a Cloudflare-supported HTTPS origin port — normally 443. Use **DNS only** for a direct connection or to diagnose the proxy. Both ends must agree on hostname, path and validation policy.

Setup warns you if you point a raw transport at a CDN, or at a domain whose AAAA record would send the tunnel over IPv6.

## Tuning

The same as [WS MUX](ws-mux.md): two connections by default, four at most, with the presets buying throughput through the window and socket buffers rather than through connection count.

## Trade-off

TLS and CDN overhead, and CDN policy — idle timeouts, allowed ports, what the edge does to long-lived connections.

One honest limitation: the TLS ClientHello is Go's, not a browser's. It is a real TLS 1.2+ handshake and it works, but a filter that fingerprints ClientHellos can tell the difference. Behind a CDN this matters less, because the handshake goes to the CDN rather than to something worth hiding.

## Occasional log noise

Public port 443 collects old SSL, malformed ClientHellos and cipher probes all day. Those are logged at debug and are not tunnel failures. As long as the carriers are up, ignore them.
