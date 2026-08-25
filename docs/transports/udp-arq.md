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

---

<div dir="rtl">

## خلاصهٔ فارسی

لایهٔ قابلیت اطمینان خود Pingify روی دیتاگرام خام: شماره ترتیب، ACK تجمعی، بازارسال با تایم‌اوت اندازه‌گیری‌شده، بازارسال سریع، و پنجرهٔ ارسال.

**یک لایهٔ ترمیم به‌جای دو تا.** تانل TCP که TCP حمل می‌کند یعنی هر دو سر همان گم‌شدن را دوباره می‌فرستند و سر زمان‌بندی با هم می‌جنگند. اینجا ترمیم یک بار اتفاق می‌افتد، در لایه‌ای که می‌داند تانل چه می‌کند.

**کِی:** UDP روی مسیر شما تمیز است و قابلیت اطمینان می‌خواهید بدون TCP داخل TCP.

اگر مسیر **Loss** هم دارد، **KCP FEC** جواب بهتری است: آن انفجار معمولی را بدون رفت‌وبرگشت ترمیم می‌کند، این منتظر بازارسال می‌ماند.

**پنجره از تعداد Carrier مهم‌تر است.** هر Stream برای تمام عمرش به یک Carrier سنجاق می‌شود، پس سقف یک دانلود این است: `پنجره × payload ÷ رفت‌وبرگشت` — هر چند Carrier که داشته باشید.

</div>
