
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
    T_NAME=""; T_ROLE=""; T_MODE="forward"; T_TRANSPORT="direct"
    T_LISTEN=""; T_CONNECT=""; T_PSK=""; T_PUBLIC_IP=""
    T_CARRIERS=4; T_WINDOW=512; T_KEEPALIVE=10; T_PRESET="balanced"
    T_FORWARDS=""; T_STATUS=""
    T_TUNIF="pfy0"; T_TUNLOCAL=""; T_TUNPEER=""; T_TUNMTU=1380
}

# ---------------------------------------------------------------------------
# performance presets
#
# carriers  how many TCP connections the link is spread over. More of them
#           absorb packet loss better, because one stalled connection is a
#           smaller share of the total.
# window    how much data one forwarded connection may have in flight. Bigger
#           fills a long path better; it is also the memory ceiling per open
#           connection.
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

# cfg_render <role> <mode> <listen> <connect> <forwards-json> <status-addr>
# Every key sits on its own line, which is what lets the manager read these
# files back with sed instead of a JSON parser.
cfg_render() {
    local role="$1" mode="$2" listen="$3" connect="$4" fwd="$5" status="$6"
    printf '{\n'
    printf '  "name": "%s",\n' "$T_NAME"
    printf '  "role": "%s",\n' "$role"
    printf '  "mode": "%s",\n' "$mode"
    printf '  "transport": "%s",\n' "$T_TRANSPORT"
    [ -n "$listen" ]  && printf '  "listen": "%s",\n' "$listen"
    [ -n "$connect" ] && printf '  "connect": "%s",\n' "$connect"
    printf '  "psk": "%s",\n' "$T_PSK"
    printf '  "carriers": %s,\n' "$T_CARRIERS"
    printf '  "window_kb": %s,\n' "$T_WINDOW"
    printf '  "keepalive_sec": %s,\n' "$T_KEEPALIVE"
    [ -n "$fwd" ] && printf '  "forwards": [%s],\n' "$fwd"
    if [ "$mode" = "tun" ]; then
        local lo="$T_TUNLOCAL" pe="$T_TUNPEER"
        if [ "$role" != "$T_ROLE" ]; then
            local pfx="${T_TUNLOCAL##*/}"
            [ "$pfx" = "$T_TUNLOCAL" ] && pfx=30
            lo="$T_TUNPEER/$pfx"
            pe="${T_TUNLOCAL%%/*}"
        fi
        printf '  "tun": { "name": "%s", "local": "%s", "peer": "%s", "mtu": %s },\n' \
               "$T_TUNIF" "$lo" "$pe" "$T_TUNMTU"
    fi
    printf '  "status_addr": "%s",\n' "$status"
    printf '  "log_level": "info"\n'
    printf '}\n'
}

cfg_save() {
    local file="$CFG_DIR/$T_NAME.json"
    cfg_render "$T_ROLE" "$T_MODE" "$T_LISTEN" "$T_CONNECT" "$T_FORWARDS" "$T_STATUS" > "$file"
    chmod 600 "$file"
    printf '%s' "$file"
}

# The peer document is this one mirrored: the roles swap, and whichever end
# accepts the link becomes the end that dials it.
cfg_peer_token() {
    local prole plisten pconnect pfwd
    if [ "$T_ROLE" = "server" ]; then prole="client"; else prole="server"; fi
    if [ -n "$T_CONNECT" ]; then
        plisten="0.0.0.0:${T_CONNECT##*:}"; pconnect=""
    else
        plisten=""; pconnect="${T_PUBLIC_IP}:${T_LISTEN##*:}"
    fi
    if [ "$prole" = "server" ]; then pfwd="$T_FORWARDS"; else pfwd=""; fi
    cfg_render "$prole" "$T_MODE" "$plisten" "$pconnect" "$pfwd" "$T_STATUS" | base64 | tr -d '\n'
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
transport_label() { case "$1" in direct) printf 'Direct' ;; *) printf '%s' "$1" ;; esac; }

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
    [ -f "$CFG_DIR/main.json" ] && suggested="tunnel$(( $(tunnel_count) + 1 ))"
    while :; do
        ask T_NAME "tunnel name" "$suggested"
        case "$T_NAME" in
            "" | *[!a-zA-Z0-9_-]*) fail "letters, digits, dash and underscore only" ;;
            *)
                if [ -f "$CFG_DIR/$T_NAME.json" ]; then
                    fail "a tunnel named $T_NAME already exists here"
                else
                    break
                fi ;;
        esac
    done

    # -- endpoint ----------------------------------------------------------
    local tport=""
    if [ "$T_ROLE" = "server" ]; then
        head2 "Tunnel port"
        dim "the KHAREJ server connects to this port; open it in your firewall"
        say ""
        ask tport "port" "9443"
        T_LISTEN="0.0.0.0:$tport"
        port_free "$tport" || warn "something is already listening on $tport"
        T_PUBLIC_IP="$SRV_IP"
    else
        head2 "IRAN server"
        say ""
        local peer=""
        ask peer "address of the IRAN server"
        [ -n "$peer" ] || { fail "an address is required"; pause; return 1; }
        ask tport "tunnel port" "9443"
        T_CONNECT="$peer:$tport"
        T_PUBLIC_IP="$SRV_IP"
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

    # -- transport ---------------------------------------------------------
    head2 "Protocol"
    item 1 "Direct" "encrypted stream, no wrapper - fastest"
    say ""
    dim "TLS and WebSocket are planned; Direct is the only one in this build"
    say ""
    local tr=""
    ask tr "select" "1"
    T_TRANSPORT="direct"

    # -- payload -----------------------------------------------------------
    head2 "What the tunnel carries"
    item 1 "Ports" "forward TCP and UDP - panels, inbounds"
    item 2 "Full IP" "a private layer-3 link between the servers"
    say ""
    local m=""
    ask m "select" "1"
    say ""

    if [ "$m" = "2" ]; then
        T_MODE="tun"
        local sub=""
        ask sub "subnet index (0-63)" "1"
        case "$sub" in "" | *[!0-9]*) sub=1 ;; esac
        T_TUNIF="pfy${sub}"
        if [ "$T_ROLE" = "server" ]; then
            T_TUNLOCAL="10.71.${sub}.1/30"; T_TUNPEER="10.71.${sub}.2"
        else
            T_TUNLOCAL="10.71.${sub}.2/30"; T_TUNPEER="10.71.${sub}.1"
        fi
        ask T_TUNMTU "MTU" "1380"
    else
        T_MODE="forward"
        if [ "$T_ROLE" = "server" ]; then
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
            dim "the port list lives on the IRAN server, nothing to set here"
        fi
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
            if [ -n "$T_LISTEN" ]; then
                local a=""
                ask a "address of the other server"
                [ -n "$a" ] && { T_CONNECT="$a:${T_LISTEN##*:}"; T_LISTEN=""; }
            else
                T_LISTEN="0.0.0.0:${T_CONNECT##*:}"
                T_CONNECT=""
            fi
            ok "this server will $( [ -n "$T_LISTEN" ] && echo accept || echo open ) the link"
        fi
    fi

    # -- review ------------------------------------------------------------
    banner
    head2 "Review"
    box_top
    box_row "$(pad_to "Tunnel" 16)${C_B}${T_NAME}${C_OFF}"
    box_row "$(pad_to "This server" 16)$(side_label "$T_ROLE")  ${C_DIM}($(role_label "$T_ROLE"))${C_OFF}"
    if [ -n "$T_LISTEN" ]; then
        box_row "$(pad_to "Link" 16)accepts on ${T_LISTEN}"
    else
        box_row "$(pad_to "Link" 16)connects to ${T_CONNECT}"
    fi
    box_row "$(pad_to "Protocol" 16)$(transport_label "$T_TRANSPORT")"
    box_row "$(pad_to "Carries" 16)$(mode_label "$T_MODE")"
    if [ "$T_MODE" = "forward" ] && [ -n "$T_FORWARDS" ]; then
        box_row "$(pad_to "Ports" 16)$(printf '%s' "$T_FORWARDS" | tr -d '"' | tr ',' ' ')"
    elif [ "$T_MODE" = "tun" ]; then
        box_row "$(pad_to "Addresses" 16)${T_TUNLOCAL} ${BX_ARR} ${T_TUNPEER}"
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
    ok "$T_NAME is running"
    dim "config: $file"

    # -- token -------------------------------------------------------------
    head2 "Token for the $( [ "$T_ROLE" = "server" ] && echo KHAREJ || echo IRAN ) server"
    dim "run Pingify there and choose New tunnel ${BX_ARR} Apply a token"
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
    local token=""
    ask token "token"
    [ -n "$token" ] || return 1

    local tmp="/tmp/pingify-import.json"
    if ! printf '%s' "$token" | base64 -d > "$tmp" 2>/dev/null; then
        fail "that is not a Pingify token"
        pause; return 1
    fi
    local name; name="$(json_str "$tmp" name)"
    if [ -z "$name" ]; then
        fail "the token is incomplete"
        rm -f "$tmp"; pause; return 1
    fi

    if [ -f "$CFG_DIR/$name.json" ]; then
        say ""
        warn "a tunnel named $name already exists on this server"
        confirm "replace it?" || { rm -f "$tmp"; return 1; }
        systemctl stop "pingify@$name" >/dev/null 2>&1
    fi

    # The status port chosen on the other server may be taken here.
    local sp; sp="$(json_str "$tmp" status_addr)"
    sed -i "s#\"status_addr\": \"[^\"]*\"#\"status_addr\": \"127.0.0.1:$(pick_free_port "${sp##*:}")\"#" "$tmp"

    # A token that dials needs a real address for the server that issued it.
    local conn; conn="$(json_str "$tmp" connect)"
    if [ -n "$conn" ]; then
        case "${conn%%:*}" in
            "" | "0.0.0.0")
                say ""
                local ip=""
                ask ip "address of the other server"
                sed -i "s#\"connect\": \"[^\"]*\"#\"connect\": \"$ip:${conn##*:}\"#" "$tmp" ;;
        esac
    fi

    install -m 600 "$tmp" "$CFG_DIR/$name.json"
    rm -f "$tmp"

    if ! "$CORE_BIN" -c "$CFG_DIR/$name.json" -check >/dev/null 2>&1; then
        say ""
        fail "the core rejected this configuration"
        "$CORE_BIN" -c "$CFG_DIR/$name.json" -check 2>&1 | sed 's/^/      /'
        rm -f "$CFG_DIR/$name.json"
        pause; return 1
    fi

    write_units
    service_enable_start "$name"
    enable_watchdog quiet
    say ""
    ok "$name is running"
    dim "config: $CFG_DIR/$name.json"
    say ""
    tunnel_status_block "$name"
    pause
}
