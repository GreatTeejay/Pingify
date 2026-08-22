
# ---------------------------------------------------------------------------
# tunnel configuration
# ---------------------------------------------------------------------------

# The T_* variables below describe one tunnel while the wizard runs.
cfg_reset() {
    T_NAME=""; T_ROLE=""; T_MODE="forward"; T_TRANSPORT="direct"
    T_LISTEN=""; T_CONNECT=""; T_PSK=""; T_PUBLIC_IP=""
    T_CARRIERS=4; T_WINDOW=512; T_KEEPALIVE=10
    T_FORWARDS=""; T_STATUS=""
    T_TUNIF="pfy0"; T_TUNLOCAL=""; T_TUNPEER=""; T_TUNMTU=1380
}

# cfg_render <role> <mode> <listen> <connect> <forwards-json> <status-addr>
# Prints one config document. Every key sits on its own line, which is what
# lets the manager read these files back with sed instead of a JSON parser.
# A config should read like a description of the tunnel, not a bag of keys.
# Each section is one question about how this end is set up, and the sections
# come in the order you would explain it to somebody: what it is, how it
# travels, what protects it, what it carries, and how it behaves.
#
# Only what applies is written. A forward tunnel has no [tun] section at all
# rather than an empty one, so nothing on the page is there to be ignored.
cfg_render() {
    local role="$1" mode="$2" listen="$3" connect="$4" fwd="$5" status="$6"
    printf '# Pingify tunnel - written by the manager, safe to edit by hand.
'
    printf '# Both servers need the same psk; everything else is local to this one.
'

    printf '
[tunnel]
'
    printf '%-16s = "%s"
' name "$T_NAME"
    printf '%-16s = "%s"   # server = IRAN, client = KHAREJ
' role "$role"
    printf '%-16s = "%s"   # forward = ports, tun = a private layer-3 link
' mode "$mode"

    printf '
[transport]
'
    printf '%-16s = "%s"
' type "$T_TRANSPORT"
    [ -n "$listen" ]  && printf '%-16s = "%s"   # this end accepts the carriers
' listen "$listen"
    [ -n "$connect" ] && printf '%-16s = "%s"   # this end dials them
' connect "$connect"
    printf '%-16s = %s   # connections the tunnel is spread over
' carriers "$T_CARRIERS"
    printf '%-16s = %s   # how often this end speaks when idle
' keepalive_sec "$T_KEEPALIVE"

    printf '
[security]
'
    printf '%-16s = "%s"
' psk "$T_PSK"

    if [ -n "$fwd" ]; then
        printf '
[forward]
'
        printf '# 443            the same port on both servers
'
        printf '# 443=8443       clients hit 443 here, it lands on 8443 there
'
        printf '# udp:500        a UDP port
'
        printf '%-16s = [%s]
' ports "$fwd"
    fi

    if [ "$mode" = "tun" ]; then
        local lo="$T_TUNLOCAL" pe="$T_TUNPEER"
        if [ "$role" != "$T_ROLE" ]; then
            local pfx="${T_TUNLOCAL##*/}"
            [ "$pfx" = "$T_TUNLOCAL" ] && pfx=30
            lo="$T_TUNPEER/$pfx"
            pe="${T_TUNLOCAL%%/*}"
        fi
        printf '
[tun]
'
        printf '%-16s = "%s"
' name "$T_TUNIF"
        printf '%-16s = "%s"   # this server, on the private link
' local_addr "$lo"
        printf '%-16s = "%s"   # the other one
' remote_addr "$pe"
        printf '%-16s = %s
' mtu "$T_TUNMTU"
    fi

    printf '
[tuning]
'
    printf '%-16s = %s   # in flight per forwarded connection
' window_kb "$T_WINDOW"

    printf '
[status]
'
    printf '%-16s = "%s"
' addr "$status"

    printf '
[logging]
'
    printf '%-16s = "info"   # error, warn, info, debug
' level
}

cfg_save() {
    local file="$(cfg_file "$T_NAME")"
    cfg_render "$T_ROLE" "$T_MODE" "$T_LISTEN" "$T_CONNECT" "$T_FORWARDS" "$T_STATUS" > "$file"
    chmod 600 "$file"
    printf '%s' "$file"
}

# The peer document is this one mirrored: the sides swap, and whichever end
# dials becomes the end that listens.
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

# Friendly names for the values stored in the config.
side_label()      { [ "$1" = "server" ] && printf 'IRAN' || printf 'KHAREJ'; }
mode_label()      { [ "$1" = "tun" ] && printf 'Full IP' || printf 'Ports'; }
transport_label() { case "$1" in direct) printf 'Direct' ;; *) printf '%s' "$1" ;; esac; }

# ---------------------------------------------------------------------------
# new tunnel
# ---------------------------------------------------------------------------

new_tunnel() {
    banner
    head2 "New Tunnel"
    ensure_core || { pause; return 1; }

    item 1 "Configure this server" "you will get a token for the other one"
    item 2 "Apply a token" "paste what the other server gave you"
    say ""
    local choice=""
    ask choice "select" "1"
    [ "$choice" = "2" ] && { import_tunnel; return; }

    cfg_reset

    # -- 1. identity -------------------------------------------------------
    head2 "1/7   Tunnel name"
    dim "used for the service name and the config file; letters and digits"
    say ""
    local suggested="pfy$(( $(tunnel_count) + 1 ))"
    while :; do
        ask T_NAME "name" "$suggested"
        case "$T_NAME" in
            "" | *[!a-zA-Z0-9_-]*)
                fail "letters, digits, dash and underscore only" ;;
            *)
                if [ -f "$(cfg_file "$T_NAME")" ]; then
                    fail "a tunnel named $T_NAME already exists"
                else
                    break
                fi ;;
        esac
    done

    # -- 2. which end is this ----------------------------------------------
    head2 "2/7   This server"
    item 1 "Iran" "clients connect to this server"
    item 2 "Kharej" "the panel and inbounds run on this server"
    say ""
    local side=""
    ask side "select" "1"
    [ "$side" = "2" ] && T_ROLE="client" || T_ROLE="server"

    # -- 3. link direction and endpoint ------------------------------------
    head2 "3/7   Link direction"
    dim "the tunnel is one link; only one end has to accept connections"
    say ""
    item 1 "Outbound" "this server connects to the other one"
    item 2 "Inbound" "the other one connects in; needs an open port"
    say ""
    local dir=""
    ask dir "select" "1"

    local tport=""
    say ""
    if [ "$dir" = "2" ]; then
        ask tport "listen port" "9443"
        T_LISTEN="0.0.0.0:$tport"
        port_free "$tport" || warn "port $tport is already in use on this server"
        T_PUBLIC_IP="$(public_ip)"
        ask T_PUBLIC_IP "public address of this server" "${T_PUBLIC_IP:-}"
    else
        local peer=""
        ask peer "address of the other server"
        [ -n "$peer" ] || { fail "an address is required"; pause; return 1; }
        ask tport "port on the other server" "9443"
        T_CONNECT="$peer:$tport"
    fi

    # -- 4. key ------------------------------------------------------------
    head2 "4/7   Shared key"
    dim "both servers authenticate with the same key; the token carries it"
    say ""
    item 1 "Generate" "recommended"
    item 2 "Enter an existing key" "if you already have one"
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

    # -- 5. transport ------------------------------------------------------
    head2 "5/7   Protocol"
    dim "how the link itself travels between the two servers"
    say ""
    item 1 "Direct" "encrypted stream, no wrapper - fastest"
    say ""
    dim "TLS and WebSocket are planned; Direct is the only one in this build"
    say ""
    local tr=""
    ask tr "select" "1"
    T_TRANSPORT="direct"

    # -- 6. payload --------------------------------------------------------
    head2 "6/7   What the tunnel carries"
    item 1 "Ports" "forward TCP and UDP ports - panels, inbounds"
    item 2 "Full IP" "a private layer-3 link between the two servers"
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
        dim "this server takes ${T_TUNLOCAL}, the other one takes ${T_TUNPEER}"
    else
        T_MODE="forward"
        dim "port           same port on both servers"
        dim "443=8443       arrives on 443 here, reaches 8443 there"
        dim "udp:500        a UDP port"
        dim "8000-8010      a range"
        say ""
        local raw=""
        ask raw "ports on the Iran server, comma separated" "443"
        T_FORWARDS="$(parse_forwards "$raw")"
        [ -n "$T_FORWARDS" ] || { fail "at least one port is required"; pause; return 1; }
    fi

    # -- 7. performance ----------------------------------------------------
    head2 "7/7   Performance"
    dim "carriers are the parallel connections the link runs over; more of"
    dim "them absorb packet loss better, 4 to 8 suits most paths"
    say ""
    if confirm "change the defaults? (carriers ${T_CARRIERS}, window ${T_WINDOW} KB)"; then
        say ""
        ask T_CARRIERS "carriers" "$T_CARRIERS"
        ask T_WINDOW "window per stream in KB" "$T_WINDOW"
        ask T_KEEPALIVE "keepalive seconds" "$T_KEEPALIVE"
    fi
    case "$T_CARRIERS" in "" | *[!0-9]*) T_CARRIERS=4 ;; esac
    case "$T_WINDOW" in "" | *[!0-9]*) T_WINDOW=512 ;; esac
    case "$T_KEEPALIVE" in "" | *[!0-9]*) T_KEEPALIVE=10 ;; esac
    [ "$T_CARRIERS" -lt 1 ] && T_CARRIERS=1
    [ "$T_CARRIERS" -gt 64 ] && T_CARRIERS=64

    T_STATUS="127.0.0.1:$(pick_free_port 9700)"

    # -- review ------------------------------------------------------------
    banner
    head2 "Review"
    box_top
    box_row "$(pad_to "tunnel" 14)${C_B}${T_NAME}${C_OFF}"
    box_row "$(pad_to "this server" 14)$(side_label "$T_ROLE")"
    box_row "$(pad_to "link" 14)$([ -n "$T_CONNECT" ] && echo "outbound to $T_CONNECT" || echo "inbound on $T_LISTEN")"
    box_row "$(pad_to "protocol" 14)$(transport_label "$T_TRANSPORT")"
    box_row "$(pad_to "carries" 14)$(mode_label "$T_MODE")"
    if [ "$T_MODE" = "forward" ]; then
        box_row "$(pad_to "ports" 14)$(printf '%s' "$T_FORWARDS" | tr -d '"' | tr ',' ' ')"
    else
        box_row "$(pad_to "addresses" 14)${T_TUNLOCAL} ${BX_ARR} ${T_TUNPEER}"
    fi
    box_row "$(pad_to "carriers" 14)${T_CARRIERS}"
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
    ok "$T_NAME is configured and running"

    # -- token -------------------------------------------------------------
    head2 "Token for the other server"
    dim "on the ${C_OFF}$( [ "$T_ROLE" = "server" ] && echo KHAREJ || echo IRAN )${C_DIM} server: New Tunnel ${BX_ARR} Apply a token"
    say ""
    rule
    printf '%s\n' "${C_YEL}$(cfg_peer_token)${C_OFF}"
    rule
    say ""
    warn "treat it like a password - it contains the shared key"
    say ""
    tunnel_status_block "$T_NAME"
    pause
}

# ---------------------------------------------------------------------------
# apply a token
# ---------------------------------------------------------------------------

import_tunnel() {
    head2 "Apply a token"
    dim "configure the other server first; it prints the token at the end"
    say ""
    local token=""
    ask token "token"
    [ -n "$token" ] || return 1

    local tmp="/tmp/pingify-import.cfg"
    if ! printf '%s' "$token" | base64 -d > "$tmp" 2>/dev/null; then
        fail "that is not a Pingify token"
        pause; return 1
    fi
    local name; name="$(json_str "$tmp" name)"
    if [ -z "$name" ]; then
        fail "the token is incomplete"
        rm -f "$tmp"; pause; return 1
    fi

    if [ -f "$(cfg_file "$name")" ]; then
        say ""
        warn "a tunnel named $name already exists on this server"
        confirm "replace it?" || { rm -f "$tmp"; return 1; }
        systemctl stop "pingify@$name" >/dev/null 2>&1
    fi

    # The status port chosen on the other server may be taken here.
    local sp; sp="$(json_str "$tmp" status_addr)"
    sed -i "s#\"status_addr\": \"[^\"]*\"#\"status_addr\": \"127.0.0.1:$(pick_free_port "${sp##*:}")\"#" "$tmp"

    # A token that dials needs the address of the server that issued it.
    local conn; conn="$(json_str "$tmp" connect)"
    if [ -n "$conn" ]; then
        case "${conn%%:*}" in
            "" | "0.0.0.0")
                say ""
                local ip=""
                ask ip "public address of the other server"
                sed -i "s#\"connect\": \"[^\"]*\"#\"connect\": \"$ip:${conn##*:}\"#" "$tmp" ;;
        esac
    fi

    install -m 600 "$tmp" "$(cfg_file "$name")"
    rm -f "$tmp"

    if ! "$CORE_BIN" -c "$(cfg_file "$name")" -check >/dev/null 2>&1; then
        say ""
        fail "the core rejected this configuration"
        "$CORE_BIN" -c "$(cfg_file "$name")" -check 2>&1 | sed 's/^/      /'
        rm -f "$(cfg_file "$name")"
        pause; return 1
    fi

    write_units
    service_enable_start "$name"
    enable_watchdog quiet
    say ""
    ok "$name is configured and running"
    say ""
    tunnel_status_block "$name"
    pause
}
