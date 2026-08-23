
# ---------------------------------------------------------------------------
# how fast is this tunnel, actually
#
# Round trip is on every screen already, and round trip is not throughput. The
# question people actually have - is this one better than the one I used
# before, on my path, today - has one honest answer, and it is a measurement.
#
# It needs both servers, because there is nothing to measure against
# otherwise: one end holds a listener open, the other pushes data at it and
# reports what arrived.
#
# What matters is that the data goes *through the tunnel*, and how you arrange
# that depends on the tunnel:
#
#   a private link      measure between the two private addresses. Clean:
#                       nothing else uses them, and every byte crosses the
#                       tunnel by definition.
#
#   no private link     there is no address that belongs to the tunnel, so
#                       the measurement goes through a forwarded port -
#                       IRAN's own loopback, which the core is listening on.
#                       That port carries the test instead of its service
#                       while the test runs, so it has to be a spare one.
#
# Measuring to the other server's public address would measure the public
# path, which is the one thing here that is not the tunnel.
# ---------------------------------------------------------------------------

IPERF_PORT=5201

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

# speed_over_link - true when this tunnel has private addresses to measure
# between, which is the clean way to do it.
speed_over_link() { [ -n "${T_TUNPEER%%/*}" ] && [ -n "${T_TUNLOCAL%%/*}" ]; }

# speed_first_port - the first forwarded port, as "local remote"
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

speed_menu() {
    banner
    head2 "Speed test"
    say ""
    dim "Measures the tunnel itself - not the public path between the two"
    dim "servers, and not whatever your proxy does with the traffic."
    say ""
    dim "It takes both servers. Hold a listener open on one, then run the"
    dim "test from the other while it waits."
    say ""
    item 1 "Run the test" "push data through and report what arrived"
    item 2 "Hold a listener open" "for the other server to measure against"
    item 0 "Back"
    say ""
    local c=""
    ask c "select"
    case "$c" in
        1) speed_run ;;
        2) speed_listen ;;
        *) return 0 ;;
    esac
}

speed_listen() {
    pick_tunnel || return 0
    cfg_load "$PICKED" || return 0
    iperf_install || { pause; return 0; }

    local bind port ports
    if speed_over_link; then
        bind="${T_TUNLOCAL%%/*}"
        port="$IPERF_PORT"
    else
        # The far end of a forwarded port is loopback on this server, so that
        # is where the core will bring the test to.
        bind="127.0.0.1"
        ports="$(speed_first_port)" || {
            fail "this tunnel forwards no TCP port to measure through"
            pause; return 0
        }
        port="${ports##* }"
        say ""
        warn "this will hold ${bind}:${port} for as long as the test runs"
        dim "whatever normally answers there must be stopped first, or the"
        dim "listener will not be able to bind"
        say ""
        confirm_yes "go ahead?" || return 0
    fi

    banner
    head2 "Listener: $PICKED"
    say ""
    ok "waiting on $(addr_tint "${bind}:${port}")"
    say ""
    dim "Now run the test from the other server against this tunnel."
    dim "This holds until you press ctrl-c."
    say ""
    trap ':' INT
    iperf3 -s -B "$bind" -p "$port" 2>&1 | sed 's/^/  /'
    trap - INT
    say ""
    ok "listener stopped"
    pause
}

speed_run() {
    pick_tunnel || return 0
    cfg_load "$PICKED" || return 0
    iperf_install || { pause; return 0; }

    local target port ports how
    if speed_over_link; then
        target="${T_TUNPEER%%/*}"
        port="$IPERF_PORT"
        how="across the private link"
    else
        target="127.0.0.1"
        ports="$(speed_first_port)" || {
            fail "this tunnel forwards no TCP port to measure through"
            dim "a tunnel with no private link is measured through one of its"
            dim "ports, and this one has none that carry TCP"
            pause; return 0
        }
        port="${ports%% *}"
        how="through forwarded port ${port}"
    fi

    banner
    head2 "Speed test: $PICKED"
    say ""
    field "Over" "$(transport_label "$T_TRANSPORT")"
    field "To" "$(addr_tint "${target}:${port}")"
    field "How" "$how"
    say ""
    dim "The other server must be holding a listener open for this tunnel."
    say ""
    confirm_yes "start?" || return 0

    local out up="" down=""
    say ""
    dim "sending - this is your users' download"
    out="$(iperf3 -c "$target" -p "$port" -t 10 -f m 2>&1)" || {
        say ""
        fail "the test did not run"
        printf '%s\n' "$out" | tail -n 5 | sed 's/^/      /'
        say ""
        dim "the usual reason is that the other server is not listening yet"
        dim "start it there:  Diagnostics ${BX_ARR} Speed test ${BX_ARR} Hold a listener open"
        pause; return 0
    }
    up="$(printf '%s\n' "$out" | awk '/sender/{print $7" "$8}' | tail -1)"

    say ""
    dim "receiving - this is your users' upload"
    out="$(iperf3 -c "$target" -p "$port" -t 10 -f m -R 2>&1)" || true
    down="$(printf '%s\n' "$out" | awk '/receiver/{print $7" "$8}' | tail -1)"

    banner
    head2 "Result: $PICKED"
    panel "$(transport_label "$T_TRANSPORT"), $how"
    field "Download" "${up:-not measured}"
    field "Upload" "${down:-not measured}"
    panel_end
    say ""
    dim "Run this on each transport and keep whichever wins on your path."
    dim "The numbers move with the hour, so take each of them more than once"
    dim "before deciding - a single run is a moment, not a verdict."
    pause
}
