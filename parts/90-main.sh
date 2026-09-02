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

# --------------------------------------------------------------------------
# what this machine is, and what Pingify is doing on it
# --------------------------------------------------------------------------

# srv_info fills in the three lines at the top of the home screen: the address
# the outside world sees this server at, and where that address is.
#
# It is cached in a file and read back from there. The home screen is drawn
# again every time you come back to it, and a lookup over the network inside
# that loop is the difference between a manager that answers at once and one
# that stops for six seconds on every return. A datacentre does not move: the
# cache is a week old before anything is fetched again.
#
# None of it is required. A server with no route out shows the address on its
# own interface and says plainly that it does not know the rest, because
# "not known from here" in a panel is information and a blank line is a bug.
SRV_TTL_DAYS=7

srv_info() {
    [ -n "${SRV_IP:-}" ] && return 0
    local cache=$STATE_DIR/server.info j

    if [ -f "$cache" ] && [ -z "$(find "$cache" -mtime "+$SRV_TTL_DAYS" 2>/dev/null)" ]; then
        IFS='|' read -r SRV_IP SRV_LOC SRV_ORG <"$cache"
    fi

    # One request, three fields, six seconds at the outside. The address being
    # looked up is this server's own. json_field is no use here - it reads the
    # core's output, which is one field to a line, and this arrives as one.
    if [ -z "${SRV_IP:-}" ] && have curl; then
        j=$(curl -fsS --max-time 6 \
            'http://ip-api.com/json/?fields=query,country,isp' 2>/dev/null)
        SRV_IP=$(printf '%s' "$j" | sed -n 's/.*"query":"\([^"]*\)".*/\1/p')
        SRV_LOC=$(printf '%s' "$j" | sed -n 's/.*"country":"\([^"]*\)".*/\1/p')
        SRV_ORG=$(printf '%s' "$j" | sed -n 's/.*"isp":"\([^"]*\)".*/\1/p')
        [ -n "$SRV_IP" ] &&
            printf '%s|%s|%s\n' "$SRV_IP" "$SRV_LOC" "$SRV_ORG" >"$cache"
    fi

    [ -n "${SRV_IP:-}" ] || SRV_IP=$(wiz_public_ip)
    [ -n "${SRV_IP:-}" ] || SRV_IP=$G_DASH
    [ -n "${SRV_LOC:-}" ] || SRV_LOC="not known from here"
    [ -n "${SRV_ORG:-}" ] || SRV_ORG="not known from here"
    return 0
}

# home_panels is the two boxes under the name.
#
# Everything on them is one file read or one systemctl call, because they are
# drawn again on every return to this screen. The side of the border is here
# rather than on every tunnel row: one server is one side - `side` is the only
# line that differs between the two ends - so it is the same in all of this
# server's configs and belongs with the server, not with a tunnel.
home_panels() {
    local n st side= up=0 off=0 total=0 core=$G_DASH core_txt tun_txt dog secs rest

    while IFS= read -r n; do
        total=$((total + 1))
        st=$(svc_state "$n")
        [ "$st" = active ] && up=$((up + 1))
        [ "$st" = disabled ] && off=$((off + 1))
        [ -n "$side" ] || side=$(toml_get "$(cfg_file "$n")" tunnel side)
    done < <(cfg_list)

    case $side in
    iran) side="IRAN $G_DASH users connect here" ;;
    kharej) side="KHAREJ $G_DASH your panel is here" ;;
    *) side="not decided yet" ;;
    esac

    srv_info
    blank
    panel_open "SERVER"
    panel_field "IP" "$(addr_text "$SRV_IP")"
    panel_field "Location" "$SRV_LOC"
    panel_field "Datacenter" "$SRV_ORG"
    panel_field "Side" "$side"
    panel_close

    # A core that is installed but will not run - built for another
    # architecture, or truncated - returns 1 with nothing on stdout, and the
    # assignment used to keep that empty string, so the line read "core" with
    # a hole where the version belongs. Put the dash back on either failure.
    if [ -x "$CORE_BIN" ]; then
        core=$(core_version) || core=$G_DASH
        [ -n "$core" ] || core=$G_DASH
    fi
    if [ "$core" = "$G_DASH" ]; then
        core_txt="${C_BAD}not installed${C_OFF}"
    elif [ "$core" = "$PINGIFY_VERSION" ]; then
        core_txt=$core
    else
        # Not a detail. A core and a script from two versions is the one
        # combination neither of them is built to work in.
        core_txt="$core ${C_WARN}$G_DASH the script is $PINGIFY_VERSION${C_OFF}"
    fi

    if [ "$total" = 0 ]; then
        tun_txt="$(state_dot none) none configured"
        dog="$(state_dot none) nothing to watch yet"
    else
        if [ "$up" = "$total" ]; then
            tun_txt="$(state_dot running) $up of $total up"
        elif [ "$up" = 0 ]; then
            tun_txt="$(state_dot stopped) none of $total up"
        else
            tun_txt="$(state_dot idle) $up of $total up"
        fi
        # There is no separate watchdog process and there should not be one.
        # systemd is the watchdog: the unit brings a tunnel back two seconds
        # after it dies. What can be wrong is a tunnel that was never enabled,
        # so that is what this line reports.
        if [ "$off" = 0 ]; then
            dog="$(state_dot running) on, a dead tunnel is back in 2s"
        else
            dog="$(state_dot idle) $off not started at boot"
        fi
    fi

    read -r secs rest </proc/uptime 2>/dev/null || secs=
    panel_open "STATUS"
    panel_field "Core ver" "$core_txt"
    panel_field "Script ver" "$PINGIFY_VERSION"
    panel_field "Tunnels" "$tun_txt"
    panel_field "Watchdog" "$dog"
    panel_field "Uptime" "$(human_secs "${secs%%.*}")"
    panel_close
}

# home_row is one tunnel, and it is also the menu item for that tunnel. The
# old manager printed a status table and then a second numbered list of the
# same names under it, so every name was on the screen twice and the numbers
# on the second list matched nothing on the first.
#
# The round trip is measured only for a tunnel that is running: probing a
# stopped one costs three seconds of ping timeout for an answer already known.
home_row() {
    local name=$1 key=$2 st=stopped dot=stopped rtt=$G_DASH up=$G_DASH rate= transport=
    st=$(svc_state "$name")
    transport=$(toml_get "$(cfg_file "$name")" transport type)
    [ -n "$transport" ] || transport=udp
    rate=$st

    case $st in
    active)
        dot=idle
        if tun_stats "$name"; then
            # How long this tunnel has been carrying, which is not how long
            # the machine has been up and not how long the unit has existed:
            # it is the core's own clock, so a tunnel that has been quietly
            # restarting every few minutes says so here.
            up=$(human_secs "$ST_UPTIME")
            # Green means somebody is at the other end, which is not what the
            # core's up says on the side that dials: there, up is true from
            # the first second because the address was in the config. Amber
            # for running-and-alone, which is what the dot has always meant.
            [ "$ST_UP" = true ] && [ "${ST_INB:-0}" != 0 ] && dot=running
            [ -n "$ST_TRANSPORT" ] && transport=$ST_TRANSPORT
            rate="$(round1 "$ST_IN")/$(round1 "$ST_OUT")"
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

    # The key is right aligned in two columns so that the tenth tunnel's dot
    # stands in the same place as the first one's, and so that the blank key
    # --status passes costs the line nothing.
    row "$(printf '%2s' "$key") $(state_dot "$dot")" \
        "$name" "${transport^^}" "$up" "$rtt" "$rate"
}

# The names of the columns, once, above them.
#
# Five numbers with no headings is a row somebody has to be told how to read.
# It is dim because it is not the data, and it goes through row() like every
# line under it, so a column cannot be renamed into the wrong place.
home_head() {
    printf '%s%s%s\n' "$C_KEY" \
        "$(row "" "TUNNEL" "VIA" "UP" "PING" "MBIT/S")" "$C_OFF"
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
    # 52, not 50: the transport column took two characters for FALLBACK, and
    # the name column gives both back. One more than this and the row runs a
    # character past the sixty-eight the screen is drawn at, which costs the
    # whole right hand end of every line to an ellipsis.
    local nw=$((UI_W - 52))
    # 24, not 26. v_name refuses a twenty-fifth character, so the two columns
    # of slack above it could never hold anything and only pushed the numbers
    # further from the name they belong to.
    [ "$nw" -gt 24 ] && nw=24
    [ "$nw" -lt 8 ] && nw=8
    # key and dot, name, transport, uptime, round trip, and the two rates.
    # The rates lose their unit to make room for the uptime; the heading over
    # the column carries it instead, which is where a unit belongs.
    #
    # Eight for the transport, not six: FALLBACK is eight characters and the
    # row at its widest is 63 of the 68 this screen is drawn at, so the room
    # was already there.
    UI_COLS=(4 "$nw" 8 7 8 12)
}

# The home screen: the name, the two panels, whatever is running, and a
# numbered list of everything that can be done from here.
#
# The numbers are fixed, and that is the point of them. They were letters, and
# the tunnels themselves were keys on this screen, so the key for Uninstall
# moved down the alphabet every time somebody added a tunnel. Nothing here
# moves now: 7 is Remove on a server with no tunnels and on a server with ten.
screen_home() {
    local n names=()
    while IFS= read -r n; do names+=("$n"); done < <(cfg_list)

    screen_top
    home_panels

    if [ "${#names[@]}" -gt 0 ]; then
        blank
        group "RUNNING NOW"
        home_cols
        home_head
        for n in "${names[@]}"; do home_row "$n" " "; done
    fi

    blank
    group "TUNNELS"
    item 1 "New tunnel" "set this server up, or finish the pair"
    item 2 "Manage tunnels" "status, ports, profile, logs, remove"
    item 3 "Health check" "every tunnel, and what to do about it"
    blank
    group "NETWORK"
    item 4 "Host tuning" "kernel profile, BBR, descriptor limits"
    item 5 "Blocking" "ping from outside, QUIC on udp 443, speedtest"
    blank
    group "MAINTENANCE"
    item 6 "Update Pingify" "script and core together, to the same version"
    item 7 "Remove" "uninstall part of it, or all of it"
    blank
    item 0 "Exit"
    blank
}

# screen_tunnels is the list, and the way into one of them.
#
# One tunnel is the common case and it does not deserve a screen of its own:
# with one there is nothing to choose, so this goes straight in. The list is
# read again on the way back out of a tunnel, because the last thing that
# screen offers is deleting it, and a tunnel that has just been deleted must
# not still be on the list you are returned to.
screen_tunnels() {
    local names=() n i k
    while IFS= read -r n; do names+=("$n"); done < <(cfg_list)

    if [ "${#names[@]}" -eq 0 ]; then
        screen_top
        blank
        rule "Manage tunnels"
        blank
        dim "no tunnels on this server yet - pick New tunnel to make one"
        pause
        return 0
    fi
    if [ "${#names[@]}" -eq 1 ]; then
        screen_tunnel "${names[0]}"
        return 0
    fi

    while :; do
        screen_top
        blank
        rule "Manage tunnels"
        blank
        home_cols
        home_head
        i=0
        while [ "$i" -lt "${#names[@]}" ]; do
            home_row "${names[i]}" "$((i + 1))"
            i=$((i + 1))
        done
        blank
        item 0 "Back"
        blank

        menu_key k || return 0
        case $k in
        0 | '') return 0 ;;
        *[!0-9]*) blank; warn "there is nothing on $k" ;;
        *)
            if [ "$k" -ge 1 ] && [ "$k" -le "${#names[@]}" ]; then
                screen_tunnel "${names[k - 1]}"
                names=()
                while IFS= read -r n; do names+=("$n"); done < <(cfg_list)
                [ "${#names[@]}" -eq 0 ] && return 0
            else
                blank
                warn "there is nothing on $k"
            fi
            ;;
        esac
    done
}

# screen_health runs the check over every tunnel rather than over one.
#
# The worst answer is the one that is kept. Returning whatever the last check
# said would tell a server whose second tunnel of three is broken that it was
# clean, because the third one was.
screen_health() {
    local names=() n rc=0 one
    while IFS= read -r n; do names+=("$n"); done < <(cfg_list)
    screen_top

    if [ "${#names[@]}" -eq 0 ]; then
        blank
        warn "there are no tunnels to check yet"
        pause
        return 0
    fi
    for n in "${names[@]}"; do
        health_check "$n" || { one=$?; [ "$one" -gt "$rc" ] && rc=$one; }
    done
    pause
    return "$rc"
}

main_menu() {
    local c
    while :; do
        screen_home
        menu_key c || return 0
        case $c in
        1) screen_new ;;
        2) screen_tunnels ;;
        3) screen_health ;;
        4) screen_host ;;
        5) screen_firewall ;;
        6) update_pingify ;;
        7) uninstall_all && exit 0 ;;
        # q is not on the screen and works anyway: it is what every question
        # in the wizard takes for "let me out of this", and somebody who
        # learned it there types it here.
        0 | q | Q) blank; return 0 ;;
        '') ;;
        *) blank; warn "there is nothing on $c" ;;
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
    home_head
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
    screen_top
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

    # Which way it is going. Anything that is not the version installed used to
    # be offered as an update, so a release that had been rolled back - or a
    # server running a build made by hand - was told to go backwards, with
    # enter as the answer that did it. Backwards is allowed, and it is not the
    # default and does not call itself an update.
    if ver_ge "$newver" "$PINGIFY_VERSION"; then
        confirm "update to $newver?" || { rm -f "$tmp"; return 1; }
    else
        warn "$newver is older than the $PINGIFY_VERSION on this server"
        fix "the core is rebuilt to match, so both ends go back together"
        confirm "go back to $newver?" n || { rm -f "$tmp"; return 1; }
    fi

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

    screen_top
    blank
    rule "Uninstall"
    field "manager" "$PINGIFY_BIN"
    field "core" "$CORE_BIN"
    field "units" "$UNIT_DIR/pingify@.service and every pingify-* unit"
    field "firewall" "the PINGIFY_* chains, flushed and removed"
    field "state" "$STATE_DIR"
    [ "${#names[@]}" -gt 0 ] && field "tunnels" "${names[*]}"
    field "tunnels in" "$CFG_DIR - kept, unless you say so below"
    blank
    # 2, not 1. Saying no is a decision rather than a failure, and main turns
    # this into an exit 0 so that `pingify --uninstall` does not report an
    # error for a deliberate no. It cannot simply be 0 either: the Remove key
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

    # The core and its sources go whatever the answer below was: they are the
    # program, not the settings, and keeping them without a manager to run
    # them leaves a binary nothing on the machine explains.
    rm -rf "$CORE_DIR" "$STATE_DIR"
    if [ "$keep" = no ]; then
        rm -rf "$CFG_DIR"
        ok "tunnels deleted"
    else
        ok "tunnels left in $CFG_DIR"
    fi
    # Only if it is empty, which it is when the tunnels went too.
    rmdir "$BASE_DIR" 2>/dev/null
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
    # Before install_self, not after. install_self writes its version stamp
    # into the state directory, so running it first put a file in the new
    # place that the move then refused to overwrite - and left the old
    # directory behind with one file in it, for ever.
    migrate_layout
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
            fix "run pingify and choose 6, Update Pingify, once the reason is fixed"
            exit 1
        fi
        ;;
    *) main_menu ;;
    esac
}

# build.sh and the tests source this file to get at its functions; that must
# not launch the menu.
[ -n "${PINGIFY_NO_MAIN:-}" ] || main "$@"
