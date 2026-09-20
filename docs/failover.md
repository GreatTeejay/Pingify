# Failover

One tunnel, several transports, one of them in use at a time. When the one in
use stops carrying, the tunnel moves to the next without anybody touching it,
and moves back when the first has been healthy for long enough to trust.

This is the core's job, not the watchdog's. The watchdog restarts a tunnel on
the transport it already has, which is exactly the wrong thing on the day that
transport is being blocked.

## What the file says

```toml
[transport]
type = "tcp"            # the primary
port = 8443

[failover]
backups = ["kcp:8443", "utls:8444"]   # the members after the primary
enabled = true          # false keeps this list and runs the primary alone
prefer = "order"        # order: the first that answers; fastest: the least round trip
switch_after_sec = 25   # silence on the transport in use before moving on
return_after_sec = 120  # how long a better member must answer to be moved back to; 0 never
probe_every_sec = 60    # how often the better members are tried while a lesser one carries
```

Both servers carry the same `[failover]` table, like the rest of the file.
Only the forwarding transports can be members - TCP, WS, WSS, Chrome TLS,
Decoy TLS and KCP - because they all carry the same streams the same way. Each
member needs its own port, and two members may share a number only when one is
TCP and the other UDP (KCP).

## How it behaves

**The side that waits listens on every member at once.** It never decides
anything: it answers on whichever transport the other side is using, which it
knows because that is where records arrive. So the two servers can never
disagree about which transport is in use, and no message is needed to switch.

**The side that dials chooses.**

1. It starts on the primary.
2. Once a second it asks whether anything has arrived on the transport in use.
   Both ends ping every ten seconds and the waiting end answers every
   keepalive, so a healthy transport is never quiet for long.
3. After `switch_after_sec` of silence - or of never coming up - it **hunts**:
   every other member is tried at once, each with one connection that sends a
   keepalive a second and times the answer. With `prefer = "order"` the hunt
   ends the moment the best-ranked member answers; otherwise it waits a couple
   of seconds after the first answer for the others, then takes the best - the
   first in the file, or the least round trip. The member taken is opened in
   full, made the one in use, and the old one is closed. If nothing answers,
   the tunnel stays where it is and hunts again after the next silence.
4. While the tunnel is on a member that is not the best it could be on, every
   better member is probed every `probe_every_sec` the same way. One that has
   answered for `return_after_sec` without a gap is moved back to - the best
   of them if several have. With `prefer = "fastest"` every other member is
   probed and the one in use is measured by the tunnel's own pings; a move is
   made only for a round trip at least a tenth shorter, so two members a
   millisecond apart do not trade places every minute.
5. `enabled = false` keeps the list in the file and runs the primary alone;
   the manager's **Tuning ▸ Failover** screen switches it either way, changes
   the preference, and edits the two timings.

**Connections carry on across a switch.** When the old transport's
connections close, every stream on them is offered again from the last byte
the far end acknowledged, down the new transport - the same mechanism that
survives one carrier connection dying (see `internal/forward/resume.go`). A
stream that cannot be made whole is reset so its program reconnects.

**Record size is the smallest any member allows.** KCP alone uses 16 KB
records; mixed with a TCP-family member the tunnel uses TCP's, so a record can
cross whichever transport is in use.

## What it did on the real pair

2026-09-17, Iran 185.31.8.129 to Germany 144.31.63.245, TCP MUX with KCP MUX
as its backup, `switch_after_sec = 10`, `return_after_sec = 30`. Two
downloads through the tunnel at once - one as fast as the path allows, one
held to 16 Mbit/s, about what a video uses - and twenty seconds in, the
primary's port blocked on the German server by dropping every packet to it,
which is what a filter that has found a port does. Eighty seconds later the
block was lifted.

	transport in use, every 5 s:
	  0-35 s  tcp          40-130 s  kcp          135 s on  tcp

	16 Mbit/s stream, every 5 s:
	  15 16 16 16  1 25 16 16 16 17 16 16 16 16 16 16 16 16 16 16
	  16 16 16 16 16 16 16 16 16 16

The tunnel moved to KCP fifteen seconds after the block and back to TCP thirty
seconds after the block was lifted. The 16 Mbit/s stream carried on across
both: one five-second sample short and the next one long, as what was held
was sent again, and nothing at all on the way back. The full-speed download
was reset, cleanly, at the first move: at 950 Mbit/s more is outstanding than
a stream is allowed to hold for a resend (4 MB; see `resume.go`), so its
program was told to reconnect.

Three things had to be fixed before it read like that, and each is in the code
beside what it fixed:

- A writer on the side that waits sat in a write to a connection the block had
  killed, for the twenty seconds the kernel allows, with the end of a stream
  queued behind it. That side now closes what the other side left on a member
  as soon as records keep arriving on another (`failover.leftBehind`).
- A stream that could not be carried on was let go at one end without a word
  to the other, whose program waited out a sixty-second timeout. It is now
  reset at both (`forward.resume`).
- Moving back closed KCP while the far end was still sending on it, and KCP
  says nothing when a session closes: six seconds of the 16 Mbit/s stream went
  into it and the stream was reset. A move back now keeps the old member open
  until the far end is heard on the new one (`failover.switchTo`).

## What it does not do

- Private-link (TUN) transports are not members. Moving a private link between
  ICMP, GRE and UDP is a different machine, and not built.
- It does not measure which member is fastest. The order in the file is the
  order of preference.
