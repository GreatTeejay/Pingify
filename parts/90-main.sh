
# ---------------------------------------------------------------------------
# installation of the manager itself
# ---------------------------------------------------------------------------

release_script() { printf 'https://github.com/%s/releases/latest/download/Pingify.sh' "$PINGIFY_REPO"; }

install_self() {
    local src="${BASH_SOURCE[0]}"
    if [ -f "$src" ] && [ -r "$src" ]; then
        if [ "$(readlink -f "$src" 2>/dev/null)" != "$(readlink -f "$SELF_BIN" 2>/dev/null)" ]; then
            install -m 0755 "$src" "$SELF_BIN" 2>/dev/null || cp -f "$src" "$SELF_BIN"
            chmod 0755 "$SELF_BIN"
        fi
    else
        # Started straight from a pipe - bash <(wget ...) - so there is no file
        # on disk to copy. Pull the published script instead.
        local tmp="/tmp/pingify.self"
        if spin "installing the pingify command" \
             fetch "$(release_script)" "$tmp" 120 \
           && bash -n "$tmp" 2>/dev/null; then
            install -m 0755 "$tmp" "$SELF_BIN"
        else
            warn "could not fetch the manager; the pingify command is not installed"
        fi
        rm -f "$tmp"
    fi
    ensure_deps
    write_units
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

    # 3.2 and earlier wrote JSON; tunnel_names only looks for TOML now.
    for f in "$CFG_DIR"/*.json; do
        [ -e "$f" ] || continue
        json_to_toml "$f" && moved=1
    done

    # 4.4 to 4.8 shaped the traffic by default, and on a real Iran<->Europe
    # path that stopped carrying anything a few seconds after each carrier
    # came up. Existing tunnels are put back on the wire shape that works.
    # Both servers have to be updated, but they were both already broken.
    for f in "$CFG_DIR"/*.toml; do
        [ -e "$f" ] || continue
        if grep -q '^obfuscate *= *true' "$f"; then
            sed -i 's/^obfuscate *= *true.*/obfuscate        = false/' "$f"
            moved=1
        fi
    done
    if [ "$moved" = "1" ]; then
        write_units
        for f in $(tunnel_names); do systemctl restart "pingify@$f" >/dev/null 2>&1; done
        info "moved the existing setup into $BASE_DIR"
        sleep 1
    fi
}

# Rewrites one 3.2-era JSON config as TOML and removes the original.
json_to_toml() {
    local j="$1" name out k v
    name="$(basename "$j" .json)"
    out="$(cfg_file "$name")"
    [ -f "$out" ] && { rm -f "$j"; return 1; }
    {
        printf '# Pingify tunnel - converted from %s\n\n' "$(basename "$j")"
        for k in name role mode transport listen connect psk status_addr log_level; do
            v="$(json_str "$j" "$k")"
            [ -n "$v" ] && printf '%s = "%s"\n' "$k" "$v"
        done
        for k in carriers window_kb keepalive_sec; do
            v="$(json_num "$j" "$k")"
            [ -n "$v" ] && printf '%s = %s\n' "$k" "$v"
        done
        v="$(sed -n 's/.*"forwards"[[:space:]]*:[[:space:]]*\[\(.*\)\].*/\1/p' "$j" | head -n1)"
        [ -n "$v" ] && printf 'forwards = [%s]\n' "$v"
        if grep -q '"tun"' "$j"; then
            local tl; tl="$(grep -m1 '"tun"' "$j")"
            printf '\n[tun]\n'
            printf 'name  = "%s"\n' "$(printf '%s' "$tl" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
            printf 'local = "%s"\n' "$(printf '%s' "$tl" | sed -n 's/.*"local"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
            printf 'peer  = "%s"\n' "$(printf '%s' "$tl" | sed -n 's/.*"peer"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
            printf 'mtu   = %s\n'   "$(printf '%s' "$tl" | sed -n 's/.*"mtu"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')"
        fi
    } > "$out"
    chmod 600 "$out"
    rm -f "$j"
    return 0
}

usage() {
    cat <<USAGE
Pingify $PINGIFY_VERSION - tunnel manager for Iran <-> Kharej server pairs

  pingify                    open the menu
  pingify --install          install the command and the systemd units
  pingify --health-check     run the watchdog pass once (used by the timer)
  pingify --apply-firewall   re-apply the blocking rules (used at boot)
  pingify --status [name]    print tunnel status and exit
  pingify --version          print the version
  pingify --help             this text

Files: $BASE_DIR
USAGE
}

# ---------------------------------------------------------------------------
# front page
# ---------------------------------------------------------------------------

info_panel() {
    local name addr up=0 total=0
    for name in $(tunnel_names); do
        total=$((total + 1))
        addr="$(toml_get "$(cfg_file "$name")" status addr)"
        if [ -n "$addr" ] && [ -x "$CORE_BIN" ] && "$CORE_BIN" -healthz "$addr" >/dev/null 2>&1; then
            up=$((up + 1))
        fi
    done

    panel "SERVER"
    field "IP" "$SRV_IP"
    field "Location" "$SRV_LOC"
    field "Datacenter" "$(printf '%.44s' "$SRV_ORG")"
    panel_end

    local core_txt tun_txt
    if [ ! -x "$CORE_BIN" ]; then
        core_txt="${C_RED}not installed${C_OFF}"
    elif core_matches_script; then
        core_txt="$(core_version)"
    else
        core_txt="${C_RED}$(core_version) - does not match the script${C_OFF}"
    fi
    if [ "$total" = "0" ]; then
        tun_txt="${C_GRY}${BX_OFF}${C_OFF} none configured"
    elif [ "$up" = "$total" ]; then
        tun_txt="${C_GRN}${BX_ON}${C_OFF} $up of $total up"
    elif [ "$up" = "0" ]; then
        tun_txt="${C_RED}${BX_ON}${C_OFF} $up of $total up"
    else
        tun_txt="${C_YEL}${BX_ON}${C_OFF} $up of $total up"
    fi

    panel "STATUS"
    field "Core ver" "$core_txt"
    field "Script ver" "$PINGIFY_VERSION"
    field "Tunnels" "$tun_txt"
    field "Watchdog" "$(state_badge "$(watchdog_state)")"
    panel_end
}

first_run() {
    [ -x "$CORE_BIN" ] && return 0
    banner
    head2 "Setting up"
    if install_core; then
        sleep 1
        return 0
    fi
    say ""
    fail "the core could not be installed"
    dim "Core in the menu has the other ways to get it"
    pause
}

main_menu() {
    while :; do
        banner
        info_panel
        group "TUNNELS"
        item 1 "New tunnel"      "set this server up"
        item 2 "Manage tunnels"  "status, ports, logs, remove"
        item 3 "Health"          "live status, watchdog, health log"
        group "NETWORK"
        item 4 "Optimize"        "buffers, limits, swap, clock"
        item 5 "Blocking"        "ICMP, speedtest, UDP 443"
        item 6 "Diagnostics"     "connectivity and configs"
        group "MAINTENANCE"
        item 7 "Update Pingify"  "script and core together, to the same version"
        item 8 "Core options"    "build here, import, export"
        item 9 "Remove"          "uninstall part of it, or all of it"
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
            5) blocking_menu ;;
            6) diagnostics_menu ;;
            7) update_pingify ;;
            8) update_menu ;;
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
        --apply-firewall)
            require_root; apply_blocking quiet; apply_nat quiet; exit 0 ;;
        --version | -v)
            echo "Pingify $PINGIFY_VERSION"; exit 0 ;;
        --help | -h)
            usage; exit 0 ;;
        --install)
            require_root; install_self; ok "installed"; exit 0 ;;
        --status)
            require_root
            if [ -n "${2:-}" ]; then tunnel_status_block "$2"; else list_tunnels; fi
            exit $? ;;
        "") ;;
        *)  usage; exit 2 ;;
    esac

    require_root
    ensure_deps
    # Every time, not only the first. Running the install line is how people
    # update, and skipping this when a copy already existed left an older
    # script on PATH beside a core that had just been updated - which is the
    # one combination the two of them cannot work in.
    install_self
    migrate_layout
    server_info
    first_run
    ensure_core_current
    main_menu
}

# build.sh sources this file to verify the embedded core sources; that must
# not launch the menu.
[ -n "${PINGIFY_NO_MAIN:-}" ] || main "$@"
