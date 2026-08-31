#
# The front door: getting the manager onto the machine, working out what the
# command line asked for, and the one screen everything else hangs off. It is
# last so that everything it dispatches to is already defined when the guard
# at the bottom calls main.
#
# Two rules shape it. A non-interactive flag must work with no terminal at all
# - a monitoring script calling --status has no stdin and no tty - so nothing
# on that path asks a question or draws a menu. And there is one renderer for
# a tunnel's line: home draws it with a key beside it, --status draws it
# without one, and they are the same function, because two renderers of the
# same five numbers drift apart and then disagree in front of the user.

# --------------------------------------------------------------------------
# putting the manager where the pingify command can find it
# --------------------------------------------------------------------------

# install_self copies this script over /usr/local/bin/pingify when the copy
# sitting there is not this one. It runs on every interactive launch, and it
# has to, because "update" for most people means re-running the install line
# from the README: that leaves a fresh script in the current directory and a
# fresh core in /usr/local/bin, with the *old* manager still on PATH beside
# it - the one combination the two of them are not built to work in.
#
# The new copy is renamed into place rather than written over the destination.
# bash reads a script as it runs, a few kilobytes at a time, so truncating the
# file it is still reading turns the rest of the run into whatever lands at
# that offset. A rename leaves the running copy's inode alone.
install_self() {
    local src=${BASH_SOURCE[0]} dir tmp stamp
    if [ ! -f "$src" ]; then
        # Started from a process substitution - bash <(curl ...) - so there is
        # no file on disk to copy from. Nothing is broken; say what is missing.
        warn "the pingify command was not installed - this script has no file on disk"
        fix "save it first:  curl -fsSLo pingify <url> && bash pingify"
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

    # The unit is a template. It changes with the script and never with a
    # tunnel, so it is written here, once, and on a version change - which is
    # what stops it being rewritten four times whenever somebody adds a fifth
    # tunnel.
    stamp=$STATE_DIR/script.version
    if [ "$(cat "$stamp" 2>/dev/null)" != "$PINGIFY_VERSION" ]; then
        unit_write
        printf '%s\n' "$PINGIFY_VERSION" >"$stamp"
    fi
    return 0
}

# --------------------------------------------------------------------------
# home
# --------------------------------------------------------------------------

# The keys tunnels are given, in order. The fixed actions own n p h u x q and
# 0, so none of those appear here: a key that means "Uninstall" on a server
# with four tunnels and "the fifth tunnel" on a server with five is how
# somebody uninstalls from muscle memory.
HOME_KEYS='123456789abcdefgijklmorstvwyz'
HOME_NAMES=()

# The line under the name: which core, which side of the border this server is
# on, and how long the machine has been up. The side is here rather than in
# every row because one server is one side - the config's `side` line is the
# only thing that differs between the two ends, and it is the same in all of
# this server's configs.
home_subtitle() {
    local core=$G_DASH side= up= rest= first=
    [ -x "$CORE_BIN" ] && core=$(core_version)

    while IFS= read -r first; do break; done < <(cfg_list)
    [ -n "$first" ] && side=$(toml_get "$(cfg_file "$first")" tunnel side)
    case $side in
    iran) side=IRAN ;;
    kharej) side=KHAREJ ;;
    *) side="no tunnel yet" ;;
    esac

    read -r up rest </proc/uptime 2>/dev/null || up=
    printf 'core %s  %s  %s  %s  up %s' \
        "$core" "$G_V" "$side" "$G_V" "$(human_secs "${up%%.*}")"
}

# home_row is one tunnel, and it is also the menu item for that tunnel. The
# old manager printed a status table and then a second numbered list of the
# same names under it, so every name was on the screen twice and the numbers
# on the second list matched nothing on the first.
#
# The round trip is measured only for a tunnel that is running: probing a
# stopped one costs three seconds of ping timeout for an answer already known.
home_row() {
    local name=$1 key=$2 st=stopped dot=stopped rtt=$G_DASH rate= transport=
    st=$(svc_state "$name")
    transport=$(toml_get "$(cfg_file "$name")" transport type)
    [ -n "$transport" ] || transport=udp
    rate=$st

    case $st in
    active)
        dot=idle
        if tun_stats "$name"; then
            [ "$ST_UP" = true ] && dot=running
            [ -n "$ST_TRANSPORT" ] && transport=$ST_TRANSPORT
            rate="$(round1 "$ST_IN")/$(round1 "$ST_OUT") Mbit/s"
        else
            rate="no answer"
        fi
        rtt=$(tun_rtt "$name")
        # Grey, never red. An ICMP tunnel cannot be pinged across - both
        # kernels have stopped answering echo, deliberately - so "no number"
        # here means "not measurable", not "slow".
        case $rtt in
        '' | *[!0-9.]*) rtt=$G_DASH ;;
        *) rtt="$(rtt_colour "$rtt")$rtt ms$C_OFF" ;;
        esac
        ;;
    disabled) dot=unknown ;;
    esac

    row " $key $(state_dot "$dot")" "$name" "${transport^^}" "$rtt" "$rate"
}

# The widths the tunnel list is drawn at, in one place, because home and
# --status both draw it. The old script kept four magic numbers in the header
# and four more in the row and they had already drifted apart.
#
# Everything but the name is a known width - "412.3/38.1 Mbit/s" is the widest
# thing the last column ever holds - so the name takes the slack, up to the 24
# characters v_name allows and no further. A wide window should not stretch one
# column across half the screen.
home_cols() {
    local nw=$((UI_W - 46))
    [ "$nw" -gt 26 ] && nw=26
    [ "$nw" -lt 8 ] && nw=8
    UI_COLS=(4 "$nw" 6 8 17)
}

screen_home() {
    local n i=0 key
    HOME_NAMES=()
    while IFS= read -r n; do HOME_NAMES+=("$n"); done < <(cfg_list)

    banner "$(home_subtitle)"
    blank
    group "TUNNELS"
    if [ "${#HOME_NAMES[@]}" -eq 0 ]; then
        blank
        dim "no tunnels on this server yet."
        dim "press n to build one, or to paste the line the other server gave you."
    else
        home_cols
        while [ "$i" -lt "${#HOME_NAMES[@]}" ]; do
            key=${HOME_KEYS:i:1}
            home_row "${HOME_NAMES[i]}" "$key"
            i=$((i + 1))
        done
    fi
    blank
    item "n" "New tunnel"
    blank
    group "HOST"
    item "p" "Ports and firewall"
    item2 "h" "Host tuning" "$(host_summary)"
    blank
    group "MAINTENANCE"
    item "u" "Update"
    item "x" "Uninstall"
    item "0" "Exit"
    blank
}

# home_pick turns a keystroke back into the tunnel it was drawn beside.
home_pick() {
    local k=$1 i=0
    while [ "$i" -lt "${#HOME_NAMES[@]}" ]; do
        [ "${HOME_KEYS:i:1}" = "$k" ] && { printf '%s' "${HOME_NAMES[i]}"; return 0; }
        i=$((i + 1))
    done
    return 1
}

main_menu() {
    local c name
    while :; do
        screen_home
        menu_key c || return 0
        case $c in
        n) screen_new ;;
        p) screen_firewall ;;
        h) screen_host ;;
        u) update_pingify ;;
        x) uninstall_all && exit 0 ;;
        0 | q | Q) blank; return 0 ;;
        '') ;;
        *)
            if name=$(home_pick "$c"); then
                screen_tunnel "$name"
            else
                blank
                warn "there is nothing on $c"
            fi
            ;;
        esac
    done
}

# --------------------------------------------------------------------------
# what the command line asked for
# --------------------------------------------------------------------------

usage() {
    cat <<USAGE

  Pingify $PINGIFY_VERSION - a tunnel between a server in Iran and one abroad

    pingify                    the menu
    pingify --new              straight to building a tunnel
    pingify --status [NAME]    one line per tunnel, or one named tunnel
    pingify --check NAME       health check; exits 0 clean, 1 warnings, 2 problems
    pingify --json             with --status or --check, machine readable
    pingify --version          the version of this script, and of the core
    pingify --uninstall        take Pingify off this server
    pingify --help             this

  Configs   $CFG_DIR/<name>.toml - identical on both servers but for one line
  Core      $CORE_BIN

USAGE
}

# --status is what a monitoring script calls. It draws the same line home
# draws, with a blank where the menu key would be, and it exits non-zero if
# any tunnel it was asked about is not running.
cmd_status() {
    local n names=() rc=0
    if [ -n "$ARG_NAME" ]; then
        [ -f "$(cfg_file "$ARG_NAME")" ] || die "there is no tunnel called $ARG_NAME"
        names=("$ARG_NAME")
    else
        while IFS= read -r n; do names+=("$n"); done < <(cfg_list)
    fi
    [ "${#names[@]}" -gt 0 ] || { warn "no tunnels are configured"; return 1; }

    if [ -n "$ARG_JSON" ]; then
        for n in "${names[@]}"; do status_json "$n"; done
        return 0
    fi

    home_cols
    for n in "${names[@]}"; do
        home_row "$n" " "
        [ "$(svc_state "$n")" = active ] || rc=1
    done
    return "$rc"
}

# One object per tunnel, one per line, so `--status --json | while read` is a
# whole integration. The field names are the core's own; inventing a second
# vocabulary for the same numbers is how the two come to mean different things.
status_json() {
    local n=$1 st
    st=$(svc_state "$n")
    # A tunnel that does not answer is not up, and saying so is the report,
    # not a failure to make one.
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
            # The name is optional, so only take the next word if it is one.
            case ${2:-} in '' | -*) ;; *) ARG_NAME=$2; shift ;; esac
            ;;
        --check)
            # A flag here is a missing name, not a name. `--check --json` used
            # to become a health check on a tunnel called "--json".
            ARG_MODE=check
            case ${2:-} in '' | -*) die "--check needs the name of a tunnel" ;; esac
            ARG_NAME=$2
            shift
            ;;
        --json) ARG_JSON=1 ;;
        --new) ARG_MODE=new ;;
        --uninstall) ARG_MODE=uninstall ;;
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

# --------------------------------------------------------------------------
# taking it all off again
# --------------------------------------------------------------------------

# uninstall_all prints the whole list before it touches any of it.
#
# The firewall goes first, and the order is not cosmetic: a DNAT rule pointing
# at a tun address that no longer exists does not error. It quietly swallows
# every connection to that port, and whatever is installed on that port next
# looks broken for a reason nothing on the machine explains.
uninstall_all() {
    local names=() n keep=yes unit
    while IFS= read -r n; do names+=("$n"); done < <(cfg_list)

    blank
    rule "Uninstall"
    field "manager" "$PINGIFY_BIN"
    field "core" "$CORE_BIN"
    field "units" "$UNIT_DIR/pingify@.service and every pingify-* unit"
    field "firewall" "the PINGIFY_* chains, flushed and removed"
    field "sources" "$SRC_DIR"
    field "state" "$STATE_DIR"
    [ "${#names[@]}" -gt 0 ] && field "tunnels" "${names[*]}"
    field "configs" "$CFG_DIR - kept, unless you say so below"
    blank
    confirm "remove all of that?" n || { dim "nothing was removed"; return 1; }
    confirm "delete the configs in $CFG_DIR as well?" n && keep=no
    blank

    for n in "${names[@]}"; do
        nat_drop "$n"
        svc_do stop "$n"
        svc_do disable "$n"
    done
    nat_clear
    block_clear

    for unit in "$UNIT_DIR"/pingify@.service "$UNIT_DIR"/pingify-*.service \
        "$UNIT_DIR"/pingify-*.timer; do
        [ -e "$unit" ] || continue
        systemctl disable --now "${unit##*/}" >/dev/null 2>&1
        rm -f "$unit"
    done
    systemctl daemon-reload >/dev/null 2>&1
    ok "services stopped and removed"

    rm -rf "$SRC_DIR" "$STATE_DIR"
    rm -f "$CORE_BIN"
    if [ "$keep" = no ]; then
        rm -rf "$CFG_DIR"
        ok "configs deleted"
    else
        ok "configs left in $CFG_DIR"
    fi
    rm -f "$PINGIFY_BIN"
    ok "Pingify is removed"

    # The ICMP carrier sets net.ipv4.icmp_echo_ignore_all=1 and nothing puts
    # it back, this included: the sysctl is the core's, and a tunnel still
    # running elsewhere on this box would start answering its own echoes and
    # double its own traffic. So the command is printed, not run.
    if [ "$(cat /proc/sys/net/ipv4/icmp_echo_ignore_all 2>/dev/null)" = 1 ]; then
        blank
        warn "this server is still not answering pings; an ICMP tunnel turned that on"
        fix "sysctl -w net.ipv4.icmp_echo_ignore_all=0"
    fi
    blank
    return 0
}

# --------------------------------------------------------------------------

main() {
    argv "$@"

    # Neither of these reads a config or writes anything, so neither needs to
    # be root, and --version is the first thing anybody runs when a pair does
    # not come up.
    case $ARG_MODE in
    help) usage; exit 0 ;;
    version)
        say "Pingify $PINGIFY_VERSION"
        [ -x "$CORE_BIN" ] && say "core $(core_version)"
        exit 0
        ;;
    esac

    require_root
    ensure_dirs

    # The exit status is the answer on these three, so it is passed straight
    # out rather than being replaced by whatever the last printf returned.
    case $ARG_MODE in
    status) cmd_status; exit $? ;;
    check) health_check "$ARG_NAME" "${ARG_JSON:+json}"; exit $? ;;
    uninstall) uninstall_all; exit $? ;;
    esac

    # Only the interactive paths reinstall the manager. A cron line calling
    # --status every minute has no business rewriting /usr/local/bin, and if
    # it did it would rewrite it from whatever stale copy that cron line
    # happens to point at.
    install_self

    # A missing core warns rather than exits: Uninstall and the host screens
    # still work without one, and a server that cannot reach GitHub and has no
    # Go toolchain is exactly the server whose operator needs to get at them.
    ensure_core || warn "there is no working core installed; Update can fetch or build one"

    case $ARG_MODE in
    new) screen_new ;;
    *) main_menu ;;
    esac
}

# build.sh and the tests source this file to get at its functions; that must
# not launch the menu.
[ -n "${PINGIFY_NO_MAIN:-}" ] || main "$@"
