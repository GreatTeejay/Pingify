
# ---------------------------------------------------------------------------
# installation of the manager itself
# ---------------------------------------------------------------------------

install_self() {
    local src="${BASH_SOURCE[0]}"
    if [ -r "$src" ] && [ "$(readlink -f "$src" 2>/dev/null)" != "$(readlink -f "$SELF_BIN" 2>/dev/null)" ]; then
        install -m 0755 "$src" "$SELF_BIN" 2>/dev/null || cp -f "$src" "$SELF_BIN"
        chmod 0755 "$SELF_BIN"
    fi
    ensure_deps
    write_units
    ok "the ${C_B}pingify${C_OFF} command is installed"
    dim "everything else lives in $BASE_DIR"
}

# Earlier versions scattered files across /etc, /var/lib and /usr/local. Move
# anything left behind into the single directory, once, without asking.
migrate_layout() {
    local moved=0 f
    if [ -d /etc/pingify ]; then
        for f in /etc/pingify/*.json; do
            [ -e "$f" ] || continue
            if [ ! -e "$CFG_DIR/$(basename "$f")" ]; then
                install -m 600 "$f" "$CFG_DIR/$(basename "$f")" && moved=1
            fi
        done
        rm -rf /etc/pingify
    fi
    if [ -x /usr/local/bin/pingify-core ] && [ ! -x "$CORE_BIN" ]; then
        install -m 0755 /usr/local/bin/pingify-core "$CORE_BIN" && moved=1
    fi
    rm -f /usr/local/bin/pingify-core
    rm -rf /var/lib/pingify /usr/local/src/pingify
    if [ "$moved" = "1" ]; then
        write_units
        for f in $(tunnel_names); do systemctl restart "pingify@$f" >/dev/null 2>&1; done
        info "moved the existing setup into $BASE_DIR"
        sleep 1
    fi
}

usage() {
    cat <<USAGE
Pingify $PINGIFY_VERSION - tunnel manager for Iran <-> Kharej server pairs

  pingify                  open the menu
  pingify --install        install the command and the systemd units
  pingify --health-check   run the watchdog pass once (used by the timer)
  pingify --status [name]  print tunnel status and exit
  pingify --version        print the version
  pingify --help           this text

Files: $BASE_DIR
USAGE
}

# ---------------------------------------------------------------------------
# the panel above the menu
# ---------------------------------------------------------------------------

info_panel() {
    local name addr up=0 total=0
    for name in $(tunnel_names); do
        total=$((total + 1))
        addr="$(json_str "$CFG_DIR/$name.json" status_addr)"
        if [ -n "$addr" ] && [ -x "$CORE_BIN" ] && "$CORE_BIN" -healthz "$addr" >/dev/null 2>&1; then
            up=$((up + 1))
        fi
    done

    local core_line="$C_RED$BX_ON$C_OFF not installed"
    [ -x "$CORE_BIN" ] && core_line="$C_GRN$BX_ON$C_OFF $(core_version)"

    local tun_line
    if [ "$total" = "0" ]; then
        tun_line="$C_GRY$BX_OFF$C_OFF none configured"
    elif [ "$up" = "$total" ]; then
        tun_line="$C_GRN$BX_ON$C_OFF $up of $total up"
    elif [ "$up" = "0" ]; then
        tun_line="$C_RED$BX_ON$C_OFF $up of $total up"
    else
        tun_line="$C_YEL$BX_ON$C_OFF $up of $total up"
    fi

    local wd wd_line
    wd="$(watchdog_state)"
    if [ "$wd" = "on" ]; then wd_line="$C_GRN$BX_ON$C_OFF on"; else wd_line="$C_YEL$BX_OFF$C_OFF off"; fi

    box_top
    box_row "$(pad_to "IP address" 15)${C_B}${SRV_IP}${C_OFF}"
    box_row "$(pad_to "Location" 15)${SRV_LOC}"
    box_row "$(pad_to "Provider" 15)$(printf '%.42s' "$SRV_ORG")"
    box_row "$(pad_to "Core" 15)${core_line}"
    box_row "$(pad_to "Tunnels" 15)${tun_line}"
    box_row "$(pad_to "Watchdog" 15)$(pad_to "$wd_line" 16)${C_DIM}tcp $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)${C_OFF}"
    box_bot
}

first_run() {
    [ -x "$CORE_BIN" ] && return 0
    banner
    head2 "First run"
    dim "installing the core into $BASE_DIR"
    say ""
    if install_core; then
        say ""
        ok "ready"
        sleep 1
    else
        say ""
        fail "the core could not be installed"
        dim "the Update core entry has the other ways to get it"
        pause
    fi
}

main_menu() {
    while :; do
        banner
        info_panel
        say ""
        item 1 "New tunnel"        "set this server up"
        item 2 "Tunnels"           "status, ports, logs, remove"
        item 3 "Live status"       "dashboard that refreshes itself"
        say ""
        item 4 "Update core"       "fetch the latest build"
        item 5 "Update script"     "fetch the latest Pingify"
        item 6 "Optimize server"   "kernel and network tuning"
        say ""
        item 7 "Diagnostics"       "reach the peer, verify configs"
        item 8 "Backup"            "save or restore your tunnels"
        item 9 "Remove"            "uninstall part of it, or all of it"
        say ""
        item 0 "Exit"
        say ""
        local c=""
        ask c "select"
        case "$c" in
            1) new_tunnel ;;
            2) manage_tunnels ;;
            3) live_dashboard ;;
            4) update_menu ;;
            5) self_update; pause ;;
            6) optimize_menu ;;
            7) diagnostics_menu ;;
            8) backup_menu ;;
            9) remove_menu ;;
            0) clear 2>/dev/null || true; exit 0 ;;
            *) ;;
        esac
    done
}

main() {
    detect_os
    case "${1:-}" in
        --health-check)
            require_root; run_health_check; exit 0 ;;
        --version | -v)
            echo "Pingify $PINGIFY_VERSION"; exit 0 ;;
        --help | -h)
            usage; exit 0 ;;
        --install)
            require_root; install_self; exit 0 ;;
        --status)
            require_root
            if [ -n "${2:-}" ]; then tunnel_status_block "$2"; else list_tunnels; fi
            exit $? ;;
        "") ;;
        *)  usage; exit 2 ;;
    esac

    require_root
    ensure_deps
    migrate_layout
    server_info
    first_run
    main_menu
}

# build.sh sources this file to verify the embedded core sources; that must
# not launch the menu.
[ -n "${PINGIFY_NO_MAIN:-}" ] || main "$@"
