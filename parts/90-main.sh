
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
        addr="$(toml_get "$(cfg_file "$name")" status addr)"
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
    box_row "$edot $(pad_to "core ${C_B}${ever}${C_OFF}" 22)$tdot tunnels ${C_B}${up}/${total}${C_OFF} up"
    box_row "$wdot $(pad_to "watchdog ${C_B}${wd}${C_OFF}" 22)${C_GRY}${BX_DOT}${C_OFF} tcp ${C_B}${cc:-unknown}${C_OFF}"
    box_bot
}

# ---------------------------------------------------------------------------
# moving an older install into place
#
# Before this version the config was JSON spread over /etc/pingify, the core
# sat in /usr/local/bin and the state in /var/lib. Everything Pingify owns now
# lives in one directory, and the format is sectioned TOML.
#
# A tunnel that is running should not need rebuilding for that, so this
# converts it in place and leaves the old file behind only if the new one
# cannot be written. It runs once: after the move there is nothing to find.
# ---------------------------------------------------------------------------

json_to_toml() {
    local j="$1" name out
    name="$(basename "$j" .json)"
    out="$(cfg_file "$name")"
    [ -f "$out" ] && return 1

    local role mode transport listen connect psk status level
    local carriers window keepalive fwd
    role="$(json_str "$j" role)"
    mode="$(json_str "$j" mode)";           : "${mode:=forward}"
    transport="$(json_str "$j" transport)"; : "${transport:=direct}"
    listen="$(json_str "$j" listen)"
    connect="$(json_str "$j" connect)"
    psk="$(json_str "$j" psk)"
    status="$(json_str "$j" status_addr)"
    level="$(json_str "$j" log_level)";     : "${level:=info}"
    carriers="$(json_num "$j" carriers)";   : "${carriers:=4}"
    window="$(json_num "$j" window_kb)";    : "${window:=1024}"
    keepalive="$(json_num "$j" keepalive_sec)"; : "${keepalive:=10}"
    fwd="$(sed -n 's/^[[:space:]]*"forwards"[[:space:]]*:[[:space:]]*\[\(.*\)\],*[[:space:]]*$/\1/p' "$j" | head -n1)"

    # edge and origin were what the roles used to be called.
    case "$role" in edge) role="server" ;; origin) role="client" ;; esac

    {
        printf '# Pingify tunnel - converted from %s\n' "$(basename "$j")"
        printf '\n[tunnel]\n'
        printf '%-16s = "%s"\n' name "$name"
        printf '%-16s = "%s"\n' role "$role"
        printf '%-16s = "%s"\n' mode "$mode"
        printf '\n[transport]\n'
        printf '%-16s = "%s"\n' type "$transport"
        [ -n "$listen" ]  && printf '%-16s = "%s"\n' listen "$listen"
        [ -n "$connect" ] && printf '%-16s = "%s"\n' connect "$connect"
        printf '%-16s = %s\n' carriers "$carriers"
        printf '%-16s = %s\n' keepalive_sec "$keepalive"
        printf '\n[security]\n'
        printf '%-16s = "%s"\n' psk "$psk"
        if [ -n "$fwd" ]; then
            printf '\n[forward]\n'
            printf '%-16s = [%s]\n' ports "$fwd"
        fi
        if [ "$mode" = "tun" ]; then
            local tl; tl="$(grep -m1 '"tun"' "$j")"
            printf '\n[tun]\n'
            printf '%-16s = "%s"\n' name  "$(printf '%s' "$tl" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
            printf '%-16s = "%s"\n' local_addr  "$(printf '%s' "$tl" | sed -n 's/.*"local"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
            printf '%-16s = "%s"\n' remote_addr "$(printf '%s' "$tl" | sed -n 's/.*"peer"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
            printf '%-16s = %s\n'   mtu "$(printf '%s' "$tl" | sed -n 's/.*"mtu"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')"
        fi
        printf '\n[tuning]\n'
        printf '%-16s = %s\n' window_kb "$window"
        printf '\n[status]\n'
        printf '%-16s = "%s"\n' addr "$status"
        printf '\n[logging]\n'
        printf '%-16s = "%s"\n' level "$level"
    } > "$out"
    chmod 600 "$out"
    rm -f "$j"
    return 0
}

migrate_layout() {
    local moved=0 f
    mkdir -p "$CFG_DIR" "$STATE_DIR"
    chmod 700 "$CFG_DIR"

    if [ -x /usr/local/bin/pingify-core ] && [ ! -x "$CORE_BIN" ]; then
        install -m 0755 /usr/local/bin/pingify-core "$CORE_BIN" && moved=1
    fi
    rm -f /usr/local/bin/pingify-core

    if [ -d /etc/pingify ]; then
        for f in /etc/pingify/*.json; do
            [ -e "$f" ] || continue
            json_to_toml "$f" && moved=1
        done
        rmdir /etc/pingify 2>/dev/null
    fi
    for f in "$CFG_DIR"/*.json; do
        [ -e "$f" ] || continue
        json_to_toml "$f" && moved=1
    done
    rm -rf /var/lib/pingify /usr/local/src/pingify

    if [ "$moved" = "1" ]; then
        write_units
        for f in $(tunnel_names); do systemctl restart "pingify@$f" >/dev/null 2>&1; done
        info "moved the existing setup into $BASE_DIR"
        sleep 1
    fi
}

first_run() {
    [ -x "$CORE_BIN" ] && return 0
    banner
    head2 "First run"
    dim "setting up the core for this server"
    say ""
    if install_core; then
        say ""
        ok "ready"
        sleep 1
    else
        say ""
        fail "the core could not be installed"
        dim "the Core menu has the other ways to get it"
        pause
    fi
}

main_menu() {
    while :; do
        banner
        status_panel
        say ""
        item 1 "New Tunnel"        "create one, or apply a token"
        item 2 "Tunnels"           "status, ports, logs, remove"
        item 3 "Health"            "dashboard, watchdog, restarts"
        item 4 "Optimize"          "BBR, buffers, limits, swap"
        item 5 "Core"              "install, update, import, export"
        item 6 "Remove"            "uninstall parts, or everything"
        item 7 "Diagnostics"       "reach the peer, verify configs"
        item 8 "Backup"            "save or restore your tunnels"
        say ""
        item 0 "Exit"
        say ""
        local c=""
        ask c "select"
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
    migrate_layout
    first_run
    main_menu
}

# build.sh sources this file to verify the embedded core sources; that must
# not launch the menu.
[ -n "${PINGIFY_NO_MAIN:-}" ] || main "$@"
