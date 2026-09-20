#!/usr/bin/env bash
#
# GRE FOU: the kernel's own GRE device, wrapped in UDP.
#
# GRE is IP protocol 47 and a great many routes drop it. The kernel can put
# the same GRE frames inside ordinary UDP datagrams - FOU, foo-over-UDP - and
# then nothing on the way sees protocol 47 at all. What crosses is UDP on one
# port, which is what our own UDP transport looks like too; the difference is
# that here the kernel does all of it and the bytes never reach a process.
# Measured between the test pair, one stream: 921 Mbit/s down and 809 up,
# against 645 and 592 for our own GRE.
#
# Three things have to be true for it, and each is undone again when the
# tunnel goes:
#
#   a FOU listener on the port, which is what unwraps the UDP
#   the GRE device itself, pointed at the other server's address
#   generic receive offload OFF on the interface the packets arrive on
#
# The last one is not optional and not ours: GRO joins arriving UDP datagrams
# together before the FOU layer has unwrapped them, the GRE frames inside come
# out malformed, and the receiver throws every one of them away. Measured on
# the pair with GRO left on: 0 Mbit/s, both directions, every time.
#
# It is also the one that costs something, because it is a setting for the
# whole interface and not for this tunnel: everything else on the server loses
# GRO too. So what it was before is written down before it is changed, and put
# back when the last tunnel that needed it is deleted.

GREFOU_STATE_PREFIX=grefou
# How long to wait for the route to the other server before going on
# without turning GRO off. Only a booting server ever waits at all.
GREFOU_ROUTE_WAIT=20

# grefou_iface NAME - the kernel device a tunnel runs on.
grefou_iface() { toml_get "$(cfg_file "$1")" tun name; }

# grefou_underlay ADDR - the interface packets to that address leave by.
grefou_underlay() {
    ip route get "$1" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1
}

# grefou_tunnels [except] - every tunnel here that is a GRE FOU one.
grefou_tunnels() {
    local except=${1:-} n
    # A plain loop, not a process substitution: called inside a command
    # substitution, the latter left the pipe's writing end open in some
    # shells and the read never ended.
    for n in $(cfg_list); do
        [ "$n" = "$except" ] && continue
        [ "$(toml_get "$(cfg_file "$n")" transport type)" = grefou ] || continue
        printf '%s\n' "$n"
    done
    return 0
}

# gro_state DEV - on, off, or empty when the interface cannot say.
gro_state() {
    have ethtool || return 0
    ethtool -k "$1" 2>/dev/null | awk '/^generic-receive-offload:/ { print $2; exit }'
}

# grefou_gro_off DEV - turn GRO off, writing down what it was first. The note
# is written once: a second tunnel on the same interface must not record "off"
# as the state to go back to.
grefou_gro_off() {
    local dev=$1 was file
    [ -n "$dev" ] || return 0
    have ethtool || {
        warn "ethtool is not installed, so GRO cannot be turned off on $dev"
        fix "apt-get install -y ethtool, then restart this tunnel"
        fix "without it this transport carries nothing at all - see Health"
        return 1
    }
    file=$STATE_DIR/$GREFOU_STATE_PREFIX.gro.$dev
    if [ ! -f "$file" ]; then
        was=$(gro_state "$dev")
        [ -n "$was" ] || was=on
        mkdir -p "$STATE_DIR" 2>/dev/null
        printf '%s\n' "$was" >"$file"
    fi
    ethtool -K "$dev" gro off 2>/dev/null || {
        warn "could not turn GRO off on $dev"
        return 1
    }
    return 0
}

# grefou_gro_restore DEV - put GRO back the way it was, when no GRE FOU tunnel
# is left that needs it off.
grefou_gro_restore() {
    local dev=$1 file was
    [ -n "$dev" ] || return 0
    file=$STATE_DIR/$GREFOU_STATE_PREFIX.gro.$dev
    [ -f "$file" ] || return 0
    was=$(cat "$file" 2>/dev/null)
    case $was in on | off) ;; *) was=on ;; esac
    if have ethtool; then
        ethtool -K "$dev" gro "$was" 2>/dev/null &&
            dim "generic receive offload on $dev is back to $was"
    fi
    rm -f "$file"
    return 0
}

# The MSS clamp, which keeps a connection through the tunnel from sending
# segments the tunnel cannot carry whole. Tagged with the tunnel's name so
# that only the rules this tunnel added are ever removed.
grefou_mss() {
    local how=$1 dev=$2 name=$3 dir
    have iptables || return 0
    for dir in -o -i; do
        case $how in
        add)
            # Once. The wizard brings the link up and the unit's pre-start
            # brings it up again, and without the check that was two of each.
            grefou_mss_rule -C "$dir" "$dev" "$name" || grefou_mss_rule -A "$dir" "$dev" "$name"
            ;;
        del)
            # Every copy, in case an older build did leave two.
            # Every copy, and no more than a handful: a delete that keeps
            # succeeding is a firewall that is lying, not a rule that is
            # still there.
            local _n=0
            while [ "$_n" -lt 16 ] && grefou_mss_rule -D "$dir" "$dev" "$name"; do _n=$((_n + 1)); done
            ;;
        esac
    done
    return 0
}

grefou_mss_rule() {
    iptables -w 2 -t mangle "$1" FORWARD "$2" "$3" -p tcp --tcp-flags SYN,RST SYN \
        -m comment --comment "pingify-grefou-$4" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
}

# grefou_up NAME - the device, the listener, the offload setting and the clamp.
# A tunnel that is already up comes up again: the device is remade, and any route somebody put on it by hand goes with it.
grefou_up() {
    local name=$1 f dev port local_ip peer mtu addr ul
    f=$(cfg_file "$name")
    dev=$(toml_get "$f" tun name)
    port=$(toml_get "$f" transport port)
    mtu=$(toml_get "$f" tun mtu)
    [ -n "$mtu" ] || mtu=1400
    if [ "$(toml_get "$f" tunnel side)" = iran ]; then
        local_ip=$(toml_get "$f" transport iran)
        peer=$(toml_get "$f" transport kharej)
        addr=$(toml_get "$f" tun iran)
    else
        local_ip=$(toml_get "$f" transport kharej)
        peer=$(toml_get "$f" transport iran)
        addr=$(toml_get "$f" tun kharej)
    fi
    [ -n "$dev" ] && [ -n "$port" ] && [ -n "$local_ip" ] && [ -n "$peer" ] && [ -n "$addr" ] || {
        fail "$name: the file does not say enough to build the link"
        return 1
    }

    modprobe fou 2>/dev/null
    modprobe ip_gre 2>/dev/null
    case " $(ip fou show 2>/dev/null) " in *" port $port "*) ;; *)
        ip fou add port "$port" ipproto 47 2>/dev/null || {
            fail "the kernel would not take a FOU listener on udp/$port"
            fix "this needs the fou module: modprobe fou"
            return 1
        } ;;
    esac

    ip link del "$dev" 2>/dev/null
    if ! ip link add "$dev" type gre local "$local_ip" remote "$peer" ttl 255 \
        encap fou encap-sport "$port" encap-dport "$port" 2>/dev/null; then
        fail "the kernel would not make $dev"
        fix "this needs the ip_gre module: modprobe ip_gre"
        ip fou del port "$port" 2>/dev/null
        return 1
    fi
    ip addr add "$addr" dev "$dev" 2>/dev/null
    ip link set "$dev" mtu "$mtu" up || {
        fail "$dev would not come up"
        return 1
    }

    # The interface the link rides, which is the one GRO has to be off on.
    # At boot it is not there yet: measured on the Iran server, this runs
    # four seconds after the card is renamed and before the default route
    # is installed, so it waits for the route rather than giving up on it.
    ul=$(grefou_underlay "$peer")
    local waited=0
    while [ -z "$ul" ] && [ "$waited" -lt "$GREFOU_ROUTE_WAIT" ]; do
        sleep 1
        waited=$((waited + 1))
        ul=$(grefou_underlay "$peer")
    done
    if [ -n "$ul" ]; then
        # Written down per tunnel: the delete puts the interface the link
        # was made on back, not whichever one the route names by then.
        mkdir -p "$STATE_DIR" 2>/dev/null
        printf '%s\n' "$ul" >"$STATE_DIR/$GREFOU_STATE_PREFIX.ul.$name"
        grefou_gro_off "$ul" ||
            warn "$dev is up, but it carries nothing until GRO is off on $ul"
    else
        # Not fatal, and deliberately so. A link that exists and carries
        # nothing is one the health check names and the watchdog restarts a
        # minute later, by which time the route is there. A link that was
        # never made is a tunnel that stays down until somebody notices.
        warn "no route to $peer yet, so GRO is still on: $dev will not carry until it is"
        fix "the next restart sets it - watch it with:  pingify --check $name"
    fi
    grefou_mss add "$dev" "$name"
    return 0
}

# grefou_dev_in_use DEV EXCEPT - whether another GRE FOU tunnel still needs
# GRO off on DEV. One whose interface was never written down counts as
# needing it: leaving GRO off is the safe mistake.
grefou_dev_in_use() {
    local dev=$1 except=$2 n f
    for n in $(grefou_tunnels "$except"); do
        f=$STATE_DIR/$GREFOU_STATE_PREFIX.ul.$n
        [ -f "$f" ] || return 0
        [ "$(cat "$f" 2>/dev/null)" = "$dev" ] && return 0
    done
    return 1
}

# grefou_down NAME - undo all of it, and leave the interface as it was found.
grefou_down() {
    local name=$1 f dev port peer ul
    f=$(cfg_file "$name")
    dev=$(grefou_iface "$name")
    port=$(toml_get "$f" transport port)
    if [ "$(toml_get "$f" tunnel side)" = iran ]; then
        peer=$(toml_get "$f" transport kharej)
    else
        peer=$(toml_get "$f" transport iran)
    fi
    [ -n "$dev" ] || return 0

    grefou_mss del "$dev" "$name"
    ip link del "$dev" 2>/dev/null
    [ -n "$port" ] && ip fou del port "$port" 2>/dev/null

    # The offload setting is the interface's, not this tunnel's, so it only
    # goes back when the last tunnel that wanted it off on that interface
    # has gone. The interface is the one written down when the link was
    # made; the route may name another one by now.
    ul=$(cat "$STATE_DIR/$GREFOU_STATE_PREFIX.ul.$name" 2>/dev/null)
    [ -n "$ul" ] || ul=$(grefou_underlay "$peer")
    rm -f "$STATE_DIR/$GREFOU_STATE_PREFIX.ul.$name"
    if [ -n "$ul" ] && ! grefou_dev_in_use "$ul" "$name"; then
        grefou_gro_restore "$ul"
    fi
    return 0
}

# grefou_note is what the wizard and the health check both say about it, in
# one place so they cannot disagree.
grefou_note() {
    dim "The kernel carries this one: fastest here, and the core only watches it."
    dim "It has no token on the wire, so anything that can forge the other"
    dim "server's address and knows the port is inside the tunnel. It also turns"
    dim "generic receive offload off on this server's interface - everything"
    dim "else here pays a little for that - and turns it back on when the"
    dim "tunnel is deleted."
}

# tunnel_boot NAME - what the unit runs before the core starts: whatever
# the transport needs from the kernel or the firewall that a reboot took
# away. The GRE FOU device is made, the AmneziaWG link brought up with a
# config written fresh from the tunnel's file, the raw TCP rule put back.
# For every other transport it says nothing and exits 0, because it runs in
# front of all of them. What goes wrong is said where systemd will show it,
# since there is no menu here.
tunnel_boot() {
    local name=${1:-} f
    [ -n "$name" ] || return 0
    f=$(cfg_file "$name")
    [ -f "$f" ] || return 0
    # Nothing here fails the unit, and that is the point of the 0 below.
    # This runs before every start, a boot included, where the network is
    # half up and a link may need a second attempt. A non-zero exit stops
    # the core starting, and twenty of those in forty seconds spend the
    # unit's start limit - after which systemd refuses every later start,
    # the watchdog's included, and the tunnel is down until somebody logs
    # in. Measured, on the tunnel carrying real users: ten minutes of it.
    # So what went wrong is said where systemd shows it, the core starts,
    # and the health check and the watchdog between them try again.
    case $(toml_get "$f" transport type) in
    grefou) grefou_up "$name" 2>&1 | boot_say "$name" ;;
    awg) awg_up "$name" 2>&1 | boot_say "$name" ;;
    rawtcp)
        rawtcp_guard "$(toml_get "$f" transport port)" 2>&1 |
            boot_say "$name" ;;
    esac
    return 0
}

# boot_say puts what a link's own routine printed into the journal, named
# and without the colour it would have used on a screen.
# boot_say puts what a link routine printed into the journal, named. The
# colour is already off here: the manager turns it off when what it writes
# to is not a terminal, and at boot it is the journal.
boot_say() {
    sed "s|^[[:space:]]*|pingify: $1: |" >&2
}
# The name the units written before this release call.
grefou_boot() { tunnel_boot "$@"; }
