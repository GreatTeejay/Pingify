# Tuning and presets

Start with **Balanced**. Change one thing, measure, keep it or put it back. Most tunnels never need anything else.

## The five presets

| Preset | For | What it does |
|---|---|---|
| **Gaming** | Minimum queueing | Small queues and windows, conservative batches. Lowest ping under load. |
| **Latency** | Interactive traffic | Low delay with a little more headroom — browsing, calls, chat |
| **Balanced** | Daily use | Browsing, social media, video and games together |
| **Download** | Video, large transfers | Larger windows, buffers and batches |
| **Extreme** | Strong hosts, high-capacity paths | Maximum concurrency. Measure before trusting it. |

## The same preset means different numbers

Deliberately, because the transports are not the same shape. "Balanced" on a WebSocket tunnel and "Balanced" on a KCP tunnel are answering different questions.

| Family | What a preset changes |
|---|---|
| **TCP** | 8–24 carriers, windows 256–4096 KB. Several carriers with moderate windows, to keep head-of-line amplification in check. |
| **KCP / PCK** | 1–8 sessions, plus packet MTU near 1280, a short flush interval, and the FEC ratio. A small pool: KCP already fills a path with one session, and a large pool multiplies parity traffic. |
| **ICMP / UDP** | 2–8 carriers, windows 256–4096 KB. These share one socket and userspace ARQ, so they do not need TCP's many congestion windows. |
| **WS / WSS** | Connection count stays at two. Throughput is bought with per-stream window (256–8192 KB) and socket buffers instead — because opening more WebSockets is the one thing this transport must not do. |
| **GRE / AmneziaWG** | Nothing. The kernel carries these; Pingify's engine is not in the path. |

**Every preset uses the same keepalive**, and that is on purpose. What keeps a carrier alive is how often the *peer* speaks, not how often this end does. Two servers on different presets used to disagree about how long to wait, and the more impatient one hung up on a perfectly healthy tunnel every few seconds.

## What each knob actually does

| Setting | Meaning |
|---|---|
| `carriers` | How many connections the tunnel holds. **Not** how much bandwidth it gets — it is how many places the tunnel can be cut at once and carry on. |
| `window_kb` | Credit per stream. A stream is pinned to one carrier for its life, so this is what decides a single download's ceiling: `window × payload ÷ round-trip`. |
| `keepalive_sec` | How often this end speaks. A carrier is declared dead after real silence, with a floor of one minute whatever this says. |
| `sndbuf_kb` / `rcvbuf_kb` | Kernel socket buffers. A large userspace window is useless if the kernel drops the burst before the engine can read it. |
| `fec_data` / `fec_parity` | KCP and PCK only. Data and parity packets per batch — the repair budget. |
| `packet_mtu` | KCP, PCK and the packet transports. Smaller survives more paths; larger is more efficient. |
| `kcp_interval_ms` | KCP and PCK. The clock. 5 ms for the latency presets, 10 ms otherwise. |

## Rules of thumb

**More carriers are not faster.** Past a point they only multiply acknowledgements, timers and reordering. If load causes latency or collapse, try *fewer* first — that is the counter-intuitive one, and it is usually right.

**Raise FEC parity only against measured loss.** Every parity packet is bandwidth and CPU spent on a repair that may not be needed. The status endpoint reports how many packets FEC actually repaired.

**For games, compare Gaming and Latency on jitter and loss**, not on idle ping. Idle ping is the number that lies.

**For video, try Download before Extreme.** Extreme is for a strong host on a high-capacity path and can make a small server worse.

**Change one thing at a time** and test the same two servers at the same hour. Routes vary by hour more than most settings vary by preset.

## Custom settings

Choose **Custom** in the tuning screen to set the numbers yourself. They are validated: a value out of range is refused rather than silently clamped, and the WebSocket connection count is capped at four wherever it is set — the wizard, the presets, an edit or a pasted token.

Per-tunnel tuning lives in that tunnel's config and travels in the setup token, so the two ends cannot drift apart.

## Host Tuning is a different thing

**Host Tuning**, in the menu, changes the machine: Linux socket ceilings, UDP minima, backlog, scheduler budget, MTU probing. **BBR** is separate again.

These affect everything on the server, not just Pingify. Apply them deliberately, and know that they persist in `/etc/sysctl.d/99-pingify.conf` until removed.

## Reading whether it worked

```bash
curl -s http://127.0.0.1:9702/status
```

Per carrier: bytes on the wire in each direction, streams open, round-trip time, uptime. For KCP and PCK it also reports retransmits, lost and duplicated segments, and FEC repairs.

Those are the numbers to compare before and after a change. A preset that raises throughput and doubles jitter has not helped if the traffic is a video call.

---

<div dir="rtl">

## خلاصهٔ فارسی

**با Balanced شروع کنید.** یک چیز را عوض کنید، اندازه بگیرید، نگه دارید یا برگردانید.

پنج پریست: Gaming (کمترین صف)، Latency (ترافیک تعاملی)، Balanced (روزمره)، Download (ویدئو و انتقال حجیم)، Extreme (سرور قوی و مسیر پرظرفیت).

**یک پریست برای هر ترنسپورت عدد متفاوتی می‌دهد** و این عمدی است، چون ترنسپورت‌ها هم‌شکل نیستند. «Balanced» روی WebSocket و روی KCP به دو سؤال متفاوت جواب می‌دهند.

**معنی هر عدد:**

- `carriers` — چند اتصال. **نه** پهنای باند؛ یعنی تانل هم‌زمان از چند جا بریده شود و باز کار کند
- `window_kb` — اعتبار هر Stream. سقف یک دانلود: `پنجره × payload ÷ رفت‌وبرگشت`
- `keepalive_sec` — هر چند وقت این طرف حرف می‌زند (کف تشخیص مرگ یک دقیقه است، هرچه اینجا بنویسید)
- `sndbuf_kb` / `rcvbuf_kb` — بافر سوکت کرنل. پنجرهٔ بزرگ بی‌فایده است اگر کرنل انفجار را قبل از خواندن دور بریزد
- `fec_data` / `fec_parity` — فقط KCP و PCK. بودجهٔ ترمیم

**قواعد سرانگشتی:** Carrier بیشتر سریع‌تر نیست — اگر زیر بار تأخیر دیدید **کمتر** را اول امتحان کنید. parity را فقط در برابر Loss اندازه‌گیری‌شده بالا ببرید. برای بازی، Gaming و Latency را روی Jitter مقایسه کنید نه پینگ بیکار.

**Host Tuning چیز دیگری است** — کل سرور را عوض می‌کند، نه فقط Pingify. آگاهانه اعمالش کنید.

</div>
