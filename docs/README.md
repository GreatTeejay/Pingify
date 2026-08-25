# Pingify documentation

Pingify connects an **Iran server** to a **Kharej server** and carries TCP and UDP services between them over a transport you choose. This is the reference for what it does, how to run it, and what each setting actually changes.

New here? [Install it](installation.md), then follow [the quick start](quick-start.md). It takes about five minutes and one copied token.

---

## Contents

| | |
|---|---|
| **[Installation](installation.md)** | Requirements, the install command, what lands where, updating and removing |
| **[Quick start](quick-start.md)** | Building the first tunnel, the setup token, and checking it works |
| **[Transports](transports/README.md)** | All nine, what each is for, and how to choose |
| **[Tuning and presets](tuning.md)** | What the five presets change, per transport, and when to leave them alone |
| **[Architecture](architecture.md)** | Carriers, streams, credit windows, framing — how a byte actually crosses |
| **[Troubleshooting](troubleshooting.md)** | Reading the log, the health check, and what each failure means |
| **[Security](security.md)** | What is encrypted, what is authenticated, what is not, and what to protect |

---

## The shape of it

```text
              ┌─────────────────────┐                  ┌──────────────────────┐
  user  ───►  │  IRAN               │ ═══ carriers ═══ │  KHAREJ              │  ───►  service
   :8010      │  forwards :8010     │                  │  dials 127.0.0.1:8010│        127.0.0.1:8010
              └─────────────────────┘                  └──────────────────────┘
```

Users connect to a forwarded port on the Iran server. Each connection becomes a **stream** with an id and a credit window of its own. Streams are multiplexed over the live **carriers**, every record is authenticated and encrypted, and the far end rebuilds them and opens the real connection. A carrier that dies is replaced without the tunnel going down.

Which end opens the connection depends on the transport, and it is not the same as which end has the ports. Ports always live on Iran.

---

## Two things worth knowing before you start

**Both servers must run the same version.** The presets, the token format and the wire records all move together. A version mismatch shows up as the two ends disagreeing about how many carriers exist — one server reporting `20 of 8 carriers up` is the classic symptom. Update both, then restart both.

**The setup token carries the whole configuration.** You build the tunnel once, on Iran, and paste one token on Kharej. Nothing is typed twice, so the two ends cannot drift apart. Treat it like a password: it contains the security token.

---

## Getting help from the tool itself

```bash
sudo pingify           # the menu: create, edit, health check, logs, update, remove
pingify --version
```

The **Health Check** in the menu is the fastest way to find out what is wrong. It checks the core and script versions, the service, the config, carrier count, round-trip time, forwarded ports, firewall rules, and whether traffic actually crosses — and it names the fix for anything it finds.

---

<div dir="rtl">

## خلاصهٔ فارسی

این پوشه مرجع کامل Pingify است.

- **[نصب](installation.md)** — پیش‌نیازها، دستور نصب، چه چیزی کجا نوشته می‌شود، آپدیت و حذف
- **[شروع سریع](quick-start.md)** — ساخت اولین تانل، توکن نصب، و چک کردن هر دو سر
- **[ترنسپورت‌ها](transports/README.md)** — هر نُه تا، با یک صفحهٔ جدا برای هرکدام
- **[تنظیمات](tuning.md)** — پریست‌ها و معنی هر عدد
- **[معماری](architecture.md)** — یک بایت واقعاً چطور عبور می‌کند
- **[عیب‌یابی](troubleshooting.md)** — خواندن لاگ و پیدا کردن علت
- **[امنیت](security.md)** — چه چیزی رمز است و چه چیزی نیست

**دو نکته قبل از شروع:** هر دو سرور باید یک نسخه باشند — اختلاف نسخه خودش را به شکل «دو طرف سر تعداد کریر اختلاف دارند» نشان می‌دهد. و توکن نصب کل کانفیگ را می‌برد، پس یک‌بار روی ایران می‌سازید و یک توکن روی خارج می‌چسبانید.

</div>
