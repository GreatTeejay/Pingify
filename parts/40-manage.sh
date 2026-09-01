#!/usr/bin/env bash
#
# The screen a person looks at most: one tunnel, what it is doing, and the
# things they might want to do to it.
#
# It is one screen and it fits on a phone. The old manager put the same
# information behind three menus and then listed the tunnels twice on the way
# in - once as a status table and again as a numbered list of the same names -
# so choosing one meant reading the same six words in two places and matching
# them up by eye.

# --------------------------------------------------------------------------
# what a tunnel is doing
# --------------------------------------------------------------------------

# tun_line fills TL_* for one tunnel: enough for a row on the home screen.
#
# Two sources and no third. systemd says whether the unit is running, and the
# core's own status endpoint says whether it is carrying anything. Nothing here
# reads the log, because a log line is prose and prose gets reworded - the old
# manager took the eighth field of an English sentence and broke the day
# somebody improved the sentence.
tun_line() {
    local name=$1 state
    TL_STATE=unknown TL_RATE= TL_PEER= TL_RTT= TL_TRANSPORT= TL_SIDE=

    local f
    f=$(cfg_file "$name")
    TL_TRANSPORT=$(toml_get "$f" transport type)
    TL_SIDE=$(toml_get "$f" tunnel side)
    TL_PEER=$(peer_addr "$name")

    state=$(svc_state "$name")
    case $state in
    disabled | stopped)
        TL_STATE=$state
        return
        ;;
    esac

    if tun_stats "$name"; then
        # Running and the far end has been seen is the only state that earns a
        # green dot. Running and alone looks identical from here and is not
        # the same thing at all.
        if [ "$ST_UP" = true ] && [ "${ST_INB:-0}" != 0 ]; then
            TL_STATE=running
        else
            TL_STATE=idle
        fi
        TL_RATE="$(round1 "$ST_IN")/$(round1 "$ST_OUT") Mbit/s"
    else
        # The unit is up but the endpoint does not answer. That is a real
        # state and it is not a failure to report in red: it happens for the
        # first second of every start.
        TL_STATE=idle
    fi
    TL_RTT=$(tun_rtt "$name")
}

# peer_addr is the other end of the private link, without its prefix.
peer_addr() {
    local f side a
    f=$(cfg_file "$1")
    side=$(toml_get "$f" tunnel side)
    if [ "$side" = iran ]; then
        a=$(toml_get "$f" tun kharej)
    else
        a=$(toml_get "$f" tun iran)
    fi
    printf '%s' "${a%%/*}"
}

my_addr() {
    local f side a
    f=$(cfg_file "$1")
    side=$(toml_get "$f" tunnel side)
    if [ "$side" = iran ]; then
        a=$(toml_get "$f" tun iran)
    else
        a=$(toml_get "$f" tun kharej)
    fi
    printf '%s' "${a%%/*}"
}

# tun_rtt is the round trip across the private link, or nothing.
#
# Nothing, on an ICMP tunnel, and that is the correct answer rather than a
# missing one. An ICMP carrier stops both kernels answering echo - it has to,
# or every packet it sends is answered twice - so a ping across the link goes
# out and is deliberately ignored. The old manager would have drawn that in red
# and told the user their working tunnel was dead.
tun_rtt() {
    local name=$1 t out
    t=$(toml_get "$(cfg_file "$name")" transport type)
    [ "$t" = icmp ] && return 0
    have ping || return 0
    out=$(ping -c 2 -W 2 -q "$(peer_addr "$name")" 2>/dev/null |
        awk -F'/' '/^rtt|^round-trip/ {printf "%.0f", $5}')
    printf '%s' "$out"
}

# --------------------------------------------------------------------------
# the tunnel screen
# --------------------------------------------------------------------------

screen_tunnel() {
    local name=$1 f
    f=$(cfg_file "$name")
    [ -f "$f" ] || { bad "there is no tunnel called $name"; return 1; }

    while :; do
        tun_line "$name"
        blank
        printf '  %s%s%s%s%s %s\n' "$C_B" "$name" "$C_OFF" \
            "$(rep ' ' $((UI_W - ${#name} - 16)))" \
            "$(state_dot "$TL_STATE")" "$TL_STATE"
        blank

        local side kharej port transport mtu dev prof
        side=$(toml_get "$f" tunnel side)
        kharej=$(toml_get "$f" transport kharej)
        port=$(toml_get "$f" transport port)
        transport=$(toml_get "$f" transport type)
        mtu=$(toml_get "$f" tun mtu)
        dev=$(toml_get "$f" tun name)
        prof=$(toml_get "$f" tuning profile)

        if [ "$side" = iran ]; then
            if [ "$transport" = icmp ]; then
                field "Side" "IRAN, dials $kharej over icmp"
            else
                field "Side" "IRAN, dials $kharej:$port/udp"
            fi
        else
            if [ "$transport" = icmp ]; then
                field "Side" "KHAREJ, waits for echo"
            else
                field "Side" "KHAREJ, waits on udp/$port"
            fi
        fi
        field "Link" "$(my_addr "$name") $G_BOTH $(peer_addr "$name")   $dev   mtu $mtu"

        if [ -n "$TL_RATE" ]; then
            local rtt=$TL_RTT
            if [ -n "$rtt" ]; then
                field "Carrying" "$TL_RATE      $(rtt_colour "$rtt")$rtt ms$C_OFF"
            else
                field "Carrying" "$TL_RATE"
            fi
        fi

        # Losses only when there are some. A line saying zero every time is a
        # line people stop reading, and then they do not see it change.
        if [ -n "${ST_LOST:-}" ] && [ "${ST_LOST:-0}" -gt 0 ]; then
            local per=$((ST_LOST / (ST_GAPS > 0 ? ST_GAPS : 1)))
            field "Path took" "$ST_LOST packets in $ST_GAPS runs, about $per at a time"
        fi

        local fw
        fw=$(forwards_of "$name" 2>/dev/null || true)
        [ -n "$fw" ] && field "Ports" "$fw  $G_ARROW  $(peer_addr "$name")"

        blank
        group "RUN"
        case $TL_STATE in
        stopped | disabled) item 1 "Start" ;;
        *) item 1 "Restart" ;;
        esac
        item 2 "Stop"
        item 3 "Live view"
        blank
        group "CHECK"
        item 4 "Health check" "what is wrong, and the fix"
        item 5 "Log"
        item 6 "Measure MTU"
        item 7 "Speed test"
        blank
        group "CHANGE"
        if [ "$side" = iran ]; then
            item2 8 "Ports" "${fw:-none}"
        else
            item2 8 "Ports" "IRAN forwards them, not this side"
        fi
        item2 9 "Profile" "$prof"
        item 10 "Advanced" "mtu, log level, queues"
        item 11 "Delete this tunnel"
        item 0 "Back"
        blank

        local k
        menu_key k || return 0
        case $k in
        1) svc_do restart "$name"; pause ;;
        2) svc_do stop "$name"; pause ;;
        3) screen_live "$name" ;;
        4) health_check "$name"; pause ;;
        5) show_log "$name" ;;
        6) measure_mtu "$name"; pause ;;
        7) speed_test "$name"; pause ;;
        8) [ "$side" = iran ] && { screen_ports "$name"; } ||
            { warn "ports are forwarded from the IRAN side"; pause; } ;;
        9) edit_profile "$name" ;;
        10) screen_advanced "$name" ;;
        11) delete_tunnel "$name" && return 0 ;;
        0 | '') return 0 ;;
        esac
    done
}

pause() {
    blank
    printf '  %spress enter%s' "$C_MUTE" "$C_OFF" >&2
    IFS= read -r _ || true
}

show_log() {
    blank
    rule "Log $G_DASH $1"
    blank
    journalctl -u "pingify@$1" -n 40 --no-pager -o cat 2>/dev/null |
        sed 's/^/    /' || dim "there is no journal for this tunnel yet"
    pause
}

# --------------------------------------------------------------------------
# changing one
# --------------------------------------------------------------------------

# edit_profile is the screen that justifies the whole tool: it does not show a
# setting, it shows what the setting buys. Every number here was measured on a
# real path between Tehran and Frankfurt.
edit_profile() {
    local name=$1 cur choice
    cur=$(toml_get "$(cfg_file "$name")" tuning profile)

    blank
    rule "What crosses this link"
    blank
    printf '    %s%s%s\n' "$C_KEY" \
        "$(pad_to '' 14)16 streams   one stream   under load" "$C_OFF"
    profile_row 1 gaming "$cur" "397 Mbit/s" "167 Mbit/s" "84.5 / 92.5 ms"
    profile_row 2 balanced "$cur" "448" "254" "93.3 / 106.5"
    profile_row 3 download "$cur" "466" "253" "115.8 / 139.3"
    blank
    dim "Balanced is not the middle: it carries one stream faster than either"
    dim "of the others. Idle ping is 81 ms whichever you choose."
    blank

    local def=2
    case $cur in gaming) def=1 ;; download) def=3 ;; esac

    # A way out that is a number, like every other screen reached from a menu.
    # This used pick, which answers 1 to 3 and nothing else on purpose - that
    # is right for a question in the wizard and wrong here: 0 was refused and
    # the screen asked again, so the only exit was the q nothing on it
    # mentions. Enter still keeps what the tunnel already has.
    item 0 "Leave it on $cur"
    blank
    menu_key choice || return 0
    [ -z "$choice" ] && choice=$def

    local want
    case $choice in
    1) want=gaming ;;
    2) want=balanced ;;
    3) want=download ;;
    0) return 0 ;;
    *) blank; warn "there is nothing on $choice"; pause; return 0 ;;
    esac
    [ "$want" = "$cur" ] && return 0

    PROFILE_WANT=$want
    if cfg_apply "$name" _edit_profile yes; then
        ok "$name is on the $want profile"
    fi
    pause
}

_edit_profile() { toml_set "$1" tuning profile "$PROFILE_WANT"; }

profile_row() {
    local key=$1 name=$2 cur=$3 a=$4 b=$5 c=$6 mark=' '
    [ "$name" = "$cur" ] && mark=$G_CUR
    printf '  %s%s%s %s%s%s  %s%s%s%s\n' \
        "$C_ACCENT" "$mark" "$C_OFF" \
        "$C_ACCENT" "$key" "$C_OFF" \
        "$(pad_to "${name^}" 11)" "$(pad_to "$a" 13)" "$(pad_to "$b" 13)" "$c"
}

screen_advanced() {
    local name=$1 f k q qs
    f=$(cfg_file "$name")
    while :; do
        # Two of these are not in the file until somebody sets them: the
        # profile carries the queue depth, and the core picks the number of
        # device queues. Reading the file alone drew "Queue depth  packets,
        # from the profile" with the number missing out of the middle of it,
        # and then offered an empty default that the validator refused - so
        # pressing enter at the question did nothing at all, twice.
        q=$(toml_get "$f" tuning queue_packets)
        qs=$(toml_get "$f" tun queues)
        blank
        rule "Advanced $G_DASH $name"
        blank
        item2 1 "MTU" "$(toml_get "$f" tun mtu)"
        item2 2 "Log level" "$(toml_get "$f" logging level)"
        if [ -n "$q" ]; then
            item2 3 "Queue depth" "$q packets, set here"
        else
            q=$(wiz_queue "$(toml_get "$f" tuning profile)")
            item2 3 "Queue depth" "$q packets, from the profile"
        fi
        item2 4 "Device queues" "${qs:-the core chooses}"
        item 5 "Show the config file"
        item 0 "Back"
        blank
        menu_key k || return 0
        case $k in
        1) local v
            ask v "mtu" "$(toml_get "$f" tun mtu)" v_mtu || continue
            MTU_WANT=$v; cfg_apply "$name" _edit_mtu yes; pause ;;
        2) local v
            blank; dim "debug says a great deal; info says what changed"; blank
            ask v "level" "$(toml_get "$f" logging level)" v_level || continue
            LEVEL_WANT=$v; cfg_apply "$name" _edit_level yes; pause ;;
        3) blank
            dim "This comes from the profile and is the one number a profile moves."
            dim "Set it directly only if you have measured your own path."
            local v
            ask v "packets" "$q" v_queue || continue
            QUEUE_WANT=$v; cfg_apply "$name" _edit_queue yes; pause ;;
        4) local v
            ask v "queues (0 lets the core choose)" "${qs:-0}" v_queues || continue
            QUEUES_WANT=$v; cfg_apply "$name" _edit_queues yes; pause ;;
        5) blank; sed 's/^/    /' "$f"; pause ;;
        0 | '') return 0 ;;
        esac
    done
}

_edit_mtu() { toml_set "$1" tun mtu "$MTU_WANT"; }
_edit_level() { toml_set "$1" logging level "$LEVEL_WANT"; }
_edit_queue() { toml_set "$1" tuning queue_packets "$QUEUE_WANT"; }
_edit_queues() { toml_set "$1" tun queues "$QUEUES_WANT"; }

v_level() {
    case $1 in
    debug | info | warn | error) return 0 ;;
    esac
    echo "debug, info, warn or error"
    return 1
}

v_queue() {
    case $1 in '' | *[!0-9]*) echo "a number of packets"; return 1 ;; esac
    { [ "$1" -ge 200 ] && [ "$1" -le 20000 ]; } || {
        echo "200 to 20000 - below that the queue refuses work the link could carry"
        return 1
    }
}

v_queues() {
    case $1 in '' | *[!0-9]*) echo "a number"; return 1 ;; esac
    [ "$1" -le 16 ] || { echo "0 to 16"; return 1; }
}

delete_tunnel() {
    local name=$1
    blank
    warn "this removes the tunnel $name from this server"
    dim "the other server keeps its own copy until you remove it there too"
    blank
    confirm "delete $name?" n || return 1

    svc_do stop "$name" 2>/dev/null || true
    systemctl disable "pingify@$name" >/dev/null 2>&1 || true
    nat_drop "$name" 2>/dev/null || true
    rm -f "$(cfg_file "$name")" "$STATE_DIR/$name.forwards"
    ok "$name is gone"
    pause
    return 0
}
