# Security

What is protected, what is not, and what you have to keep safe yourself.

## The short version

- Every transport except **GRE** carries authenticated AES-256-GCM records.
- **The security token is never sent on the wire**, on any transport.
- **GRE has no encryption at all** — not even the record layer, because the engine is not in its path.
- The setup token is a secret. It contains the security token.

## The record layer

Everything the engine carries is sealed with AES-256-GCM under keys derived with HKDF from your token, per carrier. Authenticated, so a middlebox that alters a byte is detected rather than obeyed — a modified frame fails to open and the carrier says the token does not match or something rewrote the stream.

Records are packed into a frame and sealed once, under a per-frame nonce that never repeats for a session.

## The handshake

Each carrier proves both ends hold the same token before anything else happens.

**The token is not transmitted.** Each side sends a fresh nonce and an HMAC over it; matching HMACs prove the shared secret without either end putting it on the wire. A replay guard refuses a nonce it has already seen.

A wrong token gets no useful answer and a randomised delay before the connection closes, so a probe learns nothing from the content or the timing. The local log says a connection was turned away and that the two servers' tokens differ — because that is the one thing an operator staring at a dead tunnel cannot otherwise find out.

## Per transport

| | Outer layer | Notes |
|---|---|---|
| **TCP MUX** | none | The inner records are the encryption |
| **TCP PCK** | packet cipher | Keyed from the token; also hides the headers |
| **KCP FEC** | packet cipher | Same. Not authenticated on its own — the inner records are |
| **UDP ARQ** | none | Header masked; the inner records are the encryption |
| **WS MUX** | none | The handshake is in the clear. Use WSS on an untrusted path |
| **WSS MUX** | TLS | See below |
| **ICMP** | packet cipher | Session-tagged from the token |
| **GRE** | **none** | **Nothing is encrypted. Nothing is hidden.** |
| **AmneziaWG** | its own | Kernel WireGuard, keys derived from the token |

## WSS and the certificate

The tunnel does **not** verify the TLS certificate, and that is deliberate: the certificate is usually self-signed, and what proves the far end is the token in the handshake that runs immediately after the upgrade.

That means TLS here is camouflage and transport encryption, not the trust boundary. Anything terminating the TLS on the path — a CDN, for instance — sees the TLS but still cannot join the tunnel, because it does not hold the token and the token never crosses.

One honest limitation: the ClientHello is Go's, not a browser's. A filter that fingerprints ClientHellos can tell the difference. Behind a CDN this matters less, since the handshake goes to the edge.

## The decoy

On the WebSocket transports, anything that is not the tunnel gets a stock nginx page and a normal 404 with the headers a real one sends. The nginx version, page date and ETag are derived from your token, so no two installs answer identically and a fleet cannot be found by matching one response against the rest of the internet.

The carrier path itself is derived from the token too, so it is neither guessable nor something anybody has to agree by hand.

## What you have to protect

| | |
|---|---|
| **The setup token** | Contains the security token. Treat it as a password; do not paste it anywhere public. |
| **`/root/Pingify/`** | Configs, keys and state. Root-only, and it should stay that way. |
| **The security token itself** | Anyone with it can join your tunnel. |
| **AmneziaWG keys** | Derived from the token and stored with the interface config. |

## Traffic shaping

Off by default. On, it masks the frame-length prefix so record sizes are not in the clear. **It must match on both servers** — one end shaping and the other not is a tunnel that cannot read itself.

It is not a substitute for choosing the right transport. What gets a tunnel noticed is usually its shape and its ports, not the sizes of its frames.

## Reasonable expectations

Pingify protects what it carries and makes the tunnel awkward to identify. It does not make you anonymous, it cannot hide that two servers are exchanging traffic, and no transport here is proof against a determined operator who controls the path.

Pick a transport that fits your route, keep both ends on the same version, keep the token secret, and use the health check.
