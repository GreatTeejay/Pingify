# GRE

The kernel's own tunnel, IP protocol 47. The fastest and lightest option here by a distance.

**Config slug:** `gre` · **Needs:** kernel GRE support, and a path that passes protocol 47 · **Group:** TUN

## What it is

Not Pingify's engine at all. The kernel moves the packets; Pingify builds the interface, the addressing, the routing and the firewall rules, and then gets out of the way.

That is why it is fast: there is no userspace in the data path, no framing, no reliability layer, no encryption. Twenty-four bytes of encapsulation and the kernel's own forwarding.

## When to use it

Two conditions, both required:

1. The path between your servers still passes IP protocol 47. Many do not.
2. You do not need the traffic hidden or encrypted.

A private link between two servers you control, on a route that is not being interfered with, is exactly what this is for.

## What it does not do

> **GRE carries nothing secret and hides nothing.**

There is no encryption and no obfuscation — not even Pingify's own record layer, because the engine is not in the path. Anything watching the link sees exactly what it is and everything inside it.

If what you are carrying is already encrypted end to end — a VPN, TLS traffic — that may be perfectly fine. If it is not, use [AmneziaWG](amneziawg.md), which is the same idea with encryption and obfuscation, or one of the [FORWARDING](README.md) transports.

The wizard asks you to confirm this before it will build one.

## Setting it up

**Create tunnel → GRE.** You will be asked for the private network the two servers sit on (`10.x.10.0/24`) and the GRE TTL.

The tunnel name carries the network: `iran-tun-gre-20` is the one on `10.20.10.0/24`.

Forwarding is done by the kernel with iptables, since the engine is not carrying anything.

## Tuning

There is nothing to tune. Carriers, windows, buffers and presets belong to Pingify's own engine and it is not in the path. The MTU starts at 1400 to leave room for GRE's 24 bytes.

## Trade-off

No encryption, no disguise, and protocol 47 is blocked on a great many routes — including most of the ones people build tunnels for. Where it works, nothing here is faster.

---

<div dir="rtl">

## خلاصهٔ فارسی

تانل خود کرنل، پروتکل IP شمارهٔ ۴۷. با فاصله سریع‌ترین و سبک‌ترین گزینه.

موتور Pingify اصلاً در مسیر داده نیست — کرنل بسته‌ها را جابه‌جا می‌کند و Pingify فقط اینترفیس، آدرس‌دهی، روتینگ و قوانین فایروال را می‌سازد. به همین دلیل سریع است: نه userspace در مسیر، نه framing، نه لایهٔ قابلیت اطمینان، نه رمزنگاری.

> **GRE هیچ چیز پنهانی حمل نمی‌کند و هیچ چیز را مخفی نمی‌کند.**

نه رمزنگاری دارد و نه استتار — حتی لایهٔ رکورد خود Pingify هم نیست، چون موتور در مسیر نیست. هر چیزی که لینک را تماشا کند دقیقاً می‌بیند این چیست و همهٔ چیزی که داخلش است.

اگر آنچه حمل می‌کنید از قبل سر‌به‌سر رمز است (یک VPN، ترافیک TLS) شاید کاملاً قابل قبول باشد. اگر نه، **AmneziaWG** همین ایده با رمزنگاری و استتار است.

**دو شرط، هر دو لازم:** مسیر هنوز پروتکل ۴۷ را عبور دهد (خیلی‌ها نمی‌دهند)، و شما به پنهان بودن ترافیک نیاز نداشته باشید.

چیزی برای tuning ندارد — Carrier و پنجره و بافر مال موتور Pingify هستند و موتور در مسیر نیست.

</div>
