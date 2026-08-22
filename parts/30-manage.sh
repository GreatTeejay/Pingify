
# ---------------------------------------------------------------------------
# reading an existing tunnel back
# ---------------------------------------------------------------------------

cfg_load() {
    local f="$CFG_DIR/$1.json"
    [ -f "$f" ] || return 1
    cfg_reset
    T_NAME="$(json_str "$f" name)"
    T_ROLE="$(json_str "$f" role)"
    T_MODE="$(json_str "$f" mode)"
    T_TRANSPORT="$(json_str "$f" transport)"; : "${T_TRANSPORT:=direct}"
    T_LISTEN="$(json_str "$f" listen)"
    T_CONNECT="$(json_str "$f" connect)"
    T_PSK="$(json_str "$f" psk)"
    T_STATUS="$(json_str "$f" status_addr)"
    T_CARRIERS="$(json_num "$f" carriers)";      : "${T_CARRIERS:=4}"
    T_WINDOW="$(json_num "$f" window_kb)";       : "${T_WINDOW:=1024}"
    T_KEEPALIVE="$(json_num "$f" keepalive_sec)"; : "${T_KEEPALIVE:=10}"
    T_FORWARDS="$(sed -n 's/^[[:space:]]*"forwards"[[:space:]]*:[[:space:]]*\[\(.*\)\],*[[:space:]]*$/\1/p' "$f" | head -n1)"
    if [ "$T_MODE" = "tun" ]; then
        local tl; tl="$(grep -m1 '"tun"' "$f")"
        T_TUNIF="$(printf '%s' "$tl"    | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
        T_TUNLOCAL="$(printf '%s' "$tl" | sed -n 's/.*"local"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
        T_TUNPEER="$(printf '%s' "$tl"  | sed -n 's/.*"peer"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
        T_TUNMTU="$(printf '%s' "$tl"   | sed -n 's/.*"mtu"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')"
        : "${T_TUNMTU:=1380}"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# status rendering
# ---------------------------------------------------------------------------

tunnel_status_block() {
    local name="$1" f="$CFG_DIR/$1.json"
    [ -f "$f" ] || { fail "no such tunnel: $name"; return 1; }
    local addr; addr="$(json_str "$f" status_addr)"
    local state; state="$(svc_state "$name")"

    local colour="$C_RED"
    [ "$state" = "active" ] && colour="$C_GRN"
    printf '  %s%s%s  service %s%s%s\n' \
        "$C_B" "$name" "$C_OFF" "$colour" "$state" "$C_OFF"
    if [ -n "$addr" ] && [ -x "$CORE_BIN" ]; then
        "$CORE_BIN" -status "$addr" 2>/dev/null || true
    fi
}

# One line per tunnel, for the overview table.
tunnel_row() {
    local name="$1" f="$CFG_DIR/$1.json"
    local role mode peer addr state brief up total rtt streams
    role="$(json_str "$f" role)"
    mode="$(json_str "$f" mode)"
    peer="$(json_str "$f" connect)"
    [ -z "$peer" ] && peer="on ${C_OFF}$(json_str "$f" listen)"
    addr="$(json_str "$f" status_addr)"
    state="$(svc_state "$name")"

    up="-"; total="$(json_num "$f" carriers)"; rtt="-"; streams="-"
    if [ "$state" = "active" ] && [ -n "$addr" ] && [ -x "$CORE_BIN" ]; then
        brief="$("$CORE_BIN" -status "$addr" -brief 2>/dev/null)"
        if [ -n "$brief" ]; then
            # state up total rtt streams uptime
            set -- $brief
            up="$2"; streams="$5"
            # An unreachable endpoint reports zeroes; keep the configured
            # carrier count so the column still says what was asked for.
            [ "$3" != "0" ] && total="$3"
            if [ "$1" = "up" ]; then rtt="${4}ms"; else rtt="-"; fi
        fi
    fi

    # Green only when the tunnel is running *and* a carrier is actually up:
    # a running process with no peer is the failure people most need to see.
    local dot="$C_GRY$BX_OFF$C_OFF"
    case "$state" in
        active)
            if [ "$up" != "0" ] && [ "$up" != "-" ]; then dot="$C_GRN$BX_ON$C_OFF"
            else dot="$C_YEL$BX_ON$C_OFF"; fi ;;
        stopped)  dot="$C_YEL$BX_OFF$C_OFF" ;;
        disabled) dot="$C_GRY$BX_OFF$C_OFF" ;;
    esac

    printf '  %s %s %s %s %s %s%s%s\n' \
        "$dot" \
        "$(pad_to "${C_B}${name}${C_OFF}" 13)" \
        "$(pad_to "$role" 7)" \
        "$(pad_to "$mode" 8)" \
        "$(pad_to "$up/$total" 6)" \
        "$C_DIM" "$rtt" "$C_OFF"
}

list_tunnels() {
    local names; names="$(tunnel_names)"
    if [ -z "$names" ]; then
        dim "no tunnels configured yet - pick Config New Tunnel to make one"
        return 1
    fi
    printf '    %s%s %s %s %s %s%s\n' \
        "$C_DIM" \
        "$(pad_to "NAME" 13)" \
        "$(pad_to "ROLE" 7)" \
        "$(pad_to "MODE" 8)" \
        "$(pad_to "LINKS" 6)" \
        "RTT" "$C_OFF"
    local n
    for n in $names; do tunnel_row "$n"; done
    return 0
}

# ---------------------------------------------------------------------------
# manage tunnels
# ---------------------------------------------------------------------------

pick_tunnel() {
    local names; names="$(tunnel_names)"
    [ -n "$names" ] || { dim "no tunnels configured yet"; return 1; }
    local i=0 n
    say ""
    for n in $names; do
        i=$((i + 1))
        item "$i" "$n" "$(svc_state "$n")"
    done
    item 0 "Back"
    say ""
    local sel=""
    ask sel "select" "1"
    [ "$sel" = "0" ] && return 1
    case "$sel" in ''|*[!0-9]*) return 1 ;; esac
    PICKED="$(printf '%s\n' $names | sed -n "${sel}p")"
    [ -n "$PICKED" ]
}

manage_tunnels() {
    while :; do
        banner
        head2 "Manage Tunnels"
        list_tunnels || { pause; return; }
        if ! pick_tunnel; then return; fi
        tunnel_menu "$PICKED"
    done
}

tunnel_menu() {
    local name="$1"
    while :; do
        banner
        head2 "Tunnel: $name"
        tunnel_status_block "$name"
        rule
        item 1 "Restart"
        item 2 "Stop"
        item 3 "Start"
        item 4 "Live log"
        item 5 "Edit forwarded ports"
        item 6 "Performance settings"
        item 7 "Show the token again"
        item 8 "Scheduled restart"
        item 9 "Delete this tunnel"
        item 0 "Back"
        say ""
        local c=""
        ask c "select"
        case "$c" in
            1) systemctl restart "pingify@$name"; ok "restarted"; sleep 1 ;;
            2) systemctl stop "pingify@$name"; ok "stopped"; sleep 1 ;;
            3) systemctl start "pingify@$name"; ok "started"; sleep 1 ;;
            4) say ""; dim "ctrl-c to stop following"; say ""
               journalctl -u "pingify@$name" -n 60 -f --no-pager || true ;;
            5) edit_forwards "$name" ;;
            6) edit_tuning "$name" ;;
            7) show_peer_token "$name" ;;
            8) recycle_menu "$name" ;;
            9) delete_tunnel "$name" && return ;;
            0|"") return ;;
        esac
    done
}

edit_forwards() {
    local name="$1" f="$CFG_DIR/$1.json"
    cfg_load "$name" || return 1
    if [ "$T_MODE" != "forward" ]; then
        warn "this is a full-IP tunnel; it has no port list"
        pause; return
    fi
    if [ "$T_ROLE" != "server" ]; then
        warn "ports are configured on the Iran side; this server is the Kharej end"
        pause; return
    fi
    say ""
    dim "current: $(printf '%s' "$T_FORWARDS" | tr -d '"')"
    say ""
    local raw=""
    ask raw "new port list (comma separated)"
    [ -n "$raw" ] || return
    local fwd; fwd="$(parse_forwards "$raw")"
    [ -n "$fwd" ] || { fail "nothing to set"; pause; return; }

    cp -f "$f" "$f.bak"
    if grep -q '"forwards"' "$f"; then
        sed -i "s#^\([[:space:]]*\"forwards\"[[:space:]]*:[[:space:]]*\).*#\1[$fwd],#" "$f"
    else
        sed -i "s#^\([[:space:]]*\"psk\".*\)#\1\n  \"forwards\": [$fwd],#" "$f"
    fi
    if "$CORE_BIN" -c "$f" -check >/dev/null 2>&1; then
        rm -f "$f.bak"
        systemctl restart "pingify@$name"
        ok "ports updated and the tunnel restarted"
    else
        mv -f "$f.bak" "$f"
        fail "that port list was rejected, nothing changed"
    fi
    pause
}

edit_tuning() {
    local name="$1" f="$CFG_DIR/$1.json"
    cfg_load "$name" || return 1
    say ""
    local car win ka
    ask car "carriers" "$T_CARRIERS"
    ask win "window (KB)" "$T_WINDOW"
    ask ka  "keepalive (seconds)" "$T_KEEPALIVE"
    case "$car$win$ka" in *[!0-9]*) fail "numbers only"; pause; return ;; esac

    cp -f "$f" "$f.bak"
    sed -i "s#^\([[:space:]]*\"carriers\"[[:space:]]*:[[:space:]]*\).*#\1$car,#" "$f"
    sed -i "s#^\([[:space:]]*\"window_kb\"[[:space:]]*:[[:space:]]*\).*#\1$win,#" "$f"
    sed -i "s#^\([[:space:]]*\"keepalive_sec\"[[:space:]]*:[[:space:]]*\).*#\1$ka,#" "$f"
    if "$CORE_BIN" -c "$f" -check >/dev/null 2>&1; then
        rm -f "$f.bak"
        systemctl restart "pingify@$name"
        ok "updated and restarted"
        warn "set the same carrier count on the other server too"
    else
        mv -f "$f.bak" "$f"
        fail "rejected, nothing changed"
    fi
    pause
}

show_peer_token() {
    cfg_load "$1" || return 1
    if [ -z "$T_CONNECT" ]; then
        T_PUBLIC_IP="$(public_ip)"
        say ""
        ask T_PUBLIC_IP "public IP of THIS server" "${T_PUBLIC_IP:-}"
    fi
    say ""
    dim "paste this on the other server: Config New Tunnel -> option 2"
    say ""
    say "${C_YEL}$(cfg_peer_token)${C_OFF}"
    say ""
    pause
}

recycle_menu() {
    local name="$1"
    say ""
    if systemctl is-enabled --quiet "pingify-recycle@$name.timer" 2>/dev/null; then
        dim "a scheduled recycle is currently active"
        if confirm "turn it off?"; then
            systemctl disable --now "pingify-recycle@$name.timer" >/dev/null 2>&1
            rm -f "$UNIT_DIR/pingify-recycle@$name.timer"
            systemctl daemon-reload
            ok "scheduled recycle removed"
        fi
        pause; return
    fi
    dim "Some Iranian ISPs quietly degrade long-lived connections. A periodic"
    dim "restart costs a second of downtime and clears that up."
    say ""
    local hours=""
    ask hours "restart every N hours (0 to cancel)" "6"
    case "$hours" in ''|*[!0-9]*|0) return ;; esac
    cat > "$UNIT_DIR/pingify-recycle@$name.timer" <<TIMER
[Unit]
Description=Pingify scheduled recycle of tunnel $name

[Timer]
OnBootSec=${hours}h
OnUnitActiveSec=${hours}h
RandomizedDelaySec=120
Unit=pingify-recycle@$name.service

[Install]
WantedBy=timers.target
TIMER
    systemctl daemon-reload
    systemctl enable --now "pingify-recycle@$name.timer" >/dev/null 2>&1
    ok "the tunnel will recycle every ${hours}h"
    pause
}

delete_tunnel() {
    local name="$1"
    say ""
    confirm "really delete tunnel $name?" || return 1
    systemctl disable --now "pingify@$name" >/dev/null 2>&1
    systemctl disable --now "pingify-recycle@$name.timer" >/dev/null 2>&1
    rm -f "$UNIT_DIR/pingify-recycle@$name.timer"
    rm -f "$CFG_DIR/$name.json" "$CFG_DIR/$name.json.bak" "$STATE_DIR/$name.fail"
    systemctl daemon-reload
    ok "tunnel $name removed"
    sleep 1
    return 0
}
