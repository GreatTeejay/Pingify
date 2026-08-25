# KCP FEC

KCP over UDP on a 10 ms clock, with Reed-Solomon parity so a short loss burst is repaired immediately instead of waiting a full round trip for a retransmission.

**Config slug:** `kcp` · **Needs:** UDP to pass between the servers · **Group:** FORWARDING

## What it is

A reliable, ordered protocol built on datagrams, tuned for latency rather than for maximum throughput on a perfect link.

For every batch of data packets it sends a few parity packets. When one or two go missing, the receiver rebuilds them from the parity it already has — no round trip, no timer, no stall. KCP handles anything FEC cannot fix, with fast retransmit after two duplicate acknowledgements and no conservative TCP-style congestion window.

The datagrams are encrypted with a key derived from the tunnel token. That is not the tunnel's security — the inner records are already authenticated AES-256-GCM — it is there to hide KCP's otherwise recognisable headers.

## When to use it

**A route that loses packets.** Video, calls, games, anything where a stall hurts more than a little overhead. This is the transport that turns a route where TCP keeps backing off into one that runs.

Do not use it if UDP is filtered or throttled on your path. Test before committing: KCP on a throttled UDP route is worse than TCP on the same route.

## Setting it up

**Create tunnel → KCP FEC**, carrier port, forwarded ports, preset. The carrier port must be open for UDP on the accepting end.

## Tuning

Four settings beyond the usual, and the presets set all of them:

| Setting | Default | What it does |
|---|---|---|
| `fec_data` | 10 | Data packets per FEC batch |
| `fec_parity` | 3 | Parity packets per batch — the repair budget |
| `packet_mtu` | 1200 | Datagram size; 1280 in the presets |
| `kcp_interval_ms` | 10 | The clock; 5 for the low-latency presets |

**Raise parity only against measured loss.** Every parity packet is real bandwidth and real CPU. Three in ten covers the common burst; ten in ten doubles your traffic to fix something that may not be happening.

The status endpoint reports retransmits, lost and duplicated segments, and how many packets FEC repaired — the numbers that say whether the overhead is earning its place.

```bash
curl -s http://127.0.0.1:9702/status
```

## Trade-off

UDP must pass, and parity costs bandwidth and CPU. On a clean link the parity is pure overhead and [TCP MUX](tcp-mux.md) will match or beat it.

---

<div dir="rtl">

## خلاصهٔ فارسی

KCP روی UDP با کلاک ۱۰ میلی‌ثانیه، به‌علاوهٔ parity رید-سالومون.

برای هر دسته بستهٔ داده، چند بستهٔ parity هم می‌رود. وقتی یکی دو تا گم شوند، گیرنده از همان parity بازسازی‌شان می‌کند — **بدون رفت‌وبرگشت، بدون تایمر، بدون وقفه**.

**کِی:** مسیری که بسته گم می‌کند. ویدئو، تماس، بازی — هر چیزی که یک وقفه در آن بیشتر از کمی سربار آزار می‌دهد. این همان ترنسپورتی است که مسیری را که TCP مدام رویش عقب می‌کشد قابل استفاده می‌کند.

**نیاز:** UDP باید عبور کند. روی مسیری که UDP را throttle می‌کند، KCP از TCP بدتر است — قبل از تعهد تست کنید.

**parity را فقط در برابر Loss اندازه‌گیری‌شده بالا ببرید.** هر بستهٔ parity پهنای باند و CPU واقعی است. سه در ده برای انفجار معمولی کافی است؛ ده در ده ترافیک را دو برابر می‌کند تا چیزی را درست کند که شاید اصلاً اتفاق نمی‌افتد.

status endpoint می‌گوید FEC چند بسته را واقعاً ترمیم کرده — همان عددی که می‌گوید سربار ارزشش را دارد یا نه.

</div>
