#!/usr/bin/env bash
#
# Update, remove, and the diagnostics screen: one command that answers "is
# this thing working, and if not, which part is broken" - in the order the
# failures actually happen, so the first red line is the one to fix.

RAW_BASE="https://raw.githubusercontent.com/${PINGIFY_REPO}/main"

restart_all() {
    local n any=0
    for n in $(cfg_list); do any=1; svc_do restart "$n"; done
    [ "$any" = 1 ] && ok "${1:-done}; every tunnel was restarted" || ok "${1:-done}"
}

# ---------------------------------------------------------------------------
# update
#
# The script and the core share a config format, so they move together. The
# new script is fetched, checked to be a script of ours, installed, and then
# handed the rest: it rebuilds its own core and restarts every tunnel.
# ---------------------------------------------------------------------------

update_pingify() {
    local tmp rc=1 url newver
    banner
    head2 "Update Pingify"
    have curl || have wget || {
        fail "neither curl nor wget is here, so there is nothing to fetch with"
        fix "apt install curl"
        pause; return 1
    }
    tmp=$(mktemp) || return 1
    for url in \
        "https://github.com/$PINGIFY_REPO/releases/latest/download/Pingify.sh" \
        "$RAW_BASE/Pingify.sh"; do
        dim "trying $url"
        if fetch "$url" "$tmp" 60; then rc=0; break; fi
    done
    if [ "$rc" != 0 ]; then
        rm -f "$tmp"
        fail "nothing could be fetched from either place"
        dim "on an Iranian server this often fails; fetch it on the Kharej box and copy it across"
        pause; return 1
    fi
    if ! head -1 "$tmp" | grep -q '^#!.*bash'; then
        rm -f "$tmp"
        fail "what came back is not a shell script - something on the way answered instead"
        pause; return 1
    fi
    if ! bash -n "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        fail "what came back does not parse, so it arrived incomplete"
        fix "try again - a truncated script is worse than an old one"
        pause; return 1
    fi
    newver=$(grep -m1 '^PINGIFY_VERSION=' "$tmp" | cut -d'"' -f2)
    if [ -z "$newver" ]; then
        rm -f "$tmp"
        fail "that script would not tell us its version, so it is not one of ours"
        pause; return 1
    fi
    if [ "$newver" = "$PINGIFY_VERSION" ] && core_matches_script; then
        rm -f "$tmp"
        ok "already on $PINGIFY_VERSION - nothing to do"
        pause; return 0
    fi
    blank
    panel_open "VERSIONS"
    panel_field "installed" "$PINGIFY_VERSION" "core" "$(core_version 2>/dev/null || printf 'none')"
    panel_field "available" "$newver"
    panel_close
    dim "the core is rebuilt to match, and every running tunnel is restarted"
    blank
    if ver_ge "$newver" "$PINGIFY_VERSION"; then
        confirm "update to $newver?" y || { rm -f "$tmp"; return 1; }
    else
        warn "$newver is older than the $PINGIFY_VERSION on this server"
        confirm "go back to $newver?" n || { rm -f "$tmp"; return 1; }
    fi
    install -m 0755 "$tmp" "$PINGIFY_BIN" || { rm -f "$tmp"; fail "could not write $PINGIFY_BIN"; pause; return 1; }
    rm -f "$tmp"
    ok "the manager is now $newver"
    blank
    info "handing over to the new script to build its core"
    sleep 1
    exec "$PINGIFY_BIN" --rebuild-core
}

# rebuild_core is what the new script does when the old one hands over.
rebuild_core() {
    local n
    unit_write
    if ensure_core; then
        while IFS= read -r n; do
            systemctl is-enabled --quiet "pingify@$n" 2>/dev/null && svc_do restart "$n"
        done < <(cfg_list)
        ok "everything is on $PINGIFY_VERSION"
        return 0
    fi
    fail "the manager was updated but its core could not be built"
    fix "run pingify and choose Update Pingify once the reason is fixed"
    return 1
}

# ---------------------------------------------------------------------------
# remove
# ---------------------------------------------------------------------------

remove_menu() {
    local c n
    banner
    head2 "Remove"
    item 1 "Remove the core only" "tunnels and configs stay"
    item 2 "Remove every tunnel" "configs and services, core stays"
    item 3 "Full uninstall" "every tunnel, unit, rule and file it wrote"
    item 0 "Back"
    blank
    menu_key c || return 0
    case $c in
    1) blank
        confirm "remove $CORE_BIN?" || return 0
        for n in $(cfg_list); do systemctl stop "pingify@$n" >/dev/null 2>&1; done
        rm -f "$CORE_BIN"
        rm -rf "$SRC_DIR"
        ok "core removed; the next run builds it again"
        pause ;;
    2) blank
        confirm "delete every tunnel on this server?" || return 0
        for n in $(cfg_list); do
            svc_do stop "$n" >/dev/null 2>&1
            systemctl disable "pingify@$n" >/dev/null 2>&1
            systemctl disable --now "pingify-recycle@$n.timer" >/dev/null 2>&1
            rm -f "$UNIT_DIR/pingify-recycle@$n.timer"
            nat_drop "$n" >/dev/null 2>&1 || true
            awg_down "$n" >/dev/null 2>&1 || true
            rm -f "$(cfg_file "$n")" "$STATE_DIR/$n.forwards" "$STATE_DIR/$n.fail"
        done
        systemctl daemon-reload 2>/dev/null
        ok "all tunnels removed"
        pause ;;
    3) full_uninstall ;;
    0 | '') return 0 ;;
    esac
}

# Everything this tool ever wrote, in one pass. The firewall rules matter
# most: a DNAT rule pointing at an address that no longer exists swallows
# every packet for that port silently.
full_uninstall() {
    local n unit rc=0 units=0 keep=yes
    blank
    warn "this removes, on this server:"
    blank
    dim "    every tunnel's service, and their configs in $CFG_DIR if you say so"
    dim "    the systemd units, the watchdog timer and the boot-time firewall units"
    dim "    the forwarding rules (iptables chains PINGIFY_NAT, PINGIFY_SNAT)"
    dim "    the blocking rules (chains PINGIFY_IN, PINGIFY_OUT) and the hosts lines"
    dim "    every AmneziaWG interface it created"
    dim "    the core binary, the state directory and this script"
    blank
    confirm "go ahead?" n || { dim "nothing was removed"; return 2; }
    confirm "delete the configs in $CFG_DIR as well?" n && keep=no
    blank
    for n in $(cfg_list); do
        nat_drop "$n" >/dev/null 2>&1 || true
        awg_down "$n" >/dev/null 2>&1 || true
        svc_do stop "$n"
        svc_do disable "$n"
        systemctl disable --now "pingify-recycle@$n.timer" >/dev/null 2>&1
    done
    systemctl disable --now pingify-health.timer >/dev/null 2>&1
    nat_teardown || rc=1
    remove_blocking || rc=1
    if have iptables; then
        iptables -w 2 -D OUTPUT -j PINGIFY_RAWTCP 2>/dev/null
        iptables -w 2 -F PINGIFY_RAWTCP 2>/dev/null
        iptables -w 2 -X PINGIFY_RAWTCP 2>/dev/null
    fi
    for unit in "$UNIT_DIR"/pingify@.service "$UNIT_DIR"/pingify-*.service "$UNIT_DIR"/pingify-*.timer; do
        [ -e "$unit" ] || continue
        systemctl disable --now "${unit##*/}" >/dev/null 2>&1
        rm -f "$unit"
        [ -e "$unit" ] && { units=1; rc=1; }
    done
    systemctl daemon-reload >/dev/null 2>&1
    [ "$units" = 0 ] && ok "services stopped and removed" || fail "some units are still in $UNIT_DIR"
    if confirm "also revert the sysctl and file-limit tuning?" n; then revert_tuning; fi
    rm -rf "$CORE_DIR" "$STATE_DIR"
    if [ "$keep" = no ]; then rm -rf "$CFG_DIR"; ok "tunnels deleted"; else ok "tunnels left in $CFG_DIR"; fi
    rmdir "$BASE_DIR" 2>/dev/null
    if [ "$(cat /proc/sys/net/ipv4/icmp_echo_ignore_all 2>/dev/null)" = 1 ]; then
        sysctl -qw net.ipv4.icmp_echo_ignore_all=0 >/dev/null 2>&1 && ok "this server answers pings again"
    fi
    blank
    if [ "$rc" = 0 ]; then
        ok "every rule and unit is gone; nothing of Pingify is left running"
        dim "check for yourself:  iptables -t nat -S | grep PINGIFY   (should print nothing)"
    else
        fail "Pingify is off, but the lines above say what is left"
    fi
    blank
    ok "removing the manager itself now"
    rm -f "$PINGIFY_BIN"
    blank
    exit "$rc"
}
uninstall_all() { full_uninstall; }

# ---------------------------------------------------------------------------
# diagnostics
# ---------------------------------------------------------------------------

diag_full() {
    local n any=0 rc=0 one
    banner
    head2 "Full check"
    printf '  %s%s%s\n' "$C_B" "This server" "$C_OFF"
    if [ -x "$CORE_BIN" ]; then
        if core_matches_script; then ok "core $(core_version)"; else warn "core $(core_version), script $PINGIFY_VERSION - update"; fi
    else
        fail "the core is not installed"
    fi
    if have timedatectl && timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then
        ok "clock is synchronised"
    else
        warn "clock may be off - see Optimize ${BX_ARR} Sync the clock"
    fi
    if [ "$(watchdog_state)" = on ]; then ok "watchdog is on"; else warn "watchdog is off - a tunnel that goes quiet will not be restarted"; fi
    for n in $(cfg_list); do
        any=1
        health_check "$n" || { one=$?; [ "$one" -gt "$rc" ] && rc=$one; }
    done
    [ "$any" = 1 ] || { blank; warn "no tunnels configured"; }
    pause
    return "$rc"
}

diag_ping() {
    pick_tunnel || return 0
    local host
    host=$(peer_public "$PICKED")
    blank
    [ -n "$host" ] || ask host "address to ping" "" v_host || return 0
    blank
    dim "the raw path to $host, outside the tunnel"
    if have ping; then
        ping -c 5 -W 2 "$host" 2>&1 | sed 's/^/    /'
        dim "an ICMP tunnel on the other server stops it answering pings - the tunnel is fine"
    else
        warn "ping is not installed"
    fi
    pause
}

# show_nat - every rule Pingify has put in the firewall, and nothing else.
show_nat() {
    blank
    if ! have iptables; then
        warn "iptables is not installed on this server"
        dim "a TCP tunnel does not need it; a TUN tunnel's ports could not be forwarded without it"
        return
    fi
    local any=0 out
    out=$(iptables -w 2 -t nat -S PINGIFY_NAT 2>/dev/null | grep -v '^-N ')
    if [ -n "$out" ]; then
        any=1
        head2 "Forwarding"
        dim "sends a port on this server across the private link"
        printf '%s\n' "$out" | sed 's/^/    /' | cut -c "1-$((UI_TERM - 2))"
        iptables -w 2 -t nat -S PINGIFY_SNAT 2>/dev/null | grep -v '^-N ' | sed 's/^/    /'
    fi
    out=$(iptables -w 2 -S PINGIFY_RAWTCP 2>/dev/null | grep -v '^-N ')
    if [ -n "$out" ]; then
        any=1
        head2 "Raw TCP"
        dim "keeps the kernel from answering our own segments with a reset"
        printf '%s\n' "$out" | sed 's/^/    /'
    fi
    out="$(iptables -w 2 -S PINGIFY_IN 2>/dev/null | grep -v '^-N ')$(iptables -w 2 -S PINGIFY_OUT 2>/dev/null | grep -v '^-N ')"
    if [ -n "$out" ]; then
        any=1
        head2 "Blocking"
        dim "the switches under Blocking in the main menu"
        iptables -w 2 -S PINGIFY_IN 2>/dev/null | grep -v '^-N ' | sed 's/^/    /' | cut -c "1-$((UI_TERM - 2))"
        iptables -w 2 -S PINGIFY_OUT 2>/dev/null | grep -v '^-N ' | sed 's/^/    /' | cut -c "1-$((UI_TERM - 2))"
    fi
    if [ "$any" = 0 ]; then
        ok "Pingify has no firewall rules on this server"
        dim "Which is normal. Rules appear when a TUN tunnel forwards ports, when"
        dim "a Raw TCP tunnel runs, or when something under Blocking is on."
    fi
}

diag_system() {
    banner
    head2 "System"
    detect_os
    panel "MACHINE"
    panel_field "OS" "$OS_PRETTY"
    panel_field "Kernel" "$(uname -r)" "Arch" "$ARCH"
    panel_field "CPU" "$(nproc 2>/dev/null || echo ?) cores" "Memory" "$(free -h 2>/dev/null | awk '/^Mem:/{print $3" of "$2}')"
    panel_end
    panel "NETWORK"
    srv_info
    panel_field "Public IP" "$SRV_IP"
    panel_field "Congestion" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" "Qdisc" "$(sysctl -n net.core.default_qdisc 2>/dev/null)"
    panel_field "Blocking" "$(block_summary)" "Open files" "$(ulimit -n)"
    panel_end
    panel "PINGIFY"
    panel_field "Script" "$PINGIFY_VERSION" "Core" "$(core_version 2>/dev/null || printf 'none')"
    panel_field "Directory" "$BASE_DIR"
    panel_field "Watchdog" "$(state_badge "$(watchdog_state)")" "Time" "$(date -u '+%Y-%m-%d %H:%M UTC')"
    panel_end
    pause
}

diagnostics_menu() {
    local c
    while :; do
        banner
        head2 "Diagnostics"
        group "Check"
        item 1 "Full check" "this server, then every tunnel"
        item 2 "Live log" "follow a tunnel as it runs"
        group "Measure"
        item 3 "iperf3" "real bandwidth between your two servers"
        item 4 "Find the MTU" "measure the path instead of guessing at it"
        item 5 "Ping the other end" "raw latency, outside the tunnel"
        group "Show"
        item 6 "Firewall rules" "the iptables rules Pingify installed, if any"
        item 7 "System summary"
        blank
        item 0 "Back"
        blank
        menu_key c || return 0
        case $c in
        1) diag_full ;;
        2) pick_tunnel && live_log "$PICKED" ;;
        3) speed_menu ;;
        4) mtu_menu ;;
        5) diag_ping ;;
        6) show_nat; pause ;;
        7) diag_system ;;
        0 | '') return 0 ;;
        esac
    done
}
