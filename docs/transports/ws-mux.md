# WS MUX

An HTTP request that becomes a WebSocket, then RFC 6455 frames. A couple of connections, with every forwarded stream multiplexed inside them.

**Config slug:** `ws` · **Needs:** nothing · **Group:** FORWARDING

## What it is

The tunnel framed as ordinary web traffic. It goes where HTTP goes: a proxy that passes port 80 passes this.

The framing is real RFC 6455, not a raw byte stream behind a handshake — anything that parses WebSocket will parse this, which is the point. Frames are ordinary sized (16 KiB at most), each piece a whole message, because that is what a chat application or a live dashboard looks like on the wire.

Anything that is not the tunnel — a browser, a scanner, a probe on the wrong path — gets a stock nginx page and a normal 404, with the headers a real one sends. Each install derives its own nginx version, page date and ETag from its token, so no two servers answer alike.

## Two connections, not twenty

This is deliberate and it is the most important thing on this page.

Twenty WebSockets opened at once from one address, each sending a small binary frame every ten seconds and never closing, is not what any application on the web does. It is the most recognisable thing a tunnel can do, and on a real Iran–Europe path it is what stopped an earlier version from carrying anything: the connections came up, moved a few kilobytes, and went deaf in both directions.

Two is the default and four is the ceiling. One would be quieter still, but one connection is a tunnel with no spare — the moment it goes, every stream on it goes and nothing crosses until it is back. A browser holds two or three open all day and nothing thinks twice about it.

## When to use it

Only HTTP crosses your path, **and** something in front of you already terminates TLS.

If you have a domain or a CDN, use [WSS MUX](wss-mux.md) instead. WS is not encrypted by itself: the tunnel's own records are, the WebSocket around them is not.

## Setting it up

**Create tunnel → WS MUX**, then the port.

**Use port 80.** A WebSocket upgrade on an unusual port is a WebSocket nothing else on the internet looks like, and that is exactly the shape that gets a flow examined.

The path the connection asks for is derived from the token, so both ends reach the same one from the same secret and nobody has to agree it by hand. Anything asking for a different path gets the decoy.

## Tuning

The presets keep the connection count fixed and buy throughput with a larger per-stream window and bigger socket buffers instead — 256 KB up to 8192 KB. See [Tuning](../tuning.md).

The WebSocket also runs its own keepalive: a Ping frame every twenty seconds, and the connection is given up on after enough complete silence. Silence means *no frame of any kind*, not "no pong" — data arriving is the strongest proof a path is alive there is.

## Trade-off

No outer encryption. Proxy and CDN idle timeouts apply. And with everything multiplexed onto very few connections, one congestion window carries the lot: a lost segment holds up every stream behind it.
