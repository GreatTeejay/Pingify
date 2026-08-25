# Quick start

Build the tunnel once on Iran, paste one token on Kharej, check both. About five minutes.

## 1. On the Iran server

```bash
sudo pingify
```

Choose **Create tunnel**, then answer:

| Question | What to say |
|---|---|
| **Transport** | [TCP MUX](transports/tcp-mux.md) unless you have a reason. It needs nothing and works on most paths. |
| **Side** | IRAN |
| **Port** | The carrier port the two servers talk on — not the service port |
| **Forwarded ports** | `8010` to carry `:8010` on Iran to `127.0.0.1:8010` on Kharej |
| **Preset** | **Balanced** to start |

The forwarded port and the carrier port are different things. A tunnel can listen on `443` for its carriers and still forward `:8010`; the user's endpoint stays Iran port `8010`.

## 2. Copy the setup token

The last screen prints one long token. Copy **all** of it.

It carries the transport, which end dials, the endpoint, carrier count, keepalive, window, buffers, port mappings, transport options, shaping and key material — with a checksum over the lot. So Kharej is configured from Iran's own settings and the two ends cannot drift apart.

> Treat it like a password. It contains the security token.

## 3. On the Kharej server

```bash
sudo pingify
```

Choose **Create tunnel → Paste a token**, paste it, and answer the two things that are local to that machine: its own address, and — for a CDN setup — which edge to dial.

Anything the transport needs is installed here, at this point. Pasting an AmneziaWG token on a server without the tooling installs it first and stops with one clear line if it cannot.

## 4. Check both ends

Run **Health Check** from the menu on **both** servers. A healthy tunnel looks like this:

```text
  ✓ core and script are both 1.0.2
  ✓ the service is running
  ✓ the config is valid
  ✓ 4 of 4 carriers up, 88.1ms to the other server
  ✓ every forwarded port is bound here
  ✓ traffic crosses in both directions
```

If a check fails it names the fix. [Troubleshooting](troubleshooting.md) goes through the common ones.

## Names

Names are side-first, always: `iran-kcp-443` and `kharej-kcp-443`, or `iran-tun-icmp-10` and `kharej-tun-icmp-10` for a private link on `10.10.10.0/24`.

The side comes first so that a list of tunnels tells you which end you are on before you open anything, and so that sorting groups the two sides apart instead of interleaving them.

## Day-to-day

```bash
sudo pingify                                        # the menu
systemctl status pingify@iran-kcp-443 --no-pager
journalctl -u pingify@iran-kcp-443 -n 100 --no-pager
curl -s http://127.0.0.1:9702/status                # live JSON, per carrier
```

The menu also carries live logs, config validation, a paired health check that tests the far end too, remote port probes, firewall rebuild, edit, update and remove.

## What to do next

- Not sure the transport is right? [Choosing a transport](transports/README.md)
- Video stalling, or ping too high under load? [Tuning and presets](tuning.md)
- Want to know what is actually happening on the wire? [Architecture](architecture.md)

---

<div dir="rtl">

## خلاصهٔ فارسی

پنج قدم:

۱. روی **ایران**: `sudo pingify` ← **Create tunnel** ← ترنسپورت (اگر دلیلی ندارید **TCP MUX**)، پورت، پورت‌های forward، پریست (**Balanced**)
۲. **کل** توکن نصب را کپی کنید
۳. روی **خارج**: `sudo pingify` ← **Create tunnel ← Paste a token**
۴. توکن را بچسبانید و فقط دو چیز محلی را جواب دهید: آدرس خودش، و برای CDN اینکه به کدام edge وصل شود
۵. روی **هر دو** سرور **Health Check** بگیرید

پورت carrier و پورت سرویس دو چیز جدا هستند: تانل می‌تواند روی `443` گوش بدهد و `:8010` را forward کند، و آدرس کاربر همان پورت `8010` ایران بماند.

نام‌ها همیشه با side شروع می‌شوند: `iran-kcp-443` و `kharej-kcp-443`.

> توکن را مثل رمز عبور نگه دارید — توکن امنیتی داخلش است.

</div>
