
# ---------------------------------------------------------------------------
# tunnel configuration
#
# Two things decide the shape of a tunnel, and both are asked on both servers
# because both ends have to agree.
#
#   kind        TCP  - the servers talk over their own public addresses
#               TUN  - a private layer-3 link, carried over ICMP today
#
#   forwarder   only meaningful under TUN, where a local tunnel exists:
#               PINGIFY  - the core carries each connection itself
#               IPTABLES - the kernel NATs onto the local tunnel
#
# A TCP tunnel has no local tunnel and adds no interface, so the core is the
# only thing that can forward on it and there is nothing to ask.
#
# Ports are asked for on the IRAN server alone - that is the end clients
# reach. The security token is typed by hand on both.
# ---------------------------------------------------------------------------

cfg_reset() {
    T_NAME=""; T_ROLE=""
    # kind is TCP or TUN; the transport, mode and forwarder all follow from it.
    T_KIND="tcp"; T_TRANSPORT="tcp"; T_MODE="forward"; T_FORWARDER="pingify"
    T_TOKEN=""
    T_PORT=9443          # the tunnel's own port, TCP only
    # Which side takes the connection. KHAREJ does, and IRAN dials out to it.
    #
    # It used to be the other way round, and on a real Iranian line that does
    # not work. Measured between a real Iran server and two abroad servers: a
    # connection dialled INTO Iran carries about six exchanges and is then
    # blackholed - no reset, no error, the packets simply stop arriving, and
    # the tunnel sits there believing every carrier is up. A connection dialled
    # OUT of Iran over the same path, the same second, the same payload, ran
    # 120 of 120 exchanges without a loss.
    #
    #   dialled into Iran     1 of 40 round trips,   24 Mbit/s
    #   dialled out of Iran  40 of 40 round trips,  254 Mbit/s, +0.7 ms
    #
    # It holds for every transport and both abroad servers, and it is why UDP
    # and ICMP cannot carry a tunnel there at all: their return traffic is
    # inbound too. IRAN still owns the forwarded ports and is still the server
    # role - only who opens the socket changed.
    T_ACCEPTS="client"
    T_PUBLIC_IP=""; T_PEER_IP=""
    # wss only, and optional: an address to dial instead of the peer, for
    # a connection that must not be seen going to the peer at all.
    T_EDGE=""
    # Optional origin certificate for WSS. Empty uses the core's automatic
    # self-signed certificate, which is valid with Cloudflare SSL mode Full.
    T_CERT_FILE=""; T_KEY_FILE=""
    T_CARRIERS=16; T_WINDOW=1024; T_KEEPALIVE=10; T_PRESET="balanced"
    T_SNDBUF=1024; T_RCVBUF=1024   # socket buffers, sized to hold a BDP
    T_FEC_DATA=10; T_FEC_PARITY=3; T_PACKET_MTU=1200; T_KCP_INTERVAL=10
    T_PCK_FLAGS="PA"
    T_OBFUSCATE="false"  # v2.1.1 wire shape; the one that survives the path
    T_ENCRYPT="false"   # off unless asked for; see Config.encrypted in the core
    T_FORWARDS=""; T_STATUS=""; T_LOG="info"
    T_TUNIF=""; T_TUNLOCAL=""; T_TUNPEER=""; T_TUNMTU=1380
    # kernel tunnels: GRE carries a TTL, AmneziaWG a port, a keypair half and
    # the obfuscation values both ends have to agree on
    T_GRE_TTL=255
    T_AWG_PORT=51820; T_AWG_PRIV=""; T_AWG_PUB=""; T_AWG_OBF=""
}

this_side_accepts() { [ "$T_ROLE" = "$T_ACCEPTS" ]; }

# PCK has no kernel connection to allocate an ephemeral source port. Keep one
# stable across reconnects, derived from the shared token, and away from the
# service/privileged ranges. The core uses the same two SHA-256 bytes.
pck_source_port() {
    local tok="$1" remote="$2" hex n
    hex="$(printf '%s' "$tok" | sha256sum | cut -c1-4)"
    n=$((16#$hex))
    n=$((20000 + n % 40000))
    if [ "$n" = "$remote" ]; then
        n=$((n + 1)); [ "$n" -ge 60000 ] && n=20000
    fi
    printf '%s' "$n"
}

# A local tunnel belongs to the TUN kind and nowhere else. A TCP tunnel runs
# over the two public addresses and leaves the machine as it found it, so the
# core is the only thing that can forward on it.
cfg_mode() {
    # GRE and AmneziaWG are the kernel's own tunnels. They always build a
    # private link, and the kernel is the only thing that can forward on it -
    # our core is not in the path at all.
    if kernel_transport; then
        T_KIND="tun"; T_MODE="tun"; T_FORWARDER="iptables"
        T_TUNIF="$(link_iface "$T_NAME")"
        return
    fi
    if [ "$T_KIND" = "tun" ]; then
        # both forwarders work here: the kernel can NAT onto the local tunnel,
        # or the core can carry the ports over the same carriers.
        [ "$T_FORWARDER" = "iptables" ] && T_MODE="tun" || T_MODE="both"
    else
        T_FORWARDER="pingify"
        T_MODE="forward"
    fi
    # A WebSocket transport is one physical connection by construction. Set
    # that invariant as soon as the transport shape is derived so programmatic
    # config creation and the interactive wizard produce the same file.
    case "$T_TRANSPORT" in ws | wss) T_CARRIERS=2 ;; esac
}

cfg_needs_link() { [ "$T_MODE" != "forward" ]; }

# The name says which server this is and what the tunnel runs on, so two
# servers side by side read as what they are without either file being opened.
# A tunnel that builds a private link wears the TUN label in front of it.
#
# Both the wizard and the importer name tunnels, and they used to do it with
# two copies of this - which drifted the moment one of them was edited, and
# left an AmneziaWG tunnel called iran-9443 after a TCP port it does not use.
tunnel_default_name() {
    local extra="${1:-}" base tail=""
    [ -n "$extra" ] && tail="-$extra"
    base="$(printf '%s' "$(side_label "$T_ROLE")" | tr 'A-Z' 'a-z')"
    # Which server, then what it is, then which one of those. In that
    # order, because the first thing anybody wants from a list of tunnels
    # is which end they are looking at - and a list sorted by name then
    # groups the two sides apart instead of interleaving them.
    #
    # TCP is the exception that names no protocol: it is the plain case,
    # and iran-9443 is clearer than iran-tcp-9443. Everything else says so,
    # because TCP 9443 and UDP 9443 are two different sockets and can both
    # exist at once.
    case "$T_TRANSPORT" in
        icmp) printf '%s-tun-icmp%s' "$base" "$tail" ;;
        gre)  printf '%s-tun-gre%s' "$base" "$tail" ;;
        awg)  printf '%s-tun-awg%s' "$base" "$tail" ;;
        udp)  printf '%s-udp-%s' "$base" "$T_PORT" ;;
        kcp)  printf '%s-kcp-%s' "$base" "$T_PORT" ;;
        pck)  printf '%s-pck-%s' "$base" "$T_PORT" ;;
        ws)   printf '%s-ws-%s' "$base" "$T_PORT" ;;
        wss)  printf '%s-wss-%s' "$base" "$T_PORT" ;;
        *)    printf '%s-%s' "$base" "$T_PORT" ;;
    esac
}

# link_octet - the x in 10.x.10.0/24.
#
# When a server holds two tunnels of the same kind, something has to tell them
# apart, and a counter tells you nothing: iran-gre-2 says only that it was
# second. The private network says which one it is - and both servers agreed
# on it, so both ends of one tunnel still arrive at the same name. The health
# port cannot do this job: it is chosen locally and independently on each
# server, so the two ends would end up called different things.
link_octet() {
    local a="${T_TUNLOCAL%%/*}"
    case "$a" in
        10.*.*.*) a="${a#10.}"; printf '%s' "${a%%.*}"; return 0 ;;
    esac
    return 1
}

# ---------------------------------------------------------------------------
# WSS behind a CDN
#
# Nothing here is a new field. The IRAN server is asked for its address as
# always, and for WSS that address is a domain - so the domain travels in
# the token like any other address, both ends dial and present the same
# name, and the config says it once, in connect.
#
# The one thing that is genuinely extra is an edge: an address to dial that
# is not the peer. The name still travels, so the CDN still routes it home;
# only the address changes, and it never names the IRAN server.
# ---------------------------------------------------------------------------

# is_name - a hostname rather than an address. Only a name can be routed on:
# TLS carries no SNI for an IP literal, so a CDN handed one has nothing to
# look at and an edge would be pointless.
is_name() {
    case "$1" in
        "" | *:*) return 1 ;;
        *[!0-9.]*) return 0 ;;
    esac
    return 1
}

# A CDN proxies these ports and no others. On any other one a proxied record
# never reaches the server at all, which looks exactly like a tunnel that
# will not start - so it is worth saying before it is built.
cdn_ports() { printf '443 2053 2083 2087 2096 8443'; }

cdn_port_ok() {
    case " $(cdn_ports) " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

cdn_port_warn() {
    [ "$T_TRANSPORT" = "wss" ] || return 0
    is_name "$T_PEER_IP" || return 0
    cdn_port_ok "$T_PORT" && return 0
    say ""
    warn "a CDN does not proxy port $T_PORT"
    dim "behind Cloudflare, WSS arrives on these and no others:"
    dim "  $(cdn_ports)"
    dim "on any other port a proxied record never reaches this server,"
    dim "which looks exactly like a tunnel that will not start"
    return 0
}

# ask_edge - only WSS, only the end that dials, and only when the peer is a
# name. Everything else has nothing for the CDN to route on.
ask_edge() {
    [ "$T_TRANSPORT" = "wss" ] || return 0
    say ""
    head2 "Edge address"
    if ! is_name "$T_PEER_IP"; then
        # An edge presents the peer's name to the CDN. When the peer is a bare
        # address there is no name, TLS sends no SNI for one, and the CDN has
        # nothing to route on - so there is nothing an edge could do here.
        dim "The IRAN server is ${C_OFF}${T_PEER_IP}${C_DIM}, an address rather than a name."
        dim "An edge only works when there is a domain to present to the CDN,"
        dim "so this tunnel goes straight there. Rebuild the IRAN end with a"
        dim "domain if you want a CDN in front."
        say ""
        return 0
    fi
    dim "Optional. This end presents ${C_OFF}${T_PEER_IP}${C_DIM} whatever address it"
    dim "dials, so a CDN still routes it to the right place. An edge is only a"
    dim "different way in - one that never names the IRAN server."
    say ""
    ask T_EDGE "edge address to dial, blank to dial ${T_PEER_IP}" "$T_EDGE"
    cdn_port_warn
}

ask_wss_certificate() {
    [ "$T_TRANSPORT" = "wss" ] && this_side_accepts || return 0
    wiz "WSS origin certificate"
    dim "Automatic works directly and behind Cloudflare in SSL mode Full."
    dim "For Full (strict), provide a Let's Encrypt or Cloudflare Origin pair."
    say ""

    local auto_cert="" auto_key="" pick_default=1
    if is_name "$T_PUBLIC_IP"; then
        auto_cert="/etc/letsencrypt/live/${T_PUBLIC_IP}/fullchain.pem"
        auto_key="/etc/letsencrypt/live/${T_PUBLIC_IP}/privkey.pem"
        if [ -r "$auto_cert" ] && [ -r "$auto_key" ]; then
            pick_default=2
            dim "A Let's Encrypt certificate was found for ${T_PUBLIC_IP}."
            say ""
        fi
    fi
    choice 1 "Automatic" "ephemeral self-signed origin certificate - Cloudflare Full"
    choice 2 "Certificate files" "stable trusted/origin pair - Cloudflare Full (strict)"
    say ""
    local c=""
    ask c "select" "$pick_default" || return 1
    [ "$c" = "2" ] || { T_CERT_FILE=""; T_KEY_FILE=""; return 0; }

    while :; do
        ask T_CERT_FILE "certificate/fullchain path" "$auto_cert" || return 1
        ask T_KEY_FILE "private key path" "$auto_key" || return 1
        if [ -r "$T_CERT_FILE" ] && [ -r "$T_KEY_FILE" ]; then
            break
        fi
        fail "both files must exist and be readable on this server"
    done
}

# listen and connect are derived, never stored anywhere shared: they are the
# one part of a tunnel that differs between the two servers.
cfg_endpoints() {
    CFG_LISTEN=""; CFG_CONNECT=""
    # A kernel tunnel names both addresses in its own section; there is no
    # socket here for anything to listen on or dial.
    kernel_transport && return
    if this_side_accepts; then
        # ICMP has no port, so listen carries the address to answer from.
        if [ "$T_TRANSPORT" = "icmp" ]; then CFG_LISTEN="${T_PUBLIC_IP:-0.0.0.0}"
        else CFG_LISTEN="0.0.0.0:$T_PORT"; fi
    else
        if [ "$T_TRANSPORT" = "icmp" ]; then
            CFG_CONNECT="$T_PEER_IP"
        else
            # The peer address, which for WSS is the domain - or the edge,
            # on the one tunnel that asks for one.
            local target="$T_PEER_IP"
            [ "$T_TRANSPORT" = "wss" ] && [ -n "$T_EDGE" ] && target="$T_EDGE"
            CFG_CONNECT="$target:$T_PORT"
        fi
    fi
}

# ---------------------------------------------------------------------------
# performance presets
#
# These numbers used to be guesses. They are now taken from iperf3 between a
# real Iran and Kharej pair:
#
#   the path carries ~100 Mbit/s in both directions
#   round trip is ~78 ms
#   one TCP connection reaches only 4-6 Mbit/s, because loss holds its
#   congestion window down around 30-90 KB
#
# A single connection is therefore worth about 6 Mbit/s no matter how much
# bandwidth exists, and filling 100 Mbit/s takes 15-20 of them. Four carriers -
# the old default - left seventy Mbit/s of a hundred unused.
#
# carriers  how many connections the link is spread over. On a lossy path this
#           is the setting that decides throughput, because each connection is
#           capped by its own window, not by the path.
# window    how much one forwarded connection may have in flight. The delay
#           bandwidth product here is about 1 MB, so anything below that
#           throttles a single large transfer even when the carriers could
#           carry it.
# ---------------------------------------------------------------------------

# The numbers, and why each one is what it is.
#
# A stream is pinned to one carrier for its life, so the window alone decides
# how fast a single download can go: window / round-trip. On the 75-90 ms this
# path actually measures, that is
#
#   256 KB  ->  ~24 Mbit/s      1024 KB  ->  ~95 Mbit/s
#   512 KB  ->  ~48 Mbit/s      4096 KB  -> ~380 Mbit/s
#
# for ONE connection. Carriers do not raise that; they spread many connections
# so one heavy download stops starving everything else.
#
# Bigger is not simply better. A window past what the path can carry does not
# go faster - it queues, and a queue is latency. That is what shows up as a
# video that stalls and a ping that swings while the speed graph looks fine.
# So the presets climb the window only as far as the traffic needs, and buy
# steadiness with carriers rather than with depth.
default_preset_buffers() {
    local ceiling=4096
    # A WebSocket has one physical TCP socket carrying every logical stream.
    # Its buffer therefore has to cover the aggregate BDP, not merely one
    # stream's credit window. It is still bounded: a deep socket queue is
    # latency, and Custom remains available for an exceptional path.
    case "$T_TRANSPORT" in
        ws | wss) ceiling=32768 ;;
        icmp | udp | kcp | pck) ceiling=65536 ;;
    esac
    T_SNDBUF="$T_WINDOW"; T_RCVBUF="$T_WINDOW"
    [ "$T_SNDBUF" -lt 512 ] && T_SNDBUF=512
    [ "$T_RCVBUF" -lt 512 ] && T_RCVBUF=512
    case "$T_TRANSPORT" in
        icmp | udp | kcp | pck)
            # Packet paths arrive in bursts. A several-megabyte kernel queue
            # lets recvmmsg drain that burst instead of losing it before ARQ
            # or KCP gets a chance to repair it.
            [ "$T_SNDBUF" -lt 4096 ] && T_SNDBUF=4096
            [ "$T_RCVBUF" -lt 4096 ] && T_RCVBUF=4096 ;;
    esac
    [ "$T_SNDBUF" -gt "$ceiling" ] && T_SNDBUF="$ceiling"
    [ "$T_RCVBUF" -gt "$ceiling" ] && T_RCVBUF="$ceiling"
}

apply_preset() {
    case "$T_TRANSPORT" in
        ws | wss)
            # One ordinary-looking WebSocket remains one physical carrier.
            # The presets buy throughput with enough per-stream credit and a
            # larger aggregate socket buffer instead of pretending that the
            # 8-24 carriers used by the other transports exist here. Two
            # connections rather than one: a browser holds that many open all
            # day, and one is a tunnel with no spare, where every cut is total.
            T_CARRIERS=2
            case "$1" in
                gaming)     T_WINDOW=256;  T_SNDBUF=1024;  T_RCVBUF=1024 ;;
                latency)    T_WINDOW=512;  T_SNDBUF=2048;  T_RCVBUF=2048 ;;
                balanced)   T_WINDOW=2048; T_SNDBUF=8192;  T_RCVBUF=8192 ;;
                throughput) T_WINDOW=4096; T_SNDBUF=16384; T_RCVBUF=16384 ;;
                extreme)    T_WINDOW=8192; T_SNDBUF=32768; T_RCVBUF=32768 ;;
                *)          return 1 ;;
            esac
            ;;
        kcp | pck)
            # KCP already fills a path with one session and repairs loss with
            # FEC. A small pool buys fairness and failover without multiplying
            # parity traffic sixteen times as the TCP presets would.
            case "$1" in
                gaming)     T_CARRIERS=1; T_WINDOW=256;  T_SNDBUF=16384; T_RCVBUF=1024;  T_FEC_DATA=10; T_FEC_PARITY=2; T_PACKET_MTU=1280; T_KCP_INTERVAL=5 ;;
                latency)    T_CARRIERS=2; T_WINDOW=512;  T_SNDBUF=16384; T_RCVBUF=2048;  T_FEC_DATA=10; T_FEC_PARITY=3; T_PACKET_MTU=1280; T_KCP_INTERVAL=5 ;;
                balanced)   T_CARRIERS=4; T_WINDOW=1024; T_SNDBUF=16384; T_RCVBUF=3072;  T_FEC_DATA=10; T_FEC_PARITY=3; T_PACKET_MTU=1280; T_KCP_INTERVAL=10 ;;
                throughput) T_CARRIERS=6; T_WINDOW=2048; T_SNDBUF=32768; T_RCVBUF=6144;  T_FEC_DATA=20; T_FEC_PARITY=4; T_PACKET_MTU=1280; T_KCP_INTERVAL=10 ;;
                extreme)    T_CARRIERS=8; T_WINDOW=4096; T_SNDBUF=65536; T_RCVBUF=16384; T_FEC_DATA=20; T_FEC_PARITY=5; T_PACKET_MTU=1280; T_KCP_INTERVAL=10 ;;
                *)          return 1 ;;
            esac
            ;;
        icmp | udp)
            # These used to run two to eight sessions on the reasoning that a
            # shared socket and a userspace ARQ do not need TCP's sixteen, and
            # that more sessions only multiply ACKs and timers. Measured, that
            # is backwards, and badly: a stream is pinned to one session for
            # its life, so a small request sharing a session with a download
            # waits behind it. With four heavy streams running,
            #
            #     2 sessions   80.7 ms      6 sessions   3.3 ms
            #     4 sessions   77.6 ms      8 sessions   2.7 ms
            #
            # and throughput was flat across all of them. The two presets named
            # for low latency were the two worst at it. What matters is that
            # there are more sessions than there are heavy streams; past that
            # nothing is gained and, measured up to thirty-two, nothing is lost
            # - even at a single stream the count made no difference at all.
            # The receive buffer is what these presets actually choose
            # between, and it used to be set as though bigger were always
            # better. It is not: on a packet transport it is the one number
            # that trades delay for bytes, and every preset here was far past
            # the point where it stops buying anything.
            #
            # Swept on a real Iran-Germany link with sixteen streams pushing,
            # measuring the round trip across the tunnel while they ran:
            #
            #     1 MiB   p50  75 ms   p90  84 ms   323 Mbit/s
            #     2 MiB   p50  77 ms   p90  90 ms   350 Mbit/s
            #     3 MiB   p50  82 ms   p90  96 ms   415 Mbit/s
            #     4 MiB   p50 110 ms   p90 123 ms   424 Mbit/s
            #     6 MiB   p50 132 ms   p90 176 ms   432 Mbit/s
            #    16 MiB   p50 133 ms   p90 165 ms   474 Mbit/s
            #
            # So gaming, which asked for four megabytes, was choosing 110 ms
            # when 75 was available - the preset named for latency was one of
            # the worst at it. Three is the knee and belongs to balanced:
            # below it a burst has nowhere to go and throughput falls away,
            # above it every megabyte costs tens of milliseconds.
            #
            # The send buffer is not this knob. Swept over the same range it
            # changed neither figure - nothing waits behind it on this machine
            # - so it stays large enough for any burst.
            case "$1" in
                gaming)     T_CARRIERS=8;  T_WINDOW=256;  T_SNDBUF=16384; T_RCVBUF=1024 ;;
                latency)    T_CARRIERS=12; T_WINDOW=512;  T_SNDBUF=16384; T_RCVBUF=2048 ;;
                balanced)   T_CARRIERS=16; T_WINDOW=1024; T_SNDBUF=16384; T_RCVBUF=3072 ;;
                throughput) T_CARRIERS=20; T_WINDOW=2048; T_SNDBUF=32768; T_RCVBUF=6144 ;;
                extreme)    T_CARRIERS=24; T_WINDOW=4096; T_SNDBUF=65536; T_RCVBUF=16384 ;;
                *)          return 1 ;;
            esac
            ;;
        *)
            # These were measured on the multi-carrier Iran-Europe path. Do
            # not trade known field behaviour for prettier round numbers.
            case "$1" in
                gaming)     T_CARRIERS=8;  T_WINDOW=256 ;;
                latency)    T_CARRIERS=12; T_WINDOW=512 ;;
                balanced)   T_CARRIERS=16; T_WINDOW=1024 ;;
                throughput) T_CARRIERS=20; T_WINDOW=2048 ;;
                extreme)    T_CARRIERS=24; T_WINDOW=4096 ;;
                *)          return 1 ;;
            esac
            default_preset_buffers
            ;;
    esac
    # One keepalive for every preset. What kept a carrier alive was how often
    # the *peer* spoke, so two ends on different presets used to disagree about
    # how long to wait - and the impatient one hung up on a healthy tunnel.
    T_KEEPALIVE=10
    T_PRESET="$1"
    return 0
}

# The tuning arrives in the token as bare numbers, so name the preset they
# match. Writing "from token" put a string in the profile field that is not a
# profile, and told a reader on this server nothing about what the tuning is -
# while the other server, with the identical numbers, called it Extreme.
# preset_name asks apply_preset rather than holding a second copy of the table.
# The two were separate lists, and the moment the presets were retuned they
# disagreed: apply_preset set balanced to 16 carriers while this still called
# 16 "custom" and 14 "balanced". A config could then report a profile no preset
# would produce.
preset_name() {
    local car="$1" win="$2" ka="$3" snd="$4" rcv="$5"
    local fecdata="${6:-}" fecparity="${7:-}" packetmtu="${8:-}" interval="${9:-}" p want got
    want="$car/$win/$ka/$snd/$rcv"
    case "$T_TRANSPORT" in
        kcp | pck) want="$want/$fecdata/$fecparity/$packetmtu/$interval" ;;
    esac
    for p in gaming latency balanced throughput extreme; do
        # in a subshell: apply_preset writes the T_ variables, and this is
        # asked from screens that are holding a tunnel in them
        got="$(apply_preset "$p" >/dev/null 2>&1
            printf '%s/%s/%s/%s/%s' "$T_CARRIERS" "$T_WINDOW" "$T_KEEPALIVE" "$T_SNDBUF" "$T_RCVBUF"
            case "$T_TRANSPORT" in
                kcp | pck) printf '/%s/%s/%s/%s' "$T_FEC_DATA" "$T_FEC_PARITY" "$T_PACKET_MTU" "$T_KCP_INTERVAL" ;;
            esac)"
        if [ "$got" = "$want" ]; then
            printf '%s' "$p"
            return 0
        fi
    done
    printf 'custom'
}

# A credit window below 64 KiB is silently raised by the core, which used to
# leave the file saying one thing while the running tunnel used another.  The
# upper bound is transport-aware: packet paths and the single shared
# WebSocket can use a large aggregate window, while a TCP carrier gains only a
# deeper queue after 4 MiB on the paths these presets target.
transport_window_max() {
    case "$T_TRANSPORT" in
        ws | wss)              printf '32768' ;;
        icmp | udp | kcp | pck) printf '4096' ;;
        *)                      printf '4096' ;;
    esac
}

tuning_values_valid() {
    local max n
    for n in "$T_CARRIERS" "$T_WINDOW" "$T_KEEPALIVE" "$T_SNDBUF" "$T_RCVBUF"; do
        case "$n" in "" | *[!0-9]*) return 1 ;; esac
    done
    [ "$T_CARRIERS" -ge 1 ] && [ "$T_CARRIERS" -le 64 ] || return 1
    # A WebSocket tunnel holds very few connections and the engine will not
    # honour more than four, so a token or an edit carrying more than that is
    # a config that would silently run as something else.
    case "$T_TRANSPORT" in ws | wss) [ "$T_CARRIERS" -le 4 ] || return 1 ;; esac
    max="$(transport_window_max)"
    [ "$T_WINDOW" -ge 64 ] && [ "$T_WINDOW" -le "$max" ] || return 1
    [ "$T_KEEPALIVE" -ge 1 ] && [ "$T_KEEPALIVE" -le 300 ] || return 1
    [ "$T_SNDBUF" -ge 64 ] && [ "$T_SNDBUF" -le 65536 ] || return 1
    [ "$T_RCVBUF" -ge 64 ] && [ "$T_RCVBUF" -le 65536 ] || return 1
    return 0
}

preset_menu() {
    CHOICE_DEF="3"
    case "$T_TRANSPORT" in
        ws | wss)
            choice 1 "Gaming" "1 MUX, 256 KB - shallow queues and the lowest loaded ping"
            choice 2 "Latency" "1 MUX, 512 KB - responsive browsing, calls and chat"
            choice 3 "Balanced" "1 MUX, 2048 KB - smooth video and everyday use"
            choice 4 "Download" "1 MUX, 4096 KB - large files on a fast path"
            choice 5 "Extreme" "1 MUX, 8192 KB - maximum single-stream throughput"
            ;;
        kcp | pck)
            choice 1 "Gaming" "1 KCP, 256 KB - minimum jitter and FEC overhead"
            choice 2 "Latency" "2 KCP, 512 KB - responsive with fast failover"
            choice 3 "Balanced" "4 KCP, 1024 KB - loss recovery and smooth video"
            choice 4 "Download" "6 KCP, 2048 KB - faster multi-flow transfers"
            choice 5 "Extreme" "8 KCP, 4096 KB - maximum packet-path throughput"
            ;;
        icmp | udp)
            choice 1 "Gaming" "8 sessions, 256 KB - lowest ping, nothing queued"
            choice 2 "Latency" "12 sessions, 512 KB - browsing, calls, chat"
            choice 3 "Balanced" "16 sessions, 1024 KB - smooth video around 100 Mbit/s"
            choice 4 "Download" "20 sessions, 2048 KB - larger receive batches and buffers"
            choice 5 "Extreme" "24 sessions, 4096 KB - maximum raw packet throughput"
            ;;
        *)
            choice 1 "Gaming" "8 carriers, 256 KB - lowest ping, nothing queued"
            choice 2 "Latency" "12 carriers, 512 KB - browsing, calls, chat"
            choice 3 "Balanced" "16 carriers, 1024 KB - video without stalls"
            choice 4 "Download" "20 carriers, 2048 KB - large files"
            choice 5 "Extreme" "24 carriers, 4096 KB - fastest, most memory"
            ;;
    esac
    choice 6 "Custom" "set the numbers yourself"
    CHOICE_DEF=""
    say ""
    local p=""
    ask p "select" "3"
    case "$p" in
        1) apply_preset gaming ;;
        2) apply_preset latency ;;
        4) apply_preset throughput ;;
        5) apply_preset extreme ;;
        6) T_PRESET="custom"
           say ""
           # WebSocket transports are one connection by construction, so there
           # is nothing to ask and a number here would only be ignored later.
           { [ "$T_TRANSPORT" = "ws" ] || [ "$T_TRANSPORT" = "wss" ]; } ||
               ask T_CARRIERS "parallel connections" "$T_CARRIERS"
           ask T_WINDOW "window per connection, KB" "$T_WINDOW"
           ask T_KEEPALIVE "keepalive seconds" "$T_KEEPALIVE"
           if [ "$T_TRANSPORT" = "kcp" ] || [ "$T_TRANSPORT" = "pck" ]; then
               ask T_FEC_DATA "FEC data shards" "$T_FEC_DATA"
               ask T_FEC_PARITY "FEC parity shards" "$T_FEC_PARITY"
               ask T_PACKET_MTU "packet MTU" "$T_PACKET_MTU"
               ask T_KCP_INTERVAL "KCP interval, ms" "$T_KCP_INTERVAL"
           fi ;;
        *) apply_preset balanced ;;
    esac
    case "$T_CARRIERS" in "" | *[!0-9]*) T_CARRIERS=16 ;; esac
    case "$T_WINDOW" in "" | *[!0-9]*) T_WINDOW=1024 ;; esac
    case "$T_KEEPALIVE" in "" | *[!0-9]*) T_KEEPALIVE=10 ;; esac
    [ "$T_CARRIERS" -lt 1 ] && T_CARRIERS=1
    [ "$T_CARRIERS" -gt 64 ] && T_CARRIERS=64
    [ "$T_WINDOW" -lt 64 ] && T_WINDOW=64
    local max_window; max_window="$(transport_window_max)"
    [ "$T_WINDOW" -gt "$max_window" ] && T_WINDOW="$max_window"
    [ "$T_KEEPALIVE" -lt 1 ] && T_KEEPALIVE=1
    [ "$T_KEEPALIVE" -gt 300 ] && T_KEEPALIVE=300
    if [ "$T_TRANSPORT" = "kcp" ] || [ "$T_TRANSPORT" = "pck" ]; then
        case "$T_FEC_DATA" in "" | *[!0-9]*) T_FEC_DATA=10 ;; esac
        case "$T_FEC_PARITY" in "" | *[!0-9]*) T_FEC_PARITY=3 ;; esac
        case "$T_PACKET_MTU" in "" | *[!0-9]*) T_PACKET_MTU=1280 ;; esac
        case "$T_KCP_INTERVAL" in "" | *[!0-9]*) T_KCP_INTERVAL=10 ;; esac
        [ "$T_FEC_DATA" -ge 1 ] && [ "$T_FEC_DATA" -le 64 ] || T_FEC_DATA=10
        [ "$T_FEC_PARITY" -ge 1 ] && [ "$T_FEC_PARITY" -le 32 ] || T_FEC_PARITY=3
        [ $((T_FEC_DATA + T_FEC_PARITY)) -le 96 ] || { T_FEC_DATA=10; T_FEC_PARITY=3; }
        [ "$T_PACKET_MTU" -ge 576 ] && [ "$T_PACKET_MTU" -le 1400 ] || T_PACKET_MTU=1280
        [ "$T_KCP_INTERVAL" -ge 5 ] && [ "$T_KCP_INTERVAL" -le 100 ] || T_KCP_INTERVAL=10
    fi
    # Whatever the preset said, WS/WSS carries the whole tunnel on one connection.
    case "$T_TRANSPORT" in ws | wss) T_CARRIERS=2 ;; esac

    # Presets chose their own transport-aware buffers above. Custom starts
    # from a safe value derived from its window and can be edited afterwards.
    [ "$T_PRESET" = "custom" ] && default_preset_buffers
}

# ---------------------------------------------------------------------------
# rendering
# ---------------------------------------------------------------------------

# Values written in quotes must use TOML/Go string escaping. This matters most
# for the shared security token: the wizard promises arbitrary one-line text,
# so a quote or backslash must remain the same secret after cfg_load.
toml_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

cfg_render() {
    local listen="$1" connect="$2" status="$3"
    printf '# Pingify tunnel - written by the manager, safe to edit by hand\n'
    printf '\n[tunnel]\n'
    printf 'name             = "%s"\n' "$T_NAME"
    printf 'role             = "%s"\n' "$T_ROLE"
    printf 'kind             = "%s"\n' "$T_KIND"
    printf 'mode             = "%s"\n' "$T_MODE"
    printf '\n[transport]\n'
    printf 'type             = "%s"\n' "$T_TRANSPORT"
    [ -n "$listen" ]  && printf 'listen           = "%s"\n' "$listen"
    [ -n "$connect" ] && printf 'connect          = "%s"\n' "$connect"
    # connect already holds the name, so nothing else is needed - except on
    # the one tunnel that dials an edge instead. There, connect holds the
    # edge, and host says which name to present when it gets there.
    [ "$T_TRANSPORT" = "wss" ] && [ -n "$T_EDGE" ] && [ -n "$T_PEER_IP" ] &&
        printf 'host             = "%s"\n' "$T_PEER_IP"
    [ "$T_TRANSPORT" = "wss" ] && [ -n "$T_CERT_FILE" ] && {
        printf 'cert_file        = "%s"\n' "$T_CERT_FILE"
        printf 'key_file         = "%s"\n' "$T_KEY_FILE"
    }
    if ! kernel_transport; then
        printf 'carriers         = %s\n' "$T_CARRIERS"
        printf 'keepalive_sec    = %s\n' "$T_KEEPALIVE"
        printf 'obfuscate        = %s\n' "$T_OBFUSCATE"
        printf 'encrypt          = %s\n' "$T_ENCRYPT"
    fi
    if [ "$T_TRANSPORT" = "kcp" ] || [ "$T_TRANSPORT" = "pck" ]; then
        printf '\n[kcp]\n'
        printf 'data_shards      = %s\n' "$T_FEC_DATA"
        printf 'parity_shards    = %s\n' "$T_FEC_PARITY"
        printf 'mtu              = %s\n' "$T_PACKET_MTU"
        printf 'interval_ms      = %s\n' "$T_KCP_INTERVAL"
    fi
    if [ "$T_TRANSPORT" = "pck" ]; then
        printf '\n[pck]\n'
        printf 'flags            = "%s"\n' "$T_PCK_FLAGS"
    fi
    printf '\n[security]\n'
    printf 'token            = "%s"\n' "$(toml_escape "$T_TOKEN")"
    printf '\n[forward]\n'
    printf 'forwarder        = "%s"\n' "$T_FORWARDER"
    [ -n "$T_FORWARDS" ] && printf 'ports            = [%s]\n' "$T_FORWARDS"
    if [ "$T_MODE" = "tun" ] || [ "$T_MODE" = "both" ]; then
        printf '\n[tun]\n'
        printf 'name             = "%s"\n' "$T_TUNIF"
        printf 'local_addr       = "%s"\n' "$T_TUNLOCAL"
        printf 'remote_addr      = "%s"\n' "$T_TUNPEER"
        printf 'mtu              = %s\n' "$T_TUNMTU"
    fi
    if [ "$T_TRANSPORT" = "gre" ]; then
        printf '\n[gre]\n'
        printf 'ttl              = %s\n' "$T_GRE_TTL"
        printf 'local_public     = "%s"\n' "$T_PUBLIC_IP"
        printf 'peer_public      = "%s"\n' "$T_PEER_IP"
    fi
    if [ "$T_TRANSPORT" = "awg" ]; then
        printf '\n[awg]\n'
        printf 'listen_port      = %s\n' "$T_AWG_PORT"
        printf 'private_key      = "%s"\n' "$T_AWG_PRIV"
        printf 'peer_key         = "%s"\n' "$T_AWG_PUB"
        printf 'obfuscation      = "%s"\n' "$T_AWG_OBF"
        printf 'local_public     = "%s"\n' "$T_PUBLIC_IP"
        printf 'peer_public      = "%s"\n' "$T_PEER_IP"
    fi
    if ! kernel_transport; then
        printf '\n[tuning]\n'
        printf 'profile          = "%s"\n' "$T_PRESET"
        printf 'window_kb        = %s\n' "$T_WINDOW"
        # The socket buffers are written only where they are read.
        #
        # A TCP carrier - tcp, ws, wss - does not take them any more. Asking
        # for SO_RCVBUF on one is clamped by the kernel to net.core.rmem_max,
        # about two hundred kilobytes, and asking at all switches off the
        # autotuning that would otherwise have grown the socket to several
        # megabytes. So the core stopped asking, and a number written here for
        # one of those would be a number that does nothing - which is the worst
        # kind to leave in a file that says it is safe to edit by hand.
        case "$(port_family "$T_TRANSPORT")" in
            udp | none)
            printf 'sndbuf_kb        = %s\n' "$T_SNDBUF"
            printf 'rcvbuf_kb        = %s\n' "$T_RCVBUF"
                ;;
        esac
        printf '\n[status]\n'
        printf 'addr             = "%s"\n' "$status"
        printf '\n[logging]\n'
        printf 'level            = "%s"\n' "$T_LOG"
    fi
}

# Name the missing field rather than letting the core report it as a flat
# rejection with nothing to point at.
cfg_check_complete() {
    local missing=""
    [ -n "$T_NAME" ]      || missing="$missing name"
    [ -n "$T_ROLE" ]      || missing="$missing side"
    [ -n "$T_TRANSPORT" ] || missing="$missing transport"
    [ -n "$T_TOKEN" ]     || missing="$missing token"
    case "$T_MODE" in
        tun | both) [ -n "$T_TUNLOCAL" ] || missing="$missing private-address" ;;
    esac
    if [ "$T_ROLE" = "server" ] && [ -z "$T_FORWARDS" ]; then
        missing="$missing ports"
    fi
    if ! this_side_accepts && [ -z "$T_PEER_IP" ]; then
        missing="$missing peer-address"
    fi
    if kernel_transport; then
        # Both ends of a kernel tunnel name both public addresses: the kernel
        # builds the link from the pair, not from whoever dialled first.
        [ -n "$T_PUBLIC_IP" ] || missing="$missing this-address"
        [ -n "$T_PEER_IP" ]   || missing="$missing peer-address"
        [ -n "$T_TUNPEER" ]   || missing="$missing peer-private-address"
        if [ "$T_TRANSPORT" = "awg" ]; then
            [ -n "$T_AWG_PRIV" ] || missing="$missing private-key"
            [ -n "$T_AWG_PUB" ]  || missing="$missing peer-key"
        fi
    else
        tuning_values_valid || {
            fail "transport tuning is invalid or outside its safe range"
            return 1
        }
    fi
    case "$T_OBFUSCATE" in true | false) ;; *) missing="$missing traffic-shaping" ;; esac
    if [ -n "$missing" ]; then
        fail "these are still missing:$missing"
        return 1
    fi
    return 0
}

cfg_save() {
    local file
    # Everything here is read through a command substitution, so anything the
    # check prints on stdout ends up inside the caller's variable instead of on
    # the screen. That turned a named missing field into a confirm prompt that
    # appeared to do nothing at all.
    cfg_check_complete >&2 || return 1
    file="$(cfg_file "$T_NAME")"
    cfg_endpoints
    cfg_render "$CFG_LISTEN" "$CFG_CONNECT" "$T_STATUS" > "$file"
    chmod 600 "$file"
    printf '%s' "$file"
}

parse_forwards() {
    local raw="$1" out="" item
    raw="${raw//,/ }"
    for item in $raw; do
        [ -n "$item" ] || continue
        [ -n "$out" ] && out="$out,"
        out="$out\"$item\""
    done
    printf '%s' "$out"
}

side_label()      { [ "$1" = "server" ] && printf 'IRAN' || printf 'KHAREJ'; }
# BRAID is what the TCP transport does: several carriers woven together, each
# flow pinned to one strand so nothing arrives out of order. The protocol is
# still plain TCP - the name describes the weave, not a new protocol.
# The name a transport is known by on screen. The config still writes the short
# slug - tcp, kcp, pck, ws, wss, icmp, gre, awg - so an existing tunnel keeps
# working and its service name never changes. Only what an operator reads moves.
transport_label() {
    case "$1" in
        icmp | echo) printf 'ICMP' ;;
        udp)         printf 'UDP ARQ' ;;
        kcp)         printf 'KCP FEC' ;;
        pck)         printf 'TCP PCK' ;;
        ws)          printf 'WS MUX' ;;
        wss)         printf 'WSS MUX' ;;
        gre)         printf 'GRE' ;;
        awg)         printf 'AmneziaWG' ;;
        *)           printf 'TCP MUX' ;;
    esac
}

# ---------------------------------------------------------------------------
# new tunnel
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# the setup token
#
# Build the tunnel on one server, paste one line on the other, and the second
# server is finished. Everything both ends have to agree on travels in it, so
# there is nothing to copy by hand and nothing to get wrong:
#
#   p5|kind|transport|mode|forwarder|dial|b64(host)|port|b64(token)|...|
#      b64(pck-flags)|profile|obfuscate|encrypt|sha256
#
# dial says what the far end does about the connection: 1 means it dials us
# and host is where, 0 means it accepts and supplies its own address. The
# private addresses are already swapped - what is ours becomes theirs.
#
# Text fields are encoded individually before the whole line is encoded. The
# older format split a perfectly valid password containing `|` into two fields
# and quietly built a different tunnel on KHAREJ. The final checksum rejects a
# truncated or mistyped token before any config is written. p2-p4 remain
# readable for upgrades.
# ---------------------------------------------------------------------------

setup_token_text_encode() {
    printf '%s' "$1" | base64 | tr -d '\n'
}

setup_token_text_decode() {
    printf '%s' "$1" | base64 -d 2>/dev/null
}

setup_token_bad() {
    SETUP_TOKEN_ERROR="$1"
    return 1
}

cfg_setup_token() {
    local dial host="" port="" tl="" tp="" mtu=""
    local ttl="" awgport="" awgpriv="" awgpub="" awgobf=""
    local body sum
    if this_side_accepts; then
        dial=1; host="$T_PUBLIC_IP"
    else
        dial=0
    fi
    # Every transport that binds a port has to carry it. Carrying it only
    # for tcp meant the far end guessed 9443 for udp, ws and wss - and a
    # wrong guess builds a tunnel whose two halves watch different ports
    # and never say so. Only icmp and gre have no port; awg keeps its own
    # in a field further along.
    case "$(port_family "$T_TRANSPORT")" in
        tcp | udp) port="$T_PORT" ;;
    esac
    if [ "$T_MODE" = "tun" ] || [ "$T_MODE" = "both" ]; then
        local pfx="${T_TUNLOCAL##*/}"
        [ "$pfx" = "$T_TUNLOCAL" ] && pfx=24
        tl="${T_TUNPEER%%/*}/${pfx}"
        tp="${T_TUNLOCAL}"
        mtu="$T_TUNMTU"
    fi
    if kernel_transport; then
        # The kernel builds its link from a pair of public addresses, so both
        # ends need both of them - not just whichever one dials.
        host="$T_PUBLIC_IP"
        if [ "$T_TRANSPORT" = "gre" ]; then
            ttl="$T_GRE_TTL"
        else
            awgport="$T_AWG_PORT"
            awgpriv="$awg_peer_priv"   # the half the other server keeps
            awgpub="$awg_self_pub"     # ours, which it lists as its peer
            awgobf="$T_AWG_OBF"
        fi
    fi
    body="$(printf 'p5|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' \
        "$T_KIND" "$T_TRANSPORT" "$T_MODE" "$T_FORWARDER" \
        "$dial" "$(setup_token_text_encode "$host")" "$port" "$(setup_token_text_encode "$T_TOKEN")" \
        "$T_CARRIERS" "$T_WINDOW" "$T_KEEPALIVE" "$T_SNDBUF" "$T_RCVBUF" \
        "$(setup_token_text_encode "$tl")" "$(setup_token_text_encode "$tp")" "$mtu" \
        "$ttl" "$awgport" "$(setup_token_text_encode "$awgpriv")" \
        "$(setup_token_text_encode "$awgpub")" "$(setup_token_text_encode "$awgobf")" \
        "$T_FEC_DATA" "$T_FEC_PARITY" "$T_PACKET_MTU" "$T_KCP_INTERVAL" \
        "$(setup_token_text_encode "$T_PCK_FLAGS")" "$T_PRESET" "$T_OBFUSCATE" "$T_ENCRYPT")"
    sum="$(printf '%s' "$body" | sha256sum | awk '{print $1}')"
    printf '%s|%s' "$body" "$sum" | base64 | tr -d '\n'
}

# Decode and validate without asking questions or touching the filesystem.
# Keeping this separate is what lets the test suite run the real Iran ->
# KHAREJ path for every transport rather than reimplementing the importer in a
# test and accidentally proving only the test itself.
setup_token_read() {
    local encoded="$1" raw fields body sum want
    local v kind tr mode fwd dial host port tok car win ka snd rcv tl tp mtu
    local ttl awgport awgpriv awgpub awgobf fecdata fecparity packetmtu kcpinterval pckflags
    local profile="" obfuscate="false" encrypt="true"
    SETUP_TOKEN_ERROR=""

    raw="$(printf '%s' "$encoded" | tr -d ' \t\r\n' | base64 -d 2>/dev/null)" ||
        { setup_token_bad "that is not valid base64"; return 1; }
    case "$raw" in
        p5\|*)
            # Thirty is a token printed before the encryption setting existed,
            # thirty-one is one printed after. Both are read: the two servers are
            # updated one at a time, and a token printed five minutes ago should
            # not stop working halfway through that.
            fields="$(printf '%s' "$raw" | awk -F'|' '{print NF}')"
            case "$fields" in
                30 | 31) ;;
                *) setup_token_bad "the token is incomplete"; return 1 ;;
            esac
            body="${raw%|*}"; sum="${raw##*|}"
            want="$(printf '%s' "$body" | sha256sum | awk '{print $1}')"
            [ "$sum" = "$want" ] || { setup_token_bad "the token checksum does not match"; return 1; }
            if [ "$fields" = "31" ]; then
                IFS='|' read -r v kind tr mode fwd dial host port tok car win ka snd rcv tl tp mtu \
                    ttl awgport awgpriv awgpub awgobf fecdata fecparity packetmtu kcpinterval \
                    pckflags profile obfuscate encrypt sum <<TOKEN
$raw
TOKEN
            else
                # There is no such field, and every tunnel that predates it was
                # encrypted - so its absence has to mean yes, not no.
                IFS='|' read -r v kind tr mode fwd dial host port tok car win ka snd rcv tl tp mtu \
                    ttl awgport awgpriv awgpub awgobf fecdata fecparity packetmtu kcpinterval \
                    pckflags profile obfuscate sum <<TOKEN
$raw
TOKEN
                encrypt="true"
            fi
            host="$(setup_token_text_decode "$host")" || { setup_token_bad "the address field is damaged"; return 1; }
            tok="$(setup_token_text_decode "$tok")" || { setup_token_bad "the security field is damaged"; return 1; }
            tl="$(setup_token_text_decode "$tl")" || { setup_token_bad "the private address is damaged"; return 1; }
            tp="$(setup_token_text_decode "$tp")" || { setup_token_bad "the peer address is damaged"; return 1; }
            awgpriv="$(setup_token_text_decode "$awgpriv")" || { setup_token_bad "the AWG private key is damaged"; return 1; }
            awgpub="$(setup_token_text_decode "$awgpub")" || { setup_token_bad "the AWG peer key is damaged"; return 1; }
            awgobf="$(setup_token_text_decode "$awgobf")" || { setup_token_bad "the AWG obfuscation is damaged"; return 1; }
            pckflags="$(setup_token_text_decode "$pckflags")" || { setup_token_bad "the PCK flags are damaged"; return 1; }
            ;;
        p2\|* | p3\|* | p4\|*)
            # Legacy fields were not individually encoded and had no checksum.
            # They are accepted as long as their values form a complete,
            # internally consistent tunnel.
            IFS='|' read -r v kind tr mode fwd dial host port tok car win ka snd rcv tl tp mtu \
                ttl awgport awgpriv awgpub awgobf fecdata fecparity packetmtu kcpinterval pckflags <<TOKEN
$raw
TOKEN
            ;;
        *) setup_token_bad "that is not a Pingify setup token"; return 1 ;;
    esac

    cfg_reset
    T_KIND="$kind"; T_TRANSPORT="$tr"; T_MODE="$mode"; T_FORWARDER="$fwd"
    T_TOKEN="$tok"; T_PORT="${port:-9443}"
    T_CARRIERS="${car:-16}"; T_WINDOW="${win:-1024}"; T_KEEPALIVE="${ka:-10}"
    T_SNDBUF="${snd:-1024}"; T_RCVBUF="${rcv:-1024}"
    T_FEC_DATA="${fecdata:-10}"; T_FEC_PARITY="${fecparity:-3}"
    T_PACKET_MTU="${packetmtu:-1200}"; T_KCP_INTERVAL="${kcpinterval:-10}"
    T_PCK_FLAGS="${pckflags:-PA}"; T_OBFUSCATE="$obfuscate"
    # An older token has no such field, and a tunnel that predates the
    # setting was encrypted - so empty has to mean yes, not no.
    case "$encrypt" in true) T_ENCRYPT="true" ;; *) T_ENCRYPT="false" ;; esac
    [ -n "$tl" ] && { T_TUNLOCAL="$tl"; T_TUNPEER="$tp"; T_TUNMTU="${mtu:-1380}"; }
    T_GRE_TTL="${ttl:-255}"; T_AWG_PORT="${awgport:-51820}"
    T_AWG_PRIV="$awgpriv"; T_AWG_PUB="$awgpub"; T_AWG_OBF="$awgobf"

    case "$T_TRANSPORT" in
        tcp | udp | kcp | pck | ws | wss)
            [ "$T_KIND/$T_MODE/$T_FORWARDER" = "tcp/forward/pingify" ] ||
                { setup_token_bad "transport, mode and forwarder disagree"; return 1; } ;;
        icmp)
            [ "$T_KIND" = "tun" ] || { setup_token_bad "ICMP is missing its TUN link"; return 1; }
            case "$T_MODE/$T_FORWARDER" in
                both/pingify | tun/iptables) ;;
                *) setup_token_bad "ICMP mode and forwarder disagree"; return 1 ;;
            esac ;;
        gre | awg)
            [ "$T_KIND/$T_MODE/$T_FORWARDER" = "tun/tun/iptables" ] ||
                { setup_token_bad "kernel tunnel fields disagree"; return 1; } ;;
        *) setup_token_bad "unknown transport $T_TRANSPORT"; return 1 ;;
    esac
    case "$dial" in 0 | 1) ;; *) setup_token_bad "invalid tunnel direction"; return 1 ;; esac
    [ -n "$T_TOKEN" ] || { setup_token_bad "the security token is empty"; return 1; }
    if [ "$dial" = "1" ] || kernel_transport; then
        [ -n "$host" ] || { setup_token_bad "the IRAN address is missing"; return 1; }
    fi
    case "$T_TRANSPORT" in
        tcp | udp | kcp | pck | ws | wss)
            case "$T_PORT" in "" | *[!0-9]*) setup_token_bad "the tunnel port is invalid"; return 1 ;; esac
            [ "$T_PORT" -ge 1 ] && [ "$T_PORT" -le 65535 ] ||
                { setup_token_bad "the tunnel port is out of range"; return 1; } ;;
    esac
    if [ "$T_MODE" = "tun" ] || [ "$T_MODE" = "both" ]; then
        [ -n "$T_TUNLOCAL" ] && [ -n "$T_TUNPEER" ] ||
            { setup_token_bad "the private link is incomplete"; return 1; }
        case "$T_TUNMTU" in "" | *[!0-9]*) setup_token_bad "the private MTU is invalid"; return 1 ;; esac
        [ "$T_TUNMTU" -ge 576 ] && [ "$T_TUNMTU" -le 9000 ] ||
            { setup_token_bad "the private MTU is out of range"; return 1; }
    fi
    if kernel_transport; then
        T_PRESET="kernel"
        if [ "$T_TRANSPORT" = "gre" ]; then
            case "$T_GRE_TTL" in "" | *[!0-9]*) setup_token_bad "the GRE TTL is invalid"; return 1 ;; esac
            [ "$T_GRE_TTL" -ge 1 ] && [ "$T_GRE_TTL" -le 255 ] ||
                { setup_token_bad "the GRE TTL is out of range"; return 1; }
        else
            case "$T_AWG_PORT" in "" | *[!0-9]*) setup_token_bad "the AWG port is invalid"; return 1 ;; esac
            [ "$T_AWG_PORT" -ge 1 ] && [ "$T_AWG_PORT" -le 65535 ] ||
                { setup_token_bad "the AWG port is out of range"; return 1; }
            [ -n "$T_AWG_PRIV" ] && [ -n "$T_AWG_PUB" ] && [ -n "$T_AWG_OBF" ] ||
                { setup_token_bad "the AWG key material is incomplete"; return 1; }
        fi
    else
        tuning_values_valid || { setup_token_bad "the transport tuning is out of range"; return 1; }
        case "$v" in
            p5) case "$profile" in gaming | latency | balanced | throughput | extreme | custom) T_PRESET="$profile" ;;
                    *) setup_token_bad "the tuning profile is invalid"; return 1 ;; esac ;;
            *) T_PRESET="$(preset_name "$T_CARRIERS" "$T_WINDOW" "$T_KEEPALIVE" "$T_SNDBUF" "$T_RCVBUF" \
                    "$T_FEC_DATA" "$T_FEC_PARITY" "$T_PACKET_MTU" "$T_KCP_INTERVAL")" ;;
        esac
    fi
    case "$T_OBFUSCATE" in true | false) ;; *) setup_token_bad "traffic shaping is invalid"; return 1 ;; esac
    if [ "$T_TRANSPORT" = "kcp" ] || [ "$T_TRANSPORT" = "pck" ]; then
        case "$T_FEC_DATA$T_FEC_PARITY$T_PACKET_MTU$T_KCP_INTERVAL" in
            "" | *[!0-9]*) setup_token_bad "KCP tuning contains a non-number"; return 1 ;;
        esac
        [ "$T_FEC_DATA" -ge 1 ] && [ "$T_FEC_DATA" -le 64 ] &&
        [ "$T_FEC_PARITY" -ge 1 ] && [ "$T_FEC_PARITY" -le 32 ] &&
        [ $((T_FEC_DATA + T_FEC_PARITY)) -le 96 ] &&
        [ "$T_PACKET_MTU" -ge 576 ] && [ "$T_PACKET_MTU" -le 1400 ] &&
        [ "$T_KCP_INTERVAL" -ge 5 ] && [ "$T_KCP_INTERVAL" -le 100 ] ||
            { setup_token_bad "KCP tuning is out of range"; return 1; }
    fi
    if [ "$T_TRANSPORT" = "pck" ]; then
        case "$T_PCK_FLAGS" in "" | *[!FSPAUCE]*) setup_token_bad "PCK flags are invalid"; return 1 ;; esac
        case "$T_PCK_FLAGS" in *A* | *S*) ;; *) setup_token_bad "PCK flags need ACK or SYN"; return 1 ;; esac
    fi

    T_ROLE="client"
    if [ "$dial" = "1" ]; then T_ACCEPTS="server"; T_PEER_IP="$host"
    else T_ACCEPTS="client"; fi
    kernel_transport && T_PEER_IP="$host"
    return 0
}

# import_tunnel turns one of those into a running tunnel on this server.
import_tunnel() {
    banner
    head2 "Paste the setup token"
    dim "Printed by the other server when its tunnel was made."
    say ""
    local token=""
    ask token "token" || { wiz_end; return 0; }
    [ -n "$token" ] || return 1

    if ! setup_token_read "$token"; then
        fail "$SETUP_TOKEN_ERROR"
        pause; return 1
    fi

    # The token says which transport this is, and AmneziaWG needs tooling on
    # the machine before any of it means anything. The create path installs it
    # when the transport is chosen; this path had no equivalent, so pasting a
    # token on a server without amneziawg-tools wrote a config and a unit that
    # could never start, and the first thing the operator saw was a failed
    # service rather than the one sentence that explains it. Install it here,
    # before anything is written, and stop if it cannot be done.
    if [ "$T_TRANSPORT" = "awg" ]; then
        awg_install || { pause; return 1; }
    fi
    server_info

    say ""
    head2 "This server"
    dim "the token came from IRAN, so this is the KHAREJ side"
    say ""
    [ -n "$SRV_IP" ] && [ "$SRV_IP" != "unknown" ] && T_PUBLIC_IP="$SRV_IP"
    ask T_PUBLIC_IP "address of this KHAREJ server" "$T_PUBLIC_IP" || { wiz_end; return 0; }
    [ -n "$T_PUBLIC_IP" ] || { fail "an address is required"; pause; return 1; }

    # The domain came in the token, so this end never types it and the two
    # ends cannot disagree about it. What is local to this server is which way
    # in it takes - and this is the end that dials, so this is where to ask.
    this_side_accepts || ask_edge
    ask_wss_certificate || { wiz_end; return 0; }

    # The ports live on IRAN, which already has them - there is nothing to ask
    # for here, and nothing on this side to answer with.

    T_NAME="$(tunnel_default_name)"
    # The network came across in the token, so this end reaches the same name
    # the other end did without either of them being told what it is.
    local oct; oct="$(link_octet)" && T_NAME="$(tunnel_default_name "$oct")"
    if [ -f "$(cfg_file "$T_NAME")" ]; then
        say ""
        warn "a tunnel named $T_NAME already exists on this server"
        confirm "replace it?" || return 1
        systemctl stop "pingify@$T_NAME" >/dev/null 2>&1
    fi
    # The interface is named after the tunnel, which only just got its name.
    cfg_needs_link && T_TUNIF="$(link_iface "$T_NAME")"
    # A kernel tunnel runs no process of ours, so there is nothing to serve a
    # status endpoint and nothing that would read one.
    kernel_transport && T_STATUS="" || T_STATUS="127.0.0.1:$(pick_status_port 9700)"

    banner
    head2 "Ready to create"
    cfg_endpoints
    local pck_local=""
    if [ "$T_TRANSPORT" = "pck" ]; then
        pck_local="$T_PORT"
        this_side_accepts || pck_local="$(pck_source_port "$T_TOKEN" "$T_PORT")"
    fi
    panel "$T_NAME"
    field "This server" "$(side_label "$T_ROLE")"
    field "Address" "$(addr_tint "$T_PUBLIC_IP")"
    [ -n "$T_EDGE" ] && field "Edge" "$(addr_tint "$T_EDGE") ${BX_ARR} presents $T_PEER_IP"
    field "Transport" "$(transport_label "$T_TRANSPORT")"
    field "Forwarder" "$(forwarder_label "$T_FORWARDER")"
    if [ -n "$CFG_LISTEN" ]; then
        field "Link" "accepts on $(addr_tint "$CFG_LISTEN")"
    else
        field "Link" "dials $(addr_tint "$CFG_CONNECT")"
    fi
    cfg_needs_link && field "Private link" "$(addr_tint "$T_TUNLOCAL") ${BX_ARR} $(addr_tint "$T_TUNPEER")"
    [ -n "$T_FORWARDS" ] && field "Ports" "$(printf '%s' "$T_FORWARDS" | tr -d '"' | tr ',' ' ')"
    [ -n "$pck_local" ] && field "PCK local port" "$pck_local/tcp"
    field "Token" "$(token_print "$T_TOKEN")"
    if kernel_transport; then
        field "Kernel link" "MTU $T_TUNMTU"
    else
        field "Tuning" "$T_PRESET" "Carriers" "$T_CARRIERS"
    fi
    panel_end
    say ""
    if [ -n "$pck_local" ] && ! this_side_accepts; then
        dim "if this provider filters unsolicited replies, allow ${pck_local}/tcp inbound here"
        say ""
    fi
    confirm_yes "create the tunnel ${C_B}${T_NAME}${C_OFF}?" || { warn "cancelled"; pause; return 1; }

    say ""
    local file
    file="$(cfg_save)" || { pause; return 1; }
    # The core only judges configs it is going to run, and a kernel tunnel has
    # no core in the path - the same split the wizard makes.
    if ! kernel_transport; then
        if ! "$CORE_BIN" -c "$file" -check >/dev/null 2>&1; then
            fail "the core rejected this configuration"
            core_matches_script || dim "the core is $(core_version) and this script is $PINGIFY_VERSION"
            "$CORE_BIN" -c "$file" -check 2>&1 | sed 's/^/      /'
            rm -f "$file"
            pause; return 1
        fi
    fi
    write_units
    if kernel_transport; then
        [ "$T_TRANSPORT" = "awg" ] && awg_write_conf "$T_NAME" "$T_TUNIF" "$(awg_conf_path "$T_TUNIF")"
        write_link_unit "$T_NAME" || { fail "could not write the unit"; pause; return 1; }
    fi
    service_enable_start "$T_NAME"
    enable_watchdog quiet
    [ "$T_FORWARDER" = "iptables" ] && apply_nat quiet
    say ""
    ok "$T_NAME is configured and running"
    say ""
    tunnel_status_block "$T_NAME"
    pause
}

new_tunnel() {
    banner
    head2 "New tunnel"
    wiz_end   # nothing is half-built until the first question is asked
    ensure_core || { pause; return 1; }
    cfg_reset
    wiz_reset
    server_info

    # -- which server is this ----------------------------------------------
    wiz "Which server is this?"
    choice 1 "IRAN" "clients connect here, and the ports live here"
    choice 2 "KHAREJ" "your panel and inbounds run here"
    choice 3 "Paste a token" "finish this server from the other one"
    say ""
    dim "q at any question leaves without building anything"
    say ""
    local side=""
    pick side "select" 1 2 3 || { wiz_end; return 0; }
    [ "$side" = "3" ] && { import_tunnel; return $?; }
    if [ "$side" = "2" ]; then T_ROLE="client"; else T_ROLE="server"; fi
    wiz_add "$(side_label "$T_ROLE")"

    # -- transport ----------------------------------------------------------
    # Two groups, because they are two different things. FORWARDING carries
    # the ports you name over an ordinary connection, and the engine is the
    # only thing in the path. TUN builds a private link the kernel routes
    # over, which is a bigger hammer and a different set of requirements.
    wiz "Transport" "FORWARDING carries your ports over a connection. TUN builds a private link."
    group "FORWARDING"
    choice 1 "TCP MUX" "every stream over a few plain TCP carriers - the compatible default"
    choice 2 "TCP PCK" "the same reliability inside raw TCP packets the kernel never sees"
    choice 3 "KCP FEC" "repairs loss without waiting for a resend - best on a lossy path"
    choice 4 "UDP ARQ" "reliability in userspace, so nothing runs TCP inside TCP"
    choice 5 "WS MUX" "an ordinary WebSocket on port 80 - goes where HTTP goes"
    choice 6 "WSS MUX" "the same inside TLS - a domain or a CDN, and the origin stays hidden"
    group "TUN"
    choice 7 "ICMP" "inside ping packets - no port at all, for a path that filters the rest"
    choice 8 "GRE" "the kernel's own tunnel: fastest, and plainly visible"
    choice 9 "AmneziaWG" "obfuscated WireGuard - encrypted, and shaped not to look like it"
    say ""
    local proto=""
    pick proto "select" 1 2 3 4 5 6 7 8 9 || { wiz_end; return 0; }

    case "$proto" in
        4)  T_KIND="tcp"; T_TRANSPORT="udp"
            T_FORWARDER="pingify"
            say ""
            dim "One reliability layer instead of two. Our own sits on the"
            dim "datagrams, so a lost packet is repaired once by the layer that"
            dim "knows what the tunnel is doing - rather than by TCP inside TCP,"
            dim "where both ends retransmit the same loss and fight over it."
            say ""
            warn "needs UDP to pass between the two servers"
            dim "some providers throttle or block it; test before committing" ;;
        7)  T_KIND="tun"; T_TRANSPORT="icmp"
            wiz "Who forwards the ports?"
            choice 1 "PINGIFY" "the core carries every connection itself"
            choice 2 "IPTABLES" "the kernel does it - lighter on a busy link"
            say ""
            local fw=""
            pick fw "select" 1 2 || { wiz_end; return 0; }
            if [ "$fw" = "2" ] && have iptables; then
                T_FORWARDER="iptables"
            else
                [ "$fw" = "2" ] && warn "iptables is not installed here - using PINGIFY"
                T_FORWARDER="pingify"
            fi ;;
        8)  T_TRANSPORT="gre"
            # GRE is protocol 47 with no encryption and no disguise. It is the
            # fastest thing here by a distance, and the easiest to recognise,
            # so say so before rather than after.
            say ""
            warn "GRE carries nothing secret and hides nothing"
            dim "it is the kernel moving packets with no encryption and no"
            dim "obfuscation, so anything watching the path can see what it is."
            dim "Fast, and worth it where the path still allows it."
            say ""
            confirm_yes "use TUN-GRE?" || return 0
            gre_ready || { fail "this kernel has no GRE support"; pause; return 1; } ;;
        9)  T_TRANSPORT="awg"
            awg_install || { pause; return 1; } ;;
        6)  T_KIND="tcp"; T_TRANSPORT="wss"
            T_FORWARDER="pingify"
            T_CARRIERS=2
            say ""
            dim "One TLS handshake, one HTTP Upgrade, and one long-lived WebSocket."
            dim "Every forwarded stream is multiplexed inside that single connection;"
            dim "opening twenty look-alike WebSockets at once is deliberately forbidden."
            say ""
            dim "WSS can go directly to the origin or through a CDN. SNI, Host and"
            dim "Origin use the tunnel domain, while an optional edge address is dialled."
            say ""
            dim "Without certificate files the origin creates a self-signed TLS 1.2+"
            dim "certificate. The token-authenticated inner handshake still proves the"
            dim "peer and AES-256-GCM still protects every tunnel frame."
            say ""
            dim "Anything outside the secret path sees an ordinary HTTPS nginx page."
            dim "Port 443 is the natural choice." ;;
        5)  T_KIND="tcp"; T_TRANSPORT="ws"
            T_FORWARDER="pingify"
            T_CARRIERS=2
            say ""
            dim "An HTTP request that becomes a WebSocket, which is what a chat"
            dim "app and a live dashboard look like. It goes where HTTP goes:"
            dim "a proxy that passes 80 passes this."
            say ""
            dim "One connection, not a braid. Every stream is multiplexed onto"
            dim "it, because twenty WebSockets opened at once from one address"
            dim "is the most recognisable thing a tunnel can do - and it is"
            dim "what stopped the old one from carrying anything."
            say ""
            dim "Anything that is not the tunnel gets a stock nginx page, so a"
            dim "scanner finds a web server with nothing on it."
            say ""
            warn "WS is not encrypted by itself"
            dim "the frames this tunnel carries are, but the WebSocket around"
            dim "them is in the clear. Choose WSS when TLS or a CDN is available."
            say ""
            dim "Port 80 is the one to use. A WebSocket on an unusual port is"
            dim "a WebSocket nothing else on the internet looks like." ;;
        3)  T_KIND="tcp"; T_TRANSPORT="kcp"
            T_FORWARDER="pingify"
            say ""
            dim "KCP repairs loss on a 10 ms clock and Reed-Solomon FEC can"
            dim "rebuild short packet-loss bursts without waiting for resend."
            dim "Use this for video, Instagram and games on a lossy route."
            say ""
            warn "needs UDP to pass between both servers" ;;
        2)  T_KIND="tcp"; T_TRANSPORT="pck"
            T_FORWARDER="pingify"
            say ""
            dim "Builds established-looking TCP packets directly, then runs"
            dim "the same KCP+FEC engine inside them. There is no kernel TCP"
            dim "connection for a middlebox to throttle or reset."
            say ""
            warn "Linux and root/CAP_NET_RAW are required on both servers"
            dim "Pingify installs narrow RST and NOTRACK rules automatically." ;;
        1)  T_KIND="tcp"; T_TRANSPORT="tcp"
            T_FORWARDER="pingify"
            say ""
            dim "Several plain TCP connections, with every forwarded stream"
            dim "multiplexed across them by id and given its own credit window."
            dim "A stall on one carrier does not hold up the others, and a"
            dim "carrier that dies is replaced without dropping the tunnel."
            say ""
            dim "Nothing to install and nothing to open: it is a TCP connection"
            dim "between two servers. Start here, and move only if the path"
            dim "gives you a reason to." ;;
        *)  T_KIND="tcp"; T_TRANSPORT="tcp"
            T_FORWARDER="pingify" ;;
    esac
    cfg_mode

    # -- which way the link is opened, TCP only ----------------------------
    #
    # Ports live on IRAN either way and clients always arrive there. This is
    # only about which end makes the connection, and the two are not equally
    # reachable: a connection dialled into an Iranian server is commonly
    # allowed to complete, carry a few exchanges, and then be blackholed with
    # no reset and no error - which looks exactly like a tunnel that is up and
    # carrying nothing. Dialled the other way the same path is clean.
    #
    # IRAN dialling out is the default because it is the one that survives.
    # See cfg_reset for the measurements: dialled into Iran a connection gets
    # about six exchanges before the path blackholes it silently; dialled out
    # of Iran the same path ran 120 of 120. The other way is kept because a
    # KHAREJ server behind NAT cannot take a connection either, and then this
    # is the only thing that helps.
    #
    # Only transports that bind a port have a choice. ICMP has no port to be
    # reachable on, and a kernel tunnel names both addresses itself.
    T_ACCEPTS="client"
    if [ "$T_TRANSPORT" != "icmp" ] && ! kernel_transport; then
        wiz "Link direction"
        CHOICE_DEF="1"
        choice 1 "IRAN dials out" "IRAN opens the connection to KHAREJ - what works through the filtering"
        choice 2 "KHAREJ dials in" "only if KHAREJ cannot take a connection, behind NAT or with no open port"
        CHOICE_DEF=""
        say ""
        local dir=""
        ask dir "select" "1" || { wiz_end; return 0; }
        if [ "$dir" = "2" ]; then
            T_ACCEPTS="server"      # IRAN accepts; KHAREJ dials in
        else
            T_ACCEPTS="client"      # KHAREJ accepts; IRAN dials out
        fi
    fi

    # -- where the servers are ---------------------------------------------
    #
    # Both addresses, always. The far one is obvious - somebody has to be
    # dialled or answered. The near one matters on a server with more than one
    # address: ICMP answers from whatever the kernel picks otherwise, and a
    # reply that leaves from an address the far end is not expecting is a reply
    # the far end throws away.
    wiz "Addresses"
    if [ -n "$SRV_IP" ] && [ "$SRV_IP" != "unknown" ]; then
        T_PUBLIC_IP="$SRV_IP"
        dim "this machine reports ${C_OFF}${SRV_IP}${C_DIM} - press enter to take it"
        say ""
    fi
    if [ "$T_TRANSPORT" = "wss" ] && this_side_accepts; then
        # For WSS the domain is not a second field - it IS the address. It is
        # what the far end dials, what the certificate is for, and the only
        # thing a CDN routes on, and it travels in the token like any other
        # address. Saying so here is the whole of it: this is the one place
        # anybody types it, because the other end reads it out of the token.
        say ""
        dim "Behind Cloudflare, put the ${C_OFF}domain${C_DIM} here rather than the address."
        dim "It is what the other end dials, what the certificate is made for,"
        dim "and the only thing a CDN can route on. A bare address works too,"
        dim "but then there is no CDN in front of it."
        say ""
        ask T_PUBLIC_IP "domain or address of this IRAN server" "$T_PUBLIC_IP" || { wiz_end; return 0; }
    else
        ask T_PUBLIC_IP "address of this $(side_label "$T_ROLE") server" "$T_PUBLIC_IP" || { wiz_end; return 0; }
    fi
    [ -n "$T_PUBLIC_IP" ] || { fail "an address is required"; pause; return 1; }

    say ""
    if [ "$T_TRANSPORT" = "wss" ] && ! this_side_accepts; then
        dim "for WSS behind Cloudflare, give the domain here, not the address"
        say ""
    fi
    ask T_PEER_IP "address of the $( [ "$T_ROLE" = "server" ] && echo KHAREJ || echo IRAN ) server" "$T_PEER_IP" || { wiz_end; return 0; }
    [ -n "$T_PEER_IP" ] || { fail "an address is required"; pause; return 1; }

    case "$T_TRANSPORT" in tcp | udp | kcp | pck | ws | wss) has_port=1 ;; *) has_port=0 ;; esac
    if [ "$has_port" = "1" ]; then
        say ""
        # The port the two servers meet on. Only the accepting end binds it,
        # so only that end can collide - and TCP 9443 and UDP 9443 are two
        # different sockets, so the protocol is part of the question.
        this_side_accepts && show_taken_tunnel_ports
        local powner=""
        while :; do
            ask T_PORT "port for the tunnel itself, same on both" "$T_PORT" || { wiz_end; return 0; }
            case "$T_PORT" in
                '' | *[!0-9]*) fail "numbers only"; continue ;;
            esac
            [ "$T_PORT" -ge 1 ] && [ "$T_PORT" -le 65535 ] || { fail "1 to 65535"; continue; }
            if this_side_accepts; then
                powner="$(tunnel_port_owner "$T_PORT" "$T_TRANSPORT")"
                if [ -n "$powner" ]; then
                    fail "${T_PORT}/$(port_family "$T_TRANSPORT") is already $powner's tunnel port"
                    dim "pick another, or delete that tunnel first"
                    continue
                fi
                if ! port_free "$T_PORT" "$(port_family "$T_TRANSPORT")"; then
                    fail "something is already listening on ${T_PORT}/$(port_family "$T_TRANSPORT")"
                    dim "check with:  ss -lnp | grep :${T_PORT}"
                    continue
                fi
            fi
            break
        done
        this_side_accepts && dim "leave ${T_PORT}/$(port_family "$T_TRANSPORT") open in this server's firewall"
    fi
    cdn_port_warn
    this_side_accepts || ask_edge
    ask_wss_certificate || { wiz_end; return 0; }

    # ---------------------------------------------------------------------
    # Encryption
    #
    # Worth asking rather than assuming, because the honest answer depends on
    # what is being carried. A tunnel in front of Xray carries traffic that is
    # already encrypted end to end, and a second cipher over the top of it
    # buys nothing the first one did not already give.
    #
    # What it does buy is the shape: with the cipher on, everything past the
    # handshake is indistinguishable from noise; with it off our framing is on
    # the wire for anything that looks. And GCM is what proves a frame arrived
    # unaltered, so without it anything that can put a packet on the carrier
    # can put data into the tunnel.
    #
    # It is not, however, where the weight is. Measured: 8.8 GB/s sealing on an
    # ordinary machine, against 12.5 MB/s for a hundred-megabit tunnel.
    # ---------------------------------------------------------------------
    # Asked on a private link and nowhere else.
    #
    # A forwarded port carries whatever the service behind it speaks, and on
    # this tool that is Xray or something like it - already encrypted end to
    # end, where a second cipher is redundant but also not ours to remove: the
    # operator did not choose what crosses it. A private link is different.
    # It carries raw IP between two machines the same person runs, they know
    # what is on it, and it is the one that is judged on speed.
    wiz "Encryption"
    choice 1 "In the clear" "what nearly every tunnel should pick  (recommended)"
    choice 2 "Encrypted" "ChaCha or AES on every frame, and it is not free"
    say ""
    dim "This used to say the cipher costs a tenth of a percent of a core. That"
    dim "was wrong, and measuring it said so: on a server abroad without the"
    dim "PCLMULQDQ instruction - which is what a cheap VPS is - a third of the"
    dim "processor went into the authenticator alone. Turning it off raised what"
    dim "the pair carried by half and dropped the delay under load from 380 ms"
    dim "to 82."
    say ""
    dim "The handshake is authenticated either way and the token still has to"
    dim "match, so nobody without it can build a tunnel here. What changes is"
    dim "whether what crosses afterwards can be read. Almost everything sent"
    dim "through one of these - Xray, a VPN, a browser - carries its own TLS"
    dim "already, and a second cipher over the top of it buys nothing."
    say ""
    local enc=""
    pick enc "select" 1 2 || { wiz_end; return 0; }
    if [ "$enc" = "2" ]; then
        T_ENCRYPT="true"
        say ""
        info "both servers must agree, and the far end is told in the token"
    else
        T_ENCRYPT="false"
    fi
    if [ "$T_TRANSPORT" = "awg" ]; then
        say ""
        ask T_AWG_PORT "UDP port for the tunnel, same on both" "$T_AWG_PORT" || { wiz_end; return 0; }
        case "$T_AWG_PORT" in "" | *[!0-9]*) T_AWG_PORT=51820 ;; esac
        dim "leave ${T_AWG_PORT}/udp open in this server's firewall"
    fi
    say ""

    # -- name, derived ------------------------------------------------------
    # iran-9443 on the Iran server, kharej-9443 abroad, and
    # iran-tun-icmp-20 / kharej-tun-icmp-20 for the two ends of a private
    # link. Two servers side by side say what they are without opening either
    # file, and every name starts with the side as promised.
    #
    # Provisional for now. When this server already holds a tunnel of the same
    # kind, what tells the two apart is the private network they sit on - and
    # that is not known until it has been asked for, a few lines down.
    T_NAME="$(tunnel_default_name)"

    # -- the private link, whenever one is needed --------------------------
    #
    # Each transport pays a different tax on every packet, so the starting MTU
    # follows the transport: GRE adds 24 bytes, AmneziaWG adds its own header
    # plus the junk it pads with, and ICMP carries ours.
    case "$T_TRANSPORT" in
        icmp) T_TUNMTU=1280 ;;
        gre) T_TUNMTU=1400 ;;
        awg) T_TUNMTU=1320 ;;
    esac
    if cfg_needs_link; then
        wiz "Private link" "Both servers get an address on a small network of their own."
        # Two tunnels on one network route into each other, and the symptom is
        # traffic going somewhere it was not meant to with nothing on the
        # server to explain it. So say what is taken, offer one that is not,
        # and do not accept a repeat.
        show_taken_nets "$T_NAME"
        local octet="" owner=""
        while :; do
            ask octet "range 10.x.10.0/24 - pick x" "$(free_link_octet "$T_NAME")" || { wiz_end; return 0; }
            case "$octet" in
                '' | *[!0-9]*) fail "a number from 0 to 255"; continue ;;
            esac
            [ "$octet" -le 255 ] || { fail "a number from 0 to 255"; continue; }
            owner="$(net_owner "10.${octet}.10" "$T_NAME")"
            if [ -n "$owner" ]; then
                fail "10.${octet}.10.0/24 already belongs to $owner"
                dim "pick another x, or delete that tunnel first"
                continue
            fi
            if host_has_net "10.${octet}.10"; then
                fail "this server already has an address on 10.${octet}.10.0/24"
                dim "something else is on that network - docker, or another VPN"
                continue
            fi
            break
        done
        if [ "$T_ROLE" = "server" ]; then
            T_TUNLOCAL="10.${octet}.10.1/24"; T_TUNPEER="10.${octet}.10.2/24"
        else
            T_TUNLOCAL="10.${octet}.10.2/24"; T_TUNPEER="10.${octet}.10.1/24"
        fi
        say ""
        ask T_TUNLOCAL "this server" "$T_TUNLOCAL" || { wiz_end; return 0; }
        ask T_TUNPEER  "the other server" "$T_TUNPEER" || { wiz_end; return 0; }

        # Now the name carries the network - always, not only when two of
        # them collide. Ten GRE tunnels where one is bare and nine are
        # numbered is not an order, it is an exception with nine examples.
        # Every one of these reads the same and says where to find it:
        # tun-iran-gre-20 is the tunnel on 10.20.10.0/24.
        local oct; oct="$(link_octet)" && T_NAME="$(tunnel_default_name "$oct")"
        T_TUNIF="$(link_iface "$T_NAME")"
        say ""
        # A kernel tunnel's interface is named after the tunnel, so there is
        # nothing to answer; ours is ours to choose - and has to be one that
        # is not already taken, or the second tunnel cannot create it.
        if ! kernel_transport; then
            local iface_owner_name=""
            while :; do
                ask T_TUNIF "device name" "$(free_tun_iface "$T_NAME" "$T_NAME")" || { wiz_end; return 0; }
                case "$T_TUNIF" in
                    '' | *[!a-zA-Z0-9_-]*) fail "letters, digits, dash and underscore"; continue ;;
                esac
                [ "${#T_TUNIF}" -le 15 ] || { fail "linux stops at 15 characters"; continue; }
                iface_owner_name="$(iface_owner "$T_TUNIF" "$T_NAME")"
                if [ -n "$iface_owner_name" ]; then
                    fail "$T_TUNIF already belongs to $iface_owner_name"
                    continue
                fi
                if host_has_iface "$T_TUNIF"; then
                    fail "this server already has an interface called $T_TUNIF"
                    continue
                fi
                break
            done
        fi
        ask T_TUNMTU   "MTU" "$T_TUNMTU" || { wiz_end; return 0; }
        case "$T_TUNMTU" in "" | *[!0-9]*) T_TUNMTU=1380 ;; esac
    fi

    # Whatever is left over - a TCP tunnel has no network to name itself
    # after, and a private one whose addresses were hand-set may not either.
    if [ -f "$(cfg_file "$T_NAME")" ]; then
        local n=2
        while [ -f "$(cfg_file "${T_NAME}-${n}")" ]; do n=$((n + 1)); done
        T_NAME="${T_NAME}-${n}"
        cfg_needs_link && T_TUNIF="$(link_iface "$T_NAME")"
    fi
    say ""
    ok "this tunnel is called ${C_B}${T_NAME}${C_OFF}"

    # -- AmneziaWG keys -----------------------------------------------------
    #
    # WireGuard needs a real keypair on each side, and each side needs the
    # other's public half. Normally that is two visits to two servers with a
    # key carried between them, and the script this came from asks for exactly
    # that. Both pairs are made here instead and the other server's half rides
    # in the setup token with everything else, because the token is already
    # the secret that carries the tunnel and one trip is better than three.
    local awg_peer_priv="" awg_self_pub=""
    if [ "$T_TRANSPORT" = "awg" ]; then
        local mine theirs
        mine="$(awg_keypair)"   || { fail "awg genkey failed"; pause; return 1; }
        theirs="$(awg_keypair)" || { fail "awg genkey failed"; pause; return 1; }
        T_AWG_PRIV="${mine%% *}"          # ours, kept here
        T_AWG_PUB="${theirs##* }"         # the other server's, listed as peer
        awg_peer_priv="${theirs%% *}"     # the other server's, travels
        awg_self_pub="${mine##* }"        # ours, travels
        T_AWG_OBF="$(awg_new_obf)"
    fi

    # -- security ----------------------------------------------------------
    wiz "Security token" "One secret, typed the same on BOTH servers. Any length."
    # What it actually does differs by transport, and saying so is better than
    # letting somebody assume GRE is encrypted because they were asked for a
    # password.
    case "$T_TRANSPORT" in
        awg) dim "here it becomes the pre-shared key WireGuard mixes into every"
             dim "handshake: without a matching one, the tunnel does not form." ;;
        gre) dim "GRE has no encryption. Here the token becomes the key GRE"
             dim "stamps on each packet, which keeps two tunnels apart - it"
             dim "does not hide anything, because GRE cannot." ;;
        *)   dim "it keys the encryption on every frame this tunnel carries." ;;
    esac
    say ""
    while :; do
        ask T_TOKEN "token" || { wiz_end; return 0; }
        T_TOKEN="$(printf '%s' "$T_TOKEN" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -n "$T_TOKEN" ] && break
        fail "a token is required"
    done
    say ""
    ok "fingerprint  ${C_YEL}$(token_print "$T_TOKEN")${C_OFF}"

    # An ICMP tunnel has no port to tell it apart from another one here - what
    # it has is an identifier taken from the token. Two of them sharing a token
    # read each other's packets. See show_taken_icmp_token.
    if [ "$T_TRANSPORT" = "icmp" ]; then
        say ""
        show_taken_icmp_token "$T_TOKEN" "$T_NAME" || :
    fi

    # -- ports: the IRAN side owns them ------------------------------------
    if [ "$T_ROLE" = "server" ]; then
        wiz "Ports" "The ports your clients will connect to, here on IRAN."
        # Two tunnels forwarding one port means whichever bound it first wins,
        # and the other simply never sees a connection. Say what is taken, and
        # do not accept a port that is.
        show_taken_ports "$T_NAME"
        dim "443   443=8443   443=10.0.0.5:443   udp:500   8000-8010"
        say ""
        local raw="" clash=""
        while :; do
            ask raw "ports, comma separated" "443" || { wiz_end; return 0; }
            T_FORWARDS="$(parse_forwards "$raw")"
            if [ -z "$T_FORWARDS" ]; then
                fail "at least one port is required"
                continue
            fi
            clash="$(forwards_clash "$raw" "$T_NAME")" && break
            printf '%s\n' "$clash" | while read -r line; do
                [ -n "$line" ] && fail "$line"
            done
            dim "pick another port, or free that one first"
        done
    fi

    # -- performance -------------------------------------------------------
    # GRE and AWG are carried by Linux itself; carriers, userspace windows and
    # socket buffers do not exist in their data path. Showing those controls
    # made a setting appear to work even though no process ever read it.
    if kernel_transport; then
        T_PRESET="kernel"
    else
        wiz "Performance" "Pick the shape of your traffic; you can change it later."
        preset_menu
    fi

    # -- logging -----------------------------------------------------------
    if ! kernel_transport; then
        wiz "How much to log" "Each level includes the ones above it."
        CHOICE_DEF="3"
        choice 1 "error" "only what is broken"
        choice 2 "warn" "and what is wrong but survivable"
        choice 3 "info" "and what a healthy tunnel does"
        choice 4 "debug" "and why each carrier and stream did what it did"
        choice 5 "trace" "and every packet - slows a busy tunnel down"
        CHOICE_DEF=""
        say ""
        local lg=""
        ask lg "select" "3" || { wiz_end; return 0; }
        case "$lg" in
            1) T_LOG="error" ;; 2) T_LOG="warn" ;;
            4) T_LOG="debug" ;; 5) T_LOG="trace" ;;
            *) T_LOG="info" ;;
        esac
    fi

    # A kernel tunnel runs no process of ours, so there is nothing to serve a
    # status endpoint and nothing that would read one.
    kernel_transport && T_STATUS="" || T_STATUS="127.0.0.1:$(pick_status_port 9700)"

    # -- review ------------------------------------------------------------
    banner
    cfg_endpoints
    head2 "Ready to create"
    local pck_local=""
    if [ "$T_TRANSPORT" = "pck" ]; then
        pck_local="$T_PORT"
        this_side_accepts || pck_local="$(pck_source_port "$T_TOKEN" "$T_PORT")"
    fi
    panel "$T_NAME"
    field "This server" "$(side_label "$T_ROLE")"
    field "Address" "$(addr_tint "$T_PUBLIC_IP")"
    [ -n "$T_EDGE" ] && field "Edge" "$(addr_tint "$T_EDGE") ${BX_ARR} presents $T_PEER_IP"
    if [ "$T_KIND" = "tun" ]; then
        field "Type" "TUN over $(transport_label "$T_TRANSPORT")"
    else
        field "Type" "$(transport_label "$T_TRANSPORT")"
    fi
    field "Forwarder" "$(forwarder_label "$T_FORWARDER")"
    if [ -n "$CFG_LISTEN" ]; then
        field "Link" "accepts on $(addr_tint "$CFG_LISTEN")"
    else
        field "Link" "connects to $(addr_tint "$CFG_CONNECT")"
    fi
    cfg_needs_link && field "Private link" "$(addr_tint "$T_TUNLOCAL") ${BX_ARR} $(addr_tint "$T_TUNPEER")"
    [ -n "$T_FORWARDS" ] && field "Ports" "$(printf '%s' "$T_FORWARDS" | tr -d '"' | tr ',' ' ')"
    [ -n "$pck_local" ] && field "PCK local port" "$pck_local/tcp"
    field "Token" "$(token_print "$T_TOKEN")"
    if kernel_transport; then
        field "Kernel link" "MTU $T_TUNMTU"
    else
        field "Tuning" "$T_PRESET"
        field "Logging" "$T_LOG"
    fi
    panel_end
    say ""
    if [ -n "$pck_local" ] && ! this_side_accepts; then
        dim "if this provider filters unsolicited replies, allow ${pck_local}/tcp inbound here"
        say ""
    fi
    if ! confirm_yes "create the tunnel ${C_B}${T_NAME}${C_OFF}?"; then
        warn "cancelled, nothing was written"
        pause
        return 1
    fi

    # -- write and start ---------------------------------------------------
    say ""
    local file
    file="$(cfg_save)" || { pause; return 1; }
    # The core only judges configs it is going to run. A kernel tunnel has no
    # core in the path at all, so asking it would be asking the wrong program.
    if ! kernel_transport; then
        if ! "$CORE_BIN" -c "$file" -check >/dev/null 2>&1; then
            fail "the core rejected this configuration"
            core_matches_script || dim "the core is $(core_version) and this script is $PINGIFY_VERSION - update the core"
            "$CORE_BIN" -c "$file" -check 2>&1 | sed 's/^/      /'
            rm -f "$file"
            pause; return 1
        fi
    fi

    write_units
    if kernel_transport; then
        [ "$T_TRANSPORT" = "awg" ] && awg_write_conf "$T_NAME" "$T_TUNIF" "$(awg_conf_path "$T_TUNIF")"
        write_link_unit "$T_NAME" || { fail "could not write the unit"; pause; return 1; }
    fi
    service_enable_start "$T_NAME"
    enable_watchdog quiet
    # Unconditional: apply_nat tears the chains down when no tunnel needs
    # them, so this is also what cleans up after a forwarder that changed.
    apply_nat quiet

    # An ICMP tunnel wants this server quiet. The kernel answering ordinary
    # pings never touches our own traffic - the transport is a raw socket the
    # kernel copies to us regardless, and both ends send echo *replies*, which
    # the kernel never answers by itself - but a tunnel hiding inside ping is
    # not helped by a host that cheerfully answers every scanner that asks.
    if [ "$T_TRANSPORT" = "icmp" ] && [ "$T_ROLE" = "server" ] && [ "$(block_state icmp)" != "on" ]; then
        mkdir -p "$STATE_DIR"
        : > "$STATE_DIR/block-icmp"
        apply_blocking quiet
        ok "this server no longer answers pings (Blocking ${BX_ARR} ICMP, to undo)"
    fi

    ok "$T_NAME is running"
    dim "$file"
    say ""

    # -- the other server --------------------------------------------------
    #
    # Only IRAN prints one. A token is a description of the tunnel written
    # from the point of view of the end that owns the ports, and the KHAREJ
    # end is what it builds - so a token printed there has nowhere to go, and
    # printing one anyway taught people to carry it the wrong way round.
    if [ "$T_ROLE" = "server" ]; then
        head2 "Now the KHAREJ server"
        dim "run Pingify there and choose  New tunnel ${BX_ARR} Paste a token"
        say ""
        rule
        printf '%s\n' "${C_YEL}$(cfg_setup_token)${C_OFF}"
        rule
        say ""
        warn "treat it like a password - it carries the security token"
    else
        head2 "Both servers are set up"
        dim "this end was built from IRAN's token, so there is nothing to carry back"
    fi
    say ""
    tunnel_status_block "$T_NAME"
    pause
}
