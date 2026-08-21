
# ---------------------------------------------------------------------------
# update / remove
# ---------------------------------------------------------------------------

RAW_BASE="https://raw.githubusercontent.com/GreatTeejay/Pingify/main"

update_menu() {
    while :; do
        banner
        head2 "Core"
        printf '  %-22s %s\n' "core" "$(core_version)"
        printf '  %-22s %s\n' "manager" "$PINGIFY_VERSION"
        printf '  %-22s %s\n' "Go toolchain" "$(find_go >/dev/null 2>&1 && "$GO_BIN" version || echo 'not installed')"
        rule
        item 1 "Download the latest core" "prebuilt, from GitHub Releases"
        item 2 "Compile the core here" "from the sources inside this script"
        item 3 "Import a core binary" "path or URL"
        item 4 "Export this core binary" "to copy to the other server"
        item 0 "Back"
        say ""
        local c=""
        ask c "select"
        case "$c" in
            1) say ""; if download_core; then restart_all "the core was updated"; fi; pause ;;
            2) say ""; if build_core; then restart_all "the core was rebuilt"; fi; pause ;;
            3) say ""; if import_core_binary; then restart_all "the core was replaced"; fi; pause ;;
            4) export_core; pause ;;
            0|"") return ;;
        esac
    done
}

restart_all() {
    local n any=0
    for n in $(tunnel_names); do any=1; systemctl restart "pingify@$n"; done
    [ "$any" = "1" ] && ok "$1; every tunnel was restarted" || ok "$1"
}

self_update() {
    say ""
    have curl || { fail "curl is needed for this"; return 1; }
    info "fetching the latest Pingify from GitHub"
    local tmp="/tmp/pingify.new"
    if ! curl -fsSL --max-time 60 "$RAW_BASE/Pingify.sh" -o "$tmp"; then
        fail "could not reach GitHub"
        dim "on an Iranian server this often fails; update from the Kharej box"
        dim "and copy the file across instead."
        return 1
    fi
    if ! bash -n "$tmp" 2>/dev/null; then
        fail "the downloaded file is not valid, refusing to install it"
        rm -f "$tmp"; return 1
    fi
    local newver; newver="$(grep -m1 '^PINGIFY_VERSION=' "$tmp" | cut -d'"' -f2)"
    install -m 0755 "$tmp" "$SELF_BIN"
    rm -f "$tmp"
    ok "Pingify updated to ${newver:-unknown}"
    dim "run 'pingify' again to pick up the new version"
}

export_core() {
    say ""
    [ -x "$CORE_BIN" ] || { fail "no core is installed here"; return 1; }
    local dest="/root/pingify-core-$(uname -m)"
    cp -f "$CORE_BIN" "$dest"
    ok "copied to $dest"
    dim "Copy it to the other server, then Update core -> 3 there."
    dim "Example, run this on the other server:"
    say ""
    say "    ${C_DIM}scp root@$(public_ip):$dest /root/pingify-core${C_OFF}"
}

remove_menu() {
    banner
    head2 "Remove"
    item 1 "Remove the core only" "tunnels and configs stay"
    item 2 "Remove every tunnel" "configs and services, core stays"
    item 3 "Full uninstall" "everything Pingify ever wrote"
    item 0 "Back"
    say ""
    local c=""
    ask c "select"
    case "$c" in
        1)  say ""
            confirm "remove $CORE_BIN?" || return
            local n
            for n in $(tunnel_names); do systemctl stop "pingify@$n" >/dev/null 2>&1; done
            rm -f "$CORE_BIN"
            rm -rf "$SRC_DIR"
            ok "core removed; rebuild it from Update Core when you need it"
            pause ;;
        2)  say ""
            confirm "delete every tunnel on this server?" || return
            local n
            for n in $(tunnel_names); do
                systemctl disable --now "pingify@$n" >/dev/null 2>&1
                systemctl disable --now "pingify-recycle@$n.timer" >/dev/null 2>&1
                rm -f "$UNIT_DIR/pingify-recycle@$n.timer" "$(cfg_file "$n")"
            done
            systemctl daemon-reload
            ok "all tunnels removed"
            pause ;;
        3)  full_uninstall ;;
        0|"") return ;;
    esac
}

full_uninstall() {
    say ""
    warn "this removes the core, every tunnel, the units and the tuning"
    confirm "go ahead?" || return
    local n
    for n in $(tunnel_names); do
        systemctl disable --now "pingify@$n" >/dev/null 2>&1
        systemctl disable --now "pingify-recycle@$n.timer" >/dev/null 2>&1
    done
    systemctl disable --now pingify-health.timer >/dev/null 2>&1
    remove_blocking
    rm -f "$UNIT_DIR"/pingify@.service "$UNIT_DIR"/pingify-health.service \
          "$UNIT_DIR"/pingify-health.timer "$UNIT_DIR"/pingify-recycle@*.service \
          "$UNIT_DIR"/pingify-recycle@*.timer
    systemctl daemon-reload
    if confirm "also revert the sysctl and file-limit tuning?"; then revert_tuning; fi
    rm -rf "$CFG_DIR" "$STATE_DIR" "$SRC_DIR"
    rm -f "$CORE_BIN"
    ok "Pingify is gone. Removing the manager itself now."
    rm -f "$SELF_BIN"
    say ""
    exit 0
}

# ---------------------------------------------------------------------------
# diagnostics
#
# One command that answers "is this thing working, and if not, which part is
# broken" - in the order the failures actually happen, so the first red line
# is the one to fix.
# ---------------------------------------------------------------------------

DIAG_BAD=0

check_pass() { printf '  %s%s%s %s\n' "$C_GRN" "$MK_OK" "$C_OFF" "$1"; }
check_fail() { printf '  %s%s%s %s\n' "$C_RED" "$MK_NO" "$C_OFF" "$1"; DIAG_BAD=$((DIAG_BAD + 1)); }
check_warn() { printf '  %s%s%s %s\n' "$C_YEL" "$MK_WARN" "$C_OFF" "$1"; }
check_note() { printf '      %s%s%s\n' "$C_DIM" "$1" "$C_OFF"; }

tcp_probe() {
    timeout 5 bash -c ": < /dev/tcp/$1/$2" 2>/dev/null
}

diag_tunnel() {
    local name="$1" f
    f="$(cfg_file "$name")"
    cfg_load "$name" || { check_fail "$name: no config"; return; }

    printf '\n  %s%s%s\n' "$C_B" "$name" "$C_OFF"

    # 1. the config the core will actually read
    if "$CORE_BIN" -c "$f" -check >/dev/null 2>&1; then
        check_pass "config is valid"
    else
        check_fail "the core rejects this config"
        "$CORE_BIN" -c "$f" -check 2>&1 | sed 's/^/      /'
        return
    fi

    # 2. the service
    case "$(svc_state "$name")" in
        active)   check_pass "service is running" ;;
        stopped)  check_fail "service is stopped"; check_note "start it from Manage tunnels"; return ;;
        *)        check_fail "service is not enabled"; return ;;
    esac

    # 3. the link itself, straight from the core
    local brief state up total rtt
    brief="$("$CORE_BIN" -status "$T_STATUS" -brief 2>/dev/null)"
    set -- $brief
    state="${1:-down}"; up="${2:-0}"; total="${3:-0}"; rtt="${4:-0}"
    if [ "$state" = "up" ]; then
        check_pass "link is up - $up of $total connections, ${rtt}ms"
        [ "$up" != "$total" ] && check_warn "some connections are still down"
    else
        check_fail "no connection to the other server"
    fi

    # 4. the path, so a down link points at a cause
    if [ -n "$T_CONNECT" ]; then
        local host="${T_CONNECT%:*}" port="${T_CONNECT##*:}"
        if tcp_probe "$host" "$port"; then
            check_pass "port $port on $host accepts connections"
        else
            check_fail "cannot reach $host:$port"
            check_note "is the other server running, and is the port open there?"
        fi
    else
        local port="${T_LISTEN##*:}"
        if ss -Hltn "sport = :$port" 2>/dev/null | grep -q .; then
            check_pass "listening on port $port"
            [ "$state" = "up" ] || check_note "open $port in your firewall and check the other server"
        else
            check_fail "nothing is listening on port $port"
        fi
    fi

    # 5. the ports clients are told to use
    if [ "$T_MODE" = "forward" ] && [ -n "$T_FORWARDS" ]; then
        local spec p missing=""
        for spec in $(printf '%s' "$T_FORWARDS" | tr -d '"' | tr ',' ' '); do
            p="${spec%%=*}"; p="${p##*:}"; p="${p%%-*}"
            case "$p" in "" | *[!0-9]*) continue ;; esac
            ss -Hltn "sport = :$p" 2>/dev/null | grep -q . || missing="$missing $p"
        done
        if [ -n "$missing" ]; then
            check_fail "not listening on:$missing"
        else
            check_pass "all forwarded ports are open"
        fi
    fi
}

diag_full() {
    banner
    head2 "Full check"
    DIAG_BAD=0

    # --- the machine ------------------------------------------------------
    printf '  %s%s%s\n' "$C_B" "This server" "$C_OFF"
    [ -x "$CORE_BIN" ] && check_pass "core $(core_version)" || check_fail "the core is not installed"

    if have timedatectl && timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then
        check_pass "clock is synchronised"
    else
        check_warn "clock may be off"
        check_note "the handshake rejects a difference over 3 minutes - see Optimize"
    fi

    if [ "$(watchdog_state)" = "on" ]; then
        check_pass "watchdog is on"
    else
        check_warn "watchdog is off - a dead tunnel will not be restarted"
    fi

    # --- each tunnel ------------------------------------------------------
    local names; names="$(tunnel_names)"
    if [ -z "$names" ]; then
        printf '\n'
        check_warn "no tunnels configured"
    else
        local n
        for n in $names; do diag_tunnel "$n"; done
    fi

    printf '\n'
    if [ "$DIAG_BAD" = "0" ]; then
        ok "everything checks out"
    else
        fail "$DIAG_BAD problem(s) above"
    fi
    pause
}

diagnostics_menu() {
    while :; do
        banner
        head2 "Diagnostics"
        item 1 "Full check" "config, service, link, path, ports"
        item 2 "Ping the other server" "plain ICMP, to see the raw latency"
        item 3 "Live log" "follow a tunnel as it runs"
        item 4 "System summary"
        item 0 "Back"
        say ""
        local c=""
        ask c "select"
        case "$c" in
            1) diag_full ;;
            2) diag_ping ;;
            3) if pick_tunnel; then
                   say ""; dim "ctrl-c to stop"; say ""
                   journalctl -u "pingify@$PICKED" -n 40 -f --no-pager || true
               fi ;;
            4) diag_system ;;
            0 | "") return ;;
        esac
    done
}

diag_ping() {
    pick_tunnel || return
    cfg_load "$PICKED" || return
    local host=""
    [ -n "$T_CONNECT" ] && host="${T_CONNECT%:*}"
    say ""
    if [ -z "$host" ]; then
        dim "this server waits for the other one, so it does not know its address"
        say ""
        ask host "address to ping"
    fi
    [ -n "$host" ] || return
    say ""
    if have ping; then
        ping -c 5 -W 2 "$host" 2>&1 | sed 's/^/    /'
    else
        warn "ping is not installed"
    fi
    pause
}

diag_system() {
    banner
    head2 "System"
    panel "MACHINE"
    field "OS" "$OS_PRETTY"
    field "Kernel" "$(uname -r)"
    field "Arch" "$ARCH"
    field "CPU" "$(nproc) cores"
    field "Memory" "$(free -h 2>/dev/null | awk '/^Mem:/{print $3" of "$2}')"
    panel_end
    panel "NETWORK"
    field "Public IP" "$SRV_IP"
    field "Congestion" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    field "Qdisc" "$(sysctl -n net.core.default_qdisc 2>/dev/null)"
    field "Blocking" "$(block_summary)"
    field "Open files" "$(ulimit -n)"
    panel_end
    panel "PINGIFY"
    field "Script" "$PINGIFY_VERSION"
    field "Core" "$(core_version)"
    field "Directory" "$BASE_DIR"
    field "Time" "$(date -u '+%Y-%m-%d %H:%M UTC')"
    panel_end
    pause
}
