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

## 15. No encryption unless it is asked for

Off by default. What is wanted from this tunnel is speed, ping and stability,
and the traffic inside it is already TLS.

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
