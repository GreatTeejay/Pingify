# AmneziaWG

Obfuscated WireGuard: kernel speed, real encryption, and deliberately shaped not to look like WireGuard.

**Config slug:** `awg` · **Needs:** amneziawg-tools on both servers, UDP passing · **Group:** TUN

## What it is

WireGuard with the handshake padded and the packet shape altered, so the very recognisable fingerprint of a WireGuard handshake is not what goes on the wire. The kernel does the moving, so it is fast in the way [GRE](gre.md) is fast, but encrypted.

Like GRE, Pingify is not in the data path. It installs the tooling, derives the keys and obfuscation parameters from your tunnel token, builds the interface and the routing, and hands the packets to the kernel.

## When to use it

You want a full encrypted private link with kernel performance, and real resistance to being identified.

For carrying a handful of forwarded ports it is a large hammer — one of the [FORWARDING](README.md) transports is simpler. For carrying everything between two servers, it is the strongest thing here.

## Setting it up

**Create tunnel → AmneziaWG.** The manager installs `amneziawg-tools` before anything else happens.

> **This install also happens when you paste a token.** A Kharej server without the tooling gets it at that moment, before any file is written — and if it cannot be installed, the import stops with one line explaining why and leaves nothing behind.

You will be asked for the UDP port (same on both servers, default 51820) and the private network the two ends sit on. **Leave that port open** in the server's firewall.

### If the install fails

It needs the Amnezia PPA, which an Iran server often cannot reach. Two options:

- Install `amneziawg` and `amneziawg-tools` from a server or mirror that can reach it, then run Pingify again.
- Use [GRE](gre.md), which needs nothing — but read what it does not do first.

## Keys and obfuscation

Both are derived from the tunnel token, so there is no second secret to manage and no chance of the two ends disagreeing. The token carries the half the other server needs; you never copy keys by hand.

## Tuning

Nothing in Pingify's own tuning applies — carriers, windows and buffers belong to the engine and the engine is not carrying this. The MTU starts at 1320 to leave room for WireGuard's header plus the junk it pads with.

## Trade-off

The tooling must install, and UDP must pass. On a route that throttles UDP this will be throttled with it.

---

<div dir="rtl">

## خلاصهٔ فارسی

WireGuard با handshake پدشده و شکل بستهٔ تغییریافته، تا آن fingerprint بسیار شناخته‌شدهٔ WireGuard روی سیم نرود.

کرنل بسته‌ها را جابه‌جا می‌کند، پس مثل GRE سریع است — ولی **رمزنگاری‌شده**.

**کِی:** یک لینک خصوصی رمزنگاری‌شدهٔ کامل با سرعت کرنل و مقاومت واقعی در برابر شناسایی می‌خواهید. برای حمل چند پورت forward شده، چکش بزرگی است؛ برای حمل همه‌چیز بین دو سرور، قوی‌ترین گزینهٔ اینجاست.

**نصب خودکار است — و موقع چسباندن توکن هم انجام می‌شود.** سرور خارجی که ابزار را ندارد، همان لحظه و **قبل از نوشتن هر فایلی** آن را می‌گیرد؛ و اگر نصب نشد، import با یک خط توضیح متوقف می‌شود و چیزی از خودش جا نمی‌گذارد.

**اگر نصب شکست خورد:** به PPA آمنزیا نیاز دارد که سرور ایران معمولاً به آن نمی‌رسد. یا از سروری که می‌رسد نصبش کنید، یا سراغ **GRE** بروید — بعد از اینکه خواندید GRE چه کاری نمی‌کند.

**کلیدها و پارامترهای استتار از توکن مشتق می‌شوند**، پس رمز دومی برای مدیریت نیست و امکان اختلاف دو سر وجود ندارد.

</div>
