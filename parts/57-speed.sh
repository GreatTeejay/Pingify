
# ---------------------------------------------------------------------------
# measuring
#
# Two different questions, and confusing them wastes an afternoon:
#
#   what can the PATH between these two servers carry?
#       iperf3 straight between the public addresses. This is the ceiling -
#       no tunnel is going to beat it.
#
#   what does the TUNNEL deliver of that?
#       the same test, but over the tunnel's own addresses. This is the
#       number your users actually get.
#
# Measuring only one tells you nothing. 90 Mbit/s through the tunnel is
# excellent on a path that carries 100 and dreadful on a path that carries
# 500, and the only way to know which you have is to measure both. So this
# does, and prints them together.
#
# iperf3 with twenty parallel streams, ten seconds each way. Twenty because a
# single TCP stream on a 90 ms path is limited by its own window long before
# the path is full - one stream measures TCP, twenty measure the path.
# ---------------------------------------------------------------------------

IPERF_PORT=5201
IPERF_STREAMS=20
IPERF_SECONDS=10

iperf_ready() { have iperf3; }

iperf_install() {
    iperf_ready && return 0
    say ""
    dim "installing iperf3"
    if have apt-get; then
        apt-get update >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y iperf3 >/dev/null 2>&1
    elif have dnf; then
        dnf install -y iperf3 >/dev/null 2>&1
    elif have yum; then
        yum install -y iperf3 >/dev/null 2>&1
    elif have apk; then
        apk add --no-cache iperf3 >/dev/null 2>&1
    fi
    iperf_ready && { ok "iperf3 installed"; return 0; }
    fail "iperf3 could not be installed here"
    dim "install it by hand and come back:  apt install -y iperf3"
    return 1
}

# iperf_bitrate OUTPUT WHICH - the [SUM] line's bitrate, which is the only
# number in a twenty-stream run that means anything. WHICH is sender or
# receiver.
iperf_bitrate() {
    printf '%s' "$1" | grep '\[SUM\]' | grep "$2" | tail -1 \
        | awk '{ for (i = 1; i < NF; i++) if ($(i+1) ~ /bits\/sec/) print $i, $(i+1) }'
}

# speed_over_link - true when this tunnel has private addresses to measure
# between, which is the clean way to do it.
speed_over_link() { [ -n "${T_TUNPEER%%/*}" ] && [ -n "${T_TUNLOCAL%%/*}" ]; }

# speed_first_port - the first forwarded TCP port, as "local remote"
speed_first_port() {
    local spec lport rport
    for spec in $(printf '%s' "$T_FORWARDS" | tr -d '"' | tr ',' ' '); do
        case "$spec" in udp:*) continue ;; tcp:*) spec="${spec#tcp:}" ;; esac
        lport="${spec%%=*}"; rport="${spec#*=}"
        [ "$rport" = "$spec" ] && rport="$lport"
        lport="${lport%%-*}"; rport="${rport%%-*}"
        case "$lport$rport" in '' | *[!0-9]*) continue ;; esac
        printf '%s %s' "$lport" "$rport"
        return 0
    done
    return 1
}

# The other server's public address, however this end happens to know it.
speed_peer_public() {
    local p="$T_PEER_IP"
    [ -n "$p" ] || p="$(status_peer "$PICKED" 2>/dev/null)"
    printf '%s' "$p"
    [ -n "$p" ]
}

speed_menu() {
    while :; do
        banner
        head2 "Speed test  ${C_DIM}(iperf3)${C_OFF}"
        say ""
        dim "Real bandwidth between your two servers, measured with iperf3 -"
        dim "${IPERF_STREAMS} parallel streams for ${IPERF_SECONDS}s each way, because one stream on a"
        dim "90 ms path runs out of window long before the path runs out of room."
        say ""
        dim "One server holds a listener; the other runs the test against it."
        say ""
        item 1 "Hold a listener" "run this FIRST, on the other server"
        item 2 "Test the tunnel" "what your users actually get"
        item 3 "Test the raw path" "the ceiling - what the route can carry at all"
        item 4 "Test both" "the pair, which is the only useful comparison"
        item 0 "Back"
        say ""
        local c=""
        ask c "select"
        case "$c" in
            1) speed_listen ;;
            2) speed_run tunnel ;;
            3) speed_run path ;;
            4) speed_run both ;;
            0 | "") return ;;
        esac
    done
}

speed_listen() {
    iperf_install || { pause; return 0; }
    banner
    head2 "Listener"
    say ""
    dim "iperf3 -s, answering on every address this server has - so it serves"
    dim "both a test over the tunnel and one over the public path."
    say ""
    ok "waiting on port $(addr_tint "$IPERF_PORT")"
    say ""
    dim "Now run the test from the other server."
    dim "ctrl-c when it is finished."
    say ""
    trap ':' INT
    iperf3 -s -p "$IPERF_PORT" 2>&1 | sed 's/^/  /'
    trap - INT
    say ""
    ok "listener stopped"
    pause
}

# speed_one TARGET LABEL - ten seconds each way against TARGET, printing what
# it finds. Sets SPEED_DOWN and SPEED_UP.
speed_one() {
    local target="$1" port="$2" out
    SPEED_DOWN=""; SPEED_UP=""

    dim "sending - this is your users' download"
    out="$(iperf3 -c "$target" -p "$port" -i 1 -t "$IPERF_SECONDS" -P "$IPERF_STREAMS" 2>&1)" || {
        say ""
        fail "the test did not run"
        printf '%s\n' "$out" | tail -n 4 | sed 's/^/      /'
        return 1
    }
    SPEED_DOWN="$(iperf_bitrate "$out" sender)"
    dim "  ${SPEED_DOWN:-no reading}"

    say ""
    dim "receiving - this is your users' upload"
    out="$(iperf3 -c "$target" -p "$port" -i 1 -t "$IPERF_SECONDS" -P "$IPERF_STREAMS" -R 2>&1)" || {
        say ""
        warn "the reverse test did not run"
        return 0
    }
    SPEED_UP="$(iperf_bitrate "$out" receiver)"
    dim "  ${SPEED_UP:-no reading}"
    return 0
}

# mbits VALUE - "412 Mbits/sec" as a bare number, for comparing two of them
mbits() {
    local n u
    n="$(printf '%s' "$1" | awk '{print $1}')"
    u="$(printf '%s' "$1" | awk '{print $2}')"
    case "$n" in '' | *[!0-9.]*) printf '0'; return 1 ;; esac
    case "$u" in
        Gbits/sec) printf '%s' "$(awk -v x="$n" 'BEGIN{printf "%d", x*1000}')" ;;
        Kbits/sec) printf '%s' "$(awk -v x="$n" 'BEGIN{printf "%d", x/1000}')" ;;
        *)         printf '%s' "$(awk -v x="$n" 'BEGIN{printf "%d", x}')" ;;
    esac
}

speed_run() {
    local what="$1"
    pick_tunnel || return 0
    cfg_load "$PICKED" || return 0
    iperf_install || { pause; return 0; }

    local tun_target="" tun_port="$IPERF_PORT" how="" pub=""
    if [ "$what" != "path" ]; then
        if speed_over_link; then
            tun_target="${T_TUNPEER%%/*}"
            how="across the private link"
        else
            local ports
            ports="$(speed_first_port)" || {
                fail "this tunnel has no private link and forwards no TCP port"
                dim "there is no way in to measure through it"
                pause; return 0
            }
            tun_target="127.0.0.1"
            tun_port="${ports%% *}"
            how="through forwarded port ${tun_port}"
        fi
    fi
    if [ "$what" != "tunnel" ]; then
        pub="$(speed_peer_public)" || {
            if [ "$what" = "path" ]; then
                fail "this end does not know the other server's public address"
                dim "it accepts rather than dials, and the tunnel is not up to be asked"
                pause; return 0
            fi
            pub=""
        }
    fi

    banner
    head2 "Speed test: $PICKED"
    say ""
    field "Transport" "$(transport_label "$T_TRANSPORT")"
    [ -n "$tun_target" ] && field "Tunnel" "$(addr_tint "${tun_target}:${tun_port}") $how"
    [ -n "$pub" ]        && field "Raw path" "$(addr_tint "${pub}:${IPERF_PORT}")"
    say ""
    warn "the other server must be holding a listener right now"
    dim "Diagnostics ${BX_ARR} Speed test ${BX_ARR} Hold a listener"
    say ""
    confirm_yes "start?" || return 0

    local td="" tu="" pd="" pu=""
    if [ -n "$tun_target" ]; then
        say ""
        head2 "Through the tunnel"
        say ""
        speed_one "$tun_target" "$tun_port" && { td="$SPEED_DOWN"; tu="$SPEED_UP"; }
    fi
    if [ -n "$pub" ]; then
        say ""
        head2 "The raw path"
        say ""
        speed_one "$pub" "$IPERF_PORT" && { pd="$SPEED_DOWN"; pu="$SPEED_UP"; }
    fi

    speed_report "$td" "$tu" "$pd" "$pu"
}

# The result, and what it means - which is the part a column of iperf output
# does not tell you.
speed_report() {
    local td="$1" tu="$2" pd="$3" pu="$4"
    banner
    head2 "Result: $PICKED"
    say ""

    if [ -n "$td$tu" ]; then
        panel "through the tunnel"
        field "Download" "${td:-not measured}"
        field "Upload" "${tu:-not measured}"
        panel_end
    fi
    if [ -n "$pd$pu" ]; then
        say ""
        panel "the raw path, for comparison"
        field "Download" "${pd:-not measured}"
        field "Upload" "${pu:-not measured}"
        panel_end
    fi

    # The comparison is the whole point. A number on its own is not a verdict.
    if [ -n "$td" ] && [ -n "$pd" ]; then
        local t p pct
        t="$(mbits "$td")"; p="$(mbits "$pd")"
        if [ "$p" -gt 0 ]; then
            pct=$((t * 100 / p))
            say ""
            if [ "$pct" -ge 80 ]; then
                ok "the tunnel is carrying ${pct}% of what the path can - that is as good as this gets"
            elif [ "$pct" -ge 50 ]; then
                warn "the tunnel is carrying ${pct}% of what the path can"
                dim "some loss is the cost of a tunnel; this much is worth a look"
                dim "try a larger window: Manage ${BX_ARR} $PICKED ${BX_ARR} Tuning ${BX_ARR} Profile"
            else
                fail "the tunnel is carrying only ${pct}% of what the path can"
                dim "the path is fine, so this is the tunnel - check the MTU first,"
                dim "then the window, then try another transport"
                dim "Diagnostics ${BX_ARR} Find the MTU"
            fi
        fi
    elif [ -n "$td" ]; then
        say ""
        dim "Run it against the raw path too - the same number means something"
        dim "quite different on a route that carries 100 Mbit than on one that"
        dim "carries 500, and only the pair tells you which you have."
    fi

    say ""
    dim "Numbers move with the hour on this route. Take each of them more than"
    dim "once before deciding anything."
    pause
}

# ---------------------------------------------------------------------------
# benchmarking the server itself
#
# A different question again: not the link, but the machine. Slow disk or a
# throttled CPU shows up as a tunnel that cannot keep up, and no amount of
# tuning fixes a server that is the bottleneck.
#
# This runs a third-party script from the internet, which is worth being
# plain about: the address is on the screen before anything runs, and nothing
# runs until you agree to it.
# ---------------------------------------------------------------------------

BENCH_URL="https://raw.githubusercontent.com/teddysun/across/master/bench.sh"

bench_menu() {
    banner
    head2 "Benchmark this server"
    say ""
    dim "CPU, disk and network, measured against public endpoints. Says whether"
    dim "the machine itself is the bottleneck - which no tunnel setting fixes."
    say ""
    warn "this downloads and runs a script written by someone else"
    say ""
    dim "$BENCH_URL"
    say ""
    dim "It is the widely used bench.sh. Read it first if you would rather;"
    dim "nothing here runs until you say so."
    say ""
    confirm "download and run it?" || return 0

    have curl || have wget || { fail "neither curl nor wget is installed"; pause; return 0; }

    local tmp="/tmp/pingify-bench.$$"
    say ""
    if ! fetch "$BENCH_URL" "$tmp" 60; then
        fail "could not download it"
        dim "this server may not be able to reach that address"
        rm -f "$tmp"
        pause; return 0
    fi
    ok "downloaded $(wc -c < "$tmp" | tr -d ' ') bytes"
    say ""
    rule
    bash "$tmp" 2>&1 | sed 's/^/  /'
    rule
    rm -f "$tmp"
    say ""
    pause
}
