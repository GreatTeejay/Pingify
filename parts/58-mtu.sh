
# ---------------------------------------------------------------------------
# finding the MTU instead of guessing it
#
# Every tunnel wraps the packet it carries, so the packet it can carry is
# smaller than the one the path allows. Guess too high and every full-size
# packet is fragmented or silently dropped - which reads as "connects fine,
# then stalls on anything large", the hardest fault here to diagnose. Guess too
# low and every packet wastes room, forever.
#
# The right number is not a constant. It is:
#
#     path MTU  -  what this transport wraps it in
#
# and the path MTU is a property of the route between these two servers today.
# Some paths carry 1500, plenty of Iranian routes carry less because they are
# themselves inside somebody else's tunnel. So it is measured, not assumed.
#
# The measurement is a ping with "do not fragment" set: if the packet is too
# big for any hop it is dropped rather than split, so the largest size that
# still gets an answer is the path MTU. Binary search finds it in ~10 pings.
# ---------------------------------------------------------------------------

# What each transport adds to every packet it carries, in bytes.
#
#   GRE   outer IP 20 + GRE 4 + our derived key 4                 = 28
#   AWG   outer IP 20 + UDP 8 + WireGuard 16 + Poly1305 tag 16    = 60
#         plus the junk AmneziaWG pads a handshake with, so more headroom
#   ICMP  outer IP 20 + ICMP 8 + our tag 4 + ARQ nonce 4 + hdr 16 = 52
#         plus the braid record header and the GCM tag it rides in
transport_overhead() {
    case "${1:-$T_TRANSPORT}" in
        gre)  printf '28' ;;
        awg)  printf '80' ;;   # 60 measured + 20 spare for the padding
        icmp) printf '80' ;;   # 52 measured + the braid frame around it
        *)    printf '40' ;;
    esac
}

# path_mtu HOST - the largest packet that reaches HOST without being fragmented,
# or nothing when the path will not answer at all.
#
# ping -M do sets DF; -s is the ICMP payload, so the packet on the wire is that
# plus 8 bytes of ICMP and 20 of IP.
path_mtu() {
    local host="$1" lo=576 hi=1500 mid payload best=0
    have ping || return 1

    # If the smallest size does not come back, nothing here is measurable -
    # the far end is not answering pings at all, which is its own answer.
    if ! ping -M do -s $((lo - 28)) -c1 -W2 -n "$host" >/dev/null 2>&1; then
        return 1
    fi
    best="$lo"

    while [ "$lo" -le "$hi" ]; do
        mid=$(((lo + hi) / 2))
        payload=$((mid - 28))
        if ping -M do -s "$payload" -c1 -W2 -n "$host" >/dev/null 2>&1; then
            best="$mid"
            lo=$((mid + 1))
        else
            hi=$((mid - 1))
        fi
    done
    printf '%s' "$best"
}

# mtu_menu - measure the path this tunnel rides on and say what its MTU should
# be. Offers to write it, because a number nobody applies is a number nobody
# uses.
mtu_menu() {
    pick_tunnel || return 0
    cfg_load "$PICKED" || return 0

    banner
    head2 "MTU: $PICKED"
    say ""
    if ! cfg_needs_link; then
        dim "This tunnel carries ports, not packets - it has no MTU of its own."
        dim "The connections inside it use whatever the two servers negotiate."
        say ""
        dim "Only TUN-ICMP, TUN-GRE and TUN-AWG have a device to set this on."
        pause
        return 0
    fi

    local peer="$T_PEER_IP"
    [ -n "$peer" ] || { fail "this tunnel has no peer address to measure to"; pause; return 0; }

    field "Transport" "$(transport_label "$T_TRANSPORT")"
    field "Measuring to" "$(addr_tint "$peer")"
    field "Set now" "$T_TUNMTU"
    say ""
    dim "Sends pings that may not be fragmented, largest first, until one comes"
    dim "back. Takes a few seconds."
    say ""

    local pmtu
    pmtu="$(path_mtu "$peer")" || {
        fail "the path would not answer a single ping"
        dim "either $peer is not reachable, or it is set to ignore ICMP -"
        dim "which the Blocking switch does, and the other server may have it on"
        say ""
        dim "turn it off there for a moment, measure, and turn it back on"
        pause
        return 0
    }

    local over want
    over="$(transport_overhead "$T_TRANSPORT")"
    want=$((pmtu - over))

    say ""
    panel "measured"
    field "Path carries" "$pmtu bytes"
    field "$(transport_label "$T_TRANSPORT") wraps" "$over bytes"
    field "So this tunnel" "$want bytes"
    panel_end
    say ""

    if [ "$pmtu" -lt 1500 ]; then
        warn "the path carries less than a full 1500-byte packet"
        dim "normal on a route that is itself inside another tunnel, and exactly"
        dim "why this is worth measuring rather than assuming"
        say ""
    fi

    if [ "$want" = "$T_TUNMTU" ]; then
        ok "the MTU is already right"
        pause
        return 0
    fi

    if [ "$want" -gt "$T_TUNMTU" ]; then
        dim "Raising it means fewer packets for the same bytes."
    else
        warn "the current $T_TUNMTU is larger than this path can carry"
        dim "every full-size packet is being fragmented or dropped, which is"
        dim "what makes a tunnel connect and then stall on anything large"
    fi
    say ""
    confirm_yes "set the MTU to $want?" || return 0

    local f; f="$(cfg_file "$PICKED")"
    cp -f "$f" "$f.bak"
    sed -i "s#^mtu .*#mtu              = $want#" "$f"
    rm -f "$f.bak"
    say ""
    ok "set to $want"
    dim "set the same on the other server - the smaller of the two is what the"
    dim "link actually gets, so leaving one high wastes the measurement"
    say ""
    if confirm_yes "restart $PICKED now?"; then
        systemctl restart "pingify@$PICKED" >/dev/null 2>&1
        ok "restarted"
    fi
    pause
}
