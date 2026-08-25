# ICMP

The reliable transport carried inside ping packets. No port exists at all.

**Config slug:** `icmp` · **Needs:** Linux, root, ICMP passing between the servers · **Group:** TUN

## What it is

The same ARQ layer [UDP ARQ](udp-arq.md) uses, with its datagrams inside ICMP echo requests and replies instead of UDP. Everything above the packet layer — reliability, ordering, encryption — is identical.

For the one network where TCP and UDP are filtered but ICMP is not, because ping is how such a network proves itself reachable.

ICMP has no ports, so a raw socket receives every ping the host sees. Each tunnel derives a session tag from its token, and a packet without this tunnel's tag is dropped without a second look — which is how several ICMP tunnels share one host, and how they stay clear of stray pings and the kernel's own replies.

## When to use it

Last. It is the slowest transport here and it is subject to ICMP rate limits, both on the servers and on everything between them. It is a fallback for a path where nothing else crosses, not a default.

If TCP works on your route, use [TCP MUX](tcp-mux.md). If UDP works, use [KCP FEC](kcp-fec.md).

## Setting it up

**Create tunnel → ICMP.** You will be asked one extra question:

| Who forwards the ports? | |
|---|---|
| **PINGIFY** | The engine carries every connection itself |
| **IPTABLES** | The kernel does it — lighter on a busy link |

ICMP builds a private link, so you will also be asked for a small network for the two servers to sit on (`10.x.10.0/24`). The wizard shows which are taken, offers one that is free, and refuses a repeat — two tunnels on one network route into each other, and the symptom is traffic going somewhere it was not meant to with nothing on the server to explain it.

The tunnel name carries that network: `iran-tun-icmp-10` is the one on `10.10.10.0/24`.

### Hosts that answer ping themselves

The kernel replying to ordinary pings costs nothing for the tunnel — the transport is a raw socket and sees the packets regardless — but it does answer every scanner on the internet. The optimise menu can turn it off if you want the server to look quiet.

## Tuning

The presets give 2 to 8 carriers with windows from 256 KB to 4096 KB, the same table [UDP ARQ](udp-arq.md) uses. The MTU starts at 1280 because ICMP carries our own header on top.

## Trade-off

Slow, and heavy on ICMP rate limits. Linux and root on both ends. Expect a lower ceiling than any other transport here — the point of it is that it crosses at all.

---

<div dir="rtl">

## خلاصهٔ فارسی

همان لایهٔ ARQ که UDP استفاده می‌کند، ولی دیتاگرام‌هایش داخل بسته‌های پینگ می‌روند. **هیچ پورتی وجود ندارد.**

برای آن یک شبکه‌ای که TCP و UDP فیلتر شده‌اند ولی ICMP نه — چون پینگ همان چیزی است که یک شبکه با آن ثابت می‌کند در دسترس است.

ICMP پورت ندارد، پس یک سوکت خام هر پینگی را که به سرور می‌رسد می‌بیند. هر تانل یک **برچسب نشست از توکن خودش** مشتق می‌کند و بسته‌ای که برچسب این تانل را نداشته باشد بدون نگاه دوم دور ریخته می‌شود — به همین دلیل چند تانل ICMP می‌توانند یک سرور را به اشتراک بگذارند.

**راه آخر است، نه انتخاب اول.** کندترین گزینهٔ اینجا و اسیر Rate Limit کرنل و هر چیزی بین دو سرور. اگر TCP کار می‌کند از TCP MUX استفاده کنید؛ اگر UDP کار می‌کند از KCP FEC.

ICMP یک لینک خصوصی می‌سازد، پس یک شبکهٔ کوچک (`10.x.10.0/24`) هم از شما می‌پرسد. نام تانل همان شبکه را حمل می‌کند: `iran-tun-icmp-10` یعنی روی `10.10.10.0/24`.

</div>
