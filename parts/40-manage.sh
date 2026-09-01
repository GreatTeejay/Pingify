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
# The queue depth beside the profile's name. "balanced" on its own does not
# say what it does, and the depth is the whole of what a profile changes.
prof_queue_note() {
    local f=$1 q
    q=$(toml_get "$f" tuning queue_packets)
    [ -n "$q" ] || q=$(wiz_queue "$(toml_get "$f" tuning profile)")
    [ -n "$q" ] || return 0
    printf ' %s %s packets' "$G_DASH" "$q"
}

tun_line() {
    local name=$1 state
    TL_STATE=unknown TL_RATE= TL_PEER= TL_RTT= TL_TRANSPORT= TL_SIDE= TL_UPTIME=

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
        TL_RATE="$(round1 "$ST_IN") in, $(round1 "$ST_OUT") out"
        TL_UPTIME=$(human_secs "$ST_UPTIME")
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
    local name=$1 t out hp peer
    t=$(toml_get "$(cfg_file "$name")" transport type)

    # An ICMP tunnel cannot be pinged. The carrier stops both kernels
    # answering echo - it has to, or every packet it sends is answered twice -
    # so the ping goes out and is deliberately ignored, and for a long time
    # this returned nothing at all and every screen showed a dash.
    #
    # The far end answers on its health port instead, and curl's time_connect
    # is the TCP handshake: one round trip across the link and nothing else in
    # it. It is the same measurement a ping would have made.
    if [ "$t" = icmp ]; then
        have curl || return 0
        hp=$(health_port_of "$name")
        peer=$(peer_addr "$name")
        [ -n "$peer" ] && [ "$hp" -gt 0 ] 2>/dev/null || return 0
        out=$(LC_ALL=C curl -s -o /dev/null --max-time 2 \
            -w '%{time_connect}' "http://$peer:$hp/healthz" 2>/dev/null) || return 0
        case $out in '' | 0 | 0.000000) return 0 ;; esac
        LC_ALL=C awk -v t="$out" 'BEGIN { printf "%.0f", t * 1000 }'
        return 0
    fi

    have ping || return 0
    # Two packets a fifth of a second apart, and one second to wait. This is
    # on the path of every redraw of the home screen: -c 2 -W 2 meant a tunnel
    # whose far end had stopped answering cost four seconds of nothing before
    # the menu appeared, once for every tunnel on the server.
    out=$(ping -c 2 -i 0.2 -W 1 -q "$(peer_addr "$name")" 2>/dev/null |
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
        screen_top
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

        # What this server is, in one line, said the way round that matters:
        # which end dials and which end waits. The old line said "iran" and
        # left the reader to remember which of the two does what.
        if [ "$side" = iran ]; then
            if [ "$transport" = icmp ]; then
                field "This end" "IRAN $G_DASH dials $(addr_text "$kharej") inside ping packets"
            else
                field "This end" "IRAN $G_DASH dials $(addr_text "$kharej") on $transport/$port"
            fi
        else
            local iran_addr
            iran_addr=$(toml_get "$f" transport iran)
            if [ "$transport" = icmp ]; then
                field "This end" "KHAREJ $G_DASH waits for ping packets from IRAN"
            else
                field "This end" "KHAREJ $G_DASH waits on $transport/$port"
            fi
            [ -n "$iran_addr" ] && field "IRAN is" "$(addr_text "$iran_addr")"
        fi
        # The name and the path, for the transports that have one. It is the
        # one thing about a WebSocket tunnel that is not in the line above,
        # and the one somebody putting a proxy in front of it needs.
        local dom
        dom=$(toml_get "$f" transport domain)
        if [ -n "$dom" ]; then
            field "Address" "$(addr_text "$dom")$(toml_get "$f" transport path)"
        fi
        field "Link" "$(my_addr "$name") $G_BOTH $(peer_addr "$name")   $dev   mtu $mtu"

        # One measurement to a line, each with the name of what it is. They
        # were one line with two numbers on it and nothing saying which was
        # which, five blank columns apart.
        if [ -n "$TL_RATE" ]; then
            field "Traffic" "$TL_RATE  Mbit/s"
        fi
        if [ -n "$TL_RTT" ]; then
            field "Round trip" "$(rtt_colour "$TL_RTT")$TL_RTT ms$C_OFF"
        elif [ "$transport" = icmp ]; then
            field "Round trip" "$C_MUTE""not measurable across an ICMP tunnel""$C_OFF"
        fi
        [ -n "${TL_UPTIME:-}" ] && field "Up for" "$TL_UPTIME"

        # Losses only when there are some. A line saying zero every time is a
        # line people stop reading, and then they do not see it change.
        if [ -n "${ST_LOST:-}" ] && [ "${ST_LOST:-0}" -gt 0 ]; then
            local per=$((ST_LOST / (ST_GAPS > 0 ? ST_GAPS : 1)))
            field "Path lost" "$ST_LOST packets in $ST_GAPS gaps, about $per at a time"
        fi

        local fw
        fw=$(forwards_of "$name" 2>/dev/null || true)
        [ -n "$fw" ] && field "Ports" "$fw  $G_ARROW  $(peer_addr "$name")"

        blank
        group "RUN"
        case $TL_STATE in
        stopped | disabled) item 1 "Start" "and start it again at every boot" ;;
        *) item 1 "Restart" "stop it and start it again" ;;
        esac
        item 2 "Stop" "until you start it, or the server reboots"
        item 3 "Live view" "the numbers above, once a second"
        blank
        group "CHECK"
        item 4 "Health check" "what is wrong, and what to do about it"
        item 5 "Log" "the last forty lines the core wrote"
        item 6 "Measure MTU" "the largest packet this path will carry"
        item 7 "Speed test" "iperf3 across the tunnel, sixteen streams"
        blank
        group "CHANGE"
        if [ "$side" = iran ]; then
            item2 8 "Ports" "${fw:-nothing is forwarded yet}"
        else
            item2 8 "Ports" "IRAN forwards them, not this side"
        fi
        item2 9 "Profile" "$prof$(prof_queue_note "$f")"
        item 10 "Advanced" "mtu, log level, queue depth, the file itself"
        item 11 "Delete this tunnel" "here only - the other server keeps its copy"
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
    screen_top
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

    screen_top
    blank
    rule "What crosses this link"
    blank
    profile_row 1 gaming "$cur" "600 packets - a small one waits behind less"
    profile_row 2 balanced "$cur" "900 packets - the one to pick if unsure"
    profile_row 3 download "$cur" "1500 packets - most on a long transfer"
    blank
    dim "A profile sets one number: how many packets may wait in the tunnel's"
    dim "queue. A deeper queue carries more at once and holds a packet longer;"
    dim "a shallower one answers sooner and gives up some throughput for it."
    blank
    dim "Both servers should be on the same one. Changing it restarts the"
    dim "tunnel here, which costs a second of traffic and nothing else."
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

# One profile, with a mark against the one this tunnel is on now.
#
# It is item() with that mark written over the left margin rather than a line
# of its own, so the three of them line up with every other menu in the script
# and there is only one place that decides how a menu line looks.
profile_row() {
    local key=$1 name=$2 cur=$3 hint=$4 line mark=' '
    # A dot, not the same arrow the line already has: two arrows on one line
    # is a line where neither of them means anything.
    [ "$name" = "$cur" ] && mark=$G_ON
    line=$(item "$key" "${name^}" "$hint")
    printf ' %s%s%s%s\n' "$C_OK" "$mark" "$C_OFF" "${line#  }"
}

screen_advanced() {
    local name=$1 f k q qs lv
    f=$(cfg_file "$name")
    while :; do
        screen_top
        # Two of these are not in the file until somebody sets them: the
        # profile carries the queue depth, and the core picks the number of
        # device queues. Reading the file alone drew "Queue depth  packets,
        # from the profile" with the number missing out of the middle of it,
        # and then offered an empty default that the validator refused - so
        # pressing enter at the question did nothing at all, twice.
        q=$(toml_get "$f" tuning queue_packets)
        qs=$(toml_get "$f" tun queues)
        lv=$(toml_get "$f" logging level)
        # Same as the two below: the core fills this in when the file leaves
        # it out, so reading the file alone drew an empty row and offered an
        # empty default that the validator then refused.
        [ -n "$lv" ] || lv=info
        blank
        rule "Advanced $G_DASH $name"
        blank
        item2 1 "MTU" "$(toml_get "$f" tun mtu)"
        item2 2 "Log level" "$lv"
        if [ -n "$q" ]; then
            item2 3 "Queue depth" "$q packets, set here"
        else
            q=$(wiz_queue "$(toml_get "$f" tuning profile)")
            item2 3 "Queue depth" "$q packets, from the profile"
        fi
        item2 4 "Device queues" "${qs:-the core chooses}"
        item2 5 "Health port" "$(health_port_of "$name") on $(my_addr "$name")"
        case $(toml_get "$f" transport type) in
        ws | wss) item2 6 "Web path" "$(toml_get "$f" transport path)" ;;
        esac
        item 7 "Show the config file"
        item 0 "Back"
        blank
        menu_key k || return 0
        case $k in
        1) local v
            ask v "mtu" "$(toml_get "$f" tun mtu)" v_mtu || continue
            MTU_WANT=$v; cfg_apply "$name" _edit_mtu yes; pause ;;
        2) local v
            blank; dim "debug says a great deal; info says what changed"; blank
            ask v "level" "$lv" v_level || continue
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
        5) blank
            dim "The port the server at the other end is asked on, over the"
            dim "private link. It is bound to this tunnel's own address, so"
            dim "nothing else on this machine can be in the way of it unless"
            dim "something holds that port on every address."
            blank
            dim "Both servers must use the same number, and changing it here"
            dim "changes it here only."
            blank
            local v
            ask v "port (-1 turns it off)" "$(health_port_of "$name")" v_hport || continue
            HEALTH_WANT=$v; cfg_apply "$name" _edit_health_port yes; pause ;;
        6) case $(toml_get "$f" transport type) in
            ws | wss) ;;
            *) blank; warn "there is nothing on 6"; pause; continue ;;
            esac
            blank
            dim "What the WebSocket handshake asks for. Anything else that"
            dim "arrives gets a 404, the way a web server would answer it."
            dim "It has to match on both servers."
            blank
            local v
            ask v "path" "$(toml_get "$f" transport path)" v_path || continue
            PATH_WANT=$v; cfg_apply "$name" _edit_path yes; pause ;;
        7) blank; sed 's/^/    /' "$f"; pause ;;
        0 | '') return 0 ;;
        esac
    done
}

_edit_mtu() { toml_set "$1" tun mtu "$MTU_WANT"; }
_edit_level() { toml_set "$1" logging level "$LEVEL_WANT"; }
_edit_queue() { toml_set "$1" tuning queue_packets "$QUEUE_WANT"; }
_edit_queues() { toml_set "$1" tun queues "$QUEUES_WANT"; }
_edit_health_port() { toml_set "$1" status health_port "$HEALTH_WANT"; }
_edit_path() { toml_set "$1" transport path "$PATH_WANT"; }

v_path() {
    case $1 in
    /*) return 0 ;;
    esac
    echo "a path starts with a slash"
    return 1
}

v_hport() {
    case $1 in
    -1) return 0 ;;
    '' | *[!0-9]*) echo "a port, or -1 to turn it off"; return 1 ;;
    esac
    { [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; } || { echo "a port is between 1 and 65535"; return 1; }
}

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
