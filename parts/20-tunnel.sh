
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
    T_ACCEPTS="client"   # KHAREJ accepts the link, IRAN dials out to it
    T_PUBLIC_IP=""; T_PEER_IP=""
    T_CARRIERS=14; T_WINDOW=1024; T_KEEPALIVE=10; T_PRESET="balanced"
    T_SNDBUF=1024; T_RCVBUF=1024   # socket buffers, sized to hold a BDP
    T_OBFUSCATE="false"  # v2.1.1 wire shape; the one that survives the path
    T_FORWARDS=""; T_STATUS=""; T_LOG="info"
    T_TUNIF="pfy0"; T_TUNLOCAL=""; T_TUNPEER=""; T_TUNMTU=1380
}

this_side_accepts() { [ "$T_ROLE" = "$T_ACCEPTS" ]; }

# A local tunnel belongs to the TUN kind and nowhere else. A TCP tunnel runs
# over the two public addresses and leaves the machine as it found it, so the
# core is the only thing that can forward on it.
cfg_mode() {
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

# listen and connect are derived, never stored anywhere shared: they are the
# one part of a tunnel that differs between the two servers.
cfg_endpoints() {
    CFG_LISTEN=""; CFG_CONNECT=""
    if this_side_accepts; then
        if [ "$T_TRANSPORT" = "icmp" ]; then CFG_LISTEN="0.0.0.0"
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

apply_preset() {
    case "$1" in
        gaming)     T_CARRIERS=8;  T_WINDOW=256 ;;
        latency)    T_CARRIERS=10; T_WINDOW=512 ;;
        balanced)   T_CARRIERS=14; T_WINDOW=1024 ;;
        throughput) T_CARRIERS=20; T_WINDOW=2048 ;;
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

preset_menu() {
    CHOICE_DEF="3"
    choice 1 "Gaming" "8 carriers - lowest ping, small bursts"
    choice 2 "Latency" "10 carriers - browsing, calls, anything interactive"
    choice 3 "Balanced" "14 carriers - fills a 100 Mbit path"
    choice 4 "Download" "20 carriers - large files"
    choice 5 "Extreme" "24 carriers - fastest, uses the most memory"
    choice 6 "Custom" "set the numbers yourself"
    CHOICE_DEF=""
    say ""
    dim "One connection is worth about 6 Mbit/s on an Iran-Europe path, so"
    dim "the carrier count is what decides speed. More of them cost memory."
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
    case "$T_CARRIERS" in "" | *[!0-9]*) T_CARRIERS=14 ;; esac
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
    if [ -n "$missing" ]; then
        fail "these are still missing:$missing"
        return 1
    fi
    return 0
}

cfg_save() {
    local file
    cfg_check_complete || return 1
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
        icmp | echo) printf 'ICMP' ;;
        *)           printf 'TCP' ;;
    esac
}

# ---------------------------------------------------------------------------
# new tunnel
# ---------------------------------------------------------------------------

new_tunnel() {
    banner
    head2 "New tunnel"
    ensure_core || { pause; return 1; }
    cfg_reset
    wiz_reset
    server_info

    # -- which server is this ----------------------------------------------
    wiz "Which server is this?"
    CHOICE_DEF="1"
    choice 1 "IRAN" "clients connect here"
    choice 2 "KHAREJ" "your panel and inbounds run here"
    CHOICE_DEF=""
    say ""
    local side=""
    ask side "select" "1"
    if [ "$side" = "2" ]; then T_ROLE="client"; else T_ROLE="server"; fi
    wiz_add "$(side_label "$T_ROLE")"

    # -- kind --------------------------------------------------------------
    wiz "Tunnel type"
    CHOICE_DEF="1"
    choice 1 "TCP" "over the two public addresses - several connections at once"
    choice 2 "TUN" "a private network between the servers"
    CHOICE_DEF=""
    say ""
    local kind=""
    ask kind "select" "1"

    if [ "$kind" = "2" ]; then
        T_KIND="tun"

        wiz "What carries the link?"
        CHOICE_DEF="1"
        choice 1 "ICMP" "inside ping packets - no port needed"
        CHOICE_DEF=""
        say ""
        dim "GRE and others will land here later."
        say ""
        local sub=""
        ask sub "select" "1"
        T_TRANSPORT="icmp"
        wiz_add "TUN over ICMP"

        wiz "Who forwards the ports?"
        CHOICE_DEF="1"
        choice 1 "PINGIFY" "the core carries every connection itself"
        choice 2 "IPTABLES" "the kernel does it - lighter on a busy link"
        CHOICE_DEF=""
        say ""
        dim "With IPTABLES the service on KHAREJ has to listen on 0.0.0.0,"
        dim "not only on 127.0.0.1."
        say ""
        local fw=""
        ask fw "select" "1"
        if [ "$fw" = "2" ] && have iptables; then
            T_FORWARDER="iptables"
        else
            [ "$fw" = "2" ] && warn "iptables is not installed here - using PINGIFY"
            T_FORWARDER="pingify"
        fi
        wiz_add "$(forwarder_label "$T_FORWARDER")"
        T_ACCEPTS="server"
    else
        T_KIND="tcp"; T_TRANSPORT="tcp"
        T_FORWARDER="pingify"
        wiz_add "TCP"
    fi
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
    # ICMP is not asked. It has no port to be reachable on, so there is
    # nothing to choose - IRAN accepts the echoes and KHAREJ sends them, which
    # is what every working ICMP tunnel has done.
    if [ "$T_TRANSPORT" = "tcp" ]; then
        wiz "Link direction"
        CHOICE_DEF="1"
        choice 1 "Direct" "IRAN opens the connection to KHAREJ"
        choice 2 "Reverse" "KHAREJ opens it to IRAN - IRAN needs the port reachable"
        CHOICE_DEF=""
        say ""
        dim "The same on both servers. The token carries it, so the second"
        dim "server is not asked."
        say ""
        local dir=""
        ask dir "select" "1"
        if [ "$dir" = "2" ]; then
            T_ACCEPTS="server"      # IRAN accepts; KHAREJ dials in
        else
            T_ACCEPTS="client"      # KHAREJ accepts; IRAN dials out
        fi
    fi

    # -- where the servers are ---------------------------------------------
    wiz "Addresses"
    if [ -n "$SRV_IP" ] && [ "$SRV_IP" != "unknown" ]; then
        T_PUBLIC_IP="$SRV_IP"
        dim "this machine reports $SRV_IP"
        say ""
    fi
    ask T_PUBLIC_IP "this server" "$T_PUBLIC_IP"

    if ! this_side_accepts; then
        say ""
        ask T_PEER_IP "address of the $( [ "$T_ROLE" = "server" ] && echo KHAREJ || echo IRAN ) server"
        [ -n "$T_PEER_IP" ] || { fail "an address is required"; pause; return 1; }
    fi

    if [ "$T_TRANSPORT" = "tcp" ]; then
        say ""
        ask T_PORT "port for the tunnel itself, same on both" "$T_PORT"
        case "$T_PORT" in "" | *[!0-9]*) T_PORT=9443 ;; esac
        this_side_accepts && dim "leave $T_PORT open in this server's firewall"
    fi

    # -- name, derived ------------------------------------------------------
    # iran-9443 on the Iran server, kharej-9443 abroad, iran-icmp for a TUN
    # tunnel. Two servers side by side say what they are without either file
    # being opened, and there is nothing to answer.
    T_NAME="$(printf '%s' "$(side_label "$T_ROLE")" | tr 'A-Z' 'a-z')"
    if [ "$T_TRANSPORT" = "icmp" ]; then
        T_NAME="${T_NAME}-icmp"
    else
        T_NAME="${T_NAME}-${T_PORT}"
    fi
    if [ -f "$(cfg_file "$T_NAME")" ]; then
        local n=2
        while [ -f "$(cfg_file "${T_NAME}-${n}")" ]; do n=$((n + 1)); done
        T_NAME="${T_NAME}-${n}"
    fi
    ok "this tunnel is called ${C_B}${T_NAME}${C_OFF}"

    # -- the private link, whenever one is needed --------------------------
    if cfg_needs_link; then
        wiz "Private link" "Both servers get an address on a small network of their own."
        local octet=""
        ask octet "range 10.x.10.0/24 - pick x" "10"
        case "$octet" in "" | *[!0-9]*) octet=10 ;; esac
        if [ "$T_ROLE" = "server" ]; then
            T_TUNLOCAL="10.${octet}.10.1/24"; T_TUNPEER="10.${octet}.10.2/24"
        else
            T_TUNLOCAL="10.${octet}.10.2/24"; T_TUNPEER="10.${octet}.10.1/24"
        fi
        say ""
        ask T_TUNLOCAL "this server" "$T_TUNLOCAL"
        ask T_TUNPEER  "the other server" "$T_TUNPEER"
        say ""
        ask T_TUNIF    "device name" "$T_TUNIF"
        ask T_TUNMTU   "MTU" "$T_TUNMTU"
        case "$T_TUNMTU" in "" | *[!0-9]*) T_TUNMTU=1380 ;; esac
    fi

    # -- security ----------------------------------------------------------
    wiz "Security token" "One secret, typed the same on BOTH servers. Any length."
    while :; do
        ask T_TOKEN "token"
        T_TOKEN="$(printf '%s' "$T_TOKEN" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -n "$T_TOKEN" ] && break
        fail "a token is required"
    done
    say ""
    ok "fingerprint  ${C_YEL}$(token_print "$T_TOKEN")${C_OFF}"
    dim "the other server must show these same eight characters"

    # -- ports: the IRAN side owns them ------------------------------------
    if [ "$T_ROLE" = "server" ]; then
        wiz "Ports" "The ports your clients will connect to, here on IRAN."
        dim "443           the same port on both servers"
        dim "443=8443      clients hit 443 here, it lands on 8443 there"
        dim "udp:500       a UDP port"
        dim "8000-8010     a range"
        say ""
        local raw=""
        ask raw "ports, comma separated" "443"
        T_FORWARDS="$(parse_forwards "$raw")"
        [ -n "$T_FORWARDS" ] || { fail "at least one port is required"; pause; return 1; }
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

    T_STATUS="127.0.0.1:$(pick_free_port 9700)"

    # -- review ------------------------------------------------------------
    banner
    cfg_endpoints
    head2 "Ready to create"
    panel "$T_NAME"
    field "This server" "$(side_label "$T_ROLE")"
    field "Address" "$T_PUBLIC_IP"
    if [ "$T_KIND" = "tun" ]; then
        field "Type" "TUN over $(transport_label "$T_TRANSPORT")"
    else
        field "Type" "$(transport_label "$T_TRANSPORT")"
    fi
    field "Forwarder" "$(forwarder_label "$T_FORWARDER")"
    if [ -n "$CFG_LISTEN" ]; then
        field "Link" "accepts on $CFG_LISTEN"
    else
        field "Link" "connects to $CFG_CONNECT"
    fi
    cfg_needs_link && field "Private link" "${T_TUNLOCAL} ${BX_ARR} ${T_TUNPEER}"
    [ -n "$T_FORWARDS" ] && field "Ports" "$(printf '%s' "$T_FORWARDS" | tr -d '"' | tr ',' ' ')"
    field "Token" "$(token_print "$T_TOKEN")"
    field "Tuning" "$T_PRESET"
    field "Logging" "$T_LOG"
    panel_end
    say ""
    if ! confirm "create it?"; then
        warn "cancelled, nothing was written"
        pause
        return 1
    fi

    # -- write and start ---------------------------------------------------
    say ""
    local file
    file="$(cfg_save)" || { pause; return 1; }
    if ! "$CORE_BIN" -c "$file" -check >/dev/null 2>&1; then
        fail "the core rejected this configuration"
        core_matches_script || dim "the core is $(core_version) and this script is $PINGIFY_VERSION - update the core"
        "$CORE_BIN" -c "$file" -check 2>&1 | sed 's/^/      /'
        rm -f "$file"
        pause; return 1
    fi

    write_units
    service_enable_start "$T_NAME"
    enable_watchdog quiet
    # Unconditional: apply_nat tears the chains down when no tunnel needs
    # them, so this is also what cleans up after a forwarder that changed.
    apply_nat quiet
    ok "$T_NAME is running"
    dim "$file"

    # -- what to do on the other server ------------------------------------
    local other
    other="$( [ "$T_ROLE" = "server" ] && echo KHAREJ || echo IRAN )"
    head2 "Now do the other side"
    dim "Run Pingify on the $other server, choose New tunnel, and answer:"
    say ""
    panel "on $other"
    field "This server" "$other"
    if [ "$T_KIND" = "tun" ]; then
        field "Type" "TUN over $(transport_label "$T_TRANSPORT")"
    else
        field "Type" "$(transport_label "$T_TRANSPORT")"
    fi
    [ "$T_TRANSPORT" = "tcp" ] && field "Tunnel port" "$T_PORT"
    field "Direction" "$( [ "$T_ACCEPTS" = "server" ] && echo "Reverse - KHAREJ dials IRAN" || echo "Direct - IRAN dials KHAREJ" )"
    field "Forwarder" "$(forwarder_label "$T_FORWARDER")"
    if cfg_needs_link; then
        field "Its address" "$T_TUNPEER"
        field "Peer address" "$T_TUNLOCAL"
    fi
    field "Token" "the same one"
    field "Fingerprint" "$(token_print "$T_TOKEN")"
    panel_end
    say ""
    dim "The fingerprint there must read $(token_print "$T_TOKEN") too."
    say ""
    tunnel_status_block "$T_NAME"
    pause
}
