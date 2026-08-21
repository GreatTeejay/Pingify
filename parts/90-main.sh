
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
USAGE
}

# ---------------------------------------------------------------------------
# the status panel above the menu
# ---------------------------------------------------------------------------

status_panel() {
    local name addr up=0 total=0
    for name in $(tunnel_names); do
        total=$((total + 1))
        addr="$(json_str "$CFG_DIR/$name.json" status_addr)"
        if [ -n "$addr" ] && [ -x "$CORE_BIN" ] && "$CORE_BIN" -healthz "$addr" >/dev/null 2>&1; then
            up=$((up + 1))
        fi
    done

    local edot="$C_RED$BX_OFF$C_OFF" ever
    ever="$(core_version)"
    [ -x "$CORE_BIN" ] && edot="$C_GRN$BX_ON$C_OFF"

    local tdot="$C_GRY$BX_OFF$C_OFF"
    if [ "$total" != "0" ]; then
        if [ "$up" = "$total" ]; then tdot="$C_GRN$BX_ON$C_OFF"
        elif [ "$up" = "0" ]; then    tdot="$C_RED$BX_ON$C_OFF"
        else                          tdot="$C_YEL$BX_ON$C_OFF"; fi
    fi

    local wd wdot="$C_YEL$BX_OFF$C_OFF"
    wd="$(watchdog_state)"
    [ "$wd" = "on" ] && wdot="$C_GRN$BX_ON$C_OFF"

    local cc; cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"

    box_top
    box_row "$edot $(pad_to "engine ${C_B}${ever}${C_OFF}" 22)$tdot tunnels ${C_B}${up}/${total}${C_OFF} up"
    box_row "$wdot $(pad_to "watchdog ${C_B}${wd}${C_OFF}" 22)${C_GRY}${BX_DOT}${C_OFF} tcp ${C_B}${cc:-unknown}${C_OFF}"
    box_bot
}

first_run() {
    [ -x "$CORE_BIN" ] && return 0
    banner
    head2 "Welcome"
    dim "Pingify needs its engine before it can build a tunnel. It will fetch the"
    dim "prebuilt binary for this CPU from GitHub, and fall back to compiling the"
    dim "sources carried inside this script if that is not reachable."
    say ""
    if confirm "install the engine now?"; then
        say ""
        install_core || { say ""; warn "you can retry any time from Update Core"; }
        pause
    fi
}

main_menu() {
    while :; do
        banner
        status_panel
        say ""
        item 1 "Config New Tunnel"       "create one, or join with a token"
        item 2 "Manage Tunnels"          "status, ports, logs, remove"
        item 3 "Health & Monitoring"     "live dashboard and watchdog"
        item 4 "Optimize Server"         "BBR, buffers, limits, swap"
        item 5 "Update Core"             "refresh the engine or Pingify"
        item 6 "Remove"                  "uninstall parts, or everything"
        item 7 "Diagnostics"             "reach the peer, verify configs"
        item 8 "Backup & Restore"        "save or reload your tunnels"
        say ""
        item 0 "Exit"
        say ""
        local c=""
        ask c "choose"
        case "$c" in
            1) new_tunnel ;;
            2) manage_tunnels ;;
            3) health_menu ;;
            4) optimize_menu ;;
            5) update_menu ;;
            6) remove_menu ;;
            7) diagnostics_menu ;;
            8) backup_menu ;;
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
    first_run
    main_menu
}

# build.sh sources this file to verify the embedded engine sources; that must
# not launch the menu.
[ -n "${PINGIFY_NO_MAIN:-}" ] || main "$@"
