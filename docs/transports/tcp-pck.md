# TCP PCK

The KCP + FEC engine inside TCP packets this process builds and reads on the network device itself, upstream of connection tracking and every netfilter chain.

**Config slug:** `pck` · **Needs:** Linux, IPv4, root/CAP_NET_RAW on **both** ends · **Group:** FORWARDING

## What it is

A TCP transport that does not use the kernel's TCP stack.

It builds its own segments and reads the replies straight off the device, so the machinery that would normally reset, throttle or drop a long-lived TCP flow has nothing to act on. **Nothing is forged**: the addresses and ports are real and the replies route normally. What does not exist is the *connection* — no handshake, no socket, no kernel state — while the segments themselves carry the sequence numbers, flags and window a real one would.

KCP with Reed-Solomon parity underneath supplies the reliability the absent stack would have provided.

## When to use it

One symptom, and it is specific:

> A plain TCP tunnel connects, runs for a while, and then stalls, dies or is throttled for no reason that appears in any log.

That is what this is for. If [TCP MUX](tcp-mux.md) is stable on your route, PCK buys you nothing and costs you root.

## Setting it up

**Create tunnel → TCP PCK.** Both ends must be Linux with root or `CAP_NET_RAW`, and both must be on this transport.

Pingify installs two narrow firewall rules automatically:

- a rule dropping outbound RST on the tunnel's own source port, so the kernel does not tear down a connection it does not know it has
- a NOTRACK rule, so conntrack does not hold state for it

Both are scoped to that port, both are removed when the tunnel is removed, and only the rules it actually installed are ever deleted. If iptables is missing or the process is not root, it says so rather than running half-configured.

## Tuning

PCK shares the KCP preset table: a small session pool, packet buffers, MTU near 1280 and a short flush interval. See [Tuning](../tuning.md).

The `pck_flags` setting controls which TCP flags the segments carry. The default (`PA` — PSH+ACK) is what an established connection looks like. Leave it alone unless you have measured that something on your path wants otherwise.

## Trade-off

Root, Linux and IPv4 on both servers. It is the least portable transport here and the one with the most moving parts between it and the network. Reach for it when the ordinary one has demonstrably failed, not before.
