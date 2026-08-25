<p align="center"><img src="assets/pingify-cover.png" alt="Pingify، تانل چندترنسپورتی پرسرعت" width="100%"></p>

<h1 align="center">Pingify</h1>
<p align="center">مدیریت تانل رمزنگاری‌شده، چندترنسپورتی و پرسرعت برای مسیرهای سخت و ناپایدار</p>
<p align="center"><a href="README.md">English</a> · <a href="README_FA.md"><b>فارسی</b></a></p>

Pingify سرور **ایران** را به سرور **خارج (Kharej)** متصل می‌کند و سرویس‌های TCP را از یک ترنسپورت قابل انتخاب عبور می‌دهد. هدف پروژه سرعت بالا برای ویدئو و وب‌گردی، پینگ و نوسان پایین برای بازی، بازیابی خودکار اتصال و نصب ساده به روش Iran-first است.

Pingify برای سرعت ساخته شده است. MUX، صف‌های کنترل‌شده، Packet Batching مخصوص هر ترنسپورت، تنظیم سوکت، FEC اختیاری و پنج پریست کاری روی مسیر مناسب سرعت بسیار خوبی می‌دهند. نتیجه نهایی به سرورها، شلوغی، Loss، MTU، روتینگ و فیلترینگ وابسته است و هیچ تانلی روی همه شبکه‌ها یک عدد ثابت را تضمین نمی‌کند.

> **مالک پروژه:** [GreatTeejay](https://github.com/GreatTeejay) · پروژه Source-Available است؛ فقط Fork گیت‌هاب با حفظ نام و لینک منبع مجاز است. [LICENSE](LICENSE)

## نحوه کار

در حالت استاندارد، خارج Carrier را به ایران باز می‌کند و کاربران به پورت Forward روی ایران وصل می‌شوند:

```text
کاربر → ایران :8010  ══ Carrier رمزنگاری‌شده TCP/UDP/KCP/PCK/ICMP/WS/WSS ══  خارج → 127.0.0.1:8010
```

هر اتصال ورودی به Stream منطقی تبدیل، روی Carrierها MUX، رمزنگاری و در سمت دیگر بازسازی می‌شود. قطع Carrier با Reconnect خودکار و systemd مدیریت می‌شود. حالت‌ها: **Forward** برای انتقال پورت، **TUN** برای لینک خصوصی Route‌شده و در موارد پشتیبانی‌شده **Both**.

## قابلیت‌ها

- ۹ ترنسپورت: TCP، UDP ARQ، KCP + FEC، PCK، ICMP، WS، WSS، GRE و AmneziaWG.
- AES-256-GCM، Handshake احراز‌شده، Key Derivation و Replay Control.
- MUX، Keepalive، Health، Reconnect، Status Endpoint و systemd.
- توکن `p5` برای انتقال دقیق کل تنظیمات از ایران به خارج.
- پنج پریست و حالت Custom؛ Tuning مستقل Stream، Packet و WebSocket.
- Traffic Shaping اختیاری، Firewall خودکار، Live Log و Health Check دوطرفه.
- Binaryهای Linux amd64 و arm64.

## مقایسه ترنسپورت‌ها

| ترنسپورت | بهترین کاربرد | مزیت | محدودیت |
|---|---|---|---|
| **KCP + FEC** | UDP دارای Loss، ویدئو/دانلود | بازیابی سریع و Throughput بالا | سربار FEC/CPU؛ نیاز به UDP |
| **PCK** | مسیر خفه‌کننده TCP طولانی | پکت خام بدون TCP Session کرنل | Linux/IPv4 و root/CAP_NET_RAW |
| **ICMP** | مسیر دارای ICMP پایدار | بدون پورت و Fallback مقاوم | احتمال Rate Limit و سقف مسیرمحور |
| **UDP ARQ** | ترافیک کم‌تاخیر | پاسخ‌گویی خوب و بازیابی Loss | فیلتر/Reordering UDP |
| **TCP MUX** | مسیر تمیز و سازگار | چند Carrier و سازگاری بالا | TCP-over-TCP روی مسیر Lossy |
| **WS** | HTTP مستقیم/Proxy | یک WebSocket با MUX داخلی | بدون TLS بیرونی و Idle Timeout |
| **WSS** | دامنه، TLS یا CDN | TLS بیرونی و MUX | سربار و سیاست CDN |
| **GRE** | لینک ساده کرنلی | سربار بسیار کم | بدون رمزنگاری؛ نیاز به Protocol 47 |
| **AmneziaWG** | لینک کرنلی امن | سرعت کرنل و رمزنگاری | نیاز به AWG و UDP |

ترتیب پیشنهادی تست: **KCP + FEC → PCK → ICMP → WSS** و سپس TCP/UDP/WS. روی همان سرورها و ساعت یکسان Throughput، Loss و Jitter را بسنجید؛ بهترین Speedtest الزاماً بهترین پینگ بازی نیست.

### MUX

- TCP چند Carrier فیزیکی دارد و هر Stream برای حفظ ترتیب روی Carrier خودش Pin می‌شود.
- WS/WSS دقیقاً یک WebSocket فیزیکی دارند و Streamها داخل آن MUX می‌شوند.
- ترنسپورت Packet از Carrier کم، Batch محدود و Session Delivery استفاده می‌کند.
- Carrier بیشتر همیشه سریع‌تر نیست؛ از پریست شروع و بعد اندازه‌گیری کنید.

## نصب

روی هر دو سرور systemd-based با دسترسی root نصب کنید:

```bash
bash <(wget -qO- https://github.com/GreatTeejay/Pingify/releases/latest/download/Pingify.sh)
```

یا:

```bash
bash <(curl -fsSL https://github.com/GreatTeejay/Pingify/releases/latest/download/Pingify.sh)
```

مدیر، دستور `pingify`، هسته مناسب معماری و سرویس‌های systemd را نصب می‌کند. Go فقط برای Fallback Build لازم می‌شود.

## راه‌اندازی و Setup Token

1. روی **ایران** `sudo pingify` و سپس **Create tunnel** را بزنید.
2. ترنسپورت، نقش Iran، Mode، پورت و پریست را انتخاب کنید.
3. **Setup Token** را کامل کپی کنید.
4. روی **خارج** همان ترنسپورت و **Paste setup token** را انتخاب کنید.
5. توکن را Paste و Health Check را در دو سمت اجرا کنید.

توکن `p5` شامل Transport، نقش‌ها، Endpoint، Carrier، Keepalive، MUX Window، Buffer، Mapping، گزینه‌های ترنسپورت، Shaping و Key Material است و Checksum دارد. محرمانه نگهش دارید و بعداً فقط یک سمت را تغییر ندهید. `p2` تا `p4` نیز سازگارند. نام‌ها Side-first هستند: `iran-kcp-443` و `kharej-kcp-443`.

پورت Carrier با پورت سرویس فرق دارد: WSS می‌تواند روی `443` باشد، قانون `:8010 → 127.0.0.1:8010` بسازد و VLESS کاربر همچنان به پورت `8010` ایران وصل شود.

## پریست و Tuning

| پریست | هدف | رفتار |
|---|---|---|
| **Gaming** | کمترین Queue Delay | Window/Queue کوچک و Batch محافظه‌کار |
| **Low latency** | ترافیک تعاملی | تاخیر پایین با ظرفیت بیشتر |
| **Balanced** | استفاده روزانه | تعادل وب، اینستا، ویدئو و بازی |
| **Throughput** | ویدئو/دانلود | Window، Buffer و Batch بزرگ‌تر |
| **Extreme** | سرور قوی/High-BDP | حداکثر همزمانی؛ نیازمند تست |

اعداد یک پریست عمداً بین ترنسپورت‌ها متفاوت‌اند: WS/WSS یک Carrier و Window/Buffer بزرگ‌تر؛ KCP/PCK Carrier کم، Packet Buffer، MTU نزدیک 1280 و Flush کوتاه؛ KCP همراه FEC؛ ICMP/UDP با Worker و Batch پکتی؛ TCP با چند Carrier و Window متعادل.

از **Balanced** شروع کنید. برای بازی Gaming و Low latency را با Jitter/Loss بسنجید. برای ویدئو قبل از Extreme، Throughput را تست کنید. FEC را فقط هنگام Loss واقعی زیاد کنید. در افت زیر بار، قبل از افزودن منابع، Queue/Carrier کمتر را آزمایش کنید.

**Per-tunnel tuning** در کانفیگ ذخیره و با توکن Mirror می‌شود. **Host Tuning** جداست و Socket Buffer، UDP Minimum، Backlog، Scheduler Budget، MTU Probing و موارد سراسری لینوکس را با پروفایل Gaming/Balanced/Throughput تغییر می‌دهد. **BBR** نیز جداست؛ تغییرات سراسری را آگاهانه اعمال کنید.

## WS، WSS و Cloudflare

WS همان WebSocket روی HTTP برای اتصال مستقیم یا Proxy دارای `Upgrade: websocket` است. WSS لایه TLS اضافه می‌کند و برای دامنه/CDN مناسب است.

| Certificate مبدأ | Proxy | SSL/TLS Mode | WebSockets |
|---|---|---|---|
| معتبر | ابر نارنجی در صورت نیاز | **Full (strict)** | روشن |
| Self-signed | ابر نارنجی در صورت نیاز | **Full** | روشن |

پورت HTTPS پشتیبانی‌شده Cloudflare، معمولاً 443، استفاده شود. برای اتصال مستقیم یا عیب‌یابی روی **DNS only** بگذارید. Hostname، Path و Validation دو سمت یکسان باشد. خطاهای Scannerهای تصادفی TLS مهم نیستند اگر Carrier واقعی Up است.

## مدیریت و عیب‌یابی

```bash
sudo pingify
systemctl status pingify@iran-kcp-443 --no-pager
journalctl -u pingify@iran-kcp-443 -n 100 --no-pager
curl -s http://127.0.0.1:9702/status
ss -ltnp
```

منو Live Log، Validation، Health Check، تست پورت مقصد، بازسازی Firewall، Restart، Edit، Update و Uninstall دارد.

- **Carrier Up ولی EOF/Refused:** تانل Probe را برده؛ سرویس مقصد خارج روی IP/Port درست Listen نیست.
- **Reconnect دوره‌ای:** نسخه، Keepalive/Shaping، Firewall، NAT/CDN Timeout، ساعت، Proxy و MTU را بررسی کنید.
- **Firewall قدیمی:** بعد از تغییر Mapping، **Apply firewall** را اجرا کنید؛ Redirect قدیمی ترافیک را می‌بلعد.

## امنیت

ترنسپورت‌های هسته Recordهای AES-256-GCM و Session Material مشتق‌شده با HKDF دارند. WSS لایه TLS بیرونی اضافه می‌کند. AmneziaWG رمزنگاری کرنلی دارد. **GRE رمزنگاری ندارد**. توکن، کلیدها، کانفیگ و `/root/Pingify` را محافظت کنید.

## فایل‌ها و توسعه

```text
/usr/local/bin/pingify        مدیر
/usr/local/bin/pingify-core   هسته
/root/Pingify/*.toml          کانفیگ‌ها
/root/Pingify/.state/         وضعیت اجرا
parts/                        Source مرتب مدیر
tests/                        تست‌ها
build.sh                      سازنده Pingify.sh
```

```bash
bash build.sh
bash tests/run.sh
```

بلوک Generated در `Pingify.sh` را مستقیم تغییر ندهید؛ `parts/` را ویرایش و دوباره Build کنید.

## لایسنس

Copyright © 2026 **GreatTeejay**. فقط مجوزهای [LICENSE](LICENSE) معتبرند. Fork گیت‌هاب با حفظ تاریخچه، لایسنس، نام سازنده و لینک منبع مجاز است. کپی مستقل، Mirror، Rebrand، بازنشر، تغییر لایسنس یا فروش بدون اجازه کتبی ممنوع است.

<p align="center">ساخته و نگهداری‌شده توسط <a href="https://github.com/GreatTeejay">GreatTeejay</a></p>
