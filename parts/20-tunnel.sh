
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
    T_ACCEPTS="server"   # IRAN accepts the link, KHAREJ dials it
    T_PUBLIC_IP=""; T_PEER_IP=""
    T_CARRIERS=4; T_WINDOW=512; T_KEEPALIVE=10; T_PRESET="balanced"
    T_FORWARDS=""; T_STATUS=""
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
# carriers  how many connections the link is spread over; more of them absorb
#           packet loss better, because one stalled connection is a smaller
#           share of the whole
# window    how much one forwarded connection may have in flight; bigger fills
#           a long path better and is the memory ceiling per open connection
# ---------------------------------------------------------------------------

apply_preset() {
    case "$1" in
        gaming)     T_CARRIERS=8;  T_WINDOW=128;  T_KEEPALIVE=5 ;;
        latency)    T_CARRIERS=6;  T_WINDOW=256;  T_KEEPALIVE=5 ;;
        balanced)   T_CARRIERS=4;  T_WINDOW=512;  T_KEEPALIVE=10 ;;
        throughput) T_CARRIERS=8;  T_WINDOW=2048; T_KEEPALIVE=15 ;;
        extreme)    T_CARRIERS=16; T_WINDOW=4096; T_KEEPALIVE=15 ;;
        *)          return 1 ;;
    esac
    T_PRESET="$1"
    return 0
}

preset_menu() {
    item 1 "Gaming" "lowest latency, small bursts"
    item 2 "Low latency" "interactive, browsing, calls"
    item 3 "Balanced" "sensible default"
    item 4 "Throughput" "large downloads"
    item 5 "Extreme" "fastest, uses the most memory"
    item 6 "Custom" "set the numbers yourself"
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
    case "$T_CARRIERS" in "" | *[!0-9]*) T_CARRIERS=4 ;; esac
    case "$T_WINDOW" in "" | *[!0-9]*) T_WINDOW=512 ;; esac
    case "$T_KEEPALIVE" in "" | *[!0-9]*) T_KEEPALIVE=10 ;; esac
    [ "$T_CARRIERS" -lt 1 ] && T_CARRIERS=1
    [ "$T_CARRIERS" -gt 64 ] && T_CARRIERS=64
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
    printf '\n[status]\n'
    printf 'addr             = "%s"\n' "$status"
    printf '\n[logging]\n'
    printf 'level            = "info"\n'
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

    item 1 "IRAN" "clients connect here"
    item 2 "KHAREJ" "the panel and inbounds run here"
    say ""
    local side=""
    ask side "select" "1"

    cfg_reset
    server_info
    if [ "$side" = "2" ]; then T_ROLE="client"; else T_ROLE="server"; fi

    # -- kind --------------------------------------------------------------
    head2 "Tunnel type"
    item 1 "TCP" "straight over the public addresses - the fast one"
    item 2 "TUN" "a private layer-3 link between the two servers"
    say ""
    dim "TCP carries the tunnel over ordinary connections between the two"
    dim "public addresses. TUN gives the servers a private network instead,"
    dim "carried inside something that is not TCP."
    say ""
    local kind=""
    ask kind "select" "1"

    if [ "$kind" = "2" ]; then
        T_KIND="tun"
        head2 "How the link is carried"
        item 1 "ICMP" "inside ping packets - needs no port at all"
        say ""
        dim "GRE and others will appear here; ICMP is what this build carries."
        say ""
        local sub=""
        ask sub "select" "1"
        T_TRANSPORT="icmp"

        # Both forwarders are available here, because a local tunnel exists
        # for the kernel to route onto.
        head2 "Forwarder"
        item 1 "PINGIFY" "the core carries each connection - TCP and UDP"
        item 2 "IPTABLES" "the kernel NATs onto the local tunnel - least CPU"
        say ""
        dim "PINGIFY needs nothing from the kernel and keeps every byte inside"
        dim "the tunnel. IPTABLES is lighter on a busy link, but the service on"
        dim "KHAREJ must listen on 0.0.0.0 rather than only on 127.0.0.1."
        say ""
        local fw=""
        ask fw "select" "1"
        if [ "$fw" = "2" ] && have iptables; then
            T_FORWARDER="iptables"
        else
            [ "$fw" = "2" ] && warn "iptables is not installed here - using PINGIFY"
            T_FORWARDER="pingify"
        fi
    else
        T_KIND="tcp"; T_TRANSPORT="tcp"
        # Nothing to choose: with no local tunnel the core is what forwards.
        T_FORWARDER="pingify"
    fi
    cfg_mode

    # -- name --------------------------------------------------------------
    head2 "Name"
    local suggested="main"
    [ -f "$(cfg_file main)" ] && suggested="tunnel$(( $(tunnel_count) + 1 ))"
    while :; do
        ask T_NAME "tunnel name" "$suggested"
        case "$T_NAME" in
            "" | *[!a-zA-Z0-9_-]*) fail "letters, digits, dash and underscore only" ;;
            *)
                if [ -f "$(cfg_file "$T_NAME")" ]; then
                    fail "a tunnel named $T_NAME already exists here"
                else
                    break
                fi ;;
        esac
    done

    # -- where the servers are ---------------------------------------------
    head2 "Servers"
    if [ -n "$SRV_IP" ] && [ "$SRV_IP" != "unknown" ]; then
        dim "this machine reports its address as $SRV_IP"
        say ""
        T_PUBLIC_IP="$SRV_IP"
    fi
    ask T_PUBLIC_IP "address of this server" "$T_PUBLIC_IP"

    if ! this_side_accepts; then
        say ""
        ask T_PEER_IP "address of the IRAN server"
        [ -n "$T_PEER_IP" ] || { fail "an address is required"; pause; return 1; }
    fi

    if [ "$T_TRANSPORT" = "tcp" ]; then
        say ""
        ask T_PORT "tunnel port, the same on both servers" "$T_PORT"
        case "$T_PORT" in "" | *[!0-9]*) T_PORT=9443 ;; esac
        this_side_accepts && dim "open $T_PORT in this server's firewall"
    fi

    # -- the private link, whenever one is needed --------------------------
    if cfg_needs_link; then
        head2 "Private link"
        dim "both servers get an address on a small network of their own"
        say ""
        local octet=""
        ask octet "private range 10.x.10.0/24, pick x" "10"
        case "$octet" in "" | *[!0-9]*) octet=10 ;; esac
        if [ "$T_ROLE" = "server" ]; then
            T_TUNLOCAL="10.${octet}.10.1/24"; T_TUNPEER="10.${octet}.10.2/24"
        else
            T_TUNLOCAL="10.${octet}.10.2/24"; T_TUNPEER="10.${octet}.10.1/24"
        fi
        say ""
        ask T_TUNLOCAL "this server's private address" "$T_TUNLOCAL"
        ask T_TUNPEER  "the other server's private address" "$T_TUNPEER"
        ask T_TUNIF    "device name" "$T_TUNIF"
        ask T_TUNMTU   "MTU" "$T_TUNMTU"
        case "$T_TUNMTU" in "" | *[!0-9]*) T_TUNMTU=1380 ;; esac
    fi

    # -- security ----------------------------------------------------------
    head2 "Security token"
    dim "One secret, typed by hand on BOTH servers, exactly the same. Any length"
    dim "you like - it is what the two ends use to recognise each other."
    say ""
    while :; do
        ask T_TOKEN "token"
        T_TOKEN="$(printf '%s' "$T_TOKEN" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -n "$T_TOKEN" ] && break
        fail "a token is required"
    done
    say ""
    ok "token fingerprint: ${C_YEL}$(token_print "$T_TOKEN")${C_OFF}"
    dim "the other server must show these same eight characters. If it does not,"
    dim "the tokens differ - fix that before looking at anything else."

    # -- ports: the IRAN side owns them ------------------------------------
    if [ "$T_ROLE" = "server" ]; then
        head2 "Ports"
        if [ "$T_FORWARDER" = "iptables" ]; then
            dim "forwarded by the kernel onto the private link"
        else
            dim "forwarded by the core, over the tunnel's own connections"
        fi
        say ""
        dim "443            same port on both servers"
        dim "443=8443       clients hit 443 here, it lands on 8443 there"
        dim "udp:500        a UDP port"
        dim "8000-8010      a range"
        say ""
        local raw=""
        ask raw "ports clients will connect to, comma separated" "443"
        T_FORWARDS="$(parse_forwards "$raw")"
        [ -n "$T_FORWARDS" ] || { fail "at least one port is required"; pause; return 1; }
    else
        dim "ports are configured on the IRAN server"
    fi

    # -- performance -------------------------------------------------------
    head2 "Performance"
    preset_menu

    T_STATUS="127.0.0.1:$(pick_free_port 9700)"

    # -- review ------------------------------------------------------------
    banner
    head2 "Review"
    cfg_endpoints
    box_top
    box_row "$(pad_to "Tunnel" 16)${C_B}${T_NAME}${C_OFF}"
    box_row "$(pad_to "This server" 16)$(side_label "$T_ROLE")  ${C_DIM}$T_PUBLIC_IP${C_OFF}"
    if [ "$T_KIND" = "tun" ]; then
        box_row "$(pad_to "Type" 16)TUN  ${C_DIM}carried over $(transport_label "$T_TRANSPORT")${C_OFF}"
    else
        box_row "$(pad_to "Type" 16)TCP"
    fi
    if [ -n "$CFG_LISTEN" ]; then
        box_row "$(pad_to "Link" 16)accepts on ${CFG_LISTEN}"
    else
        box_row "$(pad_to "Link" 16)connects to ${CFG_CONNECT}"
    fi
    cfg_needs_link && box_row "$(pad_to "Private link" 16)${T_TUNLOCAL} ${BX_ARR} ${T_TUNPEER}"
    box_row "$(pad_to "Forwarder" 16)$(forwarder_label "$T_FORWARDER")"
    [ -n "$T_FORWARDS" ] && box_row "$(pad_to "Ports" 16)$(printf '%s' "$T_FORWARDS" | tr -d '"' | tr ',' ' ')"
    box_row "$(pad_to "Performance" 16)${T_PRESET}  ${C_DIM}${T_CARRIERS} connections, ${T_WINDOW} KB window${C_OFF}"
    box_bot
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
    [ "$T_FORWARDER" = "iptables" ] && apply_nat quiet
    ok "$T_NAME is running"
    dim "config: $file"

    # -- what to do on the other server ------------------------------------
    head2 "Now the $( [ "$T_ROLE" = "server" ] && echo KHAREJ || echo IRAN ) server"
    dim "run Pingify there, choose New tunnel, and answer with:"
    say ""
    box_top
    box_row "$(pad_to "This server" 18)$( [ "$T_ROLE" = "server" ] && echo KHAREJ || echo IRAN )"
    if [ "$T_KIND" = "tun" ]; then
        box_row "$(pad_to "Type" 18)TUN, over $(transport_label "$T_TRANSPORT")"
    else
        box_row "$(pad_to "Type" 18)TCP"
    fi
    [ "$T_TRANSPORT" = "tcp" ] && box_row "$(pad_to "Tunnel port" 18)${T_PORT}"
    box_row "$(pad_to "IRAN address" 18)$( this_side_accepts && printf '%s' "$T_PUBLIC_IP" || printf '%s' "$T_PEER_IP" )"
    box_row "$(pad_to "Forwarder" 18)$(forwarder_label "$T_FORWARDER")"
    if cfg_needs_link; then
        box_row "$(pad_to "Its private addr" 18)${T_TUNPEER}"
        box_row "$(pad_to "Peer private addr" 18)${T_TUNLOCAL}"
    fi
    box_row "$(pad_to "Token fingerprint" 18)${C_YEL}$(token_print "$T_TOKEN")${C_OFF} ${C_DIM}(must match the other server)${C_OFF}"
    box_bot
    say ""
    tunnel_status_block "$T_NAME"
    pause
}
