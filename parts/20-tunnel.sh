
# ---------------------------------------------------------------------------
# tunnel configuration
#
# Two roles, and picking the country picks both of them:
#
#   IRAN   = server = clients connect here, and it accepts the tunnel link
#   KHAREJ = client = the panel and inbounds run here, and it dials Iran
#
# That is the deployment almost everyone wants, so the wizard does not ask
# about it twice. Swapping which end accepts the link is still possible - it
# is one question behind the advanced prompt at the end.
# ---------------------------------------------------------------------------

cfg_reset() {
    T_NAME=""; T_ROLE=""; T_MODE="forward"; T_TRANSPORT="braid"
    T_FORWARDER="pingify"
    T_PSK=""
    T_PORT=9443          # agreed by both ends
    T_ACCEPTS="server"   # which role accepts the link; the other one dials
    T_PUBLIC_IP=""       # this server's own address
    T_PEER_IP=""         # the other server's address
    T_CARRIERS=4; T_WINDOW=512; T_KEEPALIVE=10; T_PRESET="balanced"
    T_FORWARDS=""; T_STATUS=""
    T_TUNIF="pfy0"; T_TUNLOCAL=""; T_TUNPEER=""; T_TUNMTU=1380
}

# This side listens when its role is the one that accepts the link.
this_side_accepts() { [ "$T_ROLE" = "$T_ACCEPTS" ]; }

# listen/connect are derived, never stored in the token: they are the one part
# of a tunnel that is different on each server.
cfg_endpoints() {
    CFG_LISTEN=""; CFG_CONNECT=""
    if this_side_accepts; then
        if [ "$T_TRANSPORT" = "echo" ]; then
            CFG_LISTEN="0.0.0.0"
        else
            CFG_LISTEN="0.0.0.0:$T_PORT"
        fi
    else
        if [ "$T_TRANSPORT" = "echo" ]; then
            CFG_CONNECT="$T_PEER_IP"
        else
            CFG_CONNECT="$T_PEER_IP:$T_PORT"
        fi
    fi
}

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

# cfg_render <role> <mode> <listen> <connect> <ports> <status-addr>
# Sectioned TOML: related settings sit together, and the manager reads it back
# with a targeted awk rather than carrying a parser.
cfg_render() {
    local role="$1" mode="$2" listen="$3" connect="$4" fwd="$5" status="$6"
    printf '# Pingify tunnel - written by the manager, safe to edit by hand\n'
    printf '\n[tunnel]\n'
    printf 'name             = "%s"\n' "$T_NAME"
    printf 'role             = "%s"\n' "$role"
    printf 'mode             = "%s"\n' "$mode"
    printf '\n[transport]\n'
    printf 'type             = "%s"\n' "$T_TRANSPORT"
    [ -n "$listen" ]  && printf 'listen           = "%s"\n' "$listen"
    [ -n "$connect" ] && printf 'connect          = "%s"\n' "$connect"
    printf 'carriers         = %s\n' "$T_CARRIERS"
    printf 'keepalive_sec    = %s\n' "$T_KEEPALIVE"
    printf '\n[security]\n'
    printf 'psk              = "%s"\n' "$T_PSK"
    # Both ends need to know which forwarder is in use - the KHAREJ side has
    # rules of its own to write. Only the side clients reach carries the port
    # list, so the other document does not end up with an empty one.
    printf '\n[forward]\n'
    printf 'forwarder        = "%s"\n' "$T_FORWARDER"
    [ -n "$fwd" ] && printf 'ports            = [%s]\n' "$fwd"
    # Only ever this server's own file: the token carries the far side's tun
    # addresses already mirrored, so there is nothing to swap here.
    if [ "$mode" = "tun" ]; then
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

# A missing field used to reach the core and come back as a flat rejection
# with no hint which one it was. Name it here instead.
cfg_check_complete() {
    local missing=""
    [ -n "$T_NAME" ]      || missing="$missing name"
    [ -n "$T_ROLE" ]      || missing="$missing role"
    [ -n "$T_MODE" ]      || missing="$missing mode"
    [ -n "$T_TRANSPORT" ] || missing="$missing transport"
    [ -n "$T_PSK" ]       || missing="$missing key"
    if [ -n "$missing" ]; then
        fail "the wizard did not collect:$missing"
        dim "nothing was written - please report this, it is a bug in Pingify"
        return 1
    fi
    return 0
}

cfg_save() {
    local file
    cfg_check_complete || return 1
    file="$(cfg_file "$T_NAME")"
    cfg_endpoints
    cfg_render "$T_ROLE" "$T_MODE" "$CFG_LISTEN" "$CFG_CONNECT" "$T_FORWARDS" "$T_STATUS" > "$file"
    chmod 600 "$file"
    printf '%s' "$file"
}

# ---------------------------------------------------------------------------
# the token
#
# It carries only what both servers must agree on. No address, because each
# server has its own; no port list, because those live on the IRAN side alone.
# The issuing server's address rides along as a suggestion, offered as the
# default when the other end asks - accept it with enter, or type the real one
# if this server sits behind a different address than it can see itself.
# ---------------------------------------------------------------------------

cfg_peer_token() {
    local prole
    if [ "$T_ROLE" = "server" ]; then prole="client"; else prole="server"; fi
    {
        printf 'v = 2\n'
        printf 'name = "%s"\n'      "$T_NAME"
        printf 'role = "%s"\n'      "$prole"
        printf 'mode = "%s"\n'      "$T_MODE"
        printf 'transport = "%s"\n' "$T_TRANSPORT"
        printf 'accepts = "%s"\n'   "$T_ACCEPTS"
        printf 'port = %s\n'        "$T_PORT"
        printf 'psk = "%s"\n'       "$T_PSK"
        printf 'carriers = %s\n'    "$T_CARRIERS"
        printf 'window_kb = %s\n'   "$T_WINDOW"
        printf 'keepalive = %s\n'   "$T_KEEPALIVE"
        printf 'profile = "%s"\n'   "$T_PRESET"
        printf 'forwarder = "%s"\n' "$T_FORWARDER"
        printf 'suggest_ip = "%s"\n' "$T_PUBLIC_IP"
        if [ "$T_MODE" = "tun" ]; then
            local pfx="${T_TUNLOCAL##*/}"
            [ "$pfx" = "$T_TUNLOCAL" ] && pfx=30
            printf 'tun_if = "%s"\n'    "$T_TUNIF"
            printf 'tun_local = "%s"\n' "$T_TUNPEER/$pfx"
            printf 'tun_peer = "%s"\n'  "${T_TUNLOCAL%%/*}"
            printf 'tun_mtu = %s\n'     "$T_TUNMTU"
        fi
    } | base64 | tr -d '\n'
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

# Friendly names for what the config stores.
side_label()      { [ "$1" = "server" ] && printf 'IRAN' || printf 'KHAREJ'; }
role_label()      { [ "$1" = "server" ] && printf 'server' || printf 'client'; }
mode_label()      { [ "$1" = "tun" ] && printf 'Full IP' || printf 'Ports'; }
transport_label() {
    case "$1" in
        braid | direct | tcp | "") printf 'Braid' ;;
        icmp) printf 'Echo' ;;
        *) printf '%s' "$1" ;;
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
    item 3 "Apply a token" "paste what the other server printed"
    say ""
    local side=""
    ask side "select" "1"
    [ "$side" = "3" ] && { import_tunnel; return; }

    cfg_reset
    server_info
    if [ "$side" = "2" ]; then T_ROLE="client"; else T_ROLE="server"; fi

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

    # -- transport ---------------------------------------------------------
    head2 "Protocol"
    item 1 "Braid" "several TCP connections woven into one encrypted stream"
    item 2 "Echo" "the same stream inside ICMP, for when TCP is blocked"
    say ""
    dim "Braid is the fast one. Echo is the fallback: every packet is small and"
    dim "has to be acknowledged, so it moves a fraction of what Braid does."
    say ""
    local tr=""
    ask tr "select" "1"
    if [ "$tr" = "2" ]; then T_TRANSPORT="echo"; else T_TRANSPORT="braid"; fi

    # -- addresses ---------------------------------------------------------
    #
    # This server's own address is asked for even though it is usually
    # detected, because the detection needs an outside lookup that an Iranian
    # server often cannot reach - and the answer is what the other end will be
    # offered as its default. Getting it wrong here used to produce a token
    # that pointed at nothing.
    head2 "Addresses"
    if [ -n "$SRV_IP" ] && [ "$SRV_IP" != "unknown" ]; then
        dim "detected on this machine: $SRV_IP"
        say ""
        T_PUBLIC_IP="$SRV_IP"
    else
        warn "could not detect this server's public address"
        say ""
        T_PUBLIC_IP=""
    fi
    while :; do
        ask T_PUBLIC_IP "address of this server" "$T_PUBLIC_IP"
        case "$T_PUBLIC_IP" in
            "" | unknown) fail "the other server needs this to reach you" ;;
            *) break ;;
        esac
    done

    if ! this_side_accepts; then
        say ""
        ask T_PEER_IP "address of the $(side_label "$T_ACCEPTS") server"
        [ -n "$T_PEER_IP" ] || { fail "an address is required"; pause; return 1; }
    fi

    if [ "$T_TRANSPORT" != "echo" ]; then
        say ""
        ask T_PORT "tunnel port" "$T_PORT"
        case "$T_PORT" in "" | *[!0-9]*) T_PORT=9443 ;; esac
        if this_side_accepts; then
            port_free "$T_PORT" || warn "something is already listening on $T_PORT"
            dim "open $T_PORT in this server's firewall"
        fi
    else
        dim "Echo needs no port - ICMP has none"
    fi

    # -- key ---------------------------------------------------------------
    head2 "Shared key"
    dim "both servers authenticate with the same key"
    say ""
    item 1 "Generate a new one" "you will get a token to paste on the other server"
    item 2 "Enter an existing key" "if the other server was configured first"
    say ""
    local kmode=""
    ask kmode "select" "1"
    say ""
    if [ "$kmode" = "2" ]; then
        ask T_PSK "key"
    else
        T_PSK="$("$CORE_BIN" -genpsk)"
        ok "generated"
    fi
    case "$T_PSK" in
        "" | *[!0-9a-fA-F]*) fail "a key is 64 hex characters"; pause; return 1 ;;
    esac

    # -- forwarder ---------------------------------------------------------
    head2 "Forwarder"
    item 1 "Pingify" "the core carries it - encrypted end to end, any protocol"
    item 2 "iptables" "the kernel carries it over a private IP link - fastest"
    say ""
    dim "Pingify never lets a packet out of the tunnel until it is on the far"
    dim "server. iptables sets up a private layer-3 link and lets the kernel"
    dim "NAT onto it, so nothing is copied into user space - less CPU on a busy"
    dim "tunnel, but it needs a full-IP link and it writes NAT rules."
    say ""
    local fw=""
    ask fw "select" "1"
    if [ "$fw" = "2" ]; then
        T_FORWARDER="iptables"
        T_MODE="tun"
        if ! have iptables; then
            warn "iptables is not installed on this server"
            dim "install it, or choose Pingify instead"
            pause
            return 1
        fi
        local sub=""
        say ""
        ask sub "private subnet index (0-63)" "1"
        case "$sub" in "" | *[!0-9]*) sub=1 ;; esac
        T_TUNIF="pfy${sub}"
        if [ "$T_ROLE" = "server" ]; then
            T_TUNLOCAL="10.71.${sub}.1/30"; T_TUNPEER="10.71.${sub}.2"
        else
            T_TUNLOCAL="10.71.${sub}.2/30"; T_TUNPEER="10.71.${sub}.1"
        fi
        T_TUNMTU=1380
        dim "this server takes ${T_TUNLOCAL}, the other one ${T_TUNPEER}"
    else
        T_FORWARDER="pingify"
        T_MODE="forward"
    fi

    # -- ports -------------------------------------------------------------
    #
    # Only the side clients connect to has any use for these.
    if [ "$T_ROLE" = "server" ]; then
        head2 "Ports"
        dim "443            same port on both servers"
        dim "443=8443       clients hit 443 here, it lands on 8443 there"
        dim "udp:500        a UDP port"
        dim "8000-8010      a range"
        say ""
        local raw=""
        ask raw "ports clients will connect to, comma separated" "443"
        T_FORWARDS="$(parse_forwards "$raw")"
        [ -n "$T_FORWARDS" ] || { fail "at least one port is required"; pause; return 1; }
    fi

    # -- performance -------------------------------------------------------
    head2 "Performance"
    preset_menu

    T_STATUS="127.0.0.1:$(pick_free_port 9700)"

    # -- advanced ----------------------------------------------------------
    say ""
    if confirm "change advanced options?"; then
        head2 "Advanced"
        dim "By default the IRAN server accepts the link and KHAREJ dials in."
        dim "Reverse it when inbound to the IRAN server is filtered."
        say ""
        if confirm "reverse which end accepts the link?"; then
            if [ "$T_ACCEPTS" = "server" ]; then T_ACCEPTS="client"; else T_ACCEPTS="server"; fi
            if ! this_side_accepts && [ -z "$T_PEER_IP" ]; then
                say ""
                ask T_PEER_IP "address of the other server"
            fi
            if this_side_accepts; then
                ok "this server now accepts the link"
            else
                ok "this server now opens the link"
            fi
        fi
    fi

    # -- review ------------------------------------------------------------
    banner
    head2 "Review"
    box_top
    box_row "$(pad_to "Tunnel" 16)${C_B}${T_NAME}${C_OFF}"
    box_row "$(pad_to "This server" 16)$(side_label "$T_ROLE")  ${C_DIM}($(role_label "$T_ROLE"))${C_OFF}"
    cfg_endpoints
    if [ -n "$CFG_LISTEN" ]; then
        box_row "$(pad_to "Link" 16)accepts on ${CFG_LISTEN}"
    else
        box_row "$(pad_to "Link" 16)connects to ${CFG_CONNECT}"
    fi
    box_row "$(pad_to "This address" 16)${T_PUBLIC_IP}"
    box_row "$(pad_to "Protocol" 16)$(transport_label "$T_TRANSPORT")"
    box_row "$(pad_to "Forwarder" 16)$(forwarder_label "$T_FORWARDER")"
    if [ -n "$T_FORWARDS" ]; then
        box_row "$(pad_to "Ports" 16)$(printf '%s' "$T_FORWARDS" | tr -d '"' | tr ',' ' ')"
    fi
    if [ "$T_MODE" = "tun" ]; then
        box_row "$(pad_to "Private link" 16)${T_TUNLOCAL} ${BX_ARR} ${T_TUNPEER}"
    fi
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
    local file; file="$(cfg_save)"
    if ! "$CORE_BIN" -c "$file" -check >/dev/null 2>&1; then
        fail "the core rejected this configuration"
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

    # -- token -------------------------------------------------------------
    head2 "Token for the $( [ "$T_ROLE" = "server" ] && echo KHAREJ || echo IRAN ) server"
    dim "run Pingify there and choose New tunnel ${BX_ARR} Apply a token"
    dim "it carries the settings only - that server fills in its own address"
    say ""
    rule
    printf '%s\n' "${C_YEL}$(cfg_peer_token)${C_OFF}"
    rule
    say ""
    warn "treat it like a password - it carries the shared key"
    say ""
    tunnel_status_block "$T_NAME"
    pause
}

# ---------------------------------------------------------------------------
# apply a token
# ---------------------------------------------------------------------------

import_tunnel() {
    banner
    head2 "Apply a token"
    dim "configure the other server first; it prints the token at the end"
    say ""
    ensure_core || { pause; return 1; }
    local token=""
    ask token "token"
    [ -n "$token" ] || return 1

    local tmp="/tmp/pingify-token"
    if ! printf '%s' "$token" | base64 -d > "$tmp" 2>/dev/null; then
        fail "that is not a Pingify token"
        pause; return 1
    fi
    if [ "$(toml_get "$tmp" "" v)" != "2" ]; then
        fail "this token was made by an older Pingify"
        dim "update both servers, then create the tunnel again"
        rm -f "$tmp"; pause; return 1
    fi

    cfg_reset
    server_info
    T_NAME="$(toml_get "$tmp" "" name)"
    T_ROLE="$(toml_get "$tmp" "" role)"
    T_MODE="$(toml_get "$tmp" "" mode)"
    T_TRANSPORT="$(toml_get "$tmp" "" transport)"
    T_ACCEPTS="$(toml_get "$tmp" "" accepts)"
    T_PORT="$(toml_get "$tmp" "" port)"
    T_PSK="$(toml_get "$tmp" "" psk)"
    T_CARRIERS="$(toml_get "$tmp" "" carriers)"
    T_WINDOW="$(toml_get "$tmp" "" window_kb)"
    T_KEEPALIVE="$(toml_get "$tmp" "" keepalive)"
    T_PRESET="$(toml_get "$tmp" "" profile)"
    T_FORWARDER="$(toml_get "$tmp" "" forwarder)"; : "${T_FORWARDER:=pingify}"
    local suggested; suggested="$(toml_get "$tmp" "" suggest_ip)"
    if [ "$T_MODE" = "tun" ]; then
        T_TUNIF="$(toml_get "$tmp" "" tun_if)"
        T_TUNLOCAL="$(toml_get "$tmp" "" tun_local)"
        T_TUNPEER="$(toml_get "$tmp" "" tun_peer)"
        T_TUNMTU="$(toml_get "$tmp" "" tun_mtu)"
    fi
    T_PUBLIC_IP="$SRV_IP"
    rm -f "$tmp"

    if [ -z "$T_NAME" ] || [ -z "$T_PSK" ]; then
        fail "the token is incomplete"
        pause; return 1
    fi

    say ""
    ok "this server will be the $(side_label "$T_ROLE") end"
    dim "tunnel $T_NAME  ${BX_DOT}  $(transport_label "$T_TRANSPORT")  ${BX_DOT}  $(mode_label "$T_MODE")"

    # The address of the other server is the one thing a token cannot know for
    # certain, so it is always confirmed here.
    if ! this_side_accepts; then
        head2 "The other server"
        [ -n "$suggested" ] && dim "it reported its address as $suggested"
        say ""
        ask T_PEER_IP "address of the $(side_label "$T_ACCEPTS") server" "$suggested"
        if [ -z "$T_PEER_IP" ] || [ "$T_PEER_IP" = "unknown" ]; then
            fail "an address is required"
            pause; return 1
        fi
    fi

    # Ports belong to whichever end the clients connect to, and only there.
    if [ "$T_MODE" = "forward" ] && [ "$T_ROLE" = "server" ]; then
        head2 "Ports"
        dim "443            same port on both servers"
        dim "443=8443       clients hit 443 here, it lands on 8443 there"
        dim "udp:500        a UDP port"
        say ""
        local raw=""
        ask raw "ports clients will connect to, comma separated" "443"
        T_FORWARDS="$(parse_forwards "$raw")"
        [ -n "$T_FORWARDS" ] || { fail "at least one port is required"; pause; return 1; }
    fi

    if [ -f "$(cfg_file "$T_NAME")" ]; then
        say ""
        warn "a tunnel named $T_NAME already exists on this server"
        confirm "replace it?" || return 1
        systemctl stop "pingify@$T_NAME" >/dev/null 2>&1
    fi

    T_STATUS="127.0.0.1:$(pick_free_port 9700)"
    local file; file="$(cfg_save)"
    if ! "$CORE_BIN" -c "$file" -check >/dev/null 2>&1; then
        say ""
        fail "the core rejected this configuration"
        "$CORE_BIN" -c "$file" -check 2>&1 | sed 's/^/      /'
        rm -f "$file"
        pause; return 1
    fi

    write_units
    service_enable_start "$T_NAME"
    enable_watchdog quiet
    [ "$T_FORWARDER" = "iptables" ] && apply_nat quiet
    say ""
    ok "$T_NAME is running"
    dim "config: $file"
    say ""
    tunnel_status_block "$T_NAME"
    pause
}
