
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
    T_ACCEPTS="server"   # reverse: IRAN accepts, KHAREJ comes to it
    T_PUBLIC_IP=""; T_PEER_IP=""
    T_CARRIERS=16; T_WINDOW=1024; T_KEEPALIVE=10; T_PRESET="balanced"
    T_SNDBUF=1024; T_RCVBUF=1024   # socket buffers, sized to hold a BDP
    T_OBFUSCATE="false"  # v2.1.1 wire shape; the one that survives the path
    T_FORWARDS=""; T_STATUS=""; T_LOG="info"
    T_TUNIF=""; T_TUNLOCAL=""; T_TUNPEER=""; T_TUNMTU=1380
    # kernel tunnels: GRE carries a TTL, AmneziaWG a port, a keypair half and
    # the obfuscation values both ends have to agree on
    T_GRE_TTL=255
    T_AWG_PORT=51820; T_AWG_PRIV=""; T_AWG_PUB=""; T_AWG_OBF=""
}

this_side_accepts() { [ "$T_ROLE" = "$T_ACCEPTS" ]; }

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
    case "$T_TRANSPORT" in
        icmp) printf 'tun-%s-icmp%s' "$base" "$tail" ;;
        gre)  printf 'tun-%s-gre%s' "$base" "$tail" ;;
        awg)  printf 'tun-%s-awg%s' "$base" "$tail" ;;
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
        if [ "$T_TRANSPORT" = "icmp" ]; then CFG_CONNECT="$T_PEER_IP"
        else CFG_CONNECT="$T_PEER_IP:$T_PORT"; fi
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
apply_preset() {
    case "$1" in
        # Games and calls: the smallest window that still fills a link, so
        # nothing is ever sat in a queue waiting. Throughput is not the point.
        gaming)     T_CARRIERS=8;  T_WINDOW=256 ;;
        # Browsing and chat - many small things at once, none of them large.
        latency)    T_CARRIERS=12; T_WINDOW=512 ;;
        # Video. One stream reaching ~95 Mbit/s covers 4K with room over, and
        # 16 carriers keep a download from taking the picture down with it.
        balanced)   T_CARRIERS=16; T_WINDOW=1024 ;;
        # Large files, where finishing sooner is worth some queueing.
        throughput) T_CARRIERS=20; T_WINDOW=2048 ;;
        # Everything the path will give. Uses real memory: each carrier holds
        # a send and a receive buffer this size.
        extreme)    T_CARRIERS=24; T_WINDOW=4096 ;;
        *)          return 1 ;;
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
    local car="$1" win="$2" p
    for p in gaming latency balanced throughput extreme; do
        # in a subshell: apply_preset writes the T_ variables, and this is
        # asked from screens that are holding a tunnel in them
        if [ "$(apply_preset "$p" >/dev/null 2>&1; printf '%s/%s' "$T_CARRIERS" "$T_WINDOW")" = "$car/$win" ]; then
            printf '%s' "$p"
            return 0
        fi
    done
    printf 'custom'
}

preset_menu() {
    CHOICE_DEF="3"
    choice 1 "Gaming" "8 carriers, 256 KB - lowest ping, nothing queued"
    choice 2 "Latency" "12 carriers, 512 KB - browsing, calls, chat"
    choice 3 "Balanced" "16 carriers, 1024 KB - video without stalls"
    choice 4 "Download" "20 carriers, 2048 KB - large files"
    choice 5 "Extreme" "24 carriers, 4096 KB - fastest, most memory"
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
           ask T_CARRIERS "parallel connections" "$T_CARRIERS"
           ask T_WINDOW "window per connection, KB" "$T_WINDOW"
           ask T_KEEPALIVE "keepalive seconds" "$T_KEEPALIVE" ;;
        *) apply_preset balanced ;;
    esac
    case "$T_CARRIERS" in "" | *[!0-9]*) T_CARRIERS=16 ;; esac
    case "$T_WINDOW" in "" | *[!0-9]*) T_WINDOW=1024 ;; esac
    case "$T_KEEPALIVE" in "" | *[!0-9]*) T_KEEPALIVE=10 ;; esac
    [ "$T_CARRIERS" -lt 1 ] && T_CARRIERS=1
    [ "$T_CARRIERS" -gt 64 ] && T_CARRIERS=64

    # Socket buffers have to hold a delay bandwidth product or the kernel
    # window cannot grow into one. Sized from the chosen window, capped where
    # more stops helping.
    T_SNDBUF="$T_WINDOW"; T_RCVBUF="$T_WINDOW"
    [ "$T_SNDBUF" -lt 512 ] && T_SNDBUF=512
    [ "$T_RCVBUF" -lt 512 ] && T_RCVBUF=512
    [ "$T_SNDBUF" -gt 4096 ] && T_SNDBUF=4096
    [ "$T_RCVBUF" -gt 4096 ] && T_RCVBUF=4096
}

# ---------------------------------------------------------------------------
# rendering
# ---------------------------------------------------------------------------

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
    printf 'carriers         = %s\n' "$T_CARRIERS"
    printf 'keepalive_sec    = %s\n' "$T_KEEPALIVE"
    printf 'obfuscate        = %s\n' "$T_OBFUSCATE"
    printf '\n[security]\n'
    printf 'token            = "%s"\n' "$T_TOKEN"
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
    printf '\n[tuning]\n'
    printf 'profile          = "%s"\n' "$T_PRESET"
    printf 'window_kb        = %s\n' "$T_WINDOW"
    printf 'sndbuf_kb        = %s\n' "$T_SNDBUF"
    printf 'rcvbuf_kb        = %s\n' "$T_RCVBUF"
    printf '\n[status]\n'
    printf 'addr             = "%s"\n' "$status"
    printf '\n[logging]\n'
    printf 'level            = "%s"\n' "$T_LOG"
}

# Name the missing field rather than letting the core report it as a flat
# rejection with nothing to point at.
cfg_check_complete() {
    local missing=""
    [ -n "$T_NAME" ]      || missing="$missing name"
    [ -n "$T_ROLE" ]      || missing="$missing side"
    [ -n "$T_TRANSPORT" ] || missing="$missing protocol"
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
    fi
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
transport_label() {
    case "$1" in
        icmp | echo) printf 'TUN-ICMP' ;;
        gre)         printf 'TUN-GRE' ;;
        awg)         printf 'TUN-AWG' ;;
        *)           printf 'TCP' ;;
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
#   p2|kind|transport|mode|forwarder|dial|host|port|token|carriers|window|
#      keepalive|snd|rcv|tunlocal|tunpeer|mtu
#
# dial says what the far end does about the connection: 1 means it dials us
# and host is where, 0 means it accepts and supplies its own address. The
# private addresses are already swapped - what is ours becomes theirs.
#
# It is a list of values rather than a config document on purpose. A document
# ties the token to whatever format that document is in, and changing the
# format then breaks every token that was ever printed.
# ---------------------------------------------------------------------------

cfg_setup_token() {
    local dial host="" port="" tl="" tp="" mtu=""
    local ttl="" awgport="" awgpriv="" awgpub="" awgobf=""
    if this_side_accepts; then
        dial=1; host="$T_PUBLIC_IP"
    else
        dial=0
    fi
    [ "$T_TRANSPORT" = "tcp" ] && port="$T_PORT"
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
    printf 'p3|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' \
        "$T_KIND" "$T_TRANSPORT" "$T_MODE" "$T_FORWARDER" \
        "$dial" "$host" "$port" "$T_TOKEN" \
        "$T_CARRIERS" "$T_WINDOW" "$T_KEEPALIVE" "$T_SNDBUF" "$T_RCVBUF" \
        "$tl" "$tp" "$mtu" \
        "$ttl" "$awgport" "$awgpriv" "$awgpub" "$awgobf" \
        | base64 | tr -d '\n'
}

# import_tunnel turns one of those into a running tunnel on this server.
import_tunnel() {
    banner
    head2 "Paste the setup token"
    dim "Printed by the other server when its tunnel was made."
    say ""
    local token=""
    ask token "token"
    [ -n "$token" ] || return 1

    local raw
    raw="$(printf '%s' "$token" | tr -d ' \t\r\n' | base64 -d 2>/dev/null)"
    case "$raw" in
        p2\|* | p3\|*) ;;
        *) fail "that is not a Pingify setup token"; pause; return 1 ;;
    esac

    # p3 added the five kernel-tunnel fields on the end. A p2 token simply
    # leaves them empty, which is what it meant.
    local v kind tr mode fwd dial host port tok car win ka snd rcv tl tp mtu
    local ttl awgport awgpriv awgpub awgobf
    IFS='|' read -r v kind tr mode fwd dial host port tok car win ka snd rcv tl tp mtu ttl awgport awgpriv awgpub awgobf <<TOKEN
$raw
TOKEN
    if [ -z "$tok" ] || [ -z "$tr" ]; then
        fail "the token is incomplete"
        pause; return 1
    fi

    cfg_reset
    server_info
    T_KIND="$kind"; T_TRANSPORT="$tr"; T_MODE="$mode"; T_FORWARDER="$fwd"
    T_TOKEN="$tok"; T_PORT="${port:-9443}"
    T_CARRIERS="$car"; T_WINDOW="$win"; T_KEEPALIVE="$ka"
    T_SNDBUF="${snd:-1024}"; T_RCVBUF="${rcv:-1024}"
    T_PRESET="$(preset_name "$car" "$win")"
    [ -n "$tl" ] && { T_TUNLOCAL="$tl"; T_TUNPEER="$tp"; T_TUNMTU="${mtu:-1380}"; }
    if kernel_transport; then
        # The kernel needs both public addresses whichever end this is, and
        # the token carries the sender's regardless of who dials.
        T_PEER_IP="$host"
        T_GRE_TTL="${ttl:-255}"
        T_AWG_PORT="${awgport:-51820}"
        T_AWG_PRIV="$awgpriv"   # made on the other server, for this one
        T_AWG_PUB="$awgpub"     # the other server's public half
        T_AWG_OBF="$awgobf"
    fi

    # A setup token is printed by the IRAN server and nowhere else, so a
    # machine pasting one is KHAREJ. There is nothing to ask: asking invited
    # the wrong answer, and the wrong answer built a tunnel with no address to
    # dial and no explanation of why it would not start.
    T_ROLE="client"
    if [ "$dial" = "1" ]; then
        # IRAN waits, so this end comes to it - the usual arrangement
        T_ACCEPTS="server"
        T_PEER_IP="$host"
    else
        # IRAN dials out, so this end is the one that waits
        T_ACCEPTS="client"
    fi

    say ""
    head2 "This server"
    dim "the token came from IRAN, so this is the KHAREJ side"
    say ""
    [ -n "$SRV_IP" ] && [ "$SRV_IP" != "unknown" ] && T_PUBLIC_IP="$SRV_IP"
    ask T_PUBLIC_IP "address of this KHAREJ server" "$T_PUBLIC_IP"
    [ -n "$T_PUBLIC_IP" ] || { fail "an address is required"; pause; return 1; }

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
    panel "$T_NAME"
    field "This server" "$(side_label "$T_ROLE")"
    field "Address" "$(addr_tint "$T_PUBLIC_IP")"
    field "Protocol" "$(transport_label "$T_TRANSPORT")"
    field "Forwarder" "$(forwarder_label "$T_FORWARDER")"
    if [ -n "$CFG_LISTEN" ]; then
        field "Link" "accepts on $(addr_tint "$CFG_LISTEN")"
    else
        field "Link" "dials $(addr_tint "$CFG_CONNECT")"
    fi
    cfg_needs_link && field "Private link" "$(addr_tint "$T_TUNLOCAL") ${BX_ARR} $(addr_tint "$T_TUNPEER")"
    [ -n "$T_FORWARDS" ] && field "Ports" "$(printf '%s' "$T_FORWARDS" | tr -d '"' | tr ',' ' ')"
    field "Token" "$(token_print "$T_TOKEN")"
    field "Carriers" "$T_CARRIERS"
    panel_end
    say ""
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
    local side=""
    pick side "select" 1 2 3
    [ "$side" = "3" ] && { import_tunnel; return $?; }
    if [ "$side" = "2" ]; then T_ROLE="client"; else T_ROLE="server"; fi
    wiz_add "$(side_label "$T_ROLE")"

    # -- protocol -----------------------------------------------------------
    # One flat list. TUN-ICMP is not a category with something inside it: it
    # is a protocol you pick, and picking it is what brings up the local link.
    wiz "Protocol"
    choice 1 "TCP" "over the two public addresses - several connections at once"
    choice 2 "TUN-ICMP" "inside ping packets, over a private link - no port at all"
    choice 3 "TUN-GRE" "the kernel's own tunnel - fastest, but plainly visible"
    choice 4 "TUN-AWG" "obfuscated WireGuard - encrypted, and shaped not to look like it"
    say ""
    local proto=""
    pick proto "select" 1 2 3 4

    case "$proto" in
        2)  T_KIND="tun"; T_TRANSPORT="icmp"
            wiz "Who forwards the ports?"
            choice 1 "PINGIFY" "the core carries every connection itself"
            choice 2 "IPTABLES" "the kernel does it - lighter on a busy link"
            say ""
            local fw=""
            pick fw "select" 1 2
            if [ "$fw" = "2" ] && have iptables; then
                T_FORWARDER="iptables"
            else
                [ "$fw" = "2" ] && warn "iptables is not installed here - using PINGIFY"
                T_FORWARDER="pingify"
            fi ;;
        3)  T_TRANSPORT="gre"
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
        4)  T_TRANSPORT="awg"
            awg_install || { pause; return 1; } ;;
        *)  T_KIND="tcp"; T_TRANSPORT="tcp"
            T_FORWARDER="pingify" ;;
    esac
    cfg_mode

    # -- which way the link is opened, TCP only ----------------------------
    #
    # Ports live on IRAN either way and clients always arrive there. This is
    # only about which end makes the TCP connection, and it matters because
    # the two are not equally reachable: one Iranian server here takes an
    # inbound connection and runs at 100 Mbit/s with no retransmits, another
    # accepts it and then loses the flow a few kilobytes in. If one direction
    # will not stay up, the other usually will.
    #
    # Reverse is what a Pingify tunnel is. IRAN accepts and KHAREJ comes to
    # it, which is the arrangement ICMP has always used and the one every
    # other transport starts from.
    #
    # TCP is asked because there it can fail: an Iranian server that will not
    # hold an inbound connection has no way to be reached, and turning the
    # link around is the only thing that helps. ICMP is not asked - it has no
    # port to be reachable on, so there is nothing to choose.
    T_ACCEPTS="server"
    if [ "$T_TRANSPORT" = "tcp" ]; then
        wiz "Link direction"
        CHOICE_DEF="1"
        choice 1 "Reverse" "KHAREJ opens the connection to IRAN - the usual one"
        choice 2 "Direct" "IRAN opens it to KHAREJ - when inbound to IRAN will not hold"
        CHOICE_DEF=""
        say ""
        local dir=""
        ask dir "select" "1"
        if [ "$dir" = "2" ]; then
            T_ACCEPTS="client"      # KHAREJ accepts; IRAN dials out
        else
            T_ACCEPTS="server"      # IRAN accepts; KHAREJ dials in
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
    ask T_PUBLIC_IP "address of this $(side_label "$T_ROLE") server" "$T_PUBLIC_IP"
    [ -n "$T_PUBLIC_IP" ] || { fail "an address is required"; pause; return 1; }

    say ""
    ask T_PEER_IP "address of the $( [ "$T_ROLE" = "server" ] && echo KHAREJ || echo IRAN ) server" "$T_PEER_IP"
    [ -n "$T_PEER_IP" ] || { fail "an address is required"; pause; return 1; }

    if [ "$T_TRANSPORT" = "tcp" ]; then
        say ""
        ask T_PORT "port for the tunnel itself, same on both" "$T_PORT"
        case "$T_PORT" in "" | *[!0-9]*) T_PORT=9443 ;; esac
        this_side_accepts && dim "leave $T_PORT open in this server's firewall"
    elif [ "$T_TRANSPORT" = "awg" ]; then
        say ""
        ask T_AWG_PORT "UDP port for the tunnel, same on both" "$T_AWG_PORT"
        case "$T_AWG_PORT" in "" | *[!0-9]*) T_AWG_PORT=51820 ;; esac
        dim "leave ${T_AWG_PORT}/udp open in this server's firewall"
    fi
    say ""

    # -- name, derived ------------------------------------------------------
    # iran-9443 on the Iran server, kharej-9443 abroad, iran-icmp for a TUN
    # tunnel. Two servers side by side say what they are without either file
    # being opened, and there is nothing to answer.
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
            ask octet "range 10.x.10.0/24 - pick x" "$(free_link_octet "$T_NAME")"
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
        ask T_TUNLOCAL "this server" "$T_TUNLOCAL"
        ask T_TUNPEER  "the other server" "$T_TUNPEER"

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
                ask T_TUNIF "device name" "$(free_tun_iface "$T_NAME" "$T_NAME")"
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
        ask T_TUNMTU   "MTU" "$T_TUNMTU"
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
        ask T_TOKEN "token"
        T_TOKEN="$(printf '%s' "$T_TOKEN" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -n "$T_TOKEN" ] && break
        fail "a token is required"
    done
    say ""
    ok "fingerprint  ${C_YEL}$(token_print "$T_TOKEN")${C_OFF}"

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
            ask raw "ports, comma separated" "443"
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
    wiz "Performance" "Pick the shape of your traffic; you can change it later."
    preset_menu

    # -- logging -----------------------------------------------------------
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
    ask lg "select" "3"
    case "$lg" in
        1) T_LOG="error" ;; 2) T_LOG="warn" ;;
        4) T_LOG="debug" ;; 5) T_LOG="trace" ;;
        *) T_LOG="info" ;;
    esac

    # A kernel tunnel runs no process of ours, so there is nothing to serve a
    # status endpoint and nothing that would read one.
    kernel_transport && T_STATUS="" || T_STATUS="127.0.0.1:$(pick_status_port 9700)"

    # -- review ------------------------------------------------------------
    banner
    cfg_endpoints
    head2 "Ready to create"
    panel "$T_NAME"
    field "This server" "$(side_label "$T_ROLE")"
    field "Address" "$(addr_tint "$T_PUBLIC_IP")"
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
    field "Token" "$(token_print "$T_TOKEN")"
    field "Tuning" "$T_PRESET"
    field "Logging" "$T_LOG"
    panel_end
    say ""
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
