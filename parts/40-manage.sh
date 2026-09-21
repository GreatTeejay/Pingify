#!/usr/bin/env bash
#
# Manage tunnels: the list, one tunnel's screen, and the things that can be
# changed on it. Everything a screen reports comes from two sources and no
# third: systemd says whether the unit is running, and the core's own status
# endpoint says whether it is carrying anything. Nothing reads the log.

# ---------------------------------------------------------------------------
# where the other end is
# ---------------------------------------------------------------------------

# peer_addr is the other end of the private link, without its prefix.
peer_addr() {
    local f side a
    f=$(cfg_file "$1")
    side=$(toml_get "$f" tunnel side)
    if [ "$side" = iran ]; then a=$(toml_get "$f" tun kharej); else a=$(toml_get "$f" tun iran); fi
    printf '%s' "${a%%/*}"
}

my_addr() {
    local f side a
    f=$(cfg_file "$1")
    side=$(toml_get "$f" tunnel side)
    if [ "$side" = iran ]; then a=$(toml_get "$f" tun iran); else a=$(toml_get "$f" tun kharej); fi
    printf '%s' "${a%%/*}"
}

# peer_public is the other server's public address, from the file.
peer_public() {
    local f side
    f=$(cfg_file "$1")
    side=$(toml_get "$f" tunnel side)
    if [ "$side" = iran ]; then toml_get "$f" transport kharej; else toml_get "$f" transport iran; fi
}

# tun_rtt is the round trip to the other end, in whole milliseconds, or
# nothing when it cannot be measured.
#
# A forward tunnel measures itself with a ping record every ten seconds and
# reports it. A private link is measured on the far end's health port: one
# TCP handshake across the link, which is one round trip and nothing else.
# Not with ping - an ICMP tunnel on either server mutes echo for every link
# on it, and a ping that waits a second for a reply that is never coming,
# once per tunnel, is why a list of nine took thirteen seconds to draw.
tun_rtt() {
    local name=$1 f out hp peer
    f=$(cfg_file "$name")
    if [ "$(toml_get "$f" tunnel mode)" = forward ]; then
        tun_stats "$name" || return 0
        case $ST_FAR_RTT in '' | 0 | *[!0-9.]*) return 0 ;; esac
        LC_ALL=C awk -v t="$ST_FAR_RTT" 'BEGIN { printf "%.0f", t }'
        return 0
    fi
    have curl || return 0
    hp=$(health_port_of "$name")
    peer=$(peer_addr "$name")
    [ -n "$peer" ] && [ "$hp" -gt 0 ] 2>/dev/null || return 0
    out=$(LC_ALL=C curl -s -o /dev/null --max-time 1 -w '%{time_connect}' "http://$peer:$hp/healthz" 2>/dev/null) || return 0
    case $out in '' | 0 | 0.000000) return 0 ;; esac
    LC_ALL=C awk -v t="$out" 'BEGIN { printf "%.0f", t * 1000 }'
}

# ---------------------------------------------------------------------------
# status rendering
# ---------------------------------------------------------------------------

# tunnel_status_block is the few lines under a tunnel's name: the service,
# the token's fingerprint, and what the core says it is doing.
tunnel_status_block() {
    local name=$1 f state colour
    f=$(cfg_file "$name")
    [ -f "$f" ] || { fail "no such tunnel: $name"; return 1; }
    state=$(svc_state "$name")
    colour=$C_RED
    [ "$state" = active ] && colour=$C_GRN
    printf '  %s%s%s  service %s%s%s   token %s%s%s\n' \
        "$C_B" "$name" "$C_OFF" "$colour" "$state" "$C_OFF" \
        "$C_YEL" "$(token_print "$(toml_get "$f" security token)")" "$C_OFF"
    if [ "$state" != active ]; then
        dim "not running - nothing to report"
        return 0
    fi
    if ! tun_stats "$name"; then
        dim "starting up, or the status port is not answering yet"
        return 0
    fi
    local link
    if [ "$ST_UP" = true ] && [ "${ST_INB:-0}" != 0 ]; then
        link="${C_GRN}up${C_OFF} for $(human_secs "$ST_UPTIME"), the other server has been heard from"
    elif [ "$ST_UP" = true ]; then
        link="${C_YEL}up${C_OFF} for $(human_secs "$ST_UPTIME"), nothing from the other server yet"
    else
        link="${C_YEL}waiting${C_OFF} for the other server, $(human_secs "$ST_UPTIME") so far"
    fi
    dim "$link"
    dim "carrying $(round1 "$ST_IN") Mbit/s in, $(round1 "$ST_OUT") out"
    if [ "${ST_LOST:-0}" -gt 0 ] 2>/dev/null; then
        dim "the path has lost $ST_LOST packets in ${ST_GAPS:-0} runs, ${ST_LATE:-0} arrived late"
    fi
    local rtt
    rtt=$(tun_rtt "$name")
    [ -n "$rtt" ] && dim "round trip $(rtt_tint "${rtt}ms") to the other server"
    return 0
}

# One line per tunnel, for the overview table. NAME SIDE PROTO LINK RTT MBIT
tunnel_row() {
    local name=$1 nw=${2:-13} num=${3:-} f side proto state dot link rtt=- rate=- lead=' '
    f=$(cfg_file "$name")
    side=$(side_label "$(toml_get "$f" tunnel side)")
    proto=$(transport_label "$(toml_get "$f" transport type)")
    state=$(svc_state "$name")
    dot="$C_GRY$BX_OFF$C_OFF" link=-
    case $state in
    active)
        if tun_stats "$name"; then
            if [ "$ST_UP" = true ] && [ "${ST_INB:-0}" != 0 ]; then
                dot="$C_GRN$BX_ON$C_OFF" link=up
            else
                dot="$C_YEL$BX_ON$C_OFF" link=alone
            fi
            rate="$(round1 "$ST_IN")/$(round1 "$ST_OUT")"
            # With failover, what is carrying now - and in yellow when that
            # is a backup, because it means the first choice has stopped.
            if [ -n "$ST_ACTIVE" ]; then
                proto=$(transport_label "$ST_ACTIVE")
                [ "$ST_ACTIVE" != "$(toml_get "$f" transport type)" ] && proto="$C_YEL$proto$C_OFF"
            fi
            rtt=$(tun_rtt "$name")
            [ -n "$rtt" ] && rtt="${rtt}ms" || rtt=-
        else
            dot="$C_YEL$BX_ON$C_OFF" link=starting
        fi
        ;;
    stopped) dot="$C_YEL$BX_OFF$C_OFF" link=stopped ;;
    *) dot="$C_GRY$BX_OFF$C_OFF" link=disabled ;;
    esac
    # With a number in front it is a row to pick as well as to read.
    [ -n "$num" ] && lead=$(printf '  %s%2s%s' "$C_CYN$C_B" "$num" "$C_OFF")
    printf '%s %s %s %s %s %s %s%s%s %s\n' \
        "$lead" "$dot" \
        "$(pad_to "${C_B}${name}${C_OFF}" "$nw")" \
        "$(pad_to "$side" 7)" \
        "$(pad_to "$proto" 15)" \
        "$(pad_to "$link" 9)" \
        "$(rtt_colour "$rtt")" "$(pad_to "$rtt" 6)" "$C_OFF" \
        "$rate"
}

# list_tunnels [numbered] - the status table. With numbered, each row
# carries the number pick_tunnel answers to, so the screen that picks a
# tunnel is the same screen that shows how it is doing.
list_tunnels() {
    local names w=13 n numbered=${1:-} ind='    ' num=
    names=$(cfg_list)
    if [ -z "$names" ]; then
        dim "no tunnels configured yet - pick New tunnel to make one"
        return 1
    fi
    for n in $names; do
        [ "${#n}" -gt "$w" ] && w=${#n}
    done
    [ -n "$numbered" ] && ind='       '
    printf '%s%s%s %s %s %s %s %s%s\n' "$ind" "$C_DIM" \
        "$(pad_to NAME "$w")" "$(pad_to SIDE 7)" "$(pad_to PROTO 15)" \
        "$(pad_to LINK 9)" "$(pad_to RTT 6)" "MBIT/S in/out" "$C_OFF"
    # Every row at once, each in its own subshell, and printed in order:
    # a row asks the far end for its round trip, and nine of those one
    # after another is nine round trips before the screen appears.
    local tmp i=0
    tmp=$(mktemp -d) || { for n in $names; do i=$((i + 1)); [ -n "$numbered" ] && num=$i; tunnel_row "$n" "$w" "$num"; done; return 0; }
    for n in $names; do
        i=$((i + 1))
        [ -n "$numbered" ] && num=$i
        tunnel_row "$n" "$w" "$num" >"$tmp/$i" 2>&1 &
    done
    wait
    i=0
    for n in $names; do
        i=$((i + 1))
        cat "$tmp/$i"
    done
    rm -rf "$tmp"
    return 0
}

# ---------------------------------------------------------------------------
# manage tunnels
# ---------------------------------------------------------------------------

# pick_tunnel [listed] - PICKED is the tunnel chosen by number. With
# listed, the numbers were just shown by list_tunnels numbered and are not
# printed a second time.
pick_tunnel() {
    local names i=0 n sel
    names=$(cfg_list)
    [ -n "$names" ] || { dim "no tunnels configured yet"; return 1; }
    blank
    if [ "${1:-}" != listed ]; then
        for n in $names; do
            i=$((i + 1))
            item "$i" "$n" "$(svc_state "$n")"
        done
    fi
    item 0 "Back"
    blank
    menu_key sel || return 1
    case $sel in '' | 0 | *[!0-9]*) return 1 ;; esac
    PICKED=$(printf '%s\n' $names | sed -n "${sel}p")
    [ -n "$PICKED" ]
}

manage_tunnels() {
    while :; do
        banner
        head2 "Manage tunnels"
        list_tunnels numbered || { pause; return 0; }
        pick_tunnel listed || return 0
        tunnel_menu "$PICKED"
    done
}

tunnel_menu() {
    local name=$1 f c side mode
    f=$(cfg_file "$name")
    while :; do
        [ -f "$f" ] || return 0
        side=$(toml_get "$f" tunnel side)
        mode=$(toml_get "$f" tunnel mode)
        banner
        head2 "Tunnel: $name"
        tunnel_status_block "$name"
        rule
        group "Service"
        item 1 "Restart"
        item 2 "Stop"
        item 3 "Start"
        item 4 "Delete this tunnel" "here only - the other server keeps its copy"
        group "Check"
        item 5 "Health check" "what is wrong, and what to do about it"
        item 6 "Live status" "the numbers, once a second"
        item 7 "Live log" "follow the core as it runs"
        group "Settings"
        # The ports live on IRAN, so the screen for them is on IRAN. On
        # this side it was an item that answered every press with a
        # refusal.
        if [ "$side" = iran ]; then
            item 8 "Ports" "$(ports_of "$name")"
        fi
        item 9 "Tuning" "profile, queue, mtu, direction, logging"
        item 10 "Scheduled restart" "$(recycle_hint "$name")"
        item 11 "Setup token" "the line the other server is built from"
        blank
        item 0 "Back"
        blank
        menu_key c || return 0
        case $c in
        1) blank; svc_do restart "$name"; sleep 1 ;;
        2) blank; svc_do stop "$name"; sleep 1 ;;
        3) blank; svc_do start "$name"; sleep 1 ;;
        4) delete_tunnel "$name" && return 0 ;;
        5) health_check "$name"; pause ;;
        6) screen_live "$name" ;;
        7) live_log "$name" ;;
        8) [ "$side" = iran ] || { blank; warn "the ports live on the IRAN server"; sleep 1; continue; }
            screen_ports "$name" ;;
        9) tuning_menu "$name" ;;
        10) recycle_menu "$name" ;;
        11) show_setup_token "$name" ;;
        0 | '') return 0 ;;
        *) blank; warn "there is nothing on $c"; sleep 1 ;;
        esac
    done
}
screen_tunnel() { tunnel_menu "$1"; }

# journald puts its own timestamp, the hostname and unit[pid] in front of
# every line; -o cat prints only what the core wrote. ctrl-c goes to every
# process in the foreground group, so it is caught here and journalctl takes
# the signal, and the menu comes back instead of a shell prompt.
live_log() {
    local name=$1
    banner
    head2 "Live log: $name"
    dim "ctrl-c to stop following"
    blank
    trap ':' INT
    journalctl -u "pingify@$name" -n 60 -f --no-pager -o cat 2>/dev/null || true
    trap - INT
}

# ---------------------------------------------------------------------------
# tuning
#
# Every number that shapes a tunnel, on one screen, split by the only
# distinction that matters when two servers disagree: the settings that have
# to match, and the ones that are nobody's business but this machine's.
# ---------------------------------------------------------------------------

# A profile is three lines in the file, not one: the depth and the receive
# queue it chooses are written as numbers, and an explicit number wins over
# the profile in the core, so changing the word alone would change nothing.
_edit_profile() {
    toml_set "$1" tuning profile "$PROFILE_WANT" &&
        toml_set "$1" tuning queue_packets "$(preset_queue "$PROFILE_WANT")" &&
        toml_set "$1" tuning rcvbuf_kb "$(preset_rcvbuf "$PROFILE_WANT")"
}
_edit_queue() { toml_set "$1" tuning queue_packets "$QUEUE_WANT"; }
_edit_mtu() { toml_set "$1" tun mtu "$MTU_WANT"; }
_edit_level() { toml_set "$1" logging level "$LEVEL_WANT"; }
_edit_fec() { toml_set "$1" tuning fec "$FEC_WANT"; }
_edit_dials() { toml_set "$1" transport dials "$DIALS_WANT"; }
_edit_path() { toml_set "$1" transport path "$PATH_WANT"; }
_edit_health_port() { toml_set "$1" status health_port "$HEALTH_WANT"; }
_edit_status_port() { toml_set "$1" status port "$STATUS_WANT"; }
_edit_conns() { toml_set "$1" transport connections "$CONNS_WANT"; }
_edit_keepalive() { toml_set "$1" transport keepalive_sec "$KEEPALIVE_WANT"; }
_edit_backups() {
    # shellcheck disable=SC2086
    toml_set "$1" failover backups "[$(fwd_toml_list $BACKUPS_WANT)]" no
    toml_set "$1" failover enabled "${ENABLED_WANT:-true}"
    toml_set "$1" failover prefer "${PREFER_WANT:-order}"
    toml_set "$1" failover switch_after_sec "${SWITCH_WANT:-25}"
    toml_set "$1" failover return_after_sec "${RETURN_WANT:-120}"
    toml_set "$1" failover probe_every_sec 60
}
_edit_fo_enabled() { toml_set "$1" failover enabled "$ENABLED_WANT"; }
_edit_fo_prefer() { toml_set "$1" failover prefer "$PREFER_WANT"; }
_edit_fo_timings() { toml_set "$1" failover switch_after_sec "$SWITCH_WANT"; toml_set "$1" failover return_after_sec "$RETURN_WANT"; }
v_switch_after() {
    case $1 in '' | *[!0-9]*) echo "seconds"; return 1 ;; esac
    { [ "$1" -ge 10 ] && [ "$1" -le 600 ]; } || { echo "10 to 600 seconds"; return 1; }
}
v_return_after() {
    case $1 in 0) return 0 ;; '' | *[!0-9]*) echo "seconds, or 0 to stay on the backup"; return 1 ;; esac
    { [ "$1" -ge 30 ] && [ "$1" -le 3600 ]; } || { echo "30 to 3600 seconds, or 0 to stay on the backup"; return 1; }
}

# failover_menu - one tunnel's backups: which, whether, in what order, and
# how patient to be. The list is kept when it is switched off, so turning it
# back on is one key.
failover_menu() {
    local name=$1 c v sw ret
    while :; do
        cfg_load "$name" || return 1
        banner
        head2 "Failover: $name"
        panel "IF $(transport_label "$T_TRANSPORT") STOPS CARRYING"
        backups_panel
        if [ -n "$T_BACKUPS" ]; then
            panel_field "Switch" "$([ "$T_FO_ENABLED" = false ] && printf 'off' || printf 'on')" "Prefer" "$([ "$T_FO_PREFER" = fastest ] && printf 'fastest round trip' || printf 'the order above')"
            panel_field "Move on after" "${T_FO_SWITCH:-25}s of silence" "Move back after" "$([ "${T_FO_RETURN:-120}" = 0 ] && printf 'never' || printf '%ss healthy' "${T_FO_RETURN:-120}")"
        fi
        panel_end
        blank
        dim "The tunnel moves to the best backup that answers, and back once a better one"
        dim "has answered for long enough. Connections carry on across a move; a single"
        dim "stream at full speed is reset so its program reconnects."
        dim "Set the same on the other server."
        rule
        item 1 "Backups" "which transports, in the order to try them"
        if [ -n "$T_BACKUPS" ]; then
            item 2 "Switch" "$([ "$T_FO_ENABLED" = false ] && printf 'off - the list is kept; turn it on' || printf 'on - turn it off and keep the list')"
            item 3 "Prefer" "$([ "$T_FO_PREFER" = fastest ] && printf 'fastest - change to the order above' || printf 'order - change to whichever answers fastest')"
            item 4 "Timings" "${T_FO_SWITCH:-25}s to move on, ${T_FO_RETURN:-120}s to move back"
        fi
        item 0 "Back"
        blank
        menu_key c || return 0
        case $c in
        1) blank
            backups_menu
            blank
            dim "In the order to try them, like 6,4 - or a single 0 for none."
            ask v "backups" "" v_backups_or_none || continue
            if [ "${v// /}" = 0 ]; then
                BACKUPS_WANT= ENABLED_WANT=true PREFER_WANT=order SWITCH_WANT= RETURN_WANT=
                cfg_apply "$name" _edit_backups yes && ok "no backups: the tunnel runs on $(transport_label "$T_TRANSPORT") alone"
                pause; continue
            fi
            [ -n "${v//[, ]/}" ] || continue
            backups_from "$v" || { pause; continue; }
            BACKUPS_WANT=$T_BACKUPS ENABLED_WANT=true PREFER_WANT=${T_FO_PREFER:-order}
            SWITCH_WANT=${T_FO_SWITCH:-25} RETURN_WANT=${T_FO_RETURN:-120}
            cfg_apply "$name" _edit_backups yes || { pause; continue; }
            ok "failover: $(backups_text)"
            this_side_waits && dim "leave those ports open in this server's firewall"
            pause ;;
        2) [ -n "$T_BACKUPS" ] || continue
            blank
            if [ "$T_FO_ENABLED" = false ]; then ENABLED_WANT=true; else ENABLED_WANT=false; fi
            cfg_apply "$name" _edit_fo_enabled yes && ok "failover is $([ "$ENABLED_WANT" = true ] && printf 'on' || printf 'off - the backups are kept in the file')"
            pause ;;
        3) [ -n "$T_BACKUPS" ] || continue
            blank
            dim "order:   the first backup in the list that answers, and back to the first"
            dim "         that recovers - you decide what is best."
            dim "fastest: every member is tried and the least round trip wins, the tunnel"
            dim "         in use included; it moves only for a tenth less."
            if [ "$T_FO_PREFER" = fastest ]; then PREFER_WANT=order; else PREFER_WANT=fastest; fi
            cfg_apply "$name" _edit_fo_prefer yes && ok "failover prefers $PREFER_WANT"
            pause ;;
        4) [ -n "$T_BACKUPS" ] || continue
            blank
            ask sw "seconds of silence before moving on" "${T_FO_SWITCH:-25}" v_switch_after || continue
            ask ret "seconds a better member must answer before moving back (0 never)" "${T_FO_RETURN:-120}" v_return_after || continue
            SWITCH_WANT=$sw RETURN_WANT=$ret
            cfg_apply "$name" _edit_fo_timings yes && ok "moving on after ${sw}s, back after ${ret}s"
            pause ;;
        0 | '') return 0 ;;
        *) blank; warn "there is nothing on $c"; sleep 1 ;;
        esac
    done
}
v_backups_or_none() { [ "${1// /}" = 0 ] && return 0; v_backups "$1"; }

# The certificate a TLS transport serves on the end that waits. Without one
# it makes its own, which a passive watcher accepts and a probe does not.
cert_label() {
    local c
    c=$(toml_get "$1" transport cert)
    [ -n "$c" ] && printf '%s' "$c" || printf 'made here, self-signed'
}
_edit_cert() {
    toml_set "$1" transport cert "$CERT_WANT" yes
    toml_set "$1" transport key "$KEY_WANT" yes
}
v_pem() {
    case $1 in '' | none | -) return 0 ;; esac
    [ -r "$1" ] || { echo "no readable file at $1"; return 1; }
    grep -q -- '-----BEGIN' "$1" 2>/dev/null || { echo "$1 is not a PEM file"; return 1; }
    return 0
}
certificate_menu() {
    local name=$1 f c k
    f=$(cfg_file "$name")
    blank
    dim "A real certificate for the name the other end dials - from Let's Encrypt,"
    dim "or your CA. Enter with nothing keeps what is set; none clears it and"
    dim "this end makes its own. The other end trusts whatever this end serves"
    dim "unless it dials a domain and a real certificate is here for it."
    dim "Now: $(cert_label "$f")"
    blank
    ask c "certificate file (PEM), or none" "$(toml_get "$f" transport cert)" v_pem || return 1
    [ -n "$c" ] || { dim "nothing changed"; return 0; }
    if [ "$c" = none ] || [ "$c" = - ]; then
        CERT_WANT= KEY_WANT=
        cfg_apply "$name" _edit_cert yes && ok "this end serves a certificate it makes itself"
        return 0
    fi
    ask k "private key file (PEM)" "$(toml_get "$f" transport key)" v_pem || return 1
    [ -n "$k" ] || { fail "a certificate needs its key"; return 1; }
    CERT_WANT=$c KEY_WANT=$k
    cfg_apply "$name" _edit_cert yes && ok "this end serves $c" && dim "the other end checks it when it dials a domain: make sure the name it dials is on the certificate"
    return 0
}

fec_label() {
    local n
    n=$(toml_get "$1" tuning fec)
    case $n in
    '' | 0) printf 'off' ;;
    *) printf '1 per %s, about %d%% more traffic' "$n" $((100 / n)) ;;
    esac
}

v_fec() {
    case $1 in 0) return 0 ;; '' | *[!0-9]*) echo "a number: 0 turns it off, otherwise 4 to 32"; return 1 ;; esac
    { [ "$1" -ge 4 ] && [ "$1" -le 32 ]; } || { echo "4 to 32, or 0 to turn it off"; return 1; }
}
v_path() { case $1 in /*) return 0 ;; esac; echo "a path starts with a slash"; return 1; }
v_hport() {
    case $1 in -1) return 0 ;; '' | *[!0-9]*) echo "a port, or -1 to turn it off"; return 1 ;; esac
    { [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; } || { echo "a port is between 1 and 65535"; return 1; }
}
v_queue() {
    case $1 in '' | *[!0-9]*) echo "a number of packets"; return 1 ;; esac
    { [ "$1" -ge 200 ] && [ "$1" -le 20000 ]; } || { echo "200 to 20000 - below that the queue refuses work the link could carry"; return 1; }
}
v_conns() {
    case $1 in '' | *[!0-9]*) echo "a number of connections"; return 1 ;; esac
    { [ "$1" -ge 1 ] && [ "$1" -le 32 ]; } || { echo "1 to 32"; return 1; }
}
v_keepalive() {
    case $1 in '' | *[!0-9]*) echo "seconds"; return 1 ;; esac
    { [ "$1" -ge 1 ] && [ "$1" -le 300 ]; } || { echo "1 to 300 seconds"; return 1; }
}
v_status_port() {
    local who
    v_port "$1" || return 1
    who=$(status_owner "$1" "${WIZ_KEEP:-}")
    [ -z "$who" ] || { echo "port $1 is already $who's status port"; return 1; }
    return 0
}

tuning_menu() {
    local name=$1 f c v
    f=$(cfg_file "$name")
    while :; do
        cfg_load "$name" || return 1
        WIZ_KEEP=$name
        banner
        head2 "Tuning: $name"
        panel "IDENTITY"
        panel_field "Token" "$(token_print "$T_TOKEN")" "Type" "$(kind_label "$T_TRANSPORT")"
        panel_field "Link" "$(dials_text)"
        [ "$T_MODE" = forward ] && backups_panel
        panel_end
        blank
        panel "PERFORMANCE - KEEP BOTH SERVERS THE SAME"
        panel_field "Profile" "$T_PRESET" "Queue" "${T_QUEUE:-$(preset_queue "$T_PRESET")} packets"
        if [ "$T_MODE" = tun ]; then
            panel_field "MTU" "$T_TUNMTU" "Parity" "$(fec_label "$f")"
        else
            panel_field "Connections" "$T_CONNS" "Keepalive" "$(toml_get "$f" transport keepalive_sec | sed 's/^$/10/') s"
        fi
        [ -n "$T_PATH" ] && panel_field "Web path" "$T_PATH"
        panel_end
        blank
        panel "LOCAL TO THIS SERVER"
        panel_field "Logging" "$T_LOG" "Status port" "127.0.0.1:$T_STATUS"
        if [ "$T_MODE" = tun ]; then
            if [ "${T_HEALTH:-0}" -gt 0 ] 2>/dev/null; then
                panel_field "Health port" "$T_HEALTH on $(my_addr "$name")"
            else
                panel_field "Health port" "off"
            fi
        fi
        panel_end
        blank
        dim "Read the top box on the other server and make it read the same."
        dim "Every change here restarts the tunnel, which costs a second of traffic."
        rule
        # Numbered as shown, not as coded: a transport without an MTU or a
        # certificate skips that item and the numbers close up behind it,
        # so the list never reads 5, 7, 8, 10.
        local -a keys=()
        tm() { keys+=("$1"); item "${#keys[@]}" "$2" "${3:-}"; }
        tm profile "Profile" "$T_PRESET - the shape of the queues"
        tm queue "Queue depth" "${T_QUEUE:-$(preset_queue "$T_PRESET")} packets - what the profile chose; change it only if you measured your path"
        if [ "$T_MODE" = tun ]; then
            tm mtu "MTU" "$T_TUNMTU - Find the MTU under Diagnostics measures it"
            case $T_TRANSPORT in
            gre) ;;
            *) tm parity "Parity" "$(fec_label "$f") - repairs a lost packet without a round trip" ;;
            esac
        else
            tm conns "Connections" "$T_CONNS parallel connections, 1 to 32"
            tm keepalive "Keepalive" "seconds between keepalives on every connection"
        fi
        case $T_TRANSPORT in icmp | gre | awg | grefou) ;; *) tm dials "Link direction" "$(dials_text)" ;; esac
        case $T_TRANSPORT in ws | wss) tm path "Web path" "$T_PATH - must match" ;; esac
        [ "$T_MODE" = forward ] && tm failover "Failover" "$(backups_text) - where to move when this transport stops"
        case $T_TRANSPORT in wss | utls | fallback) this_side_waits && tm cert "Certificate" "$(cert_label "$f") - what this end serves" ;; esac
        tm logging "Logging" "$T_LOG"
        tm status "Status port" "127.0.0.1:$T_STATUS - local, where the manager asks"
        if [ "$T_MODE" = tun ]; then
            if [ "${T_HEALTH:-0}" -gt 0 ] 2>/dev/null; then
                tm health "Health port" "$T_HEALTH - the same on both, on the link's own address"
            else
                tm health "Health port" "off - the far end is not asked over the link"
            fi
        fi
        tm file "Show the config file"
        item 0 "Back"
        blank
        menu_key c || { WIZ_KEEP=; return 0; }
        case $c in
        0 | '') WIZ_KEEP=; return 0 ;;
        *[!0-9]*) blank; warn "there is nothing on $c"; sleep 1; continue ;;
        esac
        if [ "$c" -lt 1 ] || [ "$c" -gt "${#keys[@]}" ]; then
            blank; warn "there is nothing on $c"; sleep 1; continue
        fi
        case ${keys[c - 1]} in
        profile) blank; preset_menu && { PROFILE_WANT=$T_PRESET; cfg_apply "$name" _edit_profile yes; }; pause ;;
        queue) blank
            dim "This comes from the profile and is the one number a profile moves."
            dim "gaming 600, balanced 900, download 1500."
            ask v "packets" "${T_QUEUE:-$(preset_queue "$T_PRESET")}" v_queue && { QUEUE_WANT=$v; cfg_apply "$name" _edit_queue yes; }
            pause ;;
        mtu) blank
            ask v "mtu" "$T_TUNMTU" v_mtu && { MTU_WANT=$v; cfg_apply "$name" _edit_mtu yes && dim "set the same on the other server"; }
            pause ;;
        conns) blank
            ask v "parallel connections" "$T_CONNS" v_conns && { CONNS_WANT=$v; cfg_apply "$name" _edit_conns yes; }
            pause ;;
        parity) blank
            dim "One extra packet per N, made of the N before it. Lose any one of"
            dim "them and this end rebuilds it at once, with no round trip. It costs"
            dim "one packet in N of bandwidth; 10 is a good start on a lossy path."
            ask v "one parity per (0 off, 4 to 32)" "${T_FEC:-0}" v_fec && { FEC_WANT=$v; cfg_apply "$name" _edit_fec yes; }
            pause ;;
        keepalive) blank
            ask v "keepalive seconds" "$(toml_get "$f" transport keepalive_sec | sed 's/^$/10/')" v_keepalive && { KEEPALIVE_WANT=$v; cfg_apply "$name" _edit_keepalive yes; }
            pause ;;
        dials) blank
            CHOICE_DEF=$([ "$T_DIALS" = iran ] && printf 1 || printf 2)
            choice 1 "Direct" "IRAN connects out to KHAREJ"
            choice 2 "Reverse" "KHAREJ connects in - a CDN in front of IRAN, or NAT"
            CHOICE_DEF=
            blank
            dim "Set the same on both servers."
            blank
            if pick v "select" "" 2; then
                DIALS_WANT=$([ "$v" = 1 ] && printf iran || printf kharej)
                cfg_apply "$name" _edit_dials yes && dim "now set the same on the other server"
            fi
            pause ;;
        path) blank
            dim "What the WebSocket handshake asks for; anything else gets a 404."
            ask v "path" "$T_PATH" v_path && { PATH_WANT=$v; cfg_apply "$name" _edit_path yes && dim "set the same on the other server"; }
            pause ;;
        logging) blank
            dim "This is local. The two servers may log at different levels."
            blank
            local _lv=3
            case $T_LOG in error) _lv=1 ;; warn) _lv=2 ;; debug) _lv=4 ;; esac
            CHOICE_DEF=$_lv
            choice 1 "error" "only what is broken"
            choice 2 "warn" "and what is wrong but survivable"
            choice 3 "info" "and what a healthy tunnel does"
            choice 4 "debug" "and why each connection and packet did what it did"
            CHOICE_DEF=
            blank
            if pick v "select" "$_lv" 4; then
                case $v in 1) LEVEL_WANT=error ;; 2) LEVEL_WANT=warn ;; 4) LEVEL_WANT=debug ;; *) LEVEL_WANT=info ;; esac
                cfg_apply "$name" _edit_level yes
            fi
            pause ;;
        status) blank
            dim "Bound to 127.0.0.1, so nothing outside this server can reach it."
            dim "One per tunnel, always: two processes cannot bind one port."
            show_taken_status "$name"
            ask v "port" "$T_STATUS" v_status_port && { STATUS_WANT=$v; cfg_apply "$name" _edit_status_port yes; }
            pause ;;
        health) blank
            dim "The port the other server is asked on, over the private link. Both"
            dim "servers must use the same number; changing it here changes it here."
            ask v "port (-1 turns it off)" "$T_HEALTH" v_hport && { HEALTH_WANT=$v; cfg_apply "$name" _edit_health_port yes; }
            pause ;;
        file) blank; sed 's/^/    /' "$f"; pause ;;
        failover) failover_menu "$name" ;;
        cert) certificate_menu "$name"; pause ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# scheduled restart
# ---------------------------------------------------------------------------

# recycle_hint NAME - the one phrase the tunnel menu shows for the timer.
recycle_hint() {
    local h
    if systemctl is-enabled --quiet "pingify-recycle@$1.timer" 2>/dev/null; then
        h=$(sed -n 's/^OnUnitActiveSec=\([0-9]*\)h$/\1/p' "$UNIT_DIR/pingify-recycle@$1.timer" 2>/dev/null)
        printf 'every %sh - for lines that degrade over time' "${h:-?}"
    else
        printf 'off - a timed restart, for lines that degrade'
    fi
}

recycle_menu() {
    local name=$1 hours
    blank
    if systemctl is-enabled --quiet "pingify-recycle@$name.timer" 2>/dev/null; then
        dim "a scheduled restart is currently active"
        if confirm "turn it off?"; then
            systemctl disable --now "pingify-recycle@$name.timer" >/dev/null 2>&1
            rm -f "$UNIT_DIR/pingify-recycle@$name.timer"
            systemctl daemon-reload 2>/dev/null
            ok "scheduled restart removed"
        fi
        pause
        return 0
    fi
    dim "Some Iranian ISPs quietly degrade long-lived connections. A periodic"
    dim "restart costs a second of downtime and clears that up."
    blank
    ask hours "restart every N hours (0 to cancel)" "6" v_number || return 0
    [ "$hours" = 0 ] && return 0
    [ -f "$UNIT_DIR/pingify-recycle@.service" ] || unit_write
    cat >"$UNIT_DIR/pingify-recycle@$name.timer" <<TIMER
[Unit]
Description=Pingify scheduled restart of tunnel $name

[Timer]
OnBootSec=${hours}h
OnUnitActiveSec=${hours}h
RandomizedDelaySec=120
Unit=pingify-recycle@$name.service

[Install]
WantedBy=timers.target
TIMER
    systemctl daemon-reload 2>/dev/null
    systemctl enable --now "pingify-recycle@$name.timer" >/dev/null 2>&1
    ok "the tunnel will restart every ${hours}h"
    pause
}

# ---------------------------------------------------------------------------
# delete
# ---------------------------------------------------------------------------

delete_tunnel() {
    local name=$1 f
    f=$(cfg_file "$name")
    blank
    warn "this removes the tunnel $name from this server"
    dim "the other server keeps its own copy until you remove it there too"
    blank
    confirm "delete $name?" n || return 1

    tunnel_remove "$name"
    ok "$name is gone"
    pause
    return 0
}

# tunnel_remove NAME - everything a tunnel put on this server, taken off
# again: the service, its timer, its firewall and kernel pieces, its files.
# The one routine for it, so that no path to deleting a tunnel forgets a
# piece the others remember.
tunnel_remove() {
    local name=$1 f
    f=$(cfg_file "$name")
    svc_do stop "$name" >/dev/null 2>&1 || true
    systemctl disable "pingify@$name" >/dev/null 2>&1 || true
    systemctl disable --now "pingify-recycle@$name.timer" >/dev/null 2>&1 || true
    rm -f "$UNIT_DIR/pingify-recycle@$name.timer"
    nat_drop "$name" >/dev/null 2>&1 || true
    awg_down "$name" >/dev/null 2>&1 || true
    grefou_down "$name" >/dev/null 2>&1 || true
    [ "$(toml_get "$f" transport type)" = rawtcp ] &&
        rawtcp_unguard "$(toml_get "$f" transport port)" >/dev/null 2>&1
    rm -f "$f" "$f.bak" "$STATE_DIR/$name.forwards" "$STATE_DIR/$name.fail" \
        "$STATE_DIR/$name.heard" "$STATE_DIR/$name.stopped"
    systemctl daemon-reload >/dev/null 2>&1
    return 0
}
