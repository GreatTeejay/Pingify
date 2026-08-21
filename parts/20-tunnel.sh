
# ---------------------------------------------------------------------------
# tunnel configuration
# ---------------------------------------------------------------------------

# All of the T_* variables below describe one tunnel while the wizard runs.
cfg_reset() {
    T_NAME=""; T_ROLE=""; T_MODE="forward"
    T_LISTEN=""; T_CONNECT=""; T_PSK=""
    T_CARRIERS=4; T_WINDOW=1024; T_KEEPALIVE=10
    T_FORWARDS=""; T_STATUS=""
    T_TUNIF="pfy0"; T_TUNLOCAL=""; T_TUNPEER=""; T_TUNMTU=1380
}

# cfg_render <role> <mode> <listen> <connect> <forwards-json> <status-addr>
# Prints one config document. Keeping every key on its own line is what lets
# the manager read these files back with sed instead of a JSON parser.
cfg_render() {
    local role="$1" mode="$2" listen="$3" connect="$4" fwd="$5" status="$6"
    printf '{\n'
    printf '  "name": "%s",\n' "$T_NAME"
    printf '  "role": "%s",\n' "$role"
    printf '  "mode": "%s",\n' "$mode"
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

# The peer document is this one mirrored: roles swap, and whichever side dials
# becomes the side that listens.
cfg_peer_token() {
    local prole plisten pconnect pfwd
    if [ "$T_ROLE" = "edge" ]; then prole="origin"; else prole="edge"; fi
    if [ -n "$T_CONNECT" ]; then
        plisten="0.0.0.0:${T_CONNECT##*:}"; pconnect=""
    else
        plisten=""; pconnect="${T_PUBLIC_IP}:${T_LISTEN##*:}"
    fi
    if [ "$prole" = "edge" ]; then pfwd="$T_FORWARDS"; else pfwd=""; fi
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

# ---------------------------------------------------------------------------
# new tunnel wizard
# ---------------------------------------------------------------------------

new_tunnel() {
    banner
    head2 "Config New Tunnel"
    ensure_core || { pause; return 1; }

    item 1 "Start from scratch" "set the tunnel up here first"
    item 2 "Join with a token" "paste what the other server printed"
    say ""
    local choice=""
    ask choice "choose" "1"
    if [ "$choice" = "2" ]; then import_tunnel; return; fi

    cfg_reset

    # --- name ------------------------------------------------------------
    head2 "Step 1 of 7   Name"
    local suggested="pfy$(( $(tunnel_count) + 1 ))"
    while :; do
        ask T_NAME "tunnel name" "$suggested"
        case "$T_NAME" in
            *[!a-zA-Z0-9_-]*|"") fail "letters, digits, dash and underscore only" ;;
            *) [ -f "$CFG_DIR/$T_NAME.json" ] && { fail "a tunnel called $T_NAME already exists"; continue; }
               break ;;
        esac
    done

    # --- which server is this --------------------------------------------
    head2 "Step 2 of 7   Which server is this?"
    item 1 "Iran server" "your users connect here"
    item 2 "Kharej server" "the panel / real services live here"
    say ""
    local side=""
    ask side "choose" "1"
    if [ "$side" = "2" ]; then T_ROLE="origin"; else T_ROLE="edge"; fi

    # --- who dials whom ---------------------------------------------------
    head2 "Step 3 of 7   Which server opens the connection?"
    item 1 "This one dials out to the peer" "best when inbound here is filtered"
    item 2 "This one waits for the peer" "needs an open port on this server"
    say ""
    local dial=""
    ask dial "choose" "1"

    local tport=""
    if [ "$dial" = "2" ]; then
        ask tport "port to listen on for the tunnel" "9443"
        T_LISTEN="0.0.0.0:$tport"
        T_PUBLIC_IP="$(public_ip)"
        say ""
        ask T_PUBLIC_IP "public IP of THIS server (the peer will dial it)" "${T_PUBLIC_IP:-}"
        if ! port_free "$tport"; then warn "something is already listening on port $tport"; fi
    else
        local peer=""
        ask peer "IP or hostname of the peer server"
        [ -n "$peer" ] || { fail "the peer address cannot be empty"; pause; return 1; }
        ask tport "tunnel port on the peer" "9443"
        T_CONNECT="$peer:$tport"
    fi

    # --- shared key -------------------------------------------------------
    head2 "Step 4 of 7   Shared key"
    dim "the same key has to end up on both servers"
    say ""
    local kmode=""
    item 1 "Generate a new one"
    item 2 "Paste the key from the other server"
    say ""
    ask kmode "choose" "1"
    if [ "$kmode" = "2" ]; then
        ask T_PSK "key (hex)"
    else
        T_PSK="$("$CORE_BIN" -genpsk)"
    fi
    case "$T_PSK" in
        *[!0-9a-fA-F]*|"") fail "that is not a hex key"; pause; return 1 ;;
    esac

    # --- mode -------------------------------------------------------------
    head2 "Step 5 of 7   What should the tunnel carry?"
    item 1 "Ports" "forward TCP/UDP ports (panels, inbounds)"
    item 2 "Full IP" "a layer-3 link between the two servers"
    say ""
    local m=""
    ask m "choose" "1"
    if [ "$m" = "2" ]; then
        T_MODE="tun"
        local sub=""
        ask sub "private /30 subnet index (0-63)" "1"
        T_TUNIF="pfy${sub}"
        if [ "$T_ROLE" = "edge" ]; then
            T_TUNLOCAL="10.71.${sub}.1/30"; T_TUNPEER="10.71.${sub}.2"
        else
            T_TUNLOCAL="10.71.${sub}.2/30"; T_TUNPEER="10.71.${sub}.1"
        fi
        ask T_TUNMTU "MTU" "1380"
    else
        T_MODE="forward"
    fi

    # --- forwarded ports --------------------------------------------------
    if [ "$T_MODE" = "forward" ]; then
        head2 "Step 6 of 7   Which ports should users reach?"
        dim "examples:  443       same port on both sides"
        dim "           443=8443  arrives on 443, lands on 8443 over there"
        dim "           udp:500   a UDP port"
        dim "           8000-8010 a whole range"
        say ""
        local raw=""
        ask raw "ports (comma separated)" "443"
        T_FORWARDS="$(parse_forwards "$raw")"
        [ -n "$T_FORWARDS" ] || { fail "at least one port is needed"; pause; return 1; }
    fi

    # --- tuning -----------------------------------------------------------
    head2 "Step 7 of 7   Tuning"
    if confirm "tune the advanced settings? (carriers, window, keepalive)"; then
        say ""
        dim "Carriers are the parallel TCP connections the tunnel runs over."
        dim "More of them ride out packet loss better; 4 to 8 suits most links."
        ask T_CARRIERS "carriers" "4"
        dim "The window is how much data may be in flight per connection."
        ask T_WINDOW "window (KB)" "1024"
        ask T_KEEPALIVE "keepalive (seconds)" "10"
    fi
    case "$T_CARRIERS" in ''|*[!0-9]*) T_CARRIERS=4 ;; esac
    [ "$T_CARRIERS" -lt 1 ] && T_CARRIERS=1
    [ "$T_CARRIERS" -gt 64 ] && T_CARRIERS=64

    T_STATUS="127.0.0.1:$(pick_free_port 9700)"

    # --- write, validate, start -------------------------------------------
    local file; file="$(cfg_save)"
    if ! "$CORE_BIN" -c "$file" -check >/dev/null 2>&1; then
        fail "the generated config was rejected:"
        "$CORE_BIN" -c "$file" -check 2>&1 | sed 's/^/    /'
        rm -f "$file"
        pause; return 1
    fi

    write_units
    service_enable_start "$T_NAME"
    ok "tunnel ${C_B}$T_NAME${C_OFF} created and started"

    enable_watchdog quiet

    say ""
    head2 "Now set up the other server"
    dim "Install Pingify over there, pick Config New Tunnel then \"Join with a"
    dim "token\", and paste the line below. It carries every matching setting"
    dim "and the shared key, so there is nothing else to type."
    say ""
    # Printed bare rather than inside a box: the token is long enough to wrap,
    # and a box border would end up copied along with it.
    rule
    printf '%s\n' "${C_YEL}$(cfg_peer_token)${C_OFF}"
    rule
    say ""
    warn "keep it private - anyone holding it can join your tunnel"
    say ""
    tunnel_status_block "$T_NAME"
    pause
}

# ---------------------------------------------------------------------------
# import from a peer token
# ---------------------------------------------------------------------------

import_tunnel() {
    head2 "Join with a token"
    dim "run Config New Tunnel on the other server first; it prints the token"
    say ""
    local token=""
    ask token "token"
    [ -n "$token" ] || return 1

    local tmp="/tmp/pingify-import.json"
    if ! printf '%s' "$token" | base64 -d > "$tmp" 2>/dev/null; then
        fail "that does not look like a Pingify token"
        pause; return 1
    fi
    local name; name="$(json_str "$tmp" name)"
    [ -n "$name" ] || { fail "the token has no tunnel name in it"; rm -f "$tmp"; pause; return 1; }

    if [ -f "$CFG_DIR/$name.json" ]; then
        warn "a tunnel called $name already exists here"
        confirm "overwrite it?" || { rm -f "$tmp"; return 1; }
        systemctl stop "pingify@$name" >/dev/null 2>&1
    fi

    # The status port from the far server may already be taken here.
    local sp; sp="$(json_str "$tmp" status_addr)"
    local newsp="127.0.0.1:$(pick_free_port "${sp##*:}")"
    sed -i "s#\"status_addr\": \"[^\"]*\"#\"status_addr\": \"$newsp\"#" "$tmp"

    # A dialling side needs the peer address; a listening side does not.
    local conn; conn="$(json_str "$tmp" connect)"
    if [ -n "$conn" ]; then
        case "${conn%%:*}" in
            ""|"0.0.0.0")
                local ip=""
                ask ip "public IP of the OTHER server"
                sed -i "s#\"connect\": \"[^\"]*\"#\"connect\": \"$ip:${conn##*:}\"#" "$tmp" ;;
        esac
    fi

    install -m 600 "$tmp" "$CFG_DIR/$name.json"
    rm -f "$tmp"

    if ! "$CORE_BIN" -c "$CFG_DIR/$name.json" -check >/dev/null 2>&1; then
        fail "the imported config was rejected:"
        "$CORE_BIN" -c "$CFG_DIR/$name.json" -check 2>&1 | sed 's/^/    /'
        rm -f "$CFG_DIR/$name.json"
        pause; return 1
    fi

    write_units
    service_enable_start "$name"
    enable_watchdog quiet
    ok "tunnel ${C_B}$name${C_OFF} imported and started"
    say ""
    tunnel_status_block "$name"
    pause
}
