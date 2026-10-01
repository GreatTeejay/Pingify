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

## 5. The reader takes the packet off the socket; a writer puts it in the device

A layer of per-flow writers and batched handovers sat between them for a
while, on the reasoning that one thread doing every write would serialise
them. It did, and it was still faster - measured once the receive buffer was
no longer being clamped, sixteen streams pushing:

|              | p50    | p90    | p99    | throughput  |
| ------------ | ------ | ------ | ------ | ----------- |
| batched      | 160 ms | 179 ms | 561 ms | 427 Mbit/s  |
| written here | 113 ms | 133 ms | 146 ms | 444 Mbit/s  |

**Superseded in part.** That table is still true of what it measured - batched
handovers behind a channel lose to writing in place. What ships now is neither:
the reader hands each packet to a writer goroutine chosen by the flow's hash,
with no batching, so it goes straight back to the socket and never waits on a
device write. One writer per core, up to four. Measured on the pair, four
rounds at each setting, both ends the same (internal/link/link.go):

	  writers   download   upload   one stream down   p90 down / up   socket lost
	     0        457        412        569 Mbit/s      106 / 94        5500
	     1        572        388        578             108 / 82         160
	     2        532        438        595             107 / 103        830

The column that decides it is the last one. With nobody but the reader writing
to the device, the socket overflowed 5500 times while the reader was busy
there; with a writer beside it, 160. `tun.write_workers = -1` still gives the
old behaviour, for comparing.

## 6. How many device queues

At eight queues the threads reading the device starved the one putting packets
on the wire. Its queue filled and it threw away three thousand packets, which
the TCP inside read as congestion and answered by halving its window. The
machine was not short of work. It was short of turns - the same shape as (1).

That part stands. What followed from it here - "one queue cannot overlap a read
with anything, so two is the floor" - does not describe the core any more. It
opens one queue (`defaultQueues`, internal/link/link.go) and the wizard writes
`queues = 1`. The reading moved: the goroutine that reads a queue is the one
that sends what it read, and the writing into the device went to the writers
in (5), so a single queue no longer has a read to overlap with anything.

**One against two has not been measured on this core.** It is one because one
flow is read by one queue whatever the count, and more queues bought nothing
that anyone has shown. Somebody with a reason to think otherwise has
`tun.queues` and should measure it.

## 7. One crossing into the kernel per batch

`sendmmsg` and `recvmmsg`, called directly - `syscall.Syscall6` on a
hand-laid `mmsghdr` in internal/carrier/batch_linux.go, not through
`golang.org/x/net/ipv4` as this section used to say.

Who actually uses them is narrower than "the packet transports":

	  transport    sends in batches      reads in batches
	  gre                yes              yes, one reader per core up to four
	  icmp               yes              yes, one reader per core up to four
	  rawtcp             yes              yes, one reader (see below)
	  udp          yes, from 1.1.0              no
	  awg                no                     no

Until 1.1.0, gre and rawtcp set up the batched path and then read one packet
per call, and udp sent one per call; section 37 is the measurement behind udp.
Raw TCP keeps one reader because the acknowledgement number in the header it
makes up is taken from the segments it reads, and that number is the thing a
stateful box in the middle checks. AmneziaWG runs the udp carrier and still
sends one per call - section 37 says why.

The readers do not make the system call at the same time. Go takes the
descriptor's read lock inside RawConn.Read, so the recvmmsg calls happen one
after another; what overlaps is the work each does with its batch afterwards.

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

**No longer true of this path.** From 2026-09-16 UDP crossed cleanly on the
same pair (21), and UDP and AmneziaWG are in every table since (26, 34). The
count of six was real when it was taken; nothing here says what stopped doing
it, or that it will not start again - which is why ICMP is still the transport
this core is built around.

The UDP carrier is still worth having. It is the same code an ICMP carrier
needs, minus a raw socket, so it is the cheapest place to get the shape right;
and this is one path, on one ISP, at one time. Somebody else's will carry UDP
happily.

## 16. No encryption unless it is asked for

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

**Superseded by 18.** Every number above was taken before fq went on the
egress. fq spaces a socket's packets out itself, so a batch handed to it is no
longer that many packets at line rate - it is that many packets given to a
queue that releases them evenly. The burst the path was policing stops at fq
and never reaches the path. Measured again with fq on, three passes each, both
ends under 65 per cent busy (internal/carrier/batch_linux.go):

	  send_batch   download   one stream down   upload   path lost
	       1        377 Mbit    435 Mbit         447      none
	      16        365         593              455      none
	      32        557         522              444      none

No loss at any of them, and half as much again on the download at thirty-two.
It ships at thirty-two. The rule above still holds for a tunnel with
`tuning.pace = false`: take fq away and a batch is a burst again.

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

**Superseded.** This was taken when `queue_packets` was fq's flow limit
directly and the tunnel was sitting on it. It is multiplied by ten now, the
tunnel no longer reaches it at any profile, and no profile sets a different
one. Section 35 has the counters. The table stays because it is the evidence
for the shallow end - too small and fq throws away the burst it is there to
space out - and not because it describes a choice anybody is still offered.

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
Our own queues looked like why. On every profile fq is allowed 9000 packets
(the 900 in the file, ten times over) and the device 1000; flagtun holds what
it likes and sets the device to 10000. Told to keep the same depth - the
download profile, and `tun.txqueuelen = 10000` - the same measurement over the
same hour:

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

## 34. Every transport on 1.0.2, and our ICMP beside flagtun's

2026-09-22, Iran to Germany, because the Turkey route was still carrying
2 Mbit/s (see 32). Each transport was built through the wizard, measured,
and deleted, in that order, one after another over twenty minutes.

	                first byte   one down   four down   up
	TCP MUX           236 ms       380        403       458
	WS MUX            231          628         86       270
	WSS MUX           237          383        367       351
	Chrome TLS MUX    231          398        366       440
	Decoy TLS MUX     232          305        507       192
	KCP MUX           236          390        772       203
	GRE               327          505        473       581
	GRE FOU           329          505        680       440
	UDP               328          485        673       568
	AmneziaWG         330          400        483       506
	Fake TCP          319          420        653       543
	ICMP              321          528        643       540

Two things about the first byte before anyone quotes it. Every measurement
here was taken from the far server against the Iran server's public
address, because that is the only way the forwarding rule in PREROUTING is
exercised at all (see 30) - so each number crosses the path twice and is
about twice what a user sees. And the private links sit ninety milliseconds
above the forwarding ones for the reason given in 26: their first byte is
two round trips because the connection inside them handshakes across the
link.

What holds: the private links carry more on four streams than the
forwarding ones, the forwarding ones answer sooner, and one stream is
within noise of 400 Mbit/s for nearly all of them on this path at this
hour. WS MUX's 86 on four streams and Decoy TLS's 192 up are the path
moving, not the transport; a run of these takes twenty minutes and the
path does not hold still for twenty minutes.

Beside it, our ICMP against flagtun's on the same pair, alternating, the
medians of five rounds, measured Iran to Germany so these first-byte
numbers cross the path once:

	                          flagtun     ours
	first byte, idle           160 ms    160 ms
	first byte, under load     215       171
	download, one stream       751       649
	download, four streams     685       680
	upload                     497       592

Four streams is a tie and the first byte idle is identical. They are ahead
by about a sixth on a single stream; we are ahead by about a fifth on
upload, and by forty milliseconds on the thing a user actually feels - a
new connection while a download is running. That last column is the same
trade 28 found: our queues are shallower on purpose.

What 28 does not show is which change closed the single-stream gap there. That
run changed three things at once - the download profile, and
`tun.txqueuelen = 10000` set by hand, which no profile sets: every profile
ships the device queue at 1000. And section 35 later found neither queue drops
a packet on this pair at any depth, which makes "the queue was the gap" harder
to believe than it looked. It is open.

---

## 35. The profile stopped meaning anything, and what could be shown about it

Three profiles shipped on one idea: a shallow queue is emptier when a small
packet arrives, so that packet waits less, and a deep one absorbs bursts and
carries more. Section 19 is the table it was measured on, and it was true.

It is not true now. Nobody broke it - other work in this core made the queues
stop forming, and nothing went back to ask what that left the profile doing.
Four things were established, and one was not.

**fq is asked for a queue larger than the qdisc it is asked of.** The profile's
`queue_packets` reaches exactly one place: fq's per-flow limit, multiplied by
ten in carrier/pace_linux.go. At the download profile that asks for 15000, of a
qdisc that holds 10000. Read off the Frankfurt server with the tunnel running:

	qdisc fq 8001: root refcnt 2 limit 10000p flow_limit 15000p

Download's depth is not rarely reached. It cannot be reached.

**No depth drops a packet, at either end of its range.** Counters taken around
each transfer, sixteen streams and eight, at both extremes of the device queue:

	  txqueuelen   streams   device packets   device dropped   fq dropped   Mbit/s
	     500          8        1,933,024            0               0         631
	     500         16        1,949,990            0               0         621
	   10000          8        1,809,311            0               0         575
	   10000         16        1,789,354            0               0         603

A queue that never drops is not shaping anything, whatever number is written on
it. The table in link/tun_linux.go was real when it was taken - 500 dropped 47,
1167 and 2320 packets then - and the read path has since become fast enough
that the queue stops building.

**The receive queue is applied, so a null result about it would be a real one.**
The core prints what it got on every start: `carrier: socket buffers, 256 KB in`
and `3072 KB in`, matching the file each time.

**DSCP does not survive this route.** Twelve UDP packets from Frankfurt to
Tehran with `IP_TOS` 0xb8, which is the expedited class, captured on arrival in
Tehran: twelve of `tos 0x18`. Every one re-marked from DSCP 46 to 6. A profile
that sets `tuning.dscp` buys nothing here.

### What could not be shown, after four attempts

Whether 256 KB or 3072 KB of receive queue changes anything today. Four
harnesses, each with the transfer proved to be running underneath the probe,
put the same tunnel at the same load here:

	  where the probe's client ran        quiet p50   under load p50 / p90 / p99   jitter
	  Frankfurt, load pulled from Tehran    74.6         74.6 / 75.1 / 75.7         0.3
	  Frankfurt, both sides detached        85.0         85.2 / 112.1 / 194.4       9.1
	  a thread beside the senders           76.8        124.8 / 223.5 / 648.7      49.0
	  a process beside the senders          85.3         90.4 / 225.2 / 533.8      70.6

The spread between harnesses is far larger than anything 256 against 3072 could
do, so none of these rows is evidence about the setting. They are evidence
about the harness. The receive queue keeps the value section 19's measurement
gave it, and this is written down so the next person does not spend an evening
discovering the same thing.

### Why they disagreed, which is the useful part

`nproc` on the Tehran server is 1.

The first harness put the probe's client on that server, beside eight download
threads. It read a p90 between 92 and 375 ms and a p99 up to 892, wandering by
a factor of four between two runs of the same setting, and it looked exactly
like queueing. At 78 to 83 per cent busy the client was waiting for the
processor and printing its own scheduling delay. Moving the client to the
two-core server - same tunnel, same load, same direction - took the p99 from
551 ms to 75.7.

The third harness fixed the overlap problem by putting the load and the probe
in one Python process. The probe thread then queued behind eight sender threads
for the interpreter lock, which is its own version of the same mistake.

So: **a latency measurement is only as good as the idlest machine at either end
of it.** With one core under the load generator there is no arrangement of
these tools that measures the path rather than the processor.

## 36. GRE FOU does not want fq, and it is the fastest link here

Every transport asks for fq on the egress interface when its carrier opens.
GRE FOU opens no carrier - the kernel moves the packets and this core returns
to watching - so it was the one transport leaving on whatever queue the
distribution had set. That looked like an oversight worth twenty per cent, by
analogy with section 18.

It was written, and then measured before being believed. A GRE FOU pair of its
own between the two servers, eight streams pushed from Frankfurt, the queue on
Frankfurt's egress flipped between the two and back, three rounds interleaved:

	  qdisc       round 1   round 2   round 3     p50 / p90     jitter
	  fq_codel    951       928       955        81.4 / 81.7     0.3 ms
	  fq          945       494       903        81.4 / 81.7     0.3 ms

fq is not better. It is level at best, it had a round at half the rate, and
the round trip does not move by a tenth of a millisecond either way. The change
was taken out again.

Why the analogy failed, which is the part worth keeping: fq earns its twenty
per cent by spacing out bursts **this process makes**. A userspace carrier
reads a batch off a device and writes it to a socket in one go, and fq spreads
that burst over time. Nothing here makes a burst - the kernel moves each packet
as the TCP inside the tunnel releases it, already paced by that TCP's own
congestion control. There is nothing left for fq to smooth, and its per-flow
accounting is work for no gain.

So `tuning.pace` and `tuning.queue_packets` are not written into a GRE FOU
config at all. Its whole `[tuning]` table is one line, the profile, which is
there because the two ends compare it.

The other number in that table is worth saying out loud. **951 Mbit/s**, with
the round trip under full load at 81.4 ms against an idle 82, and 0.3 ms of
jitter. The same pair over a userspace UDP private link, measured the same
evening, carried about 600. The kernel path is not a little faster, and it
costs nothing in delay to use it.

## 37. UDP sends in batches, and it loses less for it

Until 1.1.0 the UDP carrier sent one packet per system call, on the reasoning
that UDP was for paths where it worked and those were not where the last ten
per cent is fought over. By September both halves had stopped being true: UDP
carried 600 Mbit/s on this pair, and AmneziaWG runs this very carrier.

So it was given sendmmsg, the way GRE, ICMP and raw TCP already had it, and
measured with one binary - the 1.1.0 core, run beside the shared one in a unit
of its own, never in its place. At `send_batch = 1` it takes exactly the old
path; at 32 it batches. Eight streams each way, both ends set the same,
interleaved:

	  throughput, Mbit/s        batch 1               batch 32
	  download                 582  635  430  555      609  747  565  700
	  upload                   787  705  686  711      802  832  455  838

Download - the Frankfurt end sending - was ahead in all four pairs, by a
quarter to a third in the second run. Upload - the Tehran end sending - in
three of four.

**The first reading of this was wrong in a way worth keeping.** Those were
throughput figures, and throughput hides loss: the TCP inside retransmits and
the number still looks fine. When the carriers' own counters were read after a
batched run, about a tenth of the packets had never arrived, and on the
download they went missing in runs of about twenty-nine - near enough the
batch size to look like exactly the burst section 17 watched the path police.

So it was measured again, the loss this time, counters read fresh after each
restart:

	                     batch 1                      batch 32
	                 lost    per gap              lost    per gap
	  download      12.06 %     56               10.85 %     60
	                 8.69 %     49                5.74 %     13
	  upload        11.96 %      4                4.62 %      3

Batching loses less, in every pair that could be read. And the runs are there
at a batch of one too - about fifty packets at a time on the download. That
is the path policing eight saturating streams, whatever sends them; the
twenty-nine was a coincidence with the batch size and not a cause.

Two readings were thrown away, and why is written down so nobody puts them
back. A third round returned nothing in either direction: the tunnel's own
counters and journal were clean, so it was the Python sources the harness
runs, not the carrier. And one upload count read 238 million packets lost at
838 Mbit/s, which cannot both be true; it is what the far end's replay window
reports when the sender restarts under it with fresh sequence numbers.

It also cost a run to learn that two measurement scripts must never share the
lab: the first was still finishing when the second started, its clean-up
stopped the second's sources, and the second's restarts landed inside the
first's last round. Both rounds were discarded.

AmneziaWG does **not** batch, although it runs this carrier. Its packets meet
the awg device before anything else, and that has no fq on it; it has never
been measured batched; and every AmneziaWG file from before 1.1.0 already says
`send_batch = 32`, which this carrier ignored until now - so honouring it would
switch batching on at upgrade for a transport nobody tried it on. The carrier
holds AmneziaWG at one per call until somebody measures it.

## 38. GRE and Fake TCP read in batches now, and neither got worse for it

Section 7 said the packet transports read with recvmmsg. Only ICMP did; GRE
and Fake TCP set the batched path up and then read one packet per call, and
GRE's own start-up line said "up to 128 in" while it did. In 1.1.0 both read
in batches - GRE with one reader per core up to four, as ICMP does; Fake TCP
with one, because the acknowledgement number in the header it makes up is
taken from the segments it reads, and two readers finishing out of order
would send it backwards under a middlebox that tracks it.

Measured old core against new on the same pair, each transport's own lab
tunnel, the arm's binary swapped in under the tunnel's own systemd unit so
that nothing else differed. Three rounds, interleaved. Download is the Tehran
end receiving; its core's CPU is over that window; loss is what its carrier
counted missing.

	  GRE            download 8 / 1        upload 8       rx cpu      lost
	  1.0.2          575  585              847            64 %       16.1 %
	  1.1.0          554  649              841            62         10.8
	  1.0.2          579  681              702            67         14.0
	  1.1.0          745  721              819            55         12.4
	  1.0.2          609  726              829            64         14.3
	  1.1.0          616  631              840            65         15.1

	  Fake TCP       download 8 / 1        upload 8       rx cpu      lost
	  1.0.2          710  428              688            64 %       14.5 %
	  1.1.0          657  718              708            65         15.0
	  1.0.2          747  676              703            69         11.0
	  1.1.0          760  738              819            79         12.8
	  1.0.2          692  750              789            80         16.2
	  1.1.0          811  825              801            77         11.7

GRE is level - each column goes both ways across the three rounds, the
receiving core a little less busy, loss a little lower. Fake TCP is better:
a single stream downloaded faster in all three rounds and the upload was
higher in all three. Neither shows the thing this was measured for, which is
a regression; the change stays.

Two things the harness got wrong on the way, kept because the next person
will meet them too. A core copied to another path was not executable - a
file built on Windows has no execute bit - and the unit failed with
status=203/EXEC, which the driver reported only as "did not come up", for
three rounds. And `grep -oE 'd8=[0-9]+' | tr -dc '0-9'` keeps the 8 from the
field's name: every download read 8,575 where it was 575, and it took two
full runs and a good deal of theorising about the tunnel before the leading
digit was seen for what it was. Cut on the equals sign.

## 39. A small stream on a busy forward tunnel: what 1.0.2 did, and what changed

Nothing in this file had measured the thing a person on a forward tunnel
actually feels: a small request - a keystroke, a game packet, a new page -
while somebody else's download saturates the link. Section 34's first-byte
column was a new connection on a quiet tunnel. So a probe was built: one
byte to an echo on a forwarded port and one byte back, twenty times a second,
on a connection that stays open, while eight streams pull through the same
tunnel. The probe records a stall past five seconds as five seconds rather
than giving up - the first version gave up, and printed zeros where it should
have printed "the tunnel was stuck".

Three cores, the same TCP MUX pair, arms swapped in under the tunnel's own
systemd unit, three rounds interleaved:

	                          down 8 / 1     under load   p50    p90    p99   jitter
	  1.0.2                    469   175                5005   5005   5005    922
	  2 KB records, 1.1.0      517   440                5002   5005   5005   2503
	  16 KB records, 1.1.0     511   470                 456   2862   5004    747

	  1.0.2                    574     0                5005   5005   5005      0
	  2 KB records, 1.1.0      503   168                 785   5004   5005   1461
	  16 KB records, 1.1.0     651   421                 158    160   1589     37

	  1.0.2                    540   648                 786   5005   5005   1553
	  2 KB records, 1.1.0      656   260                1471   4974   4974   2816
	  16 KB records, 1.1.0     590   112                 231   5005   5005   1084

**1.0.2 is stuck.** Every sample past the probe's limit, in two rounds of
three, with zero jitter because every one of them is the same five seconds.
A single stream started after the saturation got 0 Mbit/s in one round. This
is what a forward tunnel did under load before, and nobody had a number for
it because nobody had asked.

The mechanism is not a queue this core built. A forward tunnel pins every
stream to one of its connections, eight bulk streams on eight connections
leave none free, and what a small record waits behind on a shared connection
is everything that connection holds: the forwarder's own queue in front of
the socket, the socket's unsent bytes, a window in flight, and - on this
path, which drops a tenth of what saturates it - every retransmission timeout
of the TCP underneath. It is TCP inside TCP under loss, which the top of
carrier/stream.go has warned about since it was written.

**What 1.1.0 does about it,** and each was measured on the way:

- `TCP_NOTSENT_LOWAT` on every carrier connection, by profile: 64 KB for
  gaming, 128 for the others. The socket buffers cannot be touched - naming
  one turns off the receive window auto-tuning this path needs - so this is
  the only queue in the socket a profile can shorten. Measured across the
  three settings under the same probe, 64 was the least bad and 512 KB, which
  was going to be the download profile's, stalled the small stream past five
  seconds in every round for no throughput at all over 128. Download gets 128.
- Records of 16 KB on every stream carrier, where the five TCP ones had kept
  2 KB after KCP was measured into 16. Alone, that made the small stream
  *worse* - 1185 ms against 714 - because the forwarder's queue in front of
  each connection is sixty-four records, sized when a record was 2 KB, and
  the 1.2 seconds its own comment records having measured at 4,000 records
  came straight back at eight times the bytes. The queue is sized in bytes
  now, as the read side already was.
- With both, the small stream under saturation comes back in 158 to 456 ms
  at the median where 1.0.2 never came back at all, and the tunnel carries
  more on eight streams and much more on one.

It is not finished. p99 still reaches the five second limit in two rounds of
three: on a path with this much loss, a stream pinned to a connection in
retransmission backoff waits for it, and no queue setting reaches that. The
only thing that would is a connection with nothing else on it - and that was
the next measurement.

**Eight connections against sixteen**, the corrected 16 KB core on both, the
same probe, three rounds interleaved:

	                 down 8 / 1      under load   p50    p90    p99   jitter
	  8 connections   537    40                 5005   5005   5005      0.5
	  16              617   389                  166    166    172      0.5
	  8               558     0                  344   2120   2607    903
	  16              422   283                  151    152    435     13.6
	  8               472     0                  282   2758   5005    872
	  16              562   507                  158    159    166      1.3

With sixteen the small stream answers in 151 to 166 ms in every round, the
ninetieth under 170, the jitter under fifteen; with eight it stalls outright
once and answers in seconds at the ninetieth the other twice, and a stream
started after the burst gets nothing in two rounds of three. The eight
stream download does not move. Eight bulk streams can occupy at most eight
connections; sixteen leaves eight for everything small. **The default is
sixteen from 1.1.0.** It was never swept before - every table in this file
up to here was taken at eight, and the note beside DefaultConnections had
said only why it was not one.

## 40. AmneziaWG batched, measured, and left alone

Section 37 held AmneziaWG at one packet per call while UDP went to batches,
because its packets meet the awg device before anything else and that device
has no fq on it. It was measured afterwards, the same A/B as section 37 on
its own lab pair, the arm's core swapped in under the tunnel's own unit,
three rounds interleaved:

	                  down 8 / 1     up 8     rx cpu     lost
	  one per call    566   652     650      45 %      17.1 %
	  batch of 32     518   629     596      41        15.8
	  one per call    642   662     650      46        13.2
	  batch of 32     645   677     703      48        15.0
	  one per call    565   524     659      47        12.2
	  batch of 32     572   645     743      48        13.3

A wash. The upload is up eight per cent at the median and the loss is up two
points; the download columns go both ways by less than the rounds differ
from each other. Every AmneziaWG file written before 1.1.0 says
`send_batch = 32`, which the carrier had always ignored, so honouring the key
now would switch all of them to batching at upgrade - for this. It stays at
one per call, and the file does not carry the key.

## 41. The five presets measured where they differ, and KCP under its cipher

2026-09-24, 02:30 to 03:45 Tehran time, the same lab pairs as sections 37
to 40, the arm's core under the tunnel's own unit, rounds interleaved. Three
questions: what the five presets of 1.1.0 do on a TCP carrier, what they do
on a private link, and what sealing every KCP packet costs. A fourth came
out of the first and was measured on its own.

The presets were still called gaming, balanced, download, unstable and
crowded when this ran; they are gaming, stable, balanced, throughput and max
now, and the numbers are the numbers.

**TCP MUX, forward mode.** The only levers a preset has on a TCP carrier are
the unsent bound (64 KB for gaming and stable, 128 for the rest) and the
connection count (16, 24 for stable, 32 for max). Eight streams pulled from
Iran while a small request went back and forth on a second forwarded port;
three rounds:

	                      down 8 / 1     lag under load p50 / p90 / p99   jitter
	  gaming      64 KB  16  596   620      166   167   173                0.6
	  balanced   128 KB  16  615   359      166   167   170                0.5
	  throughput 128 KB  16  515   564      171   172   181                0.8
	  stable      64 KB  24  650   106      164   164   454                7.4
	  max        128 KB  32  573   481      164   165   168                0.6

	  gaming                 515   598      162   162   165                0.4
	  balanced               640   218      159   160   170                0.7
	  throughput             611   600     5005  5005  5005                0.1
	  stable                 586   499      157   158   160                0.3
	  max                    582   125      164   165   166                0.4

	  gaming                 361   310      160   161   173                0.7
	  balanced               591   560     5005  5005  5005                1.7
	  throughput             605   736      157   158   159                0.3
	  stable                 676   588      156   157   159                0.5
	  max                    652   516      168   168   169                0.4

Throughput does not separate them: 515 to 676 Mbit/s with the rounds
differing more than the presets. Neither does the lag when it answers: 156
to 171 ms at the median for all five, jitter under a millisecond. What
separates them is the two rows that did not answer at all. A 5005 is the
probe's whole window with nothing back - the small stream stalled for five
seconds - and both of them fell on 128 KB arms, none on the six 64 KB arms.
Two of nine against none of six is not a measurement; it is a reason to
make one. That is the fourth question, below.

**UDP, tun mode.** Here a preset's levers are the receive queue (256 KB or
3072) and parity (1 in 10 for stable). Gaming, balanced and an unstable line
without its parity are the same file on a private link, and so are
throughput and max, so three arms cover the five. IRAN pulled eight streams
and one from KHAREJ, KHAREJ pulled eight back, the receiving core's CPU and
the download's loss from IRAN's counters:

	                      down 8 / 1     up 8    rx cpu    lost      loss
	  256 KB              853   678      806     69 %     222149    15.4 %
	  3072 KB             845   748      761     71       133656    10.0
	  256 KB, parity 10   800   550      660     77        97805     7.8

	  256 KB              897   525      841     74       158318    10.8
	  3072 KB             799   666      763     69       120708     9.6
	  256 KB, parity 10   740   450      696     69       113826     9.7

	  256 KB              875   666      769     66       117029     8.4
	  3072 KB             931   571      784     77       112289     7.6
	  256 KB, parity 10   798   387      688     76       103406     8.1

The queue depth is the wash section 35 said it was: 853, 897, 875 against
845, 799, 931 on eight streams, and the deep queue's fewer gaps are the
socket absorbing what the shallow one dropped, which is what section 35
argued is the congestion signal arriving late. Parity is not free. One in
ten costs eight to ten per cent on the aggregate, twenty on the upload, and
the single stream drops from the six hundreds to the four hundreds, because
every eleventh packet is now overhead and the encoder runs on the same one
core in Tehran that is already at seventy per cent. What it buys on this
path is nothing visible, because this path does not lose packets on its
own: every loss in these columns is the download's own saturation, which
parity cannot repair. That is why stable is a preset for a line that loses
packets and not the default: on a clean line it is a tax.

**KCP under its cipher.** Section 39's forward harness on the KCP pair, 16
connections, the core with kcp-go's cipher left nil against the same core
sealing every packet under XChaCha20-Poly1305 keyed from the token:

	                    down 8 / 1     lag under load p50 / p90 / p99   jitter
	  in the clear     783   249      257   328   405               45.7
	  sealed           756   256      228   300   357               37.3
	  in the clear     803   250      225   268   303               31.0
	  sealed           747   223      245   313   373               38.9
	  in the clear     810   242      235   273   318               32.4
	  sealed           760   266      243   332   449               41.4

Five per cent of the aggregate - 783, 803, 810 against 756, 747, 760 - and
nothing on the lag: the medians land on both sides of each other. That is
the cipher's whole price, and what it buys is that the packet on the wire
no longer carries kcp-go's header in fixed places. It stays. The same table
says something about KCP itself: on this clean path its lag under load is
225 to 260 ms where TCP MUX's, in the first table, is 160, because eight
bulk streams over sixteen KCP sessions are paced by KCP's own retransmit
timer and window, not the kernel's BBR. KCP is for the path that throttles
TCP, not this one.

**The unsent bound on its own.** Gaming and balanced differ on a TCP carrier
in exactly one thing, 64 KB against 128 KB of unsent bytes a bulk stream may
park in front of a small one, so those two files are that A/B. Five rounds,
the same harness:

	                 down 8 / 1     lag under load p50 / p90 / p99   jitter
	  64 KB          584   403      169   169   195                1.1
	  128 KB         603   610      166   167   172                0.5
	  64 KB          515   515      163   163   164                0.3
	  128 KB         546   487      166   166   169                0.4
	  64 KB          634   473      165   165   166                0.3
	  128 KB         554   526      165   166   169                0.6
	  64 KB          488   493     5005  5005  5005                0.4
	  128 KB         617   559      168   169   171                0.4
	  64 KB          543   418      166   166   168                0.3
	  128 KB         532   345      165   165   166                0.2

The stall fell on the 64 KB arm this time. Ten rounds, one stall, on the
bound the earlier two had spared: the bound is not what stalls the small
stream, and the two of nine above were the path having a moment. Everything
else is equal to the round's noise - 163 to 169 ms at the median on both,
throughput both ways. So balanced keeps 128 KB, gaming and stable keep 64,
and the difference between them is what section 39 measured, a bulk
stream's worth of parking, not a stall. What does stall a small stream for
five seconds about once in ten probe windows on this harness - it did it
once to the fixed 16 KB arm in section 39 as well - is not the profile, is
not the connection count at sixteen, and is not settled here.

## 42. The Turkey tunnel is slow because the Turkey server cannot send

2026-09-25, 11:50 to 12:30 Tehran time, the live GRE FOU pair between Iran
and Turkey (`iran-grefou-8466` / `kharej-grefou-8466`) with the users on it.
The operator's words were that the tunnel was worth nothing and that they
could not tell whether the server was the reason. It is the server.

**What was wrong first, and is not the reason.** Both ends of the link were
MTU 1400. GRE FOU puts 36 bytes around every packet - 20 of IP, 8 of UDP, 4
of GRE, 4 of key - and the Iran server's own interface is 1400, so every
full packet Iran sent was 1436 on an interface that takes 1400. The wizard
wrote 1400 because it assumed a 1500 interface. Turkey's counters since
boot held 16 million packets refused for size and 87 thousand fragments
that never reassembled. Three rounds against the same path with nothing of
ours in it, Turkey serving and Iran pulling and pushing:

	                   down 1 / 4      up 1      first byte
	  raw path          2    5        1483         80 ms
	  link at 1400      1    1        1458         97
	  link at 1364      1    2        1391        194
	  raw path          2    6        1499         79
	  link at 1400      0    1        1519         97
	  link at 1364      1    2        1574         81
	  raw path          2    5        1637         81
	  link at 1400      1    2        1244        116
	  link at 1364      1    2        1397        111

Turkey refused no packet for size in any of the nine arms and Iran one, so
the 16 million were history, not today. 1364 is right for a server whose interface is 1400
and it stays - both files say so now, and the wizard, the token paste and
the boot hook derive it from the interface since this section - but it
moves nothing here. What the table does say is the direction: 1.4 Gbit/s
from Iran to Turkey, and from Turkey to Iran two to six megabits on the raw
path and nought to two through the tunnel, which was carrying the users'
nine at the same time.

**Not the port.** TCP pulled from Turkey on four ports, one stream and
four, two rounds:

	  tcp/443     3 5   3 5      tcp/8443    3 5   3 5
	  tcp/80      2 5   2 5      tcp/29085   3 6   2 5

UDP was another matter in the same minutes. A steady stream of datagrams
from Iran to an echo on Turkey, on udp/443 and udp/29500 alike, at 300 a
second and at 830, brought 6 back each time. A fresh flow of UDP between
these two servers already stopped after its sixth datagram that morning,
while the GRE FOU flow the users rode, which was not fresh, carried them
all day. Section 43 is what happened when that stopped too.

**The Turkey server, to everywhere.** Each server against public endpoints
in the same minutes:

	                    download        upload
	  Turkey            1062 Mbit/s     3.2 Mbit/s    (Cloudflare)
	                     174            -             (OVH)
	  Iran               224            94            (Cloudflare)

and Turkey's interface, read over ten seconds with the users on it: 11
Mbit/s out, 8 in, on a 10 Gbit/s virtual NIC. The machine takes a gigabit
in and sends about ten megabits out, in total, to anywhere. The users'
traffic comes in from the internet and has to go out to Iran, so every one
of them shares those ten megabits, and no transport can carry more than the
server sends. Section 32 read this route as about three megabits each way
and blamed the route; that was the same ceiling seen from inside it.

It was not always so. The interface has sent 3.1 TB in the 19 days since
boot, 15 Mbit/s on average, which ten megabits could not have done - the
shape of a provider that throttles a machine after a monthly traffic
allowance. The fix is at the provider or a different server, and this is
how to tell, in two commands, on the next one:

	curl -s -o /dev/null -w '%{speed_download}\n' 'https://speed.cloudflare.com/__down?bytes=50000000'
	head -c 20000000 /dev/urandom | curl -s -o /dev/null -w '%{speed_upload}\n' --data-binary @- https://speed.cloudflare.com/__up

Both are bytes per second; a server for this job needs the second one to be
at least what the users should get.

## 43. When Iran blocks the foreign server: what still carries

At 22:13 UTC on 2026-09-25 (01:43 in Tehran) the users' GRE FOU tunnel to
Turkey stopped, and both watchdogs began restarting it every two minutes and
a quarter. Nothing on either server had changed. Both were up, Iran answered
SSH from inside the country, and each still reached the rest of the world.
What had changed was what Iran let through between it and one address,
92.249.61.49. The same things that morning (section 42) and that night,
23:50 to 00:40 UTC:

	                                          that morning      that night
	  TCP, Iran pulling from Turkey           2 to 6 *          10 Mbit/s
	  TCP, Iran pushing to Turkey             1483 to 1637      0
	  TCP opened by Turkey into Iran          -                 0, either way
	  a stream of fresh UDP datagrams         6 came back       6 arrived, each way
	  the users' GRE FOU flow                 carrying          stopped
	  Iran to Cloudflare, down / up           224 / 94          196 / 112
	  * the users were taking the rest of Turkey's ten megabits

A fresh UDP flow was stopped after six datagrams that morning already; what
changed at 22:13 is that the established one stopped as well, and that TCP
from Iran to that address carried nothing any more - neither what Iran sent
on its own connections, nor anything on a connection Turkey opened. A
download still crossed, Turkey answering what Iran asked for, at the ten
megabits that are the Turkey server's own ceiling (section 42).

Every transport, built through the 1.0.2 wizard between the two servers,
given twenty seconds after it first said up, then measured from Iran - a
pull through the tunnel from a source on Turkey, which is the users'
direction, and a push the other way:

	                      says up   carried to Iran   health check
	  TCP MUX               yes           0             nothing wrong
	  WS MUX                yes           0             nothing wrong
	  WSS MUX               yes           0             nothing wrong
	  Chrome TLS MUX        yes           0             nothing wrong
	  Decoy TLS MUX         yes           0             nothing wrong
	  KCP MUX               yes           0             nothing wrong
	  GRE                   yes           0             15 to 70 % lost
	  GRE FOU               yes           0             nothing wrong
	  UDP                   yes           0             silent after the first packets
	  AmneziaWG             no            0             never completed a handshake
	  Fake TCP              no            0             never seen
	  ICMP                  yes           9 Mbit/s      12 to 29 % lost under load
	  WS via Cloudflare     yes           9 Mbit/s      nothing wrong, no drops
	  WSS via Cloudflare    yes         9.5 Mbit/s      nothing wrong (the users' own)

Two ways through. One is ICMP, which the filter did not touch. The other is
not to talk to the blocked address from Iran at all: a Cloudflare name that
fronts the Iran server, and the foreign server dialling it. Iran then only
exchanges packets with Cloudflare, which it reaches at full speed, and
Cloudflare carries it to Turkey. That is what the users run on now
(`iran-wss-443` / `kharej-wss-443`, Iran listening on 80 behind
a Cloudflare name of the operator's): 9.5 Mbit/s, the whole of what Turkey can send, and not
one carrier connection dropped in its first minute and a half. The round
trip is 111 ms against the 40 of the direct path; that is the price.

The worst lines in the table are the first six and GRE FOU. Each of those
tunnels connected, said it was up, and passed its health check, while
carrying nothing. Two TCP tunnels built by hand the same night, Chrome TLS
MUX on 443 and TCP MUX on 29446, showed how when their connections were read
with ss: a congestion window of one, the same segments sent again and
again, a few kilobytes through at most. The filter let the tiny heartbeat
through and stopped the full-size segments behind it; KCP, over UDP, kept
its heartbeat the same way and carried nothing. Nothing in a tunnel could
see it, because everything it measured was small.

So a forward tunnel now probes. Every third heartbeat has a companion padded
to 1800 bytes - enough to need a full-size segment, and small enough that a
1.0.2 far end, whose records stop at 2048 bytes, takes it and echoes it.
The probe rides a carrier connection of its own. Every stream carrier
delivers in order, so a probe the path stops holds up whatever is queued
behind it on its connection; on the heartbeat's it would stall the
heartbeat, which has to keep crossing for a stopped probe to mean anything.
The first version did exactly that, and a review caught it before it ran
anywhere: the test's wire had skipped the stopped record and delivered what
came after it, which no stream carrier does, and now it does not either.

A probe counts as missed when the next one leaves and it has not come back.
After three misses in a row, ninety seconds, with the heartbeat still
answering and less than 64 KB of data arriving meanwhile - streams and
forwarded datagrams both - the status says `data_blocked`, and the health
check says the other server answers the heartbeat and nothing the size of
data crosses. The cause is a filter on the foreign address, for which this
section is the way around, or a path smaller than the interface, for which
it is MTU probing. Data arriving at all rules it out: a busy tunnel can lose
a probe's echo to a full queue, but it cannot be carrying and blocked at
once. A tunnel of one connection is not probed, and a private link has no
forwarder to probe with: GRE FOU passed its check in this sweep while
carrying nothing, and still would.

## 44. Through Cloudflare at the evening peak: freezes, and the other roads

On 2026-09-29 the users' tunnel on the second pair ran WSS MUX through a
Cloudflare name that fronts the Iran server, sixteen connections, about a
thousand users' connections on them. At 16:00 UTC, 19:30 in Tehran, its
median was fine and its tail was not. Forty fresh connections through it, a
byte and its echo, then ten round trips on each:

	                                   median    p90    worst
	  first byte of a new connection    112      272    3196 ms
	  a round trip on an open one       109      159    3446 ms

Nothing on the servers explained the tail. Neither was busy; the receive
queues of Iran's carrier sockets were empty in six samples a second apart,
so no reader was waiting on a slow user; the foreign server resolved names
in 6 to 21 ms and reached Telegram's data centres in 20 to 30 and Instagram's
in 10 to 40. What did explain it: 208 carrier connections ended in nine
hours, most of them in bursts, and a connection the path stops carrying ends
only when the kernel gives it up, twenty seconds without an acknowledgement
(streamUserTimeout) - twenty seconds in which every stream pinned to it
waits.

So from 1.1.3 the side that dials listens to each connection on its own
(stallAfter, in internal/carrier/stream.go). The far end acknowledges every
sixteen kilobytes a stream takes, and a connection quiet for half a second is
sent a beat the far end answers on it, so a connection that works has always
heard within a second and a half. One quiet for three seconds, while at least
half the others have heard within one and a half, is closed, which is what
its ending would have done twenty seconds later: its slot is redialled and
its streams carried on from the last byte the far end acknowledged. It holds
back when most connections are quiet together - that is the path, not the
connection, and the failover's to judge - and when the far end has never
answered a beat, which a core before 1.1.3 does not.

Two things the first build on the pair taught it. The minute after the
restart a thousand programs reconnected at once and the foreign server's xray
took its time with them; a reader handing a frame to a program that slow
reads nothing more meanwhile, most connections went quiet that way together,
and the rule rightly held back - while the one connection the path really had
stopped waited twenty-nine seconds behind them. A reader busy handing a frame
up now counts as hearing, and is never replaced. And a replacement through
Cloudflare came up and carried nothing, and sat there for the thirty seconds a
slot is left alone after a replacement; that pause is for a connection that
worked and went quiet, and one that has heard nothing since it was made is now
replaced again after three seconds, then six, doubling up to thirty.

Ten minutes of the users' tunnel after the first build, at 32 connections,
the same hour of the evening, felt through the tunnel the same way - eight
connections held open and asked a byte four times a second, and a fresh
connection every two seconds:

	                                     before                 after
	  new connections, median/p90/worst  112 / 272 / 3196 ms    97 / 101 / 330 ms
	  of them over a second              2 of 40                0 of 293
	  round trips on open ones           109 / p90 159 /        96 / p99 147 /
	                                     worst 3446 ms          worst 721 ms
	  of them over a second              (not counted)          0 of 13835

Two connections were replaced in those ten minutes; the second was the
replacement that never carried, above.

The other roads between the same two servers, the same hour, each a test
tunnel of its own for about a minute, the foreign server dialling:

	                           new connection        idle round trip   down, 4 streams   ended
	                           median / p90 / worst  median / worst
	  WSS via Cloudflare       112 / 408 / 859        107 / 439         779 Mbit/s        6
	  the same, again           97 / 101 / 101         96 / 101         781               9, 5 connections failed
	  WS via Cloudflare, 8080   98 / 101 / 108         97 / 313         780               0
	  Chrome TLS MUX, direct    77 /  82 /  83         76 /  97         661               0
	  Decoy TLS MUX, direct     80 /  83 /  88         77 /  90         614               0
	  WSS MUX, direct           77 /  83 /  90         75 /  84         744               2
	  TCP MUX, direct           -                      -                -                 13, one every ten seconds
	  UDP                       6 of 200 datagrams came back

Pings to the foreign server's address lost 70 to 90 per cent from Iran while
the router in front of it, on the same path, answered every one, and so did
8.8.8.8, 1.1.1.1 and 9.9.9.9: the filter has that address, not the route. It
shows in what it does to each transport - TCP MUX cut every ten seconds, UDP
after six datagrams - and not, that hour, in what it did to the three that
look like TLS to a site. A minute of a test's traffic is not the users' load,
though: that morning WSS MUX direct, carrying the users, lost 166 to 173
carrier connections in ten minutes, which is why they were moved to
Cloudflare in the first place.

## 45. A crowd: the forward tunnel, the packet level, and flagtun

On 2026-09-30 the users of the second pair complained of a slow tunnel at
the evening peak, and the forward tunnel's own log said why: a stream whose
program read slowly held up every stream behind it on the same connection,
and the resets that followed were users' connections given up on. Every
TCP multiplexer has this - Backhaul's too - because a connection delivers in
order: one lost packet, or one slow reader, and the forty users pinned to
that connection wait together.

A crowd through one test link filled to the top, 80 Mbit/s between Iran 1
and Germany, 44 users on 32 connections - downloads, video, slow readers,
sixteen chatting a byte four times a second, a new connection every quarter
second - the chat's round trip:

	                                        chat p90          fairness of the downloads
	  the forward tunnel as it was          1072 - 1655 ms    0.65 - 0.99
	  rewritten, 128 KB parked per stream    760 - 1111
	  rewritten, 16 KB parked per stream     573 -  760       0.76 - 0.995
	  the packet level, the same link        212 -  228       0.998

The rewrite (internal/forward: a scheduler per connection, control first,
then fresh streams, then busy ones in turn; a window per stream counted from
what the far end's program has taken) halves the tail. What is parked in the
kernel in front of it is outside its reach and waits in the kernel's order,
so tuning.profile now parks 32 KB (64 for throughput and max): at 128 KB, 44
users on 32 connections - two and a half megabits each - is 400 ms in front
of every keystroke. The rest of the tail is the one ordered connection, and
no scheduler above it can remove it; at the packet level each user's TCP runs
end to end and a loss is that user's alone. Measured the same way at 44
users with the link full: the forward tunnel's chatting users p90 900 ms and
up to 3 s, jitter 315 - 366 ms; at the packet level 225 ms and at most 470,
jitter 36 - 50. So the users' ports now go to a private link at the packet
level while one answers (pingify-core -switch, internal/l3switch), and to the
forward tunnel, Cloudflare first, when none does.

That makes the private link the users' road, and it was compared with
flagtun's ICMP, v1.69 at its defaults, on the same path in the same minutes,
each a test link of its own, taking turns. Four fixes came out of it:

- The device's queue. Germany's ICMP link had dropped 1.1 million packets on
  the way out by evening, each a user's TCP halving its window. At
  txqueuelen 10000 and an 8 MB receive buffer: 503 and 535 Mbit/s on one and
  four streams, against flagtun's 483 and 509 and the old link's 424 and
  364; 14 thousand dropped where the old link dropped 1.1 million.
- The order. The readers of one socket are one per core, and a batch taken
  second could reach the device first: on Iran 1, 28,013 packets captured on
  the wire had two out of order, and the link, after its readers, twenty. The
  batches are now numbered as they come off the socket and handed over in
  that order (inOrder, internal/carrier/order.go).
- The loss counter. A far end that restarted ahead of the old count showed
  as hundreds of millions of packets lost; a jump past sixteen million is now
  a new beginning.
- A device queue per core, up to four (defaultQueues, internal/link). One
  queue on Germany dropped 75 thousand packets and carried 451 - 584 Mbit/s;
  four dropped 7 thousand and carried 561 - 579, flagtun 546 - 604.

Ten minutes, three rounds, each round a normal crowd (about 36 Mbit/s) for
25 s and then four downloads flat out while sixteen chat for 13 s; medians of
the rounds:

	                              normal: chat p50 / p99    full: Mbit/s   chat p50 / p99
	  flagtun                          76 / 88               553           152 / 531
	  ours, 4 queues, mtu 1360         76 / 91               575           224 / 685
	  the same, txqueuelen 2000        76 / 83               578           222 / 984

Under a normal load the two are the same. With the link full, ours carried
more and answered later; section 46 is where that time was.

## 46. Where a full link's time goes: a queue on the way out

The full link's extra 70 ms of section 45, looked for directly. Four
downloads flat out from Germany through a test link while sixteen chat,
sampling every half second eth0's queue on Germany and the carrier sockets'
receive queues on Iran 1, 2026-09-30 21:35 UTC:

	                     downloads   chat p50 / p90 / p99   Germany's eth0: queue   dropped there
	  flagtun              590        210 / 226 / 589        up to 9,005 packets      9,441
	  ours                 588        229 / 339 / 877        up to 8,953             60,062
	  ours, paced at 900   521        252 / 301 / 808        up to 8,945             19,151

The receive side was empty throughout: Iran 1's sockets held at most 340 KB
for a moment and dropped nothing, its interface dropped nothing. The time is
all in one place, eth0's fq on Germany - the server's own way out, which
carries about 600 Mbit/s and not more. The whole tunnel is one socket and so
one flow to fq, one queue first in first out, and the downloads stand
thousands of packets in it: 9,000 packets of 1,400 bytes at 600 Mbit/s is
170 ms, in front of every other user's packet. flagtun stood the same queue.
And the loss the link had been counting on this path - 59,208 packets in that
run - was fq throwing ours away at its limit, 60,062: not the path at all.
The TCP inside resent 8.8 per cent of what it sent.

The queue can only be made short where the flows inside the tunnel can be
seen, which is the tun device, and only if the device, not eth0, is the
narrowest point. So cake on the device, a little under what eth0 carries,
one queue per flow (tun.shape_kharej_mbit, internal/link/shape.go). The same
test, the same minutes, the first three 13 s and the last two 20 s:

	                  downloads   chat p50 / p90 / p99   TCP resent   eth0 queue   dropped at eth0
	  no limit          614        219 / 365 / 894        8.8%         ~9,000       71,583
	  cake 520          452         82 /  96 / 231        0.17%        0            0
	  cake 560          451         88 / 133 / 399        0.10%        up to 1,617  0
	  cake 600          538         85 / 106 / 171        0.08%        up to 4,086  0
	  cake 660          552         94 / 158 / 324        0.10%        up to 2,912  0

with the path's own round trip at 76 ms. At 600 the chat waits 9 ms over
the path where it waited 143, the downloads keep 88 per cent of what they
had, and the resending - traffic paid for twice - is gone. At 660 the queue
starts to come back at eth0. Germany's two links to Iran 1 run at 600 since
22:10 UTC the same day. Iran 1's way out and the Turkey pair are not limited:
what their ways out carry has not been measured, and a number set above it
does nothing while one set below costs speed.

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

- **Before blaming a route, ask each server what it can send to anywhere.**
  Section 32 blamed the Iran to Turkey route for three megabits; section 42
  found the Turkey server sent ten megabits in total, to Cloudflare as much
  as to Iran, while taking a gigabit in. One upload to a public endpoint
  from each end would have said so on the first day.

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

- **A latency measurement is only as good as the idlest machine at either end.**
  On a one core server the load generator and the probe are the same queue.
  Move the clock to the other end, and if that end is also busy, do not report
  a tail at all.

- **Prove the load was running under the probe, in the output.** Two servers
  started from two clocks cannot be shown afterwards to have overlapped, and
  `date` on one minus `date` on the other measures the ssh round trip - it read
  +6 seconds one minute and -6 the next.

- **Do not put the probe in the same interpreter as the load.** Eight sender
  threads and one timing thread share a lock, and the timing thread reports it.

- **Read the loss, not just the rate.** A transfer that loses a tenth of its
  packets can still post a good number, because the TCP inside resends them.
  The carrier counts what never arrived; ask it.

- **One measurement at a time.** Two scripts sharing a lab will restart each
  other's tunnels and stop each other's sources, and neither will say so.

- **A probe that gives up at the first stall reports "no data" where it
  should report the stall.** Record the timeout as a sample and carry on.

- **When a number is impossible, suspect the harness before the tunnel.**
  8,575 Mbit/s over an internet path is not a measurement, it is a parsing
  bug, and the tunnel's own counters had said 950 all along.

- **An analogy is a hypothesis, not a result.** fq was worth twenty per cent to
  every carrier that had been measured, so giving it to the one that had not
  looked like tidying up. It was worth nothing there, for a reason that was
  obvious afterwards. Measure the one you are about to change.
