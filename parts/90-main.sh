#!/usr/bin/env bash
#
# The front door: getting the manager onto the machine, working out what the
# command line asked for, and the one screen everything else hangs off. It
# is last so that everything it dispatches to is already defined when the
# guard at the bottom calls main.

# ---------------------------------------------------------------------------
# installation of the manager itself
# ---------------------------------------------------------------------------

# install_self copies this script over /usr/local/bin/pingify when the copy
# sitting there is not this one. The new copy is renamed into place rather
# than written over the destination: bash reads a script as it runs, so
# truncating the file it is still reading turns the rest of the run into
# whatever lands at that offset.
install_self() {
    local src=${BASH_SOURCE[0]} dir tmp stamp
    if [ ! -f "$src" ]; then
        warn "the pingify command was not installed - this script has no file on disk"
        fix "save it first:  curl -fsSLo Pingify.sh <url> && bash Pingify.sh"
        return 1
    fi
    if ! cmp -s "$src" "$PINGIFY_BIN"; then
        dir=${PINGIFY_BIN%/*}
        tmp=$(mktemp "$dir/.pingify.XXXXXX") || return 1
        if ! { cat "$src" >"$tmp" && chmod 0755 "$tmp" && mv -f "$tmp" "$PINGIFY_BIN"; }; then
            rm -f "$tmp"
            warn "could not write $PINGIFY_BIN"
            return 1
        fi
    fi
    # The units change with the script and never with a tunnel, so they are
    # written on a version change and not on every tunnel creation.
    stamp=$STATE_DIR/script.version
    if [ "$(cat "$stamp" 2>/dev/null)" != "$PINGIFY_VERSION" ]; then
        if unit_write && [ -s "$UNIT_DIR/pingify@.service" ]; then
            printf '%s\n' "$PINGIFY_VERSION" >"$stamp"
        else
            warn "could not write $UNIT_DIR/pingify@.service"
            return 1
        fi
    fi
    return 0
}

usage() {
    cat <<USAGE
Pingify $PINGIFY_VERSION - tunnel manager for Iran <-> Kharej server pairs

  pingify                    open the menu
  pingify --new              straight to building a tunnel
  pingify --status [name]    print tunnel status and exit
  pingify --check name       health check; exits 0 clean, 1 warnings, 2 problems
  pingify --json             with --status or --check, machine readable
  pingify --health-check     run the watchdog pass once (used by the timer)
  pingify --apply-firewall   re-apply the forwarding and blocking rules (used at boot)
  pingify --update           fetch a newer script and core
  pingify --uninstall        take Pingify off this server
  pingify --install          install the command and the systemd units
  pingify --version          print the version
  pingify --help             this text

Files: $BASE_DIR
USAGE
}

# ---------------------------------------------------------------------------
# front page
# ---------------------------------------------------------------------------

info_panel() {
    local name up=0 total=0 core_txt tun_txt side=
    for name in $(cfg_list); do
        total=$((total + 1))
        tunnel_is_up "$name" && up=$((up + 1))
        [ -n "$side" ] || side=$(toml_get "$(cfg_file "$name")" tunnel side)
    done
    srv_info
    panel "SERVER"
    panel_field "IP" "$(addr_tint "$SRV_IP")"
    panel_field "Location" "$SRV_LOC"
    panel_field "Datacenter" "$(printf '%.44s' "$SRV_ORG")"
    case $side in
    iran) panel_field "Side" "IRAN - users connect here" ;;
    kharej) panel_field "Side" "KHAREJ - your panel is here" ;;
    esac
    panel_end
    if [ ! -x "$CORE_BIN" ]; then
        core_txt="${C_RED}not installed${C_OFF}"
    elif core_matches_script; then
        core_txt=$(core_version)
    else
        core_txt="${C_RED}$(core_version) - does not match the script${C_OFF}"
    fi
    if [ "$total" = 0 ]; then
        tun_txt="${C_GRY}${BX_OFF}${C_OFF} none configured"
    elif [ "$up" = "$total" ]; then
        tun_txt="${C_GRN}${BX_ON}${C_OFF} $up of $total up"
    elif [ "$up" = 0 ]; then
        tun_txt="${C_RED}${BX_ON}${C_OFF} $up of $total up"
    else
        tun_txt="${C_YEL}${BX_ON}${C_OFF} $up of $total up"
    fi
    panel "STATUS"
    panel_field "Core ver" "$core_txt"
    panel_field "Script ver" "$PINGIFY_VERSION"
    panel_field "Tunnels" "$tun_txt"
    panel_field "Watchdog" "$(state_badge "$(watchdog_state)")"
    panel_end
}

first_run() {
    [ -x "$CORE_BIN" ] && return 0
    banner
    head2 "First-time setup"
    panel "INSTALL"
    panel_field "1  Manager" "installed at $PINGIFY_BIN"
    panel_field "2  Core" "compiled here from the source inside this script"
    panel_field "3  Services" "systemd units and the health watchdog"
    panel_end
    blank
    if build_core; then
        unit_write
        ok "Pingify is ready - choose New tunnel from the next screen"
        sleep 1
        return 0
    fi
    blank
    fail "the core could not be built"
    dim "it needs a Go toolchain, which this script offers to fetch when it is missing"
    pause
    return 1
}

# ensure_core_current rebuilds a core that does not match the script: they
# read the same config file, so a mismatch rejects tunnels.
ensure_core_current() {
    [ -x "$CORE_BIN" ] || return 0
    core_matches_script && return 0
    banner
    head2 "Core update"
    warn "the core is $(core_version), this script is $PINGIFY_VERSION"
    dim "they have to match - the config format is shared between them"
    blank
    if build_core; then
        restart_all "the core was updated"
    else
        blank
        fail "the core could not be updated"
        dim "until it matches, new tunnels will be rejected"
    fi
    pause
}

screen_home() {
    banner
    info_panel
    group "TUNNELS"
    item 1 "New tunnel" "set this server up, or finish the pair"
    item 2 "Manage tunnels" "status, ports, tuning, logs, remove"
    item 3 "Health" "live status, watchdog, health log"
    group "NETWORK"
    item 4 "Optimize" "host profiles, BBR, forwarding, swap"
    item 5 "Blocking" "ICMP, speedtest, UDP 443"
    item 6 "Diagnostics" "connectivity, iperf3, MTU, rules"
    group "MAINTENANCE"
    item 7 "Update Pingify" "script and core together, to the same version"
    item 8 "Remove" "uninstall part of it, or all of it"
    blank
    item 0 "Exit"
    blank
}

main_menu() {
    local c
    while :; do
        screen_home
        menu_key c || return 0
        case $c in
        1) new_tunnel; wiz_end ;;
        2) manage_tunnels ;;
        3) health_menu ;;
        4) optimize_menu ;;
        5) blocking_menu ;;
        6) diagnostics_menu ;;
        7) update_pingify ;;
        8) remove_menu ;;
        0 | q | Q) blank; return 0 ;;
        '') ;;
        *) blank; warn "there is nothing on $c"; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# what the command line asked for
# ---------------------------------------------------------------------------

# --status is what a monitoring script calls. It exits non-zero if any tunnel
# it was asked about is not running.
cmd_status() {
    local n names=() rc=0
    if [ -n "$ARG_NAME" ]; then
        [ -f "$(cfg_file "$ARG_NAME")" ] || die "there is no tunnel called $ARG_NAME"
        names=("$ARG_NAME")
    else
        while IFS= read -r n; do names+=("$n"); done < <(cfg_list)
    fi
    [ "${#names[@]}" -gt 0 ] || { warn "no tunnels are configured" >&2; return 1; }
    if [ -n "$ARG_JSON" ]; then
        for n in "${names[@]}"; do
            status_json "$n"
            [ "$(svc_state "$n")" = active ] || rc=1
        done
        return "$rc"
    fi
    if [ -n "$ARG_NAME" ]; then
        tunnel_status_block "$ARG_NAME"
    else
        list_tunnels
    fi
    for n in "${names[@]}"; do [ "$(svc_state "$n")" = active ] || rc=1; done
    return "$rc"
}

status_json() {
    local n=$1 st
    st=$(svc_state "$n")
    tun_stats "$n" || ST_UP=false
    printf '{"name":"%s","service":"%s","up":%s,"transport":"%s","profile":"%s"' \
        "$n" "$st" "${ST_UP:-false}" "$ST_TRANSPORT" "$ST_PROFILE"
    printf ',"side":"%s","in_mbit":%s,"out_mbit":%s,"lost":%s,"reordered":%s,"uptime_sec":%s}\n' \
        "$ST_SIDE" "${ST_IN:-0}" "${ST_OUT:-0}" "${ST_LOST:-0}" "${ST_LATE:-0}" "${ST_UPTIME:-0}"
}

argv() {
    ARG_MODE=menu ARG_NAME= ARG_JSON=
    while [ "$#" -gt 0 ]; do
        case $1 in
        --status)
            ARG_MODE=status
            case ${2:-} in '' | -*) ;; *) ARG_NAME=$2; shift ;; esac
            ;;
        --check)
            ARG_MODE=check
            case ${2:-} in '' | -*) die "--check needs the name of a tunnel" ;; esac
            ARG_NAME=$2
            shift
            ;;
        --json) ARG_JSON=1 ;;
        --new) ARG_MODE=new ;;
        --update) ARG_MODE=update ;;
        --rebuild-core) ARG_MODE=rebuild ;;
        --uninstall) ARG_MODE=uninstall ;;
        --install) ARG_MODE=install ;;
        --health-check) ARG_MODE=health ;;
        --apply-firewall) ARG_MODE=firewall ;;
        --version | -v) ARG_MODE=version ;;
        --help | -h) ARG_MODE=help ;;
        *)
            usage >&2
            die "$1 is not an option this script has"
            ;;
        esac
        shift
    done
}

main() {
    local rc
    argv "$@"
    case $ARG_MODE in
    help) usage; exit 0 ;;
    version)
        say "Pingify $PINGIFY_VERSION"
        [ -x "$CORE_BIN" ] && say "core $(core_version)"
        exit 0
        ;;
    esac

    require_root
    detect_os
    ensure_dirs

    case $ARG_MODE in
    status) cmd_status; exit $? ;;
    check) health_check "$ARG_NAME" "${ARG_JSON:+--json}"; exit $? ;;
    health) run_health_check; exit 0 ;;
    firewall) apply_blocking quiet; nat_apply_all; exit 0 ;;
    uninstall)
        full_uninstall
        rc=$?
        [ "$rc" = 2 ] && rc=0
        exit "$rc"
        ;;
    update) update_pingify; exit $? ;;
    install) ensure_deps; install_self && ok "installed"; exit $? ;;
    rebuild) rebuild_core; exit $? ;;
    esac

    ensure_deps
    migrate_layout
    install_self
    srv_info
    first_run || exit 1
    ensure_core_current

    case $ARG_MODE in
    new) new_tunnel; wiz_end ;;
    *) main_menu ;;
    esac
}

# build.sh and the tests source this file to get at its functions; that must
# not launch the menu.
[ -n "${PINGIFY_NO_MAIN:-}" ] || main "$@"
