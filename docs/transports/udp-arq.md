# UDP ARQ

Pingify's own reliability layer on raw datagrams: sequence numbers, cumulative acknowledgements, retransmission on a measured timeout, fast retransmit on duplicate acks, and a send window.

**Config slug:** `udp` · **Needs:** UDP to pass between the servers · **Group:** FORWARDING

## What it is

One reliability layer instead of two.

A TCP tunnel carrying TCP means both ends retransmit the same loss and fight each other over the timing. Here the repair happens once, in the layer that knows what the tunnel is doing, and the datagrams underneath are just datagrams.

The ARQ deliberately knows nothing about UDP. It takes a function that puts one datagram on the wire and a stream of datagrams coming back, which is why the same layer also carries [ICMP](icmp.md) — and why it is tested against a link that loses, reorders and duplicates on purpose, rather than only against a real network on a good day.

## When to use it

UDP is clean on your path and you want reliability without TCP inside TCP.

If the route also **loses** packets, [KCP FEC](kcp-fec.md) is the better answer: it repairs the common burst without a round trip, where this waits for a retransmission.

## Setting it up

**Create tunnel → UDP ARQ**, carrier port, forwarded ports, preset. The carrier port must be open for UDP on the accepting end.

## Tuning

The presets give 2 to 8 carriers with windows from 256 KB to 4096 KB.

These carriers share one socket and userspace ARQ, so they do not need TCP's sixteen-to-twenty-four congestion windows. Too many sessions only multiply acknowledgements, timers and reordering; a small pool gives loss isolation while a wide window fills a fast path.

The window matters more than the carrier count here. A stream is pinned to one carrier for its life, so the segments allowed in flight decide how fast a single download can go — `window × payload ÷ round-trip` — however many carriers the tunnel has.

## Trade-off

UDP filtering, throttling and reordering. Many providers treat sustained UDP differently from TCP and some throttle it hard. Test before committing.
