
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
        item 4 "Export this core binary" "to copy to the peer"
        item 5 "Update Pingify itself" "fetch the newest manager script"
        item 0 "Back"
        say ""
        local c=""
        ask c "select"
        case "$c" in
            1) say ""; if download_core; then restart_all "the core was updated"; fi; pause ;;
            2) say ""; if build_core; then restart_all "the core was rebuilt"; fi; pause ;;
            3) say ""; if import_core_binary; then restart_all "the core was replaced"; fi; pause ;;
            4) export_core; pause ;;
            5) self_update; pause ;;
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
    info "fetching the latest Pingify from GitHub"
    local tmp="/tmp/pingify.new"
    if ! fetch_to "$RAW_BASE/Pingify.sh" "$tmp" 60; then
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
    dim "Move it to the other server and use Update Core -> 3 there."
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
# ---------------------------------------------------------------------------

tcp_probe() {
    local host="$1" port="$2"
    timeout 5 bash -c ": < /dev/tcp/$host/$port" 2>/dev/null
}

diagnostics_menu() {
    while :; do
        banner
        head2 "Diagnostics"
        item 1 "Reach the other server"
        item 2 "Ping the peer"
        item 3 "Validate every config"
        item 4 "Listening ports"
        item 5 "System summary"
        item 6 "Tail a tunnel log"
        item 0 "Back"
        say ""
        local c=""
        ask c "select"
        case "$c" in
            1) diag_reach ;;
            2) diag_ping ;;
            3) diag_configs ;;
            4) say ""; ss -Hltnp 2>/dev/null | sed 's/^/  /' | head -n 40; pause ;;
            5) diag_system ;;
            6) if pick_tunnel; then journalctl -u "pingify@$PICKED" -n 80 --no-pager | sed 's/^/  /'; pause; fi ;;
            0|"") return ;;
        esac
    done
}

diag_reach() {
    pick_tunnel || return
    cfg_load "$PICKED" || return
    say ""
    if [ -n "$T_CONNECT" ]; then
        local host="${T_CONNECT%:*}" port="${T_CONNECT##*:}"
        info "opening a TCP connection to $host:$port"
        if tcp_probe "$host" "$port"; then
            ok "the peer accepted the connection - the path is clear"
        else
            fail "no answer from $host:$port"
            dim "check that the peer's tunnel is running, that its firewall allows"
            dim "the port, and that the provider is not blocking it"
        fi
    else
        local port="${T_LISTEN##*:}"
        info "this server listens on port $port; checking it is bound"
        if ss -Hltn "sport = :$port" 2>/dev/null | grep -q .; then
            ok "port $port is open and listening"
            dim "run this same check from the other server to test the path"
        else
            fail "nothing is listening on $port - is the tunnel running?"
        fi
    fi
    pause
}

diag_ping() {
    pick_tunnel || return
    cfg_load "$PICKED" || return
    local host=""
    if [ -n "$T_CONNECT" ]; then host="${T_CONNECT%:*}"; fi
    [ -n "$host" ] || ask host "peer IP"
    [ -n "$host" ] || return
    say ""
    ping -c 5 -W 2 "$host" 2>&1 | sed 's/^/  /'
    pause
}

diag_configs() {
    say ""
    local n bad=0
    for n in $(tunnel_names); do
        if "$CORE_BIN" -c "$(cfg_file "$n")" -check >/dev/null 2>&1; then
            ok "$n"
        else
            bad=1
            fail "$n"
            "$CORE_BIN" -c "$(cfg_file "$n")" -check 2>&1 | sed 's/^/      /'
        fi
    done
    [ "$bad" = "0" ] && dim "every config is valid"
    pause
}

diag_system() {
    say ""
    printf '  %-22s %s\n' "os" "$OS_PRETTY"
    printf '  %-22s %s\n' "kernel" "$(uname -r)"
    printf '  %-22s %s\n' "arch" "$ARCH"
    printf '  %-22s %s\n' "cpu" "$(nproc) cores"
    printf '  %-22s %s\n' "memory" "$(free -h | awk '/^Mem:/{print $3" used of "$2}')"
    printf '  %-22s %s\n' "public ip" "$(public_ip)"
    printf '  %-22s %s\n' "core" "$(core_version)"
    printf '  %-22s %s\n' "watchdog" "$(watchdog_state)"
    printf '  %-22s %s\n' "congestion control" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    printf '  %-22s %s\n' "time" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    pause
}

# ---------------------------------------------------------------------------
# backup / restore
# ---------------------------------------------------------------------------

backup_menu() {
    banner
    head2 "Backup & Restore"
    item 1 "Back up every tunnel"
    item 2 "Restore from a backup"
    item 0 "Back"
    say ""
    local c=""
    ask c "select"
    case "$c" in
        1)  say ""
            local out="/root/pingify-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
            if tar -czf "$out" -C / etc/pingify 2>/dev/null; then
                chmod 600 "$out"
                ok "written to $out"
                warn "it contains your shared keys - keep it somewhere safe"
            else
                fail "nothing to back up"
            fi
            pause ;;
        2)  say ""
            local src=""
            ask src "path to the backup file"
            [ -f "$src" ] || { fail "no such file"; pause; return; }
            confirm "this replaces the configs on this server. continue?" || return
            tar -xzf "$src" -C / || { fail "could not unpack it"; pause; return; }
            write_units
            local n
            for n in $(tunnel_names); do service_enable_start "$n"; ok "started $n"; done
            pause ;;
        0|"") return ;;
    esac
}
