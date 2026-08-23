
# ---------------------------------------------------------------------------
# update / remove
# ---------------------------------------------------------------------------

RAW_BASE="https://raw.githubusercontent.com/GreatTeejay/Pingify/main"

restart_all() {
    local n any=0
    for n in $(tunnel_names); do any=1; systemctl restart "pingify@$n"; done
    [ "$any" = "1" ] && ok "$1; every tunnel was restarted" || ok "$1"
}

# The script and the core share a config format, so they have to move
# together. Updating one alone is how a machine ends up with two versions of
# Pingify on it that refuse to work with each other.
update_pingify() {
    banner
    head2 "Update Pingify"
    if ! self_update; then pause; return 1; fi
    say ""
    info "restarting with the new version to bring the core along"
    sleep 1
    exec "$SELF_BIN"
}

self_update() {
    say ""
    info "fetching the latest Pingify from GitHub"
    local tmp="/tmp/pingify.new"
    if ! fetch "$RAW_BASE/Pingify.sh" "$tmp" 60; then
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
}

remove_menu() {
    banner
    head2 "Remove"
    item 1 "Remove the core only" "tunnels and configs stay"
    item 2 "Remove every tunnel" "configs and services, core stays"
    item 3 "Full uninstall" "every tunnel, unit, rule and file it wrote"
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
            ok "core removed; the next run downloads it again"
            pause ;;
        2)  say ""
            confirm "delete every tunnel on this server?" || return
            local n
            for n in $(tunnel_names); do
                # A kernel tunnel leaves an interface and a unit file of its
                # own behind; read it before the config goes.
                if cfg_load "$n" >/dev/null 2>&1 && kernel_transport; then
                    ip link del "$T_TUNIF" 2>/dev/null
                    rm -f "$UNIT_DIR/pingify@$n.service" "$(awg_conf_path "$T_TUNIF")"
                fi
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

# Everything this tool ever wrote, in one pass. The firewall rules matter
# most: a DNAT rule pointing at an address that no longer exists swallows
# every packet for that port silently, and an uninstall that leaves one
# behind hands the next person a server that is broken in a way nothing on
# it explains.
full_uninstall() {
    say ""
    warn "this removes, on this server:"
    say ""
    dim "    every tunnel and its config in $CFG_DIR"
    dim "    the systemd units, timers and the boot-time firewall unit"
    dim "    the forwarding rules (iptables chains PINGIFY_NAT, PINGIFY_POST)"
    dim "    the blocking rules (chains PINGIFY_IN, PINGIFY_OUT, PINGIFY_FWD)"
    dim "    the ICMP block in /etc/sysctl.d and the speedtest lines in /etc/hosts"
    dim "    every GRE and AmneziaWG interface it created"
    dim "    the core binary, the state directory and this script"
    say ""
    confirm "go ahead?" || return

    local n
    for n in $(tunnel_names); do
        # The kernel tunnels hold an interface that outlives their unit if
        # the stop never ran, and a unit file that is not the shared template.
        if cfg_load "$n" >/dev/null 2>&1 && kernel_transport; then
            ip link del "$T_TUNIF" 2>/dev/null
            rm -f "$UNIT_DIR/pingify@$n.service"
        fi
        systemctl disable --now "pingify@$n" >/dev/null 2>&1
        systemctl disable --now "pingify-recycle@$n.timer" >/dev/null 2>&1
    done
    systemctl disable --now pingify-health.timer >/dev/null 2>&1

    # both sets of chains, unhooked from the built-in ones and deleted
    remove_blocking
    have iptables && nat_drop_chains

    rm -f "$UNIT_DIR"/pingify@.service "$UNIT_DIR"/pingify-health.service \
          "$UNIT_DIR"/pingify-health.timer "$UNIT_DIR"/pingify-recycle@*.service \
          "$UNIT_DIR"/pingify-recycle@*.timer "$UNIT_DIR"/pingify-firewall.service
    systemctl daemon-reload

    if confirm "also revert the sysctl and file-limit tuning?"; then revert_tuning; fi
    rm -rf "$CFG_DIR" "$STATE_DIR" "$SRC_DIR"
    rm -f "$CORE_BIN"

    say ""
    ok "every rule and unit is gone; nothing of Pingify is left running"
    dim "check for yourself:  iptables -t nat -S | grep PINGIFY   (should print nothing)"
    say ""
    ok "removing the manager itself now"
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
        check_pass "link is up - $up of $total connections, $(rtt_tint "${rtt}ms")"
        [ "$up" != "$total" ] && check_warn "some connections are still down"
    else
        check_fail "no connection to the other server"
    fi

    # 4. the path, so a down link points at a cause
    cfg_endpoints
    if [ -n "$CFG_CONNECT" ]; then
        local host="${CFG_CONNECT%:*}" port="${CFG_CONNECT##*:}"
        if [ "$T_TRANSPORT" = "icmp" ]; then
            host="$CFG_CONNECT"
            if have ping && ping -c 2 -W 2 "$host" >/dev/null 2>&1; then
                check_pass "$host answers a ping - the ICMP path is open"
            else
                check_fail "$host does not answer a ping"
                check_note "an ICMP tunnel cannot work if ping does not get through"
            fi
            return
        fi
        if tcp_probe "$host" "$port"; then
            check_pass "port $port on $host accepts connections"
        else
            check_fail "cannot reach $host:$port"
            check_note "is the other server running, and is the port open there?"
        fi
    else
        local port="${CFG_LISTEN##*:}"
        if [ "$T_TRANSPORT" = "icmp" ]; then
            check_pass "ICMP needs no port to be open here"
            return
        fi
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
        group "Check"
        item 1 "Full check" "config, service, link, path, ports"
        item 2 "Live log" "follow a tunnel as it runs"
        group "Measure"
        item 3 "iperf3" "real bandwidth between your two servers"
        item 4 "Benchmark & Speedtest" "this machine: cpu, disk, and a real speedtest"
        item 5 "Find the MTU" "measure the path instead of guessing at it"
        item 6 "Ping the other end" "raw latency, outside the tunnel"
        group "Show"
        item 7 "Forwarding rules" "the iptables rules Pingify installed, if any"
        item 8 "System summary"
        say ""
        item 0 "Back"
        say ""
        local c=""
        ask c "select"
        case "$c" in
            1) diag_full ;;
            2) if pick_tunnel; then live_log "$PICKED"; fi ;;
            3) speed_menu ;;
            4) bench_menu ;;
            5) mtu_menu ;;
            6) diag_ping ;;
            7) show_nat; pause ;;
            8) diag_system ;;
            0 | "") return ;;
        esac
    done
}

diag_ping() {
    pick_tunnel || return
    cfg_load "$PICKED" || return
    local host=""
    cfg_endpoints
    [ -n "$CFG_CONNECT" ] && host="${CFG_CONNECT%:*}"
    # The end that accepts has no configured peer, but the running tunnel
    # knows who connected to it - so ask that before asking a person.
    [ -n "$host" ] || host="$(status_peer "$PICKED")"
    say ""
    if [ -z "$host" ]; then
        dim "this server waits for the other one, and nothing has connected yet -"
        dim "so neither its config nor the tunnel knows the far address"
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
