# What the measurements cost

Everything here was found by running the tunnel between a server in Iran and
one in Germany and watching what happened, not by reasoning about it. Each one
took a measurement to find and would take another to find again. A core
written from scratch is free to make every one of these mistakes a second
time, which is the whole reason this file exists.

The new core is not finished until it satisfies all of them.

Where a number appears it was measured on: Iran 185.31.8.129 (one core),
Germany 46.247.109.83 (two cores), round trip on the wire 75-81 ms.

---

## 1. Two processors, whatever the machine says

On a one-core machine Go runs one P. A goroutine that becomes runnable waits
for the running one to reach a point where it can be taken off, and sysmon
forces that only after ten milliseconds. Two of those is twenty.

A packet already read off the device and already built sat waiting for a turn:

|                | tun to wire | round trip |
| -------------- | ----------- | ---------- |
| one processor  | 18.63 ms    | 99.9 ms    |
| two            | 0.05 ms     | 81.2 ms    |
| four           | 0.08 ms     | 81.3 ms    |

The wire underneath was 81, so all of the gap was this. Sixteen streams
carried 391.9 Mbit/s on one processor and 391.5 on two, so nothing paid for
it. Most servers people run this on in Iran have one core.

**Set a floor of two on GOMAXPROCS at startup.**

## 2. ICMP: both ends send echo *request*

Not a request answered by a reply. Both directions send type 8. Counted on
the real path, out of 300:

|                  | echo reply (0) | echo request (8) |
| ---------------- | -------------- | ---------------- |
| Iran to Germany  | nothing        | 300 of 300       |
| Germany to Iran  | nothing        | most             |
| Iran to Turkey   | 300 of 300     | 300 of 300       |

Germany to Iran with echo reply carried nothing at all. A tunnel built the
textbook way - client asks, server answers - does not come up on this path,
and that is why ICMP appeared not to work for weeks.

This also means the kernel must be told to stop answering the tunnel's own
requests: `net.ipv4.icmp_echo_ignore_all=1` on both ends.

## 3. The kernel silently cuts the socket buffer you asked for

`SO_RCVBUF` is clamped to `net.core.rmem_max` and reports success. `ss -m`
showed `skmem:(r0,rb425984,...,d925)` - the buffer we did not get, and 925
packets dropped because of it.

`SO_RCVBUFFORCE` and `SO_SNDBUFFORCE` are not clamped, and we run as root.
**Use the FORCE variants, then read the value back and warn if it was cut.**

## 4. Never set SO_RCVBUF on a TCP socket

Calling it switches off `tcp_rmem` autotuning for that socket and pins the
window where you put it. Buffer tuning belongs to the packet transports only.

## 5. The reader that takes the packet off the socket writes it to the device

A layer of per-flow writers and batched handovers sat between them for a
while, on the reasoning that one thread doing every write would serialise
them. It did, and it was still faster - measured once the receive buffer was
no longer being clamped, sixteen streams pushing:

|              | p50    | p90    | p99    | throughput  |
| ------------ | ------ | ------ | ------ | ----------- |
| batched      | 160 ms | 179 ms | 561 ms | 427 Mbit/s  |
| written here | 113 ms | 133 ms | 146 ms | 444 Mbit/s  |

## 6. Device queues follow the processors: floor two, ceiling eight

At eight queues the threads reading the device starved the one putting packets
on the wire. Its queue filled and it threw away three thousand packets, which
the TCP inside read as congestion and answered by halving its window. The
machine was not short of work. It was short of turns - the same shape as (1).

One queue cannot overlap a read with anything, so two is the floor.

## 7. One crossing into the kernel per batch

`recvmmsg` and `sendmmsg` for the packet transports, via
`golang.org/x/net/ipv4` ReadBatch/WriteBatch.

## 8. The private link does not need a reliability layer

One IP packet, one datagram, no ordering and no retransmit. IP has never
promised the layers above it anything else, and the TCP inside has its own
recovery - putting a second one underneath it makes both slower and neither
more correct.

This is the single biggest structural mistake in the old core: the private
link was built on top of a stream multiplexer it does not use, and the direct
path had to be added beside it afterwards. **In the new core the two paths are
separate from the first line.**

## 9. Drop when the send queue is full; do not queue deeper

A full queue means the wire is behind. Dropping is what a router does and it
is the congestion signal the sender inside is waiting for. Queueing deeper
only adds delay to a packet that is already late.

## 10. Do not drop packets for having waited too long

The opposite of (9), and it is a real distinction. A deadline was tried - drop
anything that waited longer than six milliseconds, on the reasoning that the
TCP inside has already given up on it. Throughput went 440 -> 158 -> 294
Mbit/s and the third run carried nothing at all. A sender that is mid-syscall
is not a sender that is behind, and six milliseconds cannot tell them apart.

Bound the queue by length, not by time.

## 11. A reset must not overtake its own stream's data

Putting the reset on the jump queue, ahead of ordinary frames, truncates the
stream it is resetting. It travels with its own data or it is wrong.

## 12. Opening a stream retries across carriers

Otherwise one dead carrier takes user connections down with it, and the pool
existed precisely so that it would not.

## 13. The replay window is a sliding bitmap

Not a map swept once per packet. O(1) for a packet that arrives in order,
which is nearly all of them.

## 14. KHAREJ dials IRAN, and one server would not carry it

The tunnel is reverse: IRAN owns the forwarded ports because users connect to
IRAN, and the server abroad reaches in. That is the arrangement Backhaul and
the rathole scripts use, and it is the default here.

One server this was tested on carries nothing on a connection opened from
outside. iperf3, no tunnel involved, four streams:

	  kharej -> iran   tcp/443     0.00 bit/s
	  kharej -> iran   tcp/80      0.00 bit/s
	  kharej -> iran   tcp/8080    0.00 bit/s
	  kharej -> iran   tcp/2053    0.00 bit/s
	  kharej -> iran   tcp/9911   21.4 Kbit/s
	  iran   -> kharej            713   Mbit/s

The connections themselves open - all eight carriers came up and fourteen
packets reached the device - and then the path stops carrying. It is the
data, not the handshake.

The traffic still has to flow *into* Iran, and it does, at full speed, as long
as the connection was opened from Iran. Through one TCP tunnel on that path:

	  iran   -> kharej   422 Mbit/s
	  kharej -> iran     475 Mbit/s   (this is what a user downloads)

So `transport.dials = "iran"` exists for that server and for others like it,
the Advanced screen offers it as Dial direction, and the check names it when a
tunnel is heard from and then goes quiet. The default stays what a reverse
tunnel is.

## 15. UDP into Iran stops after six packets

Measured with no tunnel involved at all: a python socket on the Iran server
sending to a python socket in Germany that echoes whatever it gets.

	  udp/8444    6 of 30 back   111111........................
	  udp/8445    6 of 15 back   111111.........
	  udp/8446    6 of 15 back   111111.........
	  udp/443     0 of 30 back   ..............................
	  udp/53      0 of 30 back   ..............................

Six. Every time, and only ever six: a fresh destination port gets six, a fresh
source port gets six, waiting a minute and starting again gets six, and firing
forty packets back to back with no pause gets six. It is a count, not a rate
and not a timeout.

The direction matters and was checked separately, from a capture on both ends
at once: Germany received every packet Iran sent and answered every one of
them. Iran received six of the answers. **Outbound from Iran is fine. Inbound
to Iran is what stops.**

This is the same shape as (14) and is probably the same device doing it. It
means UDP is not a slow transport on this path, it is an unusable one - and it
is why ICMP is the transport worth making good, not the fallback.

The UDP carrier is still worth having. It is the same code an ICMP carrier
needs, minus a raw socket, so it is the cheapest place to get the shape right;
and this is one path, on one ISP, at one time. Somebody else's will carry UDP
happily.

## 15. No encryption unless it is asked for

Off by default. What is wanted from this tunnel is speed, ping and stability,
and the traffic inside it is already TLS.

## 17. The bursts the path drops are the ones we make

A tunnel does not generate traffic, it repeats it, and the TCP inside has
already decided when each packet should go. Draining the device and firing
sixty-four packets into the wire in one sendmmsg undoes that pacing and hands
the path a burst at line rate. Something on the way polices a burst by dropping
a run of it - a hundred and seventy-three packets in a row, twice in fifteen
seconds.

Counted at the far end by looking for gaps in our own sequence numbers, which
is the only place this is visible:

	  send_batch    the path lost    one stream
	      64           2.870%         129.8 Mbit/s
	      16           0.728%         144.1
	       4           1.145%         157.0
	       1           0.000%         170.6

flagtun on the same path in the same minute lost nothing, which is what said
the loss was ours and not the route's. Batching cost nothing to give up:
sixteen streams carried 442.7 Mbit/s at a batch of one against 443.2 at
sixty-four, because with sixteen streams the packets are already there when you
look. It is the single stream, the one that arrives paced, that a batch can
only damage - and the single stream is what the batch was added to help.

**One packet per crossing on the way out. Batch on the way in, never on the
way out.**

## 18. fq on the egress, and a rate the tunnel works out for itself

fq spaces a socket's packets instead of letting a backlog leave in a clump.
That alone is most of the difference, and it needs no number:

	  eth0 qdisc      one stream    retransmissions
	  fq_codel        187.2 Mbit/s  247, 847, 201
	  fq              229.7         86
	  fq, paced       243.7         none

A rate on top helps further and cannot be chosen in advance. Half the link
speed is unavailable - every server this runs on is a virtual machine and
virtio_net reports its speed as -1. A number in the config is worse: nobody can
compute what a path between two countries will carry.

So it is measured. Once a second, work out the rate, keep the best second seen,
hold the cap half again above it. The peak decays by a sixty-fourth on a busy
second that is slower, so it follows what the tunnel is doing now rather than
the best it ever did - without that, a sixteen-stream run leaves the cap at 793
Mbit/s and a single stream afterwards gets no help from it at all, falling from
255 to 228.

**The first version of that loop deadlocked and it is worth remembering why.**
It started at a floor of 25 Mbit/s, which throttled the TCP inside from the
first second, so the measured rate never grew, so the cap never grew. Three
runs at 23 Mbit/s. A loop that learns from what it limits has to be allowed to
see the thing unlimited first.

## 19. The queue is one straight trade, and it is the profile

fq's flow_limit must be above the burst it is smoothing - the default of a
hundred packets would drop exactly what it was set to space out - and below the
depth at which the queue becomes the delay. Twenty thousand is a quarter of a
second at four hundred megabits and behaves like one: measured once with the
rate cap still catching up, p50 302 ms and a tail at 1174.

Between those two ends there is a straight line with nothing free on it.
Restarted fresh at each depth:

	  profile     queue    16 streams   one stream   under load
	  gaming        600     397 Mbit/s   167 Mbit/s   84.5 / 92.5 ms
	  balanced      900     448          254          93.3 / 106.5
	  download     1500     466          253         115.8 / 139.3

Deeper than 1500 buys nothing at all and costs a great deal: 2500, 4000 and
6000 leave one stream at 250, 251 and 247 while p99 goes 462, 626, 928. The
ceiling is the path, not the queue.

Balanced is not the average of the other two - it carries a single stream
faster than either. The quiet round trip does not move between them at all,
81.0 / 81.1 / 81.2, because an empty queue is an empty queue however deep it
was allowed to get. **A profile changes what happens when the link is busy,
which is the only time any of it is felt.**

## 20. Count the gaps in your own sequence numbers

Nothing else on either machine can see what the path takes. The device says
zero, the qdisc says zero, the socket says d0, and a thousand packets a minute
are disappearing. The sender's counter is consecutive, so a number that never
arrives is a packet the path lost, and the run length - how many went together
- matters more than the total. Losses spread one at a time are noise a window
shrugs off; the same number in runs is a window halved once per run.

Verified against an independent count, an iptables rule at each end: the tunnel
said 993 and the kernels said 996.

## 21. KCP is held back by its own flushes, not by the path

Measured 2026-09-16, Iran 185.31.8.129 to Germany 144.31.63.245. On the day, UDP
crossed cleanly: forty of forty on each of three flows, at 100 and 1350 bytes.
Nothing above 1350 crossed at all, so that is the packet size.

Four things that looked like the limit and were not:

- **Loss.** During one download KCP counted 12,446 segments lost and resent.
  The kernels counted 473,872 packets sent and 473,435 received: the path lost
  437. The rest were retransmissions of packets that had arrived, their
  acknowledgements late behind the Iran server's one busy core.
- **Bursts.** Pacing the socket with fq made it worse, not better - lost went
  4% at no cap, 7.6% at 1000 Mbit/s, 15.6% at 600, 29% at 400. KCP without a
  congestion window sends faster than any cap, and the cap's queue drops it.
- **The receive buffer.** It was real once - 256 KB dropped six thousand
  packets in twelve seconds - and eight megabytes dropped none. After that it
  was not the limit.
- **Write delay.** Flushing on KCP's clock instead of on every write added
  7 to 11 ms to the first byte and bought little.

What was the limit is the sending process. Profiled during one download,
seventy per cent of it was kcp-go walking every in-flight segment of the window,
under the session's lock, once for every write - and the tunnel wrote once per
two kilobyte record. Records of sixteen kilobytes are an eighth of the writes:

	              one download   four at once   upload   iran memory
	2 KB records    256 Mbit/s     680            212      88 MB
	16 KB           297            795            198      71

A window of 8192 instead of 4096 carried one download a little faster (344,
348) and four at once much slower (488, 528), with UDP receive drops on Iran.

## 22. The first core's transports, against this one

Same pair, same hour, each transport alone, in turn. Fifteen seconds of each
measurement from an endless source, the Iran side at nice 10. The first core
ran with the largest windows it accepts and its throughput profile.

	                   first byte   one down   four down   one up   iran memory
	TCP MUX (this)       83 ms       938 Mbit/s   908        761      15 MB
	KCP MUX (this)       82          284          798        203      75
	TCP MUX (first)      74          492         1008        601     121
	KCP FEC (first)      77          284          473        132     105
	TCP PCK (first)      86          113          217        141      91
	UDP ARQ (first)      78          110          419         12      84

Nothing the first core had carried more than its own TCP, and nothing of its
beat this core's TCP except four streams at once, by a tenth, for eight times
the memory. Its KCP matched one download and lost half of four at once to
90,503 UDP receive drops. Its UDP uploads did not work.

TCP PCK - KCP inside TCP-shaped packets - has no counterpart here and needs
none: Fake TCP is the same idea without the second reliability layer, and on
the same day carried 387 to 529 Mbit/s down and 698 to 770 up across its link,
where PCK carried 113 and 141.

## 23. What was not the transports

Three things that looked like a slow transport, on 2026-09-16, and were not:

- **Every TUN transport downloaded at 200 Mbit/s** - ICMP, GRE, UDP, Fake TCP
  and AmneziaWG alike, while each uploaded at 700. The test's own receiving
  socket had SO_RCVBUF set to four megabytes, which is (4) again: a window
  pinned where it was put, across an 80 ms round trip. Without it the same
  links carried 388 to 670.
- **The TLS transports uploaded at 107 to 813**, from one run to the next, and
  Decoy TLS MUX once at 133 - with 254 MB retransmitted in eight seconds on the one
  connection carrying it. Plain TLS from Python, on the same pair, held 870 to
  930 for a whole minute, with any SNI including www.microsoft.com, and TCP
  through the tunnel retransmitted heavily too. The loss is the path's, it
  comes and goes, and it is not the handshake: nothing on either server was
  busy, the Iran core at 3.5% of its one core.
- **ICMP carried the least of the TUN transports.** The path takes it in runs:
  135,000 to 180,000 packets per test, 40 to 60 at a time, at a send batch of
  64, of 8 and of 1 alike. One download ranged 298 to 735 at the same setting.
  It is a policer on the way, and nothing about how the packets leave changed
  what it let through.

## 24. The kernel's GRE in UDP is the fastest link here, and GRO is why it was not

Golden GRE (github.com/LivingG0D/Golden-GRE) is a bash wrapper around one
Linux feature: a kernel GRE device with `encap fou`, so the frames cross as
UDP and nothing on the path sees protocol 47. Nothing custom is on the wire.
Measured 2026-09-18 on the pair, first with a link made by hand, then with
their scripts as shipped, then as this manager's own GRE FOU transport:

	                              one down   four down   up      iran idle
	by hand, MTU 1400, GRO on         1          3          0
	by hand, MTU 1320, GRO on         0          2          0
	their scripts, MTU 1400, GRO off 907        636        793
	GRE FOU, this manager            933        573        777      46%
	our GRE, same hour, GRO off      396        350        712
	our UDP, same hour, GRO off      552        507        510

The first two rows were the reason it was nearly dismissed. With generic
receive offload on, the receiving NIC joins the arriving UDP datagrams before
FOU has unwrapped them, the GRE frames inside come out malformed, and the UDP
layer drops every one - `UdpInErrors` climbs by the million and nothing else
says a word. Their up script turns GRO off on the underlay and says why in a
comment; a link made by hand without that step carries nothing, and no MTU
fixes it. So the transport turns it off itself, writes down what it was, and
puts it back when the last tunnel needing it is deleted, because it is a
setting for the whole interface: with it off, our AmneziaWG link went from
439 Mbit/s to 224.

The default MTU of 1400 was suspected too - the underlay on Iran is 1400 and
the path carries 1350 - and it was not the problem: `IpFragCreates` stayed
at zero through a 904 Mbit/s download, the kernel having worked the path out.

What the speed costs is everything the core does to a packet: there is no
token on the wire, no sequence to count the path's losses by, and no stream
to move to another transport. The core still runs, and only watches.

## 25. Failover takes the best member that answers, and comes back the same way

2026-09-18, TCP MUX with Chrome TLS MUX and KCP MUX as its backups, in that
order, on tunnels made through the menu. For the test the silence was 10 s,
the return 30 s, the probe every 10 s. A 16 Mbit/s stream ran throughout.

	T+20   tcp and chrome tls blocked on the German server
	T+42   moved tcp -> kcp          one hunt found the one member left
	T+80   chrome tls unblocked
	T+114  moved kcp -> chrome tls   the better member, without waiting for tcp
	T+140  tcp unblocked
	T+170  moved chrome tls -> tcp

	16 Mbit/s stream, every 5 s:
	16 16 16 16 0 44 16 16 16 16 16 16 16 16 16 16 16 16 16 16 16 16 17 16 16 ...

One sample lost and one long at the first move, and nothing at either return.
The earlier design would have spent a silence on chrome tls before finding kcp,
and would never have left kcp for chrome tls: it probed the primary alone.

Something worth knowing about the probes: one names slot 0 like any dialler,
so on the side that waits it takes that slot from whatever holds it. Probing
the member in use would have evicted the tunnel's own first connection once a
minute. The member in use is therefore never probed; its round trip is the
forward layer's own ping.

## 26. Every transport, one evening, in Mbit/s

2026-09-18, 18:29 to 18:41 Tehran time, the same pair, each transport alone,
fifteen seconds of each measurement from an endless source, the Iran side at
nice 10. The forwarding transports ran the core as built that day; the TUN
ones are the tunnels that have run on the pair since the 15th.

	                  first byte   one down   four down   up
	TCP MUX             80 ms       1003        758       179 / 674
	WS MUX              81          1011        824       122
	WSS MUX             79           828        667       336
	Chrome TLS MUX      82           653        658       117
	Decoy TLS MUX       79           536        918       273
	KCP MUX             83           382        777       225
	ICMP               168           241        296       393
	GRE                148           265        585       671
	UDP                165           294        446       675
	Fake TCP           147           503        535       537
	AmneziaWG          153           539        364       548
	GRE FOU            162           923        735       836   (at 15:48 the next day, beside
	GRE, same minutes  149           586        633       765    our GRE and UDP for a fair pair)
	UDP, same minutes  165           457        456       473

Two numbers for TCP's upload because it was measured twice, ten minutes
apart: 179, then 674. The forwarding transports were measured first, in the
minutes the Iran to Germany direction was being held to a couple of hundred
megabits, and the TUN transports afterwards, when it was not. The path
changes faster than a run of eleven takes, which is why the file above says
to interleave, and why no two transports' uploads here should be compared
against each other without a second look.

What holds across every run of this pair: on a clean path the plain stream
transports - TCP MUX and WS MUX - carry the most and cost the least; the TLS
ones give up a fifth to a third of a single stream for the disguise; KCP
carries a third of a single stream and nearly all of four, because one
session's window is the limit; and a TUN transport's first byte is two round
trips, because the connection inside it handshakes across the link.

## 27. GRE FOU beside TCP MUX on the Turkey pair, at peak

2026-09-19, 00:45 to 01:00 Tehran time, Iran to the user's Turkey server
(92.249.61.49, 2 cores, vmxnet3), a path of 37 ms where the live tunnel
`iran-tcp-8446` carries real users on TCP MUX. Neither number below is that
tunnel: TCP MUX is a second pair built for the test on port 8460 with the core
built the day before, GRE FOU a pair on udp/8466, ten seconds a measurement,
the two alternated.

	                  first byte   one down   four down   up
	TCP MUX             40 ms        717        812       353
	GRE FOU             75          1360        725      1551
	TCP MUX             40           339        821       146
	GRE FOU             75          1020        339      1487
	no tunnel at all     -            74        284      1879   (minutes earlier)

The first byte is one round trip for the MUX, whose connections are already
open, and two for the kernel link, whose TCP handshakes across it. Every
other column favours the kernel link, uploads by four times, as on the
Germany pair.

What the hour showed about the live tunnel is the reason to prefer it here.
Before anything was measured, its Iran side reported a far RTT of 2.2 s, then
45 s while the upload test ran, then 24 s, then 37 ms again. The sockets
explained it: of its eight connections, three had a kernel RTT of 1 to 5 s
and two had retransmitted 190,000 segments, on a path that gave a single
stream 74 Mbit/s without any tunnel. A pong on such a connection waits behind
up to 16 MB of everyone's data, and every user's stream waits behind every
other's loss. Over the kernel link each user's TCP runs end to end from the
panel to the client: one user's loss is that user's, and there is no buffer
of the core's to wait in.

The upload test at 1.5 Gbit/s filled Iran's uplink for ten seconds and the
users felt it. Do not measure uploads at peak on a server that has users.

The users were moved at 21:34 UTC: the TCP pair deleted through the menu on
each server, the four ports set on the GRE FOU tunnel's Ports screen. Twenty
seconds on Iran, one reconnect for the users, and 772 connections were on the
kernel link a minute later, at 40 ms far RTT.

## 28. FlagTun's ICMP beside ours, and what the difference turned out to be

2026-09-20, 02:52 to 04:10 Tehran time, Iran to Germany, flagtun 4b3f5143
(github.com/optimator7/flagtun, the June build) against `iran-icmp-1`, the
same pair of servers and the same minutes, each measurement eight or ten
seconds from an endless source, alternated, and the medians of five rounds.
Both links were MTU 1320. Neither side answers a ping inside the tunnel -
`icmp_echo_ignore_all` is 1 on both servers, which an ICMP tunnel needs - so
every number here is TCP.

	                          FlagTun   ours
	first byte, idle           161 ms   161 ms
	first byte, under load     211      161
	download, one stream       633      299
	download, four streams     460      465
	upload                     605      635

One column of that is a real gap and the rest is noise: a single stream
carried twice as much over theirs, and it won every one of the five rounds.
Our own queues are why. On the balanced profile the core holds 900 packets
and the device 1000; flagtun holds what it likes and sets the device to
10000. Told to keep the same depth - the download profile, and
`tun.txqueuelen = 10000` - the same measurement over the same hour:

	                          FlagTun   ours
	download, one stream       618      615
	first byte, under load     179      161

So the single stream was a setting, not a shape. What does not move with a
setting is the second line: ours answers a new connection in the same 161 ms
whether or not a download is running, and theirs takes 20 to 90 ms longer,
which is the deeper queue being paid for. Their own log says the same thing
from the other side - `drop=9361`, `drop=32625` in consecutive stats lines
while pushing, packets their queue threw away.

Four streams and upload are a tie inside the noise, and the first byte is
161 ms for both because a TUN transport's first byte is two round trips
whoever wrote it.

The cost per byte is the same. Measured as a delta of the process's own
jiffies over a transfer: 5.3 to 8.0 per cent of a core per 100 Mbit for
theirs, 6.2 to 7.6 for ours on one stream; 11.3 to 12.9 against 11.6 to 13.4
on four. A one-core Iran server, where flagtun ran one worker and our core
forces two processors (see 1).

What this pair of servers does to any measurement is worth repeating: nine
paired single-stream samples ran 168 to 874 Mbit/s for flagtun and 177 to
835 for ours, in the same minutes. Only the medians of a run of rounds mean
anything here, and only against the other transport measured beside it.

## 29. How long a tunnel takes to come back, and the link that never said it had gone

2026-09-20, the Iran and Germany pair, timed by polling each tunnel's status
once a second while the far end was taken away and given back. Two ways of
taking it away, because they are not the same thing: the far end stopped,
which answers every connection with a reset, and the path blackholed with
`iptables -j DROP`, which answers nothing at all.

	                         noticed it had gone   carrying again
	TCP MUX, far end stopped        at once            5 s
	TCP MUX, path blackholed        23 s               1 s
	private link, far end stopped   31 s               4 s

A stream transport notices a reset immediately and a blackhole after the
kernel's `TCP_USER_TIMEOUT`, which is set to twenty seconds. Coming back is
one redial: the backoff runs 0.5 s doubling to 8 s, so the wait is never
longer than that whatever the outage was.

The private link had to be taught both halves of this.

It never noticed at all. A datagram carrier has no connection to lose, and
`Up()` was "we know where the far end is" - an address learned once and kept
for ever. Through a sixty second outage the status said up, the panel showed
a green dot, `--check` said the tunnel was fine and `/healthz` answered 200.
Now it is "the far end has been heard from within three keepalives, and
never less than thirty seconds", which is the 31 s above.

For that to be true on both ends, both ends have to send keepalives. Only
the side that dialled did, so an idle link gave the dialling side nothing to
hear and it would have called every quiet link dead. Both sides send them
now - a few bytes every ten seconds - and a far end too old to send its own
still takes them.

Coming back was twelve seconds, which is one keepalive interval: the far end
returns, and nothing here knows until its next one arrives. A link that is
not carrying now sends them every two seconds instead of every ten, which
makes it four. Nothing pays for that except an outage.

What none of this covers is the tunnel the kernel carries. GRE FOU has no
connection and no keepalive: the device either exists or it does not, and
what it needs after a reboot is the manager rebuilding it - see the note in
`tunnel_boot` about why that must never fail the unit.

## 30. Every transport, built through the wizard and taken away again

2026-09-20. Not a throughput run: a check that each of the twelve is whole
from end to end. For each one the wizard on IRAN was answered as a person
would answer it, the token pasted into the wizard on KHAREJ, the link
waited for, traffic pulled through a forwarded port, `--check` read on both
servers, and the tunnel deleted from both. Twelve for twelve.

	                first byte    carried   IRAN check    KHAREJ check
	TCP MUX            77 ms      470        7 ok          6 ok
	WS MUX             87         380        7             6
	WSS MUX            75         178        7             6
	Chrome TLS MUX     72         168        7             6
	Decoy TLS MUX      80         265        7             6
	KCP MUX            80         243        7             6
	ICMP               73         389        8             7
	GRE                80         240        7 + 2 bad     6 + 2 warn
	UDP                76         361        8             7
	Fake TCP           81         291        8             7
	AmneziaWG          78         342        9             8
	GRE FOU            83         345       10             9

Three things the run found, none of them about a transport.

A private link's forwarded port cannot be tested from the server that owns
it. The rule is a DNAT in PREROUTING, and a connection opened on that
server leaves through OUTPUT, which never meets it. The first attempt read
0 Mbit/s for every one of ICMP, AmneziaWG and GRE FOU and they were all
working; the pull has to come in from outside, which is what the numbers
above are.

GRE was the only one to fail its own health check, and the check was wrong.
It counted lost packets a minute with no idea how many had arrived: 12,025
a minute sounds like a broken path and was one in a hundred of a 240 Mbit/s
transfer. Loss is now a share of what the tunnel carried, with the rate
kept for scale, and two per cent is what makes it a problem.

The wizard asked GRE to confirm itself and asked nothing of WS, UDP or KCP,
whose warnings are just as serious. Only GRE FOU asks now, because it is
the only one that changes a setting the whole server shares.

## 31. Closing the rest of the review

2026-09-20, the findings from the four readers that were left open after
the first pass, and what each one turned out to be worth.

Three were about what a link cannot know. A datagram carrier resolved its
peer's name once, at start, and kept that address until the process
restarted: a far end on a dynamic name moved and was never found again. The
name is looked up again after half a minute of silence now. `retire()` took
a member out of the table before keeping its counters, so a status read in
between showed the totals going backwards, which is the one thing totals
must not do. And `stamp` on the ICMP sender wrote eight bytes of header
without checking it had eight, which the link never gives it and anything
else would have taken the process down.

Two were the manager reaching past its own tunnel. Deleting a tunnel's last
forwarded port removed the sysctl file that holds IP forwarding on, undoing
what somebody had chosen under Optimize for the whole machine. And the
uninstall pulled each link out from under its own running unit, which
systemd restarted, whose pre-start put the device, the listener and the
offload setting back - after which the stop that followed left all three
behind. Both now leave the machine's business to the machine.

The rest were the face. `q` left the front page and nowhere else, and on one
screen it fell out of the menu entirely; every numbered screen takes it now,
and every one of them says the same thing about a key that is not on it.
Tuning asked for the dial direction and the log level as words typed from
memory while the wizard picked them from a list. A tunnel's ports had an
item on the KHAREJ side whose only answer was a refusal. The health port
printed -1 rather than "off". And the setup token, printed once at the end
of the wizard, could not be asked for again - which is a pair that cannot be
finished if the screen was closed, and the wizard hid it entirely when the
tunnel did not start on the first try.

One was measured rather than argued. The pre-start hook sources the whole
2.7 MB script before every tunnel start, which reads like a cost: it is 40
milliseconds on the Iran server. Left as it is.

The long sentences are gone as a class rather than one at a time. Every
line the manager prints now folds at the screen's width, with what follows
indented under it, so a warning on an eighty column terminal is two lines
instead of one line and a fragment.

## 32. Telling a bad tunnel from a bad path, and what the Turkey route did

2026-09-21, the users on the Iran to Turkey tunnel were seeing loss and
lag. A probe inside the tunnel said 21 to 34 per cent of packets never came
back, at 50 ms; the same probe to the same server on a fresh UDP port said
0.2 per cent at 40 ms. That reads as a broken tunnel and it is not one.

The instrument matters. A `ping` to the far server said 20 per cent loss,
which was ICMP rate limiting and nothing else; a UDP echo at the same rate
said 0.2. Never diagnose one of these with ping.

What settled it was offering the same load to both:

	                          loss at 9.6 Mbit/s each way
	the raw path, no tunnel            59%
	a fresh UDP tunnel                 64%
	the GRE FOU tunnel                 36%

The tunnel lost the least of the three. So the probe inside it had been
riding a flow already past what the path would carry: the tunnel carries
the users' 8 Mbit/s, and a fresh tunnel carrying nothing was clean at the
same moment.

The path's own ceiling, measured with no tunnel involved:

	  1.0 Mbit/s    0.1% lost    41 ms
	  1.9           0.2          40
	  2.9           0.6          41
	  4.8          13.3          80
	  6.7          40.0          82

About three megabits each way, and then it falls over and the round trip
doubles. TCP straight between the two servers, no tunnel: 2 Mbit/s on one
stream, 5 on four. The same Iran server to Germany in the same minute: 943
Mbit/s. Germany to Turkey: 37 ms, no loss. So neither server was at fault
and neither was the tunnel - that one route was.

The order that gets there: ask whether the box is dropping anything
(counters, fragmentation, cpu), then whether a fresh flow on the same path
is clean, then offer both the same load, then measure the bare path with
nothing of ours in it, and keep a second route as the control.

## 33. Two GRE FOU tunnels to one server need a key

Found while building a second one to test the above. The kernel files a GRE
device under local address, remote address and key, and we set no key, so
the second tunnel to the same peer was refused - "RTNETLINK answers: File
exists" - however different its FOU port was. The manager reported only
that the kernel would not make the device.

The key now comes from the tunnel's token, so both ends work the same
number out without being told it, and the refusal says what it means. The
key is in the clear on the wire and separates tunnels; it does not protect
them, which is what the transport's own note already says about the token.

It is a change to what is on the wire, so both ends have to be remade
together. On the pair carrying real users that was two devices recreated
within three seconds of each other, and the users' connections survived it.

---

# How to measure, so the numbers mean something

These cost as much time as the findings did.

- **`pkill -f <pattern>` kills the shell running it.** The pattern appears in
  its own command line. This left four tunnels running on each server and made
  every measurement after it worthless - throughput visibly fell 296, 238, 181
  as the copies piled up. Use `pkill` without `-f`, and keep the kill and the
  launch in separate ssh calls.

- **`scp` onto a running binary fails with "Text file busy".** If the error
  goes to /dev/null the measurement runs on the old binary and looks fine.
  Copy beside it and rename, and print the size that landed.

- **Interleave.** Run A, then B, then A again. Never compare a number taken now
  against one taken an hour ago: the path changes, and so does the neighbours'
  traffic.

- **Watch the load average on both servers before believing anything.**

- **One ICMP id per test connection.** conntrack allows one reply per id, so a
  test that reuses one id measures conntrack, not the tunnel.

- **Ask the server what is running, do not assume.** Every measurement above
  was taken with a `ps` in the same breath.

- **Time the transfer, not the file.** A 200 MB file crosses a fast transport
  in two seconds, most of which is the ramp up, and a slow one in eight. Timed
  that way TCP MUX read 631 Mbit/s; given fifteen seconds of an endless source
  it read 967.

- **A profile of an idle process says nothing.** Check that it caught the
  work: two per cent of samples is a transfer that had already finished.
