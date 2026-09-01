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
    #
    # The stamp is written only when the unit is really there. It used to be
    # written whether or not unit_write had worked, so a run where $UNIT_DIR
    # was unwritable left pingify@.service missing and never tried again - the
    # stamp said this version had already done it. The file is the test rather
    # than unit_write's status, because unit_write ends in a daemon-reload and
    # so returns 0 even when its heredoc failed.
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
    # A core that is installed but will not run - built for another
    # architecture, or truncated - returns 1 with nothing on stdout, and the
    # assignment used to keep that empty string: the banner then read
    # "core   |  IRAN" with a hole where the version belongs. Put the dash
    # back on either failure.
    if [ -x "$CORE_BIN" ]; then
        core=$(core_version) || core=$G_DASH
        [ -n "$core" ] || core=$G_DASH
    fi

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
    # 24, not 26. v_name refuses a twenty-fifth character, so the two columns
    # of slack above it could never hold anything and only pushed the numbers
    # further from the name they belong to.
    [ "$nw" -gt 24 ] && nw=24
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
    pingify --update           fetch a newer script and core
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
    # To stderr, because this is the one line on this path that is prose. On
    # stdout it went into the --json stream, where a consumer parsing objects
    # got "! no tunnels are configured" instead.
    [ "${#names[@]}" -gt 0 ] || { warn "no tunnels are configured" >&2; return 1; }

    if [ -n "$ARG_JSON" ]; then
        # The same answer as the screen below gives. This loop used to return
        # 0 whatever it found, so a monitoring script that asked for JSON -
        # the only kind that reads the exit status without reading the output
        # - was told every tunnel was fine while they were all stopped.
        for n in "${names[@]}"; do
            status_json "$n"
            [ "$(svc_state "$n")" = active ] || rc=1
        done
        return "$rc"
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
        # The health check tells both operators to run `pingify --update` when
        # the two ends disagree about a version. Until this case existed that
        # advice fell through to the catch-all below and died with "--update is
        # not an option this script has", which is a poor thing to read when
        # the program itself sent you there.
        --update) ARG_MODE=update ;;
        # Not for people. update_pingify installs the new script and then execs
        # it with this, because the script that did the fetching no longer
        # knows what core the new one wants.
        --rebuild-core) ARG_MODE=rebuild ;;
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
# update_pingify fetches a newer script and, if the version moved, a core to
# match it.
#
# Two places are tried and the order is deliberate. A release asset is what a
# version number points at, but a push to main updates the raw URL instantly
# while the release carrying the matching core lands minutes later - so
# somebody updating in that window from the release alone gets a script that
# does not match the core beside it. Raw main is the fallback, not the first
# choice, because it is whatever was pushed rather than whatever was released.
#
# Nothing is installed until it parses. A half-downloaded shell script is a
# syntactically valid prefix of a working one, which is the worst possible
# failure: it runs, and it stops in the middle.
PINGIFY_REPO=${PINGIFY_REPO:-GreatTeejay/Pingify}

update_pingify() {
    local tmp rc=1 url
    blank
    rule "Update"
    blank

    have curl || have wget || {
        bad "neither curl nor wget is here, so there is nothing to fetch with"
        fix "apt install curl"
        pause
        return 1
    }

    tmp=$(mktemp) || return 1
    for url in \
        "https://github.com/$PINGIFY_REPO/releases/latest/download/Pingify.sh" \
        "https://raw.githubusercontent.com/$PINGIFY_REPO/main/Pingify.sh"; do
        dim "trying $url"
        if have curl; then
            curl -fsSL --connect-timeout 20 --retry 2 -o "$tmp" "$url" 2>/dev/null && rc=0
        else
            wget -qO "$tmp" "$url" 2>/dev/null && rc=0
        fi
        [ "$rc" = 0 ] && break
    done

    if [ "$rc" != 0 ]; then
        rm -f "$tmp"
        bad "nothing could be fetched from either place"
        fix "check this server can reach github, or copy Pingify.sh over yourself"
        pause
        return 1
    fi

    # It must be a shell script, it must parse, and it must be ours. A captive
    # portal answering every request with an HTML login page passes "the
    # download worked" and fails all three of these.
    if ! head -1 "$tmp" | grep -q '^#!.*bash'; then
        rm -f "$tmp"
        bad "what came back is not a shell script - something on the way answered instead"
        pause
        return 1
    fi
    if ! bash -n "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        bad "what came back does not parse, so it arrived incomplete"
        fix "try again - a truncated script is worse than an old one"
        pause
        return 1
    fi

    local newver
    newver=$(PINGIFY_NO_MAIN=1 bash -c '. "$1"; printf "%s" "$PINGIFY_VERSION"' _ "$tmp" 2>/dev/null)
    if [ -z "$newver" ]; then
        rm -f "$tmp"
        bad "that script would not tell us its version, so it is not one of ours"
        pause
        return 1
    fi
    if [ "$newver" = "$PINGIFY_VERSION" ]; then
        rm -f "$tmp"
        ok "already on $PINGIFY_VERSION - nothing to do"
        pause
        return 0
    fi

    blank
    field "installed" "$PINGIFY_VERSION"
    field "available" "$newver"
    blank
    dim "the core is rebuilt to match, and every running tunnel is restarted"
    blank
    confirm "update to $newver?" || { rm -f "$tmp"; return 1; }

    install -m 0755 "$tmp" "$PINGIFY_BIN" || {
        rm -f "$tmp"
        bad "could not write $PINGIFY_BIN"
        pause
        return 1
    }
    rm -f "$tmp"
    ok "the manager is now $newver"

    # The core has to move with it: a script and a core from different versions
    # is the one combination neither is built to work in. Hand over to the new
    # script rather than doing it here, because this one no longer knows what
    # the new core is supposed to be.
    blank
    dim "handing over to the new script to build its core"
    blank
    exec "$PINGIFY_BIN" --rebuild-core
}

uninstall_all() {
    local names=() n keep=yes unit rc=0 units=0
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
    # 2, not 1. Saying no is a decision rather than a failure, and main turns
    # this into an exit 0 so that `pingify --uninstall` does not report an
    # error for a deliberate no. It cannot simply be 0 either: the menu's x key
    # exits the program when this function succeeds, and a decline has to leave
    # the operator on the screen they were looking at.
    confirm "remove all of that?" n || { dim "nothing was removed"; return 2; }
    confirm "delete the configs in $CFG_DIR as well?" n && keep=no
    blank

    for n in "${names[@]}"; do
        nat_drop "$n"
        svc_do stop "$n"
        svc_do disable "$n"
    done
    # Both of these ran with their status thrown away, under ok lines that
    # printed regardless. An uninstall that could not reach iptables reported a
    # clean removal with the PINGIFY_* chains still in the kernel, which is the
    # worst way to leave them: whatever is installed on one of those ports next
    # looks broken for a reason nothing on the machine explains.
    # They are two separate cleanups and both run whatever the other did: a
    # failed NAT teardown is no reason to leave the blocking rules behind too.
    nat_teardown || rc=1
    remove_blocking || rc=1
    if [ "$rc" != 0 ]; then
        bad "the firewall chains are still installed"
        fix "run this again once iptables works"
    fi

    for unit in "$UNIT_DIR"/pingify@.service "$UNIT_DIR"/pingify-*.service \
        "$UNIT_DIR"/pingify-*.timer; do
        [ -e "$unit" ] || continue
        systemctl disable --now "${unit##*/}" >/dev/null 2>&1
        rm -f "$unit"
        # rm -f says nothing about a file it could not remove, so the file
        # itself is the test.
        [ -e "$unit" ] && { units=1; rc=1; }
    done
    systemctl daemon-reload >/dev/null 2>&1
    if [ "$units" = 0 ]; then
        ok "services stopped and removed"
    else
        bad "some units are still in $UNIT_DIR"
    fi

    rm -rf "$SRC_DIR" "$STATE_DIR"
    rm -f "$CORE_BIN"
    if [ "$keep" = no ]; then
        rm -rf "$CFG_DIR"
        ok "configs deleted"
    else
        ok "configs left in $CFG_DIR"
    fi
    rm -f "$PINGIFY_BIN"
    # The closing line reports what happened rather than what was intended.
    if [ "$rc" = 0 ]; then
        ok "Pingify is removed"
    else
        bad "Pingify is off, but the lines above say what is left"
    fi

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
    return "$rc"
}

# --------------------------------------------------------------------------

main() {
    local rc
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
    # The word matters. chk_finish tests for --json, and the bare "json" that
    # was passed here never matched it, so `--check NAME --json` rendered the
    # escape coded human screen into whatever was parsing it and exited as
    # though it had answered the question that was asked.
    check) health_check "$ARG_NAME" "${ARG_JSON:+--json}"; exit $? ;;
    uninstall)
        uninstall_all
        rc=$?
        # 2 is "you said no", which is not an error to report to a shell.
        [ "$rc" = 2 ] && rc=0
        exit "$rc"
        ;;
    esac

    # Update comes before ensure_core on purpose. Building the core this
    # version wants, moments before the next version asks for a different one,
    # is a Go build on a slow server that nobody gets any use out of - and
    # update_pingify installs the manager itself, so install_self has nothing
    # to add either.
    case $ARG_MODE in
    update) update_pingify; exit $? ;;
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
    rebuild)
        require_root
        ensure_dirs
        unit_write
        if ensure_core; then
            local n
            while IFS= read -r n; do
                systemctl is-enabled --quiet "pingify@$n" 2>/dev/null &&
                    svc_do restart "$n"
            done < <(cfg_list)
            ok "everything is on $PINGIFY_VERSION"
        else
            bad "the manager was updated but its core could not be built"
            fix "run pingify and choose Update again once the reason is fixed"
            exit 1
        fi
        ;;
    *) main_menu ;;
    esac
}

# build.sh and the tests source this file to get at its functions; that must
# not launch the menu.
[ -n "${PINGIFY_NO_MAIN:-}" ] || main "$@"
