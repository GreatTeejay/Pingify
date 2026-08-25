# Architecture

How a byte actually crosses, and why the pieces are shaped the way they are. You do not need this to run a tunnel — but it is what makes the log and the tuning make sense.

## The layers

```text
  user's TCP connection
        │
        ▼
  stream          an id, a credit window, a receive buffer
        │
        ▼
  records         cmdSYN, cmdData, cmdWND, cmdFIN, cmdRST, cmdPing, cmdPong
        │         several packed into one frame
        ▼
  frame           4-byte length + AES-256-GCM sealed records
        │
        ▼
  carrier         a net.Conn: TCP, KCP session, WebSocket, ARQ over ICMP …
        │
        ▼
  the wire
```

Everything above the carrier is identical for every transport. That is not an accident — it is the only reason a new transport is cheap to add. A transport answers three questions and nothing else: dial one carrier, accept one, shut down.

## Carriers

A carrier is one connection between the two servers. The pool holds several, replaces one that dies, and reports how many are up.

Each carrier runs three goroutines: a reader, a writer and a keepalive.

- The **reader** pulls a frame, opens it with the session key, and dispatches the records inside.
- The **writer** takes records off a queue, packs as many as fit into one frame, seals it and writes it once. That batching is most of the throughput advantage over a naive tunnel.
- The **keepalive** speaks every few seconds and declares the carrier dead after real silence.

**The keepalive never blocks.** It used to queue its ping and wait for room, which on a carrier whose peer had gone meant waiting forever — the writer stuck on a peer that acknowledged nothing, the queue full behind it, and the one check that would have noticed the silence never running again. A ping that cannot be queued is dropped now, because a full queue already means the writer is behind and a keepalive is the least valuable record in it.

## Streams

Every user connection becomes a stream with an id, pinned to one carrier for its life so its bytes stay in order.

```text
  cmdSYN   open a stream, here is the target
  cmdData  bytes
  cmdWND   I consumed this much, you may send that much more
  cmdFIN   I am done sending
  cmdRST   this stream is over, and here is why
```

`cmdRST` carries the reason back. Without it, a working tunnel with a dead service on the far side closes the user's connection with nothing to say — which is indistinguishable from a broken tunnel, and is exactly what "it does not work" looks like from outside.

## Credit windows

Each stream gets a window. The sender may have that much in flight and no more; the receiver returns credit as it consumes.

This is what stops one stalled connection from consuming the whole tunnel's memory. It is also what `window_kb` sets, and why a single download's ceiling is `window × payload ÷ round-trip` — however many carriers exist.

**Credit goes back in as few records as the sender can afford to wait for.** One record per read meant one control record for every 32 KiB consumed — hundreds a second on a busy stream, each one a frame to seal, a wakeup for the writer, and a place in the queue ahead of traffic that was actually going somewhere. That is where jitter under load came from. Credit now accumulates and goes out at half the window, or the instant there is nothing left to read — because the next read blocks there, and credit held past that point is credit the sender is waiting on.

## Records and frames

Records are packed into one frame until the frame is full, then sealed once with AES-256-GCM under a per-frame nonce. One seal, one write, many records.

The frame is preceded by a four-byte length. With traffic shaping on, that length is masked, so the sizes are not in the clear.

## The handshake

Before any of this, each carrier runs a short handshake that proves both ends hold the same token and derives the session keys.

**The token is never sent.** Each side sends a nonce and an HMAC over it; matching HMACs prove the shared secret without either end transmitting it. A replay guard refuses a nonce it has seen. A wrong token gets no useful answer and a randomised delay, so a probe learns nothing from content or timing.

Session keys are derived per carrier, so no two carriers share key material.

## Failure and recovery

| What happens | What the tunnel does |
|---|---|
| A carrier's socket errors | The carrier dies with the reason; the pool redials it |
| A carrier hears nothing for its idle limit | It is declared dead and replaced |
| Every carrier is down | One warning, with the reason the last one went |
| The far side refuses a connection | `cmdRST` with the reason, rate-limited in the log |
| The peer's version differs | A warning naming the disagreement |

The idle limit has a floor of one minute regardless of the keepalive setting, because the two ends are configured separately and neither may hang up on the other for being slower.

## Log volume follows the clock, not the traffic

A rule the codebase keeps deliberately, with tests for it: **the volume of the log must follow the count of carriers and the clock, never the count of events.**

A tunnel that is down is precisely the state a client retries hardest in. A line per dropped connection means thousands a minute of the one message that says nothing, landing on top of the handful that say *why* it went down — which are the only ones worth having when it is down. Those are rate-limited to one a minute, each carrying the count it stood for.

The log path itself cannot block the tunnel either. Under systemd, stderr is a pipe to journald and a pipe blocks when full, so every log call was once a place the process could stop — including calls made from inside a carrier's read loop. Lines go on a queue now; when the queue is full a line is dropped and counted, and the count goes out with the next line that fits.

## The decoy

On the WebSocket transports, anything that is not the tunnel gets a web server with nothing on it: the stock nginx page at `/`, a normal 404 elsewhere, with the headers a real one sends.

A port that answers nothing is rare, and rare is what gets examined. The nginx version, page date and ETag are derived from the tunnel's own token, so no two servers answer identically and a fleet cannot be found by matching one response against the rest of the internet.
