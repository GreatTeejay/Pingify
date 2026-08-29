
# ---------------------------------------------------------------------------
# reading an existing tunnel back
# ---------------------------------------------------------------------------

cfg_load() {
    local f
    f="$(cfg_file "$1")"
    [ -f "$f" ] || return 1
    cfg_reset
    T_NAME="$(toml_get "$f" tunnel name)"
    T_ROLE="$(toml_get "$f" tunnel role)"
    T_MODE="$(toml_get "$f" tunnel mode)";                  : "${T_MODE:=forward}"
    T_KIND="$(toml_get "$f" tunnel kind)"
    if [ -z "$T_KIND" ]; then
        # written before the kind was recorded
        [ "$(toml_get "$f" transport type)" = "icmp" ] && T_KIND="tun" || T_KIND="tcp"
    fi
    T_TRANSPORT="$(toml_get "$f" transport type)";          : "${T_TRANSPORT:=tcp}"
    T_TOKEN="$(toml_get "$f" security token)"
    T_STATUS="$(toml_get "$f" status addr)"
    T_CARRIERS="$(toml_get "$f" transport carriers)";       : "${T_CARRIERS:=4}"
    T_KEEPALIVE="$(toml_get "$f" transport keepalive_sec)"; : "${T_KEEPALIVE:=10}"
    T_OBFUSCATE="$(toml_get "$f" transport obfuscate)";     : "${T_OBFUSCATE:=false}"
    T_ENCRYPT="$(toml_get "$f" transport encrypt)";         : "${T_ENCRYPT:=true}"
    T_CERT_FILE="$(toml_get "$f" transport cert_file)"
    T_KEY_FILE="$(toml_get "$f" transport key_file)"
    T_WINDOW="$(toml_get "$f" tuning window_kb)";           : "${T_WINDOW:=512}"
    T_SNDBUF="$(toml_get "$f" tuning sndbuf_kb)";           : "${T_SNDBUF:=$T_WINDOW}"
    T_RCVBUF="$(toml_get "$f" tuning rcvbuf_kb)";           : "${T_RCVBUF:=$T_WINDOW}"
    T_PRESET="$(toml_get "$f" tuning profile)";             : "${T_PRESET:=custom}"
    T_FEC_DATA="$(toml_get "$f" kcp data_shards)";          : "${T_FEC_DATA:=10}"
    T_FEC_PARITY="$(toml_get "$f" kcp parity_shards)";      : "${T_FEC_PARITY:=3}"
    T_PACKET_MTU="$(toml_get "$f" kcp mtu)";                : "${T_PACKET_MTU:=1200}"
    T_KCP_INTERVAL="$(toml_get "$f" kcp interval_ms)";      : "${T_KCP_INTERVAL:=10}"
    T_PCK_FLAGS="$(toml_get "$f" pck flags)";               : "${T_PCK_FLAGS:=PA}"
    T_FORWARDS="$(toml_arr "$f" ports)"
    T_FORWARDER="$(toml_get "$f" forward forwarder)";       : "${T_FORWARDER:=pingify}"
    # pfy0 is what tunnels built before the device was named after them
    # actually have on the wire, so it stays as the fallback for those.
    T_TUNIF="$(toml_get "$f" tun name)";                    : "${T_TUNIF:=pfy0}"
    T_TUNLOCAL="$(toml_get "$f" tun local_addr)"
    T_TUNPEER="$(toml_get "$f" tun remote_addr)"
    T_TUNMTU="$(toml_get "$f" tun mtu)";                    : "${T_TUNMTU:=1380}"

    # A kernel tunnel keeps its own section, and both public addresses in it:
    # nothing about it is derived from a listen or connect line.
    if kernel_transport; then
        T_GRE_TTL="$(toml_get "$f" gre ttl)";               : "${T_GRE_TTL:=255}"
        T_AWG_PORT="$(toml_get "$f" awg listen_port)";      : "${T_AWG_PORT:=51820}"
        T_AWG_PRIV="$(toml_get "$f" awg private_key)"
        T_AWG_PUB="$(toml_get "$f" awg peer_key)"
        T_AWG_OBF="$(toml_get "$f" awg obfuscation)"
        if [ "$T_TRANSPORT" = "gre" ]; then
            T_PUBLIC_IP="$(toml_get "$f" gre local_public)"
            T_PEER_IP="$(toml_get "$f" gre peer_public)"
        else
            T_PUBLIC_IP="$(toml_get "$f" awg local_public)"
            T_PEER_IP="$(toml_get "$f" awg peer_public)"
        fi
        # Reverse, like every other Pingify tunnel: IRAN is the end that
        # waits. T_ACCEPTS names the role that waits, not this machine, so it
        # reads the same on both servers.
        T_ACCEPTS="server"
        return 0
    fi

    # The endpoint is derived, so recover what it was built from.
    local l c
    l="$(toml_get "$f" transport listen)"
    c="$(toml_get "$f" transport connect)"
    if [ -n "$l" ]; then
        T_ACCEPTS="$T_ROLE"
        case "$l" in *:*) T_PORT="${l##*:}" ;; esac
    else
        [ "$T_ROLE" = "server" ] && T_ACCEPTS="client" || T_ACCEPTS="server"
        T_PEER_IP="${c%:*}"
        case "$c" in *:*) T_PORT="${c##*:}" ;; *) T_PEER_IP="$c" ;; esac
    fi

    # A WSS tunnel that dials an edge has the edge in connect and the name
    # it presents in host - so host is the peer, and what connect gave us
    # was the edge all along.
    local hn; hn="$(toml_get "$f" transport host)"
    if [ -n "$hn" ]; then
        T_EDGE="$T_PEER_IP"
        T_PEER_IP="$hn"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# status rendering
# ---------------------------------------------------------------------------

tunnel_status_block() {
    local name="$1" f="$(cfg_file "$1")"
    [ -f "$f" ] || { fail "no such tunnel: $name"; return 1; }
    local addr; addr="$(toml_get "$f" status addr)"
    local state; state="$(svc_state "$name")"

    local colour="$C_RED"
    [ "$state" = "active" ] && colour="$C_GRN"
    printf '  %s%s%s  service %s%s%s   token %s%s%s\n' \
        "$C_B" "$name" "$C_OFF" "$colour" "$state" "$C_OFF" \
        "$C_YEL" "$(token_print "$(toml_get "$f" security token)")" "$C_OFF"

    # A stopped tunnel has no status endpoint to ask, and printing the raw
    # "connection refused" from trying anyway reads like a fault when it is
    # only the consequence of the line above.
    if [ "$state" != "active" ]; then
        dim "not running - nothing to report"
        return 0
    fi
    [ -n "$addr" ] && [ -x "$CORE_BIN" ] || return 0
    if ! "$CORE_BIN" -status "$addr" 2>/dev/null; then
        # Either it is still coming up, or no carrier has arrived. The status
        # server answers within a second of starting, so a refusal this soon
        # after a start is the former.
        dim "starting up, or the other server has not connected yet"
    fi
    return 0
}

# One line per tunnel, for the overview table. The second argument is how wide
# the name column is; list_tunnels works it out from the names it is about to
# print, so one long name cannot push its own row out of line with the rest.
tunnel_row() {
    local name="$1" nw="${2:-13}" f="$(cfg_file "$1")"
    local role proto fwder addr state brief up total rtt links kern=0
    role="$(side_label "$(toml_get "$f" tunnel role)")"
    proto="$(transport_label "$(toml_get "$f" transport type)")"
    fwder="$(forwarder_label "$(toml_get "$f" forward forwarder)")"
    addr="$(toml_get "$f" status addr)"
    state="$(svc_state "$name")"

    up="-"; total="$(toml_get "$f" transport carriers)"; rtt="-"
    if [ "$state" = "active" ]; then
        if kernel_transport "$(toml_get "$f" transport type)"; then
            kern=1
            # No core and no status endpoint: the kernel holds the link, and
            # the answer comes from the interface plus one ping across it.
            # In a subshell, because cfg_load writes every T_ variable and
            # this runs once per tunnel inside somebody else's loop.
            total=1
            brief="$(cfg_load "$name" >/dev/null 2>&1 && kernel_brief "$name")"
        elif [ -n "$addr" ] && [ -x "$CORE_BIN" ]; then
            brief="$("$CORE_BIN" -status "$addr" -brief 2>/dev/null)"
        fi
    fi
    if [ -n "$brief" ]; then
        # state up total rtt streams uptime - one shape for every kind
        set -- $brief
        up="$2"
        # An unreachable endpoint reports zeroes; keep the configured carrier
        # count so the column still says what was asked for.
        [ "$3" != "0" ] && total="$3"
        if [ "$1" = "up" ]; then rtt="${4}ms"; else rtt="-"; fi
    fi

    # GRE and AmneziaWG have exactly one link, because they are not built out
    # of connections the way our own transports are - there is no second one
    # to open. Printing "1/1" beside a "24/24" invited the reading that they
    # were running at a twenty-fourth of it, so they say up or down and leave
    # counting to the transports that have something to count.
    if [ "$kern" = "1" ]; then
        case "$up" in
            0) links="down" ;;
            -) links="-" ;;
            *) links="up" ;;
        esac
    else
        links="$up/$total"
    fi

    # Green only when the tunnel is running *and* a carrier is actually up:
    # a running process with no peer is the failure people most need to see.
    local dot="$C_GRY$BX_OFF$C_OFF"
    case "$state" in
        active)
            if [ "$up" != "0" ] && [ "$up" != "-" ]; then dot="$C_GRN$BX_ON$C_OFF"
            else dot="$C_YEL$BX_ON$C_OFF"; fi ;;
        stopped)  dot="$C_YEL$BX_OFF$C_OFF" ;;
        disabled) dot="$C_GRY$BX_OFF$C_OFF" ;;
    esac

    printf '  %s %s %s %s %s %s %s%s%s\n' \
        "$dot" \
        "$(pad_to "${C_B}${name}${C_OFF}" "$nw")" \
        "$(pad_to "$role" 8)" \
        "$(pad_to "$proto" 10)" \
        "$(pad_to "$fwder" 9)" \
        "$(pad_to "$links" 6)" \
        "$(rtt_colour "$rtt")" "$rtt" "$C_OFF"
}

list_tunnels() {
    local names; names="$(tunnel_names)"
    if [ -z "$names" ]; then
        dim "no tunnels configured yet - pick New tunnel to make one"
        return 1
    fi
    # As wide as the widest name, never narrower than the header. It was a
    # fixed 13, and the moment a name grew past that - which it did as soon
    # as the private network went into it - that row alone slid right and
    # every column after it stopped lining up.
    local w=13 n
    for n in $names; do
        [ "${#n}" -gt "$w" ] && w="${#n}"
    done

    printf '    %s%s %s %s %s %s %s%s\n' \
        "$C_DIM" \
        "$(pad_to "NAME" "$w")" \
        "$(pad_to "SIDE" 8)" \
        "$(pad_to "PROTO" 10)" \
        "$(pad_to "FORWARDER" 9)" \
        "$(pad_to "LINKS" 6)" \
        "RTT" "$C_OFF"
    for n in $names; do tunnel_row "$n" "$w"; done
    return 0
}

# ---------------------------------------------------------------------------
# manage tunnels
# ---------------------------------------------------------------------------

pick_tunnel() {
    local names; names="$(tunnel_names)"
    [ -n "$names" ] || { dim "no tunnels configured yet"; return 1; }
    local i=0 n
    say ""
    for n in $names; do
        i=$((i + 1))
        item "$i" "$n" "$(svc_state "$n")"
    done
    item 0 "Back"
    say ""
    local sel=""
    # No default. It used to offer 1, so the key people press to leave a menu
    # picked the first tunnel in it instead.
    ask sel "select"
    [ "$sel" = "0" ] && return 1
    case "$sel" in ''|*[!0-9]*) return 1 ;; esac
    PICKED="$(printf '%s\n' $names | sed -n "${sel}p")"
    [ -n "$PICKED" ]
}

manage_tunnels() {
    while :; do
        banner
        head2 "Manage Tunnels"
        list_tunnels || { pause; return; }
        if ! pick_tunnel; then return; fi
        tunnel_menu "$PICKED"
    done
}

tunnel_menu() {
    local name="$1" is_kernel=0
    while :; do
        is_kernel=0
        cfg_load "$name" >/dev/null 2>&1 && kernel_transport && is_kernel=1
        banner
        head2 "Tunnel: $name"
        tunnel_status_block "$name"
        rule
        group "Service"
        item 1 "Restart"
        item 2 "Stop"
        item 3 "Start"
        item 4 "Delete this tunnel"
        group "Check"
        item 5 "Health check" "what is wrong, and what to do about it"
        item 6 "Live log"
        group "Settings"
        item 7 "Ports" "$(printf '%s' "$(toml_arr "$(cfg_file "$name")" ports)" | tr -d '"' | tr ',' ' ')"
        if [ "$is_kernel" = "1" ]; then
            item 8 "Kernel link" "MTU and kernel-owned transport settings"
        else
            item 8 "Tuning" "transport preset, window, buffers, shaping"
        fi
        item 9 "Scheduled restart"
        say ""
        item 0 "Back"
        say ""
        local c=""
        ask c "select"
        case "$c" in
            1) systemctl restart "pingify@$name"; ok "restarted"; sleep 1 ;;
            2) systemctl stop "pingify@$name"; ok "stopped"; sleep 1 ;;
            3) systemctl start "pingify@$name"; ok "started"; sleep 1 ;;
            4) delete_tunnel "$name" && return ;;
            5) health_check "$name" ;;
            6) live_log "$name" ;;
            7) edit_forwards "$name" ;;
            8) if [ "$is_kernel" = "1" ]; then kernel_link_info "$name"; else tuning_menu "$name"; fi ;;
            9) recycle_menu "$name" ;;
            0|"") return ;;
        esac
    done
}

kernel_link_info() {
    local name="$1"
    cfg_load "$name" || return 1
    banner
    head2 "Kernel link: $name"
    say ""
    panel "LINUX DATA PATH"
    field "Transport" "$(transport_label "$T_TRANSPORT")" "MTU" "$T_TUNMTU"
    field "Private link" "$T_TUNLOCAL ${BX_ARR} $T_TUNPEER"
    case "$T_TRANSPORT" in
        gre) field "GRE TTL" "$T_GRE_TTL" ;;
        awg) field "AWG port" "$T_AWG_PORT/udp" ;;
    esac
    panel_end
    say ""
    dim "Linux carries this tunnel directly. Core carriers, MUX windows,"
    dim "socket buffers and traffic shaping do not exist on this path."
    dim "The MTU and peer parameters above are the transport's tuning and"
    dim "were mirrored by the setup token when both ends were created."
    pause
}

# journald puts its own timestamp, the hostname and unit[pid] in front of
# every line. Our line already carries a timestamp, so all that prefix bought
# was half the terminal width - on a 24-carrier tunnel it pushed the actual
# message off the right edge. -o cat prints only what the core wrote.
live_log() {
    local name="$1"
    banner
    head2 "Live log: $name"
    say ""
    dim "ctrl-c to stop following"
    say ""
    # ctrl-c goes to every process in the foreground group, and a script with
    # no handler for it dies. So the key that stops following also closed the
    # manager and dropped you back to a shell - the same "I had to start it
    # again" as the dashboard that would not take enter. Catch it here, let
    # journalctl take the signal and go, and come back to the menu.
    trap ':' INT
    journalctl -u "pingify@$name" -n 60 -f --no-pager -o cat || true
    trap - INT
}

edit_logging() {
    local name="$1" f
    f="$(cfg_file "$name")"
    banner
    head2 "Logging: $name"
    say ""
    choice 1 "error" "only what is broken"
    choice 2 "warn" "and what is wrong but survivable"
    choice 3 "info" "and what a healthy tunnel does"
    choice 4 "debug" "and why each carrier and stream did what it did"
    choice 5 "trace" "and every packet - slows a busy tunnel down"
    say ""
    dim "This is local. The two servers may log at different levels."
    say ""
    local c="" lvl
    ask c "select" "3"
    case "$c" in
        1) lvl="error" ;; 2) lvl="warn" ;;
        4) lvl="debug" ;; 5) lvl="trace" ;;
        3|"") lvl="info" ;;
        *) fail "pick 1 to 5"; pause; return ;;
    esac
    cp -f "$f" "$f.bak"
    if grep -q '^level' "$f"; then
        sed -i "s#^level.*#level            = \"$lvl\"#" "$f"
    else
        printf '
[logging]
level            = "%s"
' "$lvl" >> "$f"
    fi
    if "$CORE_BIN" -c "$f" -check >/dev/null 2>&1; then
        rm -f "$f.bak"
        systemctl restart "pingify@$name"
        ok "logging at $lvl"
    else
        mv -f "$f.bak" "$f"
        fail "the core rejected that; nothing was changed"
    fi
    pause
}

# The health port is where -status and the watchdog ask how a tunnel is doing.
# It is picked automatically and bound to loopback, so it is not reachable from
# anywhere and cannot collide with another tunnel - but a fixed one is easier
# to point a monitor at, so it can be set.
edit_health() {
    local name="$1" f
    f="$(cfg_file "$name")"
    cfg_load "$name" || return 1
    banner
    head2 "Health port: $name"
    say ""
    dim "Bound to 127.0.0.1, so nothing outside this server can reach it."
    dim "Used by -status and by the watchdog. Local to this server: the two"
    dim "ends do not have to match."
    say ""
    dim "One per tunnel, always: each tunnel is its own process, and two"
    dim "processes cannot bind one port."
    say ""
    show_taken_health "$name"
    local p="" owner=""
    while :; do
        ask p "port" "${T_STATUS##*:}"
        case "$p" in '' | *[!0-9]*) fail "numbers only"; continue ;; esac
        [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || { fail "1 to 65535"; continue; }
        owner="$(health_owner "$p" "$name")"
        if [ -n "$owner" ]; then
            fail "port $p is already $owner's health port"
            continue
        fi
        break
    done

    cp -f "$f" "$f.bak"
    sed -i "s#^addr .*#addr             = \"127.0.0.1:$p\"#" "$f"
    if "$CORE_BIN" -c "$f" -check >/dev/null 2>&1; then
        rm -f "$f.bak"
        systemctl restart "pingify@$name"
        ok "health port is now $p"
    else
        mv -f "$f.bak" "$f"
        fail "the core rejected that; nothing was changed"
    fi
    pause
}

shaping_label() {
    case "$(toml_get "$(cfg_file "$1")" transport obfuscate)" in
        true) printf 'on' ;;
        *)    printf 'off' ;;
    esac
}

# Not a performance knob: it decides what the tunnel looks like from outside,
# and the two servers have to agree or nothing passes.
edit_shaping() {
    local name="$1" f="$(cfg_file "$1")" now
    now="$(shaping_label "$name")"
    banner
    head2 "Traffic shaping - currently ${C_YEL}${now}${C_OFF}"
    say ""
    dim "ON   the frame length is masked and the opening frames carry random"
    dim "     filler, so nothing on the wire sits at a fixed offset. The cost is"
    dim "     that the stream then looks like nothing at all, and a filter that"
    dim "     drops what it cannot identify will drop exactly that."
    say ""
    dim "OFF  each frame carries a plain length in front, so the tunnel looks"
    dim "     like an ordinary length-prefixed protocol."
    say ""
    ok "the payload is AES-256-GCM either way - this changes the shape, not the secrecy"
    say ""
    warn "set it the SAME on both servers. If they differ, no traffic passes at all."
    say ""
    local want=""
    ask want "shaping on? (yes/no)" "$([ "$now" = "on" ] && echo yes || echo no)"
    case "$want" in
        y|yes|true|on|1)  want="true" ;;
        n|no|false|off|0) want="false" ;;
        *) fail "answer yes or no"; pause; return ;;
    esac

    cp -f "$f" "$f.bak"
    # Append rather than substitute: a replacement carrying a newline has to
    # be escaped, and that escape does not survive every layer it passes
    # through on the way into this file.
    sed -i -e '/^obfuscate/d' \
           -e "/^keepalive_sec/a obfuscate        = $want" "$f"
    if "$CORE_BIN" -c "$f" -check >/dev/null 2>&1; then
        rm -f "$f.bak"
        systemctl restart "pingify@$name"
        ok "shaping is $([ "$want" = "true" ] && echo on || echo off) - now do the same on the other server"
    else
        mv -f "$f.bak" "$f"
        fail "the core rejected that; nothing was changed"
    fi
    pause
}

edit_forwards() {
    local name="$1" f="$(cfg_file "$1")"
    cfg_load "$name" || return 1
    if [ "$T_ROLE" != "server" ]; then
        warn "the port list lives on the IRAN server; this is the KHAREJ end"
        pause; return
    fi
    say ""
    dim "current: $(printf '%s' "$T_FORWARDS" | tr -d '"')"
    say ""
    # Everything except this tunnel's own list, which it is allowed to keep.
    show_taken_ports "$name"
    local raw="" fwd="" clash=""
    while :; do
        ask raw "new port list (comma separated)"
        [ -n "$raw" ] || return
        fwd="$(parse_forwards "$raw")"
        [ -n "$fwd" ] || { fail "nothing to set"; return; }
        clash="$(forwards_clash "$raw" "$name")" && break
        printf '%s
' "$clash" | while read -r line; do
            [ -n "$line" ] && fail "$line"
        done
        dim "pick another port, or free that one first"
        say ""
    done

    cp -f "$f" "$f.bak"
    if grep -q '^ports' "$f"; then
        sed -i "s#^ports.*#ports            = [$fwd]#" "$f"
    else
        sed -i "s#^\(forwarder.*\)#\1\nports            = [$fwd]#" "$f"
    fi
    if "$CORE_BIN" -c "$f" -check >/dev/null 2>&1; then
        rm -f "$f.bak"
        systemctl restart "pingify@$name"
        apply_nat quiet
        ok "ports updated and the tunnel restarted"
    else
        mv -f "$f.bak" "$f"
        fail "that port list was rejected, nothing changed"
    fi
    pause
}

# Every number that shapes a tunnel, on one screen, split by the only
# distinction that matters when two servers disagree: the settings that have to
# match, and the ones that are nobody's business but this machine's.
# ---------------------------------------------------------------------------
# what the numbers actually buy
#
# A window in kilobytes and a carrier count mean nothing on their own. What a
# person wants to know is how fast one connection can go, and that has one
# answer: a stream may have at most one window of data in flight, so it cannot
# beat window / round-trip no matter what the path underneath can do.
#
#   1024 KB at 90 ms  ->  93 Mbit/s for a single connection
#   4096 KB at 90 ms  -> 372 Mbit/s
#
# Which is the whole reason the bigger presets exist, and the reason raising
# carriers does nothing for a single download.
# ---------------------------------------------------------------------------

# stream_ceiling WINDOW_KB RTT_MS -> megabits per second, or "-"
stream_ceiling() {
    local win="$1" rtt="${2%%.*}"
    # Checked apart, not joined: an empty window beside a good round trip
    # reads as a perfectly good number when the two are concatenated.
    case "$win" in '' | *[!0-9]*) printf '%s' '-'; return 1 ;; esac
    case "$rtt" in '' | *[!0-9]*) printf '%s' '-'; return 1 ;; esac
    [ "$rtt" -gt 0 ] || { printf '%s' '-'; return 1; }
    # KB * 8 bits / ms  ==  kbit/ms  ==  Mbit/s, near enough for a menu
    printf '%s' "$(( win * 8 / rtt ))"
}

# The round trip this tunnel is actually seeing, so the ceiling above is about
# this path rather than a number out of a book. Falls back to a typical
# Iran-to-Europe figure when the tunnel is not up to be asked.
tuning_rtt() {
    local name="$1" brief=""
    if [ -n "$T_STATUS" ] && [ -x "$CORE_BIN" ] && [ "$(svc_state "$name")" = "active" ]; then
        brief="$("$CORE_BIN" -status "$T_STATUS" -brief 2>/dev/null)"
    fi
    if [ -n "$brief" ]; then
        set -- $brief
        if [ "$1" = "up" ] && [ "${4%%.*}" -gt 0 ] 2>/dev/null; then
            printf '%s' "${4%%.*}"
            return 0
        fi
    fi
    printf '90'
    return 1
}

tuning_menu() {
    local name="$1" f v
    f="$(cfg_file "$name")"
    while :; do
        cfg_load "$name" || return 1
        banner
        head2 "Tuning: $name"

        local rtt measured ceiling
        rtt="$(tuning_rtt "$name")" && measured="measured" || measured="assumed"
        ceiling="$(stream_ceiling "$T_WINDOW" "$rtt")"

        panel "IDENTITY"
        field "Token" "$(token_print "$T_TOKEN")" "Shaping" "$(shaping_label "$name")"
        field "Type" "$(transport_label "$T_TRANSPORT")" "Forwarder" "$(forwarder_label "$T_FORWARDER")"
        panel_end
        say ""
        panel "PERFORMANCE - KEEP BOTH SERVERS THE SAME"
        field "Profile" "$T_PRESET"
        field "Carriers" "$T_CARRIERS" "Window" "${T_WINDOW} KB"
        field "Buffers" "${T_SNDBUF} / ${T_RCVBUF} KB" "Keepalive" "${T_KEEPALIVE} s"
        if [ "$T_TRANSPORT" = "kcp" ] || [ "$T_TRANSPORT" = "pck" ]; then
            field "FEC" "${T_FEC_DATA}+${T_FEC_PARITY}" "Packet" "${T_PACKET_MTU} B / ${T_KCP_INTERVAL} ms"
        fi
        panel_end
        dim "Local health endpoint: $T_STATUS"
        say ""

        # The one number worth reading off this screen.
        panel "what that buys"
        field "One link" "up to ${ceiling} Mbit/s" "Round trip" "${rtt} ms, ${measured}"
        # The stream MUX above the carrier shares one physical WebSocket.
        case "$T_TRANSPORT" in
            ws | wss) field "Spread over" "all streams / 1 WebSocket" ;;
            *)        field "Spread over" "$T_CARRIERS carriers at once" ;;
        esac
        panel_end

        # A socket that cannot hold a window's worth of data makes the window
        # a number on paper: the kernel stops the writer before the credit
        # runs out, and the extra window buys nothing.
        if [ "$T_SNDBUF" -lt "$T_WINDOW" ] || [ "$T_RCVBUF" -lt "$T_WINDOW" ]; then
            say ""
            warn "the buffers are smaller than the window"
            dim "a socket that cannot hold one window makes the rest of it"
            dim "unreachable - raise the buffers to ${T_WINDOW} KB or lower the window"
        fi

        say ""
        dim "Read the top box on the other server and make it read the same."
        dim "The rest is local; it will not break the link."

        rule
        item 1 "Profile" "pick a preset and set them all at once"
        case "$T_TRANSPORT" in
            ws | wss) item 2 "Connection" "fixed at 1 by the WebSocket MUX" ;;
            *)        item 2 "Carriers" "$T_CARRIERS - parallel connections" ;;
        esac
        item 3 "Window" "$T_WINDOW KB - the ceiling on one connection"
        item 4 "Buffers" "$T_SNDBUF / $T_RCVBUF KB - what the sockets hold"
        item 5 "Keepalive" "$T_KEEPALIVE seconds"
        item 6 "Traffic shaping" "$(shaping_label "$name") - must match"
        item 7 "Logging" "$T_LOG"
        item 8 "Health port" "$T_STATUS"
        item 0 "Back"
        say ""
        local c=""
        ask c "select"
        case "$c" in
            1) say ""; preset_menu
               tuning_write "$name" "$T_CARRIERS" "$T_WINDOW" "$T_KEEPALIVE" "$T_SNDBUF" "$T_RCVBUF" ;;
            2) case "$T_TRANSPORT" in
                   ws | wss) say ""; warn "the WebSocket MUX always uses one physical connection"; pause ;;
                   *) say ""; ask v "parallel connections" "$T_CARRIERS"
                      tuning_write "$name" "$v" "$T_WINDOW" "$T_KEEPALIVE" "$T_SNDBUF" "$T_RCVBUF" ;;
               esac ;;
            3) say ""
               dim "one connection tops out at window / round trip"
               dim "at ${rtt} ms:  1024 KB = $(stream_ceiling 1024 "$rtt") Mbit/s   4096 KB = $(stream_ceiling 4096 "$rtt") Mbit/s"
               say ""
               ask v "window per connection, KB" "$T_WINDOW"
               tuning_write "$name" "$T_CARRIERS" "$v" "$T_KEEPALIVE" "$T_SNDBUF" "$T_RCVBUF" ;;
            4) edit_buffers "$name" ;;
            5) say ""; ask v "keepalive seconds" "$T_KEEPALIVE"
               tuning_write "$name" "$T_CARRIERS" "$T_WINDOW" "$v" "$T_SNDBUF" "$T_RCVBUF" ;;
            6) edit_shaping "$name" ;;
            7) edit_logging "$name" ;;
            8) edit_health "$name" ;;
            0|"") return ;;
        esac
    done
}

# The socket buffers, on their own screen because there are two of them and
# because getting them wrong is quiet: too small and the window above is a
# fiction, too large and a busy server spends real memory on carriers that
# are idle.
edit_buffers() {
    local name="$1" snd rcv total_buf
    cfg_load "$name" || return 1
    banner
    head2 "Buffers: $name"
    say ""
    case "$T_TRANSPORT" in
        ws | wss | icmp | udp | pck)
            dim "This transport uses one shared socket for its send and receive buffers."
            ;;
        *)
            dim "Each carrier gets a send and a receive buffer of this size, so a"
            dim "$T_CARRIERS-carrier tunnel holds ${T_CARRIERS} of each."
            ;;
    esac
    say ""
    case "$T_TRANSPORT" in
        ws | wss | icmp | udp | pck) total_buf="$(( (T_SNDBUF + T_RCVBUF) / 1024 )) MB" ;;
        *)        total_buf="$(( (T_SNDBUF + T_RCVBUF) * T_CARRIERS / 1024 )) MB" ;;
    esac
    field "Now" "${T_SNDBUF} / ${T_RCVBUF} KB" "In total" "$total_buf"
    say ""
    dim "They should be at least the window (${T_WINDOW} KB), or the window"
    dim "cannot fill. Past that they buy nothing."
    say ""
    ask snd "send buffer, KB" "$T_SNDBUF"
    ask rcv "receive buffer, KB" "$T_RCVBUF"
    tuning_write "$name" "$T_CARRIERS" "$T_WINDOW" "$T_KEEPALIVE" "$snd" "$rcv"
}

# tuning_write <name> <carriers> <window> <keepalive> [sndbuf] [rcvbuf]
tuning_write() {
    local name="$1" car="$2" win="$3" ka="$4" snd="${5:-}" rcv="${6:-}" f n max_window
    f="$(cfg_file "$name")"
    [ -n "$snd" ] || snd="$win"
    [ -n "$rcv" ] || rcv="$win"
    case "$T_TRANSPORT" in ws | wss) car=1 ;; esac
    for n in "$car" "$win" "$ka" "$snd" "$rcv"; do
        case "$n" in "" | *[!0-9]*) fail "numbers only"; pause; return ;; esac
    done
    [ "$car" -ge 1 ] && [ "$car" -le 64 ] || { fail "carriers must be 1 to 64"; pause; return; }
    max_window="$(transport_window_max)"
    [ "$win" -ge 64 ] && [ "$win" -le "$max_window" ] || {
        fail "window must be 64 to $max_window KB for $(transport_label "$T_TRANSPORT")"
        pause; return
    }
    [ "$ka" -ge 1 ] && [ "$ka" -le 300 ] || { fail "keepalive must be 1 to 300 seconds"; pause; return; }
    # 64 MB a socket is already past anything a real path can use, and 64 of
    # them is 4 GB of a server that has other work to do.
    [ "$snd" -ge 64 ] && [ "$rcv" -ge 64 ] &&
    [ "$snd" -le 65536 ] && [ "$rcv" -le 65536 ] || {
        fail "buffers must be 64 KB to 64 MB"
        pause; return
    }

    cp -f "$f" "$f.bak"
    sed -i "s#^carriers.*#carriers         = $car#" "$f"
    sed -i "s#^window_kb.*#window_kb        = $win#" "$f"
    sed -i "s#^keepalive_sec.*#keepalive_sec    = $ka#" "$f"
    sed -i "s#^sndbuf_kb.*#sndbuf_kb        = $snd#" "$f"
    sed -i "s#^rcvbuf_kb.*#rcvbuf_kb        = $rcv#" "$f"
    if [ "$T_TRANSPORT" = "kcp" ] || [ "$T_TRANSPORT" = "pck" ]; then
        sed -i "/^\[kcp\]/,/^\[/ {
            s#^data_shards.*#data_shards      = $T_FEC_DATA#
            s#^parity_shards.*#parity_shards    = $T_FEC_PARITY#
            s#^mtu.*#mtu              = $T_PACKET_MTU#
            s#^interval_ms.*#interval_ms      = $T_KCP_INTERVAL#
        }" "$f"
    fi
    # A hand-set profile is no longer whichever preset it started as.
    sed -i "s#^profile.*#profile          = \"$(preset_name "$car" "$win" "$ka" "$snd" "$rcv" \
        "$T_FEC_DATA" "$T_FEC_PARITY" "$T_PACKET_MTU" "$T_KCP_INTERVAL")\"#" "$f"
    if "$CORE_BIN" -c "$f" -check >/dev/null 2>&1; then
        rm -f "$f.bak"
        systemctl restart "pingify@$name"
        ok "saved and restarted"
    else
        mv -f "$f.bak" "$f"
        fail "the core rejected that; nothing was changed"
    fi
    sleep 1
}



recycle_menu() {
    local name="$1"
    say ""
    if systemctl is-enabled --quiet "pingify-recycle@$name.timer" 2>/dev/null; then
        dim "a scheduled recycle is currently active"
        if confirm "turn it off?"; then
            systemctl disable --now "pingify-recycle@$name.timer" >/dev/null 2>&1
            rm -f "$UNIT_DIR/pingify-recycle@$name.timer"
            systemctl daemon-reload
            ok "scheduled recycle removed"
        fi
        pause; return
    fi
    dim "Some Iranian ISPs quietly degrade long-lived connections. A periodic"
    dim "restart costs a second of downtime and clears that up."
    say ""
    local hours=""
    ask hours "restart every N hours (0 to cancel)" "6"
    case "$hours" in ''|*[!0-9]*|0) return ;; esac
    cat > "$UNIT_DIR/pingify-recycle@$name.timer" <<TIMER
[Unit]
Description=Pingify scheduled recycle of tunnel $name

[Timer]
OnBootSec=${hours}h
OnUnitActiveSec=${hours}h
RandomizedDelaySec=120
Unit=pingify-recycle@$name.service

[Install]
WantedBy=timers.target
TIMER
    systemctl daemon-reload
    systemctl enable --now "pingify-recycle@$name.timer" >/dev/null 2>&1
    ok "the tunnel will recycle every ${hours}h"
    pause
}

delete_tunnel() {
    local name="$1"
    say ""
    confirm "really delete tunnel $name?" || return 1

    # Read it before the file goes, so the kernel leftovers can be named.
    local was_kernel=0 iface=""
    if cfg_load "$name" >/dev/null 2>&1 && kernel_transport; then
        was_kernel=1; iface="$T_TUNIF"
    fi

    systemctl disable --now "pingify@$name" >/dev/null 2>&1
    systemctl disable --now "pingify-recycle@$name.timer" >/dev/null 2>&1
    rm -f "$UNIT_DIR/pingify-recycle@$name.timer"
    if [ "$was_kernel" = "1" ]; then
        # The instance unit is a real file for these, not the shared template,
        # and the interface outlives the unit if the stop did not run.
        rm -f "$UNIT_DIR/pingify@$name.service"
        [ -n "$iface" ] && {
            ip link del "$iface" 2>/dev/null
            rm -f "$(awg_conf_path "$iface")"
        }
    fi
    rm -f "$(cfg_file "$name")" "$(cfg_file "$name").bak" "$STATE_DIR/$name.fail"
    systemctl daemon-reload
    # Its forwarding rules outlive the config unless something removes them,
    # and a DNAT rule pointing at an address that no longer exists swallows
    # every packet for that port - which looks exactly like a broken tunnel.
    apply_nat quiet
    ok "tunnel $name removed"
    sleep 1
    return 0
}
