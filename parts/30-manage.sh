
# ---------------------------------------------------------------------------
# reading an existing tunnel back
# ---------------------------------------------------------------------------

cfg_load() {
    local f
    f="$(cfg_file "$1")"
    [ -f "$f" ] || return 1
    cfg_reset
    T_NAME="$(toml_get "$f" tunnel name)"
    T_ROLE="$(toml_get "$f" tunnel role)"
    T_MODE="$(toml_get "$f" tunnel mode)";                  : "${T_MODE:=forward}"
    T_KIND="$(toml_get "$f" tunnel kind)"
    if [ -z "$T_KIND" ]; then
        # written before the kind was recorded
        [ "$(toml_get "$f" transport type)" = "icmp" ] && T_KIND="tun" || T_KIND="tcp"
    fi
    T_TRANSPORT="$(toml_get "$f" transport type)";          : "${T_TRANSPORT:=tcp}"
    T_TOKEN="$(toml_get "$f" security token)"
    T_STATUS="$(toml_get "$f" status addr)"
    T_CARRIERS="$(toml_get "$f" transport carriers)";       : "${T_CARRIERS:=4}"
    T_KEEPALIVE="$(toml_get "$f" transport keepalive_sec)"; : "${T_KEEPALIVE:=10}"
    T_WINDOW="$(toml_get "$f" tuning window_kb)";           : "${T_WINDOW:=512}"
    T_PRESET="$(toml_get "$f" tuning profile)";             : "${T_PRESET:=custom}"
    T_FORWARDS="$(toml_arr "$f" ports)"
    T_FORWARDER="$(toml_get "$f" forward forwarder)";       : "${T_FORWARDER:=pingify}"
    T_TUNIF="$(toml_get "$f" tun name)";                    : "${T_TUNIF:=pfy0}"
    T_TUNLOCAL="$(toml_get "$f" tun local_addr)"
    T_TUNPEER="$(toml_get "$f" tun remote_addr)"
    T_TUNMTU="$(toml_get "$f" tun mtu)";                    : "${T_TUNMTU:=1380}"

    # The endpoint is derived, so recover what it was built from.
    local l c
    l="$(toml_get "$f" transport listen)"
    c="$(toml_get "$f" transport connect)"
    if [ -n "$l" ]; then
        T_ACCEPTS="$T_ROLE"
        case "$l" in *:*) T_PORT="${l##*:}" ;; esac
    else
        [ "$T_ROLE" = "server" ] && T_ACCEPTS="client" || T_ACCEPTS="server"
        T_PEER_IP="${c%:*}"
        case "$c" in *:*) T_PORT="${c##*:}" ;; *) T_PEER_IP="$c" ;; esac
    fi
    return 0
}

# ---------------------------------------------------------------------------
# status rendering
# ---------------------------------------------------------------------------

tunnel_status_block() {
    local name="$1" f="$(cfg_file "$1")"
    [ -f "$f" ] || { fail "no such tunnel: $name"; return 1; }
    local addr; addr="$(toml_get "$f" status addr)"
    local state; state="$(svc_state "$name")"

    local colour="$C_RED"
    [ "$state" = "active" ] && colour="$C_GRN"
    printf '  %s%s%s  service %s%s%s   token %s%s%s\n' \
        "$C_B" "$name" "$C_OFF" "$colour" "$state" "$C_OFF" \
        "$C_YEL" "$(token_print "$(toml_get "$f" security token)")" "$C_OFF"

    # A stopped tunnel has no status endpoint to ask, and printing the raw
    # "connection refused" from trying anyway reads like a fault when it is
    # only the consequence of the line above.
    if [ "$state" != "active" ]; then
        dim "not running - nothing to report"
        return 0
    fi
    [ -n "$addr" ] && [ -x "$CORE_BIN" ] || return 0
    if ! "$CORE_BIN" -status "$addr" 2>/dev/null; then
        # Either it is still coming up, or no carrier has arrived. The status
        # server answers within a second of starting, so a refusal this soon
        # after a start is the former.
        dim "starting up, or the other server has not connected yet"
    fi
    return 0
}

# One line per tunnel, for the overview table.
tunnel_row() {
    local name="$1" f="$(cfg_file "$1")"
    local role proto fwder addr state brief up total rtt streams
    role="$(side_label "$(toml_get "$f" tunnel role)")"
    proto="$(transport_label "$(toml_get "$f" transport type)")"
    fwder="$(forwarder_label "$(toml_get "$f" forward forwarder)")"
    peer="$(toml_get "$f" transport connect)"
    [ -z "$peer" ] && peer="on ${C_OFF}$(toml_get "$f" transport listen)"
    addr="$(toml_get "$f" status addr)"
    state="$(svc_state "$name")"

    up="-"; total="$(toml_get "$f" transport carriers)"; rtt="-"; streams="-"
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

    printf '  %s %s %s %s %s %s %s%s%s\n' \
        "$dot" \
        "$(pad_to "${C_B}${name}${C_OFF}" 13)" \
        "$(pad_to "$role" 8)" \
        "$(pad_to "$proto" 10)" \
        "$(pad_to "$fwder" 9)" \
        "$(pad_to "$up/$total" 6)" \
        "$C_DIM" "$rtt" "$C_OFF"
}

list_tunnels() {
    local names; names="$(tunnel_names)"
    if [ -z "$names" ]; then
        dim "no tunnels configured yet - pick New tunnel to make one"
        return 1
    fi
    printf '    %s%s %s %s %s %s %s%s\n' \
        "$C_DIM" \
        "$(pad_to "NAME" 13)" \
        "$(pad_to "SIDE" 8)" \
        "$(pad_to "PROTO" 10)" \
        "$(pad_to "FORWARDER" 9)" \
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
        group "Check"
        item 1 "Test the path" "go through the tunnel and say where it stops"
        item 2 "Live log"
        group "Settings"
        item 3 "Ports" "$(printf '%s' "$(toml_arr "$(cfg_file "$name")" ports)" | tr -d '"' | tr ',' ' ')"
        item 4 "Tuning" "carriers, window, keepalive, logging"
        item 5 "Scheduled restart"
        group "Service"
        item 6 "Restart"
        item 7 "Stop"
        item 8 "Start"
        say ""
        item d "Delete this tunnel"
        item 0 "Back"
        say ""
        local c=""
        ask c "select"
        case "$c" in
            1) probe_path "$name" ;;
            2) say ""; dim "ctrl-c to stop following"; say ""
               journalctl -u "pingify@$name" -n 60 -f --no-pager || true ;;
            3) edit_forwards "$name" ;;
            4) tuning_menu "$name" ;;
            5) recycle_menu "$name" ;;
            6) systemctl restart "pingify@$name"; ok "restarted"; sleep 1 ;;
            7) systemctl stop "pingify@$name"; ok "stopped"; sleep 1 ;;
            8) systemctl start "pingify@$name"; ok "started"; sleep 1 ;;
            d|D) delete_tunnel "$name" && return ;;
            0|"") return ;;
        esac
    done
}

# Connecting to a forwarded port proves nothing on its own: this server accepts
# before it has said a word to the tunnel. The core's probe goes the whole way
# and reports where it stopped.
probe_path() {
    local name="$1" f
    f="$(cfg_file "$name")"
    cfg_load "$name" || return 1
    banner
    head2 "Testing the path for: $name"
    say ""
    if [ "$T_ROLE" != "server" ]; then
        warn "this is the KHAREJ end - the ports live on the IRAN server"
        dim "run this from the menu over there instead"
        pause; return
    fi
    if ! systemctl is-active --quiet "pingify@$name"; then
        fail "the tunnel is not running; start it first"
        pause; return
    fi
    "$CORE_BIN" -c "$f" -probe 2>&1 | sed 's/^/  /'
    say ""
    dim "A port that fails is one the other server could not reach. The service"
    dim "there must be listening on the address after the arrow."
    pause
}

edit_logging() {
    local name="$1" f
    f="$(cfg_file "$name")"
    banner
    head2 "Logging: $name"
    say ""
    choice 1 "error" "only what is broken"
    choice 2 "warn" "and what is wrong but survivable"
    choice 3 "info" "and what a healthy tunnel does"
    choice 4 "debug" "and why each carrier and stream did what it did"
    choice 5 "trace" "and every packet - slows a busy tunnel down"
    say ""
    dim "This is local. The two servers may log at different levels."
    say ""
    local c="" lvl
    ask c "select" "3"
    case "$c" in
        1) lvl="error" ;; 2) lvl="warn" ;;
        4) lvl="debug" ;; 5) lvl="trace" ;;
        3|"") lvl="info" ;;
        *) fail "pick 1 to 5"; pause; return ;;
    esac
    cp -f "$f" "$f.bak"
    if grep -q '^level' "$f"; then
        sed -i "s#^level.*#level            = \"$lvl\"#" "$f"
    else
        printf '
[logging]
level            = "%s"
' "$lvl" >> "$f"
    fi
    if "$CORE_BIN" -c "$f" -check >/dev/null 2>&1; then
        rm -f "$f.bak"
        systemctl restart "pingify@$name"
        ok "logging at $lvl"
    else
        mv -f "$f.bak" "$f"
        fail "the core rejected that; nothing was changed"
    fi
    pause
}

edit_forwards() {
    local name="$1" f="$(cfg_file "$1")"
    cfg_load "$name" || return 1
    if [ "$T_ROLE" != "server" ]; then
        warn "the port list lives on the IRAN server; this is the KHAREJ end"
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
    if grep -q '^ports' "$f"; then
        sed -i "s#^ports.*#ports            = [$fwd]#" "$f"
    else
        sed -i "s#^\(forwarder.*\)#\1\nports            = [$fwd]#" "$f"
    fi
    if "$CORE_BIN" -c "$f" -check >/dev/null 2>&1; then
        rm -f "$f.bak"
        systemctl restart "pingify@$name"
        apply_nat quiet
        ok "ports updated and the tunnel restarted"
    else
        mv -f "$f.bak" "$f"
        fail "that port list was rejected, nothing changed"
    fi
    pause
}

# Every number that shapes a tunnel, on one screen, split by the only
# distinction that matters when two servers disagree: the settings that have to
# match, and the ones that are nobody's business but this machine's.
tuning_menu() {
    local name="$1" f v
    f="$(cfg_file "$name")"
    while :; do
        cfg_load "$name" || return 1
        banner
        head2 "Tuning: $name"

        panel "both servers must agree"
        field "Token" "$(token_print "$T_TOKEN")"
        field "Type" "$(transport_label "$T_TRANSPORT")" "Forwarder" "$(forwarder_label "$T_FORWARDER")"
        panel_end
        say ""
        panel "local to this server"
        field "Profile" "$T_PRESET"
        field "Carriers" "$T_CARRIERS" "Window" "${T_WINDOW} KB"
        field "Keepalive" "${T_KEEPALIVE} s"
        panel_end
        say ""
        dim "Read the top box on the other server and make it read the same."
        dim "The bottom box may differ; it will not break the link."

        rule
        item 1 "Profile" "pick a preset and set all three at once"
        item 2 "Carriers" "$T_CARRIERS - parallel connections"
        item 3 "Window" "$T_WINDOW KB per connection"
        item 4 "Keepalive" "$T_KEEPALIVE seconds"
        item 5 "Logging" "$T_LOG"
        item 0 "Back"
        say ""
        local c=""
        ask c "select"
        case "$c" in
            1) say ""; preset_menu
               tuning_write "$name" "$T_CARRIERS" "$T_WINDOW" "$T_KEEPALIVE" ;;
            2) say ""; ask v "parallel connections" "$T_CARRIERS"
               tuning_write "$name" "$v" "$T_WINDOW" "$T_KEEPALIVE" ;;
            3) say ""; ask v "window per connection, KB" "$T_WINDOW"
               tuning_write "$name" "$T_CARRIERS" "$v" "$T_KEEPALIVE" ;;
            4) say ""; ask v "keepalive seconds" "$T_KEEPALIVE"
               tuning_write "$name" "$T_CARRIERS" "$T_WINDOW" "$v" ;;
            5) edit_logging "$name" ;;
            0|"") return ;;
        esac
    done
}

# tuning_write <name> <carriers> <window> <keepalive>
tuning_write() {
    local name="$1" car="$2" win="$3" ka="$4" f
    f="$(cfg_file "$name")"
    case "$car$win$ka" in *[!0-9]*|"") fail "numbers only"; pause; return ;; esac
    [ "$car" -ge 1 ] && [ "$car" -le 64 ] || { fail "carriers must be 1 to 64"; pause; return; }

    cp -f "$f" "$f.bak"
    sed -i "s#^carriers.*#carriers         = $car#" "$f"
    sed -i "s#^window_kb.*#window_kb        = $win#" "$f"
    sed -i "s#^keepalive_sec.*#keepalive_sec    = $ka#" "$f"
    if "$CORE_BIN" -c "$f" -check >/dev/null 2>&1; then
        rm -f "$f.bak"
        systemctl restart "pingify@$name"
        ok "saved and restarted"
    else
        mv -f "$f.bak" "$f"
        fail "the core rejected that; nothing was changed"
    fi
    sleep 1
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
    rm -f "$(cfg_file "$name")" "$(cfg_file "$name").bak" "$STATE_DIR/$name.fail"
    systemctl daemon-reload
    # Its forwarding rules outlive the config unless something removes them,
    # and a DNAT rule pointing at an address that no longer exists swallows
    # every packet for that port - which looks exactly like a broken tunnel.
    apply_nat quiet
    ok "tunnel $name removed"
    sleep 1
    return 0
}
