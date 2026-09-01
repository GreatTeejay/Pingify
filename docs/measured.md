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

## 14. Iran dials out

Connections *into* the Iran server are blackholed after about six exchanges.
The side that owns the ports is not the side that dials. Settled; do not
revisit.

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
