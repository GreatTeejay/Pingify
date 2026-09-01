#!/usr/bin/env bash
#
# The wizard: six questions on the first server, one paste on the second.
#
# That asymmetry is the whole design, and it falls out of one fact about the
# core - the config file is byte-identical on both servers except the line
# side = "iran" / side = "kharej". So the second server does not answer
# questions at all. It takes the first server's file, flips one line, and
# writes it. A setting added to the core needs no change here, and the two ends
# cannot drift apart, which was the most common way a tunnel came up carrying
# nothing.
#
# The old setup token was 31 pipe-separated fields. Both the encoder and the
# decoder had to agree on the order, a new core setting meant editing both, and
# a truncated paste was diagnosed by counting fields. Here the token *is* the
# config file, and one hash catches every kind of damage.
#
# Every question is its own function reading into a T_* variable. That is so a
# test can drive the real wizard through its stdin instead of grepping this
# file for the strings it hopes are in it: the old suite had 130 assertions
# that were greps over the script's own source, and they pinned wording, broke
# on renames, and passed happily on dead code.

# The tunnel being edited may keep its own values - a screen that re-asks for a
# port must not report the tunnel's own port as taken. The wizard creates, so
# this stays empty here; every owner lookup below also takes the name as an
# optional last argument, so a caller that has one need not set a global and
# remember to put it back.
WIZ_KEEP=

# --------------------------------------------------------------------------
# addresses, and who already has them
# --------------------------------------------------------------------------

# wiz_ip4_int turns a dotted quad into a number so two of them can be compared.
# The 10# prefixes are not decoration: bash reads a leading zero as octal, so
# without them 10.010.0.1 compares as 10.8.0.1 and the answer is quietly wrong.
wiz_ip4_int() {
    local a b c d rest x
    IFS=. read -r a b c d rest <<<"$1"
    [ -z "$rest" ] || return 1
    for x in "$a" "$b" "$c" "$d"; do
        case $x in '' | *[!0-9]*) return 1 ;; esac
        [ "$((10#$x))" -le 255 ] || return 1
    done
    printf '%s' $(((10#$a << 24) + (10#$b << 16) + (10#$c << 8) + 10#$d))
}

# wiz_net_overlap answers whether 10.<octet>.10.0/24 lands inside an address
# already on this host. Comparing the top min(24, prefix) bits is what makes a
# docker bridge on 10.42.0.0/16 count as owning 10.42.10.0/24 - a plain string
# match on the second octet would miss it, and the tunnel would come up on a
# range the kernel already routes somewhere else.
wiz_net_overlap() {
    local addr=$1 plen=$2 oct=$3 a b m
    a=$(wiz_ip4_int "$addr") || return 1
    case $plen in '' | *[!0-9]*) return 1 ;; esac
    # An octet that is not a number would become an arithmetic syntax error
    # below, and inside a validator that error is what the user gets told.
    case $oct in '' | *[!0-9]*) return 1 ;; esac
    b=$(((10 << 24) + ((10#$oct) << 16) + (10 << 8)))
    m=$plen
    [ "$m" -gt 24 ] && m=24
    # A /0 on an interface is not a claim on anything; treating it as one would
    # make every octet look taken.
    [ "$m" -ge 1 ] || return 1
    [ "$((a >> (32 - m)))" -eq "$((b >> (32 - m)))" ]
}

# wiz_link_owner prints what owns 10.<octet>.10.0/24 here, or returns 1.
wiz_link_owner() {
    local oct=$1 keep=${2:-$WIZ_KEEP} n a dev addr plen
    while IFS= read -r n; do
        [ "$n" = "$keep" ] && continue
        a=$(toml_get "$(cfg_file "$n")" tun iran)
        case ${a%%/*} in
        10."$oct".*) printf 'the tunnel %s' "$n"; return 0 ;;
        esac
    done < <(cfg_list)
    # Process substitution, not a pipe: a pipe puts the loop in a subshell and
    # the return below would leave only the subshell, so a clash on the host
    # would be found and then thrown away.
    while read -r dev addr; do
        [ -n "$addr" ] || continue
        plen=${addr#*/}
        [ "$plen" = "$addr" ] && plen=32
        if wiz_net_overlap "${addr%%/*}" "$plen" "$oct"; then
            printf '%s on %s' "$addr" "$dev"
            return 0
        fi
    done < <(ip -4 -o addr 2>/dev/null | awk '$3 == "inet" { print $2, $4 }')
    return 1
}

# wiz_device_owner prints what owns a tun device name here, or returns 1.
wiz_device_owner() {
    local dev=$1 n keep=${2:-$WIZ_KEEP}
    while IFS= read -r n; do
        [ "$n" = "$keep" ] && continue
        [ "$(toml_get "$(cfg_file "$n")" tun name)" = "$dev" ] &&
            { printf 'the tunnel %s' "$n"; return 0; }
    done < <(cfg_list)
    # An interface with no config behind it is another tool's, or one of ours
    # left over from a crash. Either way the core cannot create it again.
    [ -e "/sys/class/net/$dev" ] && { printf 'an interface already on this host'; return 0; }
    return 1
}

# Who holds a port number, on the protocol that matters.
#
# 8443/udp and 8443/tcp are two different ports and always have been, so a UDP
# tunnel on 8443 is not in the way of a TCP one, and refusing it would be a
# refusal with nothing behind it. ICMP has no ports at all, so an icmp tunnel
# matches no protocol and owns no number.
wiz_port_owner() {
    local p=$1 keep=${2:-$WIZ_KEEP} proto=${3:-${T_TRANSPORT:-udp}} n f
    while IFS= read -r n; do
        [ "$n" = "$keep" ] && continue
        f=$(cfg_file "$n")
        [ "$(toml_get "$f" transport type)" = "$proto" ] || continue
        [ "$(toml_get "$f" transport port)" = "$p" ] &&
            { printf 'the tunnel %s' "$n"; return 0; }
    done < <(cfg_list)
    return 1
}

# wiz_port_bound asks whether anything on this host already listens on a udp
# port. When ss is missing the answer is "no": refusing to go on because a
# check could not run is a wall the user cannot climb, and the core will say so
# plainly at start-up if the bind really fails.
# And what the kernel says is listening, on that same protocol.
wiz_port_bound() {
    local p=$1 proto=${2:-${T_TRANSPORT:-udp}} flag=-lnu
    have ss || return 1
    [ "$proto" = tcp ] && flag=-lnt
    ss "$flag" 2>/dev/null |
        awk -v want=":$p\$" 'NR > 1 && $4 ~ want { hit = 1 } END { exit !hit }'
}

# wiz_public_ip is a default for the KHAREJ side, read from the interfaces
# rather than from a lookup service. The first server is in Iran on a path that
# blocks half the internet, so a wizard that pauses to curl an address service
# is a wizard that hangs where it is hardest to debug.
# Every address of this server the outside world could reach, one to a line.
#
# The private ranges are struck out, carrier grade NAT included: an address in
# 100.64/10 is one the machine's provider handed it behind a shared public one,
# and a config naming it is a config nothing outside that provider can dial.
wiz_public_ips() {
    local a found=1
    for a in $(ip -4 -o addr show scope global 2>/dev/null |
        awk '$3 == "inet" { sub("/.*", "", $4); print $4 }'); do
        case $a in
        10.* | 127.* | 192.168.* | 169.254.* | \
            172.1[6-9].* | 172.2[0-9].* | 172.3[01].* | \
            100.6[4-9].* | 100.[7-9][0-9].* | 100.1[01][0-9].* | 100.12[0-7].*) continue ;;
        esac
        printf '%s\n' "$a"
        found=0
    done
    return "$found"
}

wiz_public_ip() {
    local a
    a=$(wiz_public_ips | head -1)
    [ -n "$a" ] || return 1
    printf '%s' "$a"
}

# --------------------------------------------------------------------------
# choosing what is free
# --------------------------------------------------------------------------

# free_octet is the lowest 1-254 that no tunnel here owns and that is not
# inside any address on this host. It prints nothing when there is none, and
# the caller says so rather than offering a default that will be refused.
free_octet() {
    local i=1
    while [ "$i" -le 254 ]; do
        wiz_link_owner "$i" >/dev/null || { printf '%s' "$i"; return 0; }
        i=$((i + 1))
    done
    return 1
}

free_device() {
    local i=0 dev
    while [ "$i" -lt 64 ]; do
        dev="pfy$i"
        wiz_device_owner "$dev" >/dev/null || { printf '%s' "$dev"; return 0; }
        i=$((i + 1))
    done
    return 1
}

# The name a tunnel is given, which is also the name of its file.
#
# It starts with the side, and that is the whole point of it: on a server with
# three tunnels, the first thing anybody needs to know about each one is which
# end of the border they are looking at - and `ls /root/pingify` should say so
# without opening anything.
#
# Then the transport, then the one number that tells two tunnels apart: the
# port for a tunnel that has one, and the private link's octet for ICMP, which
# has no port at all.
#
#   iran-udp-8443     kharej-udp-8443
#   iran-icmp-99      kharej-icmp-99
#
# It is built from those two because neither can name a side. The name lives in
# the shared file, so a name like iran-9443 - which is what the old scheme
# produced - is a lie on one of the two servers from the moment it is written.
default_name() {
    local side=${1:-$T_SIDE} trans=${2:-$T_TRANSPORT} port=${3:-$T_PORT} oct=${4:-$T_OCTET}
    local base n i
    # For AmneziaWG the number worth having in the name is the port somebody
    # opened, not the one the carrier uses inside the link.
    [ "$trans" = awg ] && port=${T_AWG_PORT:-$port}
    base="$side-$trans-${port:-$oct}"
    n=$base
    i=2
    while [ -e "$(cfg_file "$n")" ]; do
        n="$base-$i"
        i=$((i + 1))
        [ "$i" -gt 20 ] && break
    done
    printf '%s' "$n"
}

# The same tunnel's name on the other server.
#
# The side is the first word of the name, so this replaces the first word. It
# is why the two files differ in two lines now rather than one: the side, and
# the name that carries it. A name that does not begin with a side is left
# alone - somebody chose it by hand and it is not this function's to rewrite.
name_for_side() {
    local name=$1 side=$2
    case $name in
    iran-* | kharej-*) printf '%s-%s' "$side" "${name#*-}" ;;
    *) printf '%s' "$name" ;;
    esac
}

# The status endpoint is one loopback port per tunnel. It is written into the
# shared file, so the second server inherits the number; wizard_paste checks it
# again there because the two servers do not have the same tunnels on them.
#
# Nothing free means nothing free. This used to fall out of the loop printing
# $STATUS_BASE with status 0 - the one port it had just proved was taken - and
# both callers wrote that number into the config without a word, so the new
# core lost the race for the loopback port and the tunnel never came up.
# Whether something on this machine already holds a port on every address.
#
# A listener on one address is not in the way: the health port is bound to the
# tunnel's own tun address, and no two tunnels have the same one. A listener
# on the wildcard *is* in the way - and on Linux an IPv6 wildcard holds the
# IPv4 one along with it, so [::]:19999 blocks 10.99.10.1:19999 too.
#
# This is why the health port is not a question. There is nothing for a person
# to know here that the machine does not already know.
wiz_health_bound() {
    local p=$1 a
    have ss || return 1
    while read -r a; do
        case $a in
        "0.0.0.0:$p" | "*:$p" | "[::]:$p" | ":::$p") return 0 ;;
        esac
    done < <(ss -ltnH 2>/dev/null | awk '{ print $4 }')
    return 1
}

wiz_free_health() {
    local p=$HEALTH_PORT n=0
    while wiz_health_bound "$p"; do
        p=$((p + 1))
        n=$((n + 1))
        [ "$n" -gt 20 ] && return 1
    done
    printf '%s' "$p"
}

wiz_free_status_port() {
    local keep=${1:-$WIZ_KEEP} i=0 p n taken
    while [ "$i" -lt 100 ]; do
        p=$((STATUS_BASE + i))
        taken=
        while IFS= read -r n; do
            [ "$n" = "$keep" ] && continue
            [ "$(toml_get "$(cfg_file "$n")" status port)" = "$p" ] && { taken=1; break; }
        done < <(cfg_list)
        [ -z "$taken" ] && { printf '%s' "$p"; return 0; }
        i=$((i + 1))
    done
    return 1
}

# --------------------------------------------------------------------------
# validators the wizard adds to the ones in the UI
# --------------------------------------------------------------------------

v_wiz_octet() {
    local who
    v_octet "$1" || return 1
    if who=$(wiz_link_owner "$1"); then
        echo "10.$1.10.0/24 is in use here by $who"
        return 1
    fi
    return 0
}

v_wiz_port() {
    local who
    v_port "$1" || return 1
    if who=$(wiz_port_owner "$1"); then
        echo "port $1 already belongs to $who"
        return 1
    fi
    # A bound port only matters on the side that waits. IRAN dials out, so a
    # local listener on the same number there is not a conflict, and refusing
    # it would be a refusal with no action behind it.
    if [ "$T_SIDE" = kharej ] && wiz_port_bound "$1"; then
        echo "$T_TRANSPORT/$1 is in use here; see: ss -lnp | grep :$1"
        return 1
    fi
    return 0
}

# Two characters are refused, and both were found by writing one and reading it
# back. A double quote ends the TOML string early, because the core's parser
# toggles on every quote it sees. A hash is worse, because it round trips
# through the core perfectly and is truncated by toml_get, which strips from a
# hash without caring whether it is inside a string - so the tunnel works and
# the fingerprint on the review panel is a different token's. Backslashes,
# pipes and spaces all survive both readers and are allowed.
v_wiz_token() {
    v_token "$1" || return 1
    case $1 in
    *'"'* | *'#'*)
        echo 'no " or # in a token - the config file cannot carry them intact'
        return 1
        ;;
    esac
    return 0
}

v_wiz_review() {
    case $1 in
    y | Y | yes | YES | n | N | no | NO | t | T) return 0 ;;
    esac
    echo "y to create it, n to stop, t to type your own token"
    return 1
}

v_wiz_paste() {
    local s=${1//[[:space:]]/}
    case $s in
    '') echo "paste the whole line the other server printed"; return 1 ;;
    PFY2.*) return 0 ;;
    esac
    echo "that is not a Pingify token - the line starts with PFY2."
    return 1
}

# --------------------------------------------------------------------------
# the six questions
# --------------------------------------------------------------------------

# The questions number themselves as they are asked.
#
# They used to carry the number in the title, and an ICMP tunnel does not have
# a port to ask about - so the wizard counted 1, 2, 3, 5, 6 and the person
# following it had every reason to wonder what they had missed.
WIZ_STEP=0
wiz_ask() {
    WIZ_STEP=$((WIZ_STEP + 1))
    rule "$WIZ_STEP $G_DOT $1"
}

q_side() {
    local n
    wiz_ask "Side"
    blank
    item "1" "IRAN" "clients connect here, and the ports live here"
    item "2" "KHAREJ" "your panel and inbounds run here"
    item "3" "Paste a token" "finish this server from the other one"
    blank
    blank
    dim "q at any question leaves without building anything"
    blank
    pick n "select" 1 3 || return 1
    case $n in
    1) T_SIDE=iran ;;
    2) T_SIDE=kharej ;;
    # Not a side. It is the other way in, and it is here rather than on a menu
    # of its own because "which server is this" is the first thing anybody
    # knows about the server they are sitting on, and finishing the second one
    # is the commonest answer of the three.
    3) T_SIDE=paste ;;
    esac
    return 0
}

# Asked on both servers, identically, because the file carries the address of
# the server abroad on both. The old wizard asked one side for "the remote" and
# the other for "the local", and the two answers were the same address written
# from two points of view, which is how the pair came to disagree.
# An address, in the colour addresses are printed in.
addr_text() { printf '%s%s%s' "$C_ADDR" "$1" "$C_OFF"; }

# Two questions, one for each end of the tunnel, and this server comes first
# because it is the one the script can answer for you.
#
# The address is read off this machine's own interfaces and offered as the
# default: if it is right, enter. When a server answers on more than one they
# are listed and picked from - taking the first and saying nothing is how the
# wrong one ends up in the file, and nothing says so until the other end has
# been dialling it for a quarter of an hour.
# Both addresses, in one step. They were two, and two steps to type two lines
# is a wizard that counts its own questions rather than the reader's work.
#
# This server's is read off its own interfaces and offered as the default: if
# it is right, enter. When a server answers on more than one they are listed
# and picked from - taking the first and saying nothing is how the wrong one
# ends up in the file, and nothing says so until the other end has been
# dialling it for a quarter of an hour.
q_addresses() {
    local def= n i=0 other=KHAREJ
    local -a addrs=()
    [ "$T_SIDE" = kharej ] && other=IRAN

    wiz_ask "Endpoints"
    blank
    # A name rather than an address is the whole of the CDN arrangement, and
    # it is one word rather than a question: a name can only ever front the
    # side that waits, because an edge answers on the name and connects
    # inward to the origin behind it. So a name here is what decides which
    # side dials, and nothing else needs asking.
    dim "an address, or a domain - a domain is what puts a CDN in front of it"
    blank
    while IFS= read -r n; do addrs+=("$n"); done < <(wiz_public_ips)

    if [ "${#addrs[@]}" -gt 1 ]; then
        dim "this server answers on more than one address - pick the right one"
        blank
        while [ "$i" -lt "${#addrs[@]}" ]; do
            item "$((i + 1))" "$(addr_text "${addrs[i]}")"
            i=$((i + 1))
        done
        item "$((i + 1))" "Something else" "a hostname, or one not listed"
        blank
        pick n "select" 1 $((i + 1)) || return 1
        if [ "$n" -le "${#addrs[@]}" ]; then
            T_HERE=${addrs[n - 1]}
        fi
        blank
    else
        def=${addrs[0]:-}
    fi
    [ -n "$T_HERE" ] || ask T_HERE "this server (${T_SIDE^^})" "$def" v_host || return 1
    ask T_THERE "the other one ($other)" "" v_host || return 1

    # Generated, never asked. Any path works and none is better than another,
    # so it is not a question - it exists so that a request for anything else
    # gets the 404 a web server would have given. The Advanced screen has it
    # for the rare case where a domain is shared with something else.
    case $T_TRANSPORT in
    ws | wss) T_PATH=$(wiz_path) ;;
    esac
    return 0
}

q_transport() {
    local n
    wiz_ask "Transport"
    blank
    item "1" "UDP" "a packet in, a packet out, nothing in the way"
    item "2" "TCP" "one open port, where a network carries only TCP"
    item "3" "WS" "an ordinary WebSocket - goes where HTTP goes"
    item "4" "WSS" "the same inside TLS - a domain, or a CDN in front"
    item "5" "ICMP" "inside ping packets - no open port at all"
    item "6" "GRE" "ip protocol 47 - no port to open, and no handshake"
    item "7" "AmneziaWG" "obfuscated WireGuard, encrypted, from their packages"
    blank
    dim "measured on one Tehran-Frankfurt pair, sixteen streams:"
    dim "  WS 427   WSS 405   ICMP 371   TCP 342   GRE 317   UDP dead there"
    blank
    dim "WS and WSS can go behind a CDN, which is what makes them the ones to"
    dim "try when a port is blocked rather than slow. While an ICMP tunnel runs"
    dim "neither server answers a ping."
    blank
    dim "GRE needs no port either and is the plainest of them: 378 Mbit/s on"
    dim "the same pair, and visible for exactly what it is to anyone looking."
    blank
    dim "AmneziaWG is the only one here this core does not implement: the link"
    dim "is theirs, installed from their own repository, and the tunnel runs"
    dim "inside it - so it is encrypted, and it is the one with a handshake."
    dim "It is UDP underneath, so where UDP dies it dies with it: on a server"
    dim "whose UDP flows stop after six packets, its handshake is the six."
    blank
    pick n "select" 1 7 || return 1
    case $n in
    1) T_TRANSPORT=udp ;;
    2) T_TRANSPORT=tcp ;;
    3) T_TRANSPORT=ws ;;
    4) T_TRANSPORT=wss ;;
    5) T_TRANSPORT=icmp ;;
    6) T_TRANSPORT=gre ;;
    7) T_TRANSPORT=awg
       awg_install || return 1
       ;;
    esac
    return 0
}

# Skipped whole for icmp, which has no ports: there is nothing to listen on and
# nothing to misconfigure, and that is half of why it survives.
q_port() {
    local def=8443 n
    # Neither of these has ports at all: one rides in echo requests and the
    # other is its own IP protocol.
    case $T_TRANSPORT in
    icmp | gre)
        T_PORT=
        return 0
        ;;
    awg)
        # The port asked for here is AmneziaWG's own, because that is the one
        # somebody has to open in a firewall. The carrier inside the link gets
        # a port of its own, worked out from the tunnel network below, where
        # nothing outside can reach it and nothing has to be asked.
        wiz_ask "Port"
        blank
        dim "AmneziaWG listens on this. The same number on both servers."
        blank
        ask T_AWG_PORT "port" "51820" v_awg_port || return 1
        return 0
        ;;
    esac
    wiz_ask "Port"
    blank
    dim "The same number on both servers, and the only port the tunnel needs."
    blank
    while IFS= read -r n; do
        [ "$(toml_get "$(cfg_file "$n")" transport type)" = icmp ] && continue
        dim "taken here:  $(toml_get "$(cfg_file "$n")" transport port)/$(toml_get "$(cfg_file "$n")" transport type)   $n"
    done < <(cfg_list)
    # Leaving the last candidate is the point of the bare break. The scan used
    # to end with def=8443, which is the number it had just proved was taken,
    # so pressing Enter at the prompt handed v_wiz_port a port it was certain
    # to refuse and the question asked itself again for no reason.
    while wiz_port_owner "$def" >/dev/null ||
        { [ "$T_SIDE" = kharej ] && wiz_port_bound "$def"; }; do
        def=$((def + 1))
        [ "$def" -gt 8500 ] && break
    done
    ask T_PORT "port" "$def" v_wiz_port || return 1
    return 0
}

# One question, not three. The old wizard asked for the octet and then re-asked
# both addresses it had just derived from it, so a hand edit at the second
# prompt walked straight past the checks that guarded the first.
# AmneziaWG's own port, which both servers bind: they each have a ListenPort,
# so something already holding it here is a link that will not come up at all.
#
# This check is the whole reason it is worth having. A leftover process on the
# Iran server was holding udp/51820, awg-quick could not bind it, the interface
# never appeared, and every screen above reported a tunnel whose far end had
# never been seen - which was true, and said nothing about why.
v_awg_port() {
    v_port "$1" || return 1
    if wiz_port_bound "$1" udp; then
        echo "something here already listens on udp/$1; see: ss -lunp | grep :$1"
        return 1
    fi
    return 0
}

# A path nobody scans for: six hex characters, from the kernel's own random
# device where there is one and from the shell's when there is not.
wiz_path() {
    local h
    h=$(head -c 3 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')
    [ -n "$h" ] || h=$(printf '%06x' $((RANDOM * RANDOM % 16777216)))
    printf '/%s' "$h"
}

q_link() {
    local def n a dev addr
    wiz_ask "Tunnel network"
    blank
    dim "A pair of addresses nothing else on either machine uses. Pick the"
    dim "middle number; both are worked out from it."
    blank
    while IFS= read -r n; do
        a=$(toml_get "$(cfg_file "$n")" tun iran)
        [ -n "$a" ] && dim "taken here:  ${a%%/*}/24  ($n)"
    done < <(cfg_list)
    while read -r dev addr; do
        case ${addr%%/*} in
        10.*) dim "taken here:  $addr  ($dev)" ;;
        esac
    done < <(ip -4 -o addr 2>/dev/null | awk '$3 == "inet" { print $2, $4 }')

    def=$(free_octet) || def=
    if [ -z "$def" ]; then
        warn "every 10.x.10.0/24 is inside an address on this host"
        fix "ip -4 -o addr   shows what has them"
    fi
    ask T_OCTET "range  10.x.10.0/24  -  x" "$def" v_wiz_octet || return 1

    T_DEV=$(free_device) || {
        bad "there is no free pfy device left on this host"
        return 1
    }
    blank
    field "IRAN" "$(addr_text "10.$T_OCTET.10.1/24")"
    field "KHAREJ" "$(addr_text "10.$T_OCTET.10.2/24")"
    field "device" "$T_DEV"
    return 0
}

# The screen that justifies the tool. Every number here was measured on the
# real path, restarted fresh at each queue depth, and the profile moves exactly
# one setting - tuning.queue_packets. Showing a bare number instead of what it
# buys is how the old tuning menu came to be scrolled past.
q_profile() {
    local n
    wiz_ask "Profile"
    blank
    item "1" "Gaming" "600 packets - a small one waits behind less"
    item "2" "Balanced" "900 packets - the one to pick if unsure"
    item "3" "Download" "1500 packets - most on a long transfer"
    blank
    dim "How many packets may wait in the tunnel's queue. Changeable later, on"
    dim "either server, without rebuilding anything."
    blank
    pick n "select" 2 3 || return 1
    case $n in
    1) T_PROFILE=gaming ;;
    2) T_PROFILE=balanced ;;
    3) T_PROFILE=download ;;
    esac
    return 0
}

wiz_queue() {
    case $1 in
    gaming) printf '600' ;;
    download) printf '1500' ;;
    *) printf '900' ;;
    esac
}

# --------------------------------------------------------------------------
# the token, which is generated rather than asked for
# --------------------------------------------------------------------------
#
# The core wants eight bytes; eighteen random ones are twenty-four base64
# characters, which removes a question, a validation loop, and the whole class
# of bug where one server has the token with a trailing space and the other
# does not.

wiz_token() {
    local t
    t=$(head -c 18 /dev/urandom 2>/dev/null | base64 2>/dev/null) || t=
    t=${t//$'\n'/}
    [ "${#t}" -ge 16 ] || return 1
    printf '%s' "$t"
}

wiz_sha256() {
    if have sha256sum; then sha256sum | cut -d' ' -f1
    elif have shasum; then shasum -a 256 | cut -d' ' -f1
    elif have openssl; then openssl dgst -sha256 | sed 's/.*= *//'
    else return 1
    fi
}

wiz_fingerprint() {
    local h
    h=$(printf '%s' "$1" | wiz_sha256) || { printf 'unknown'; return 0; }
    printf '%s' "${h:0:8}"
}

# --------------------------------------------------------------------------
# the review panel and the file it describes
# --------------------------------------------------------------------------

wiz_review() {
    local trans prof f
    f=$(cfg_file "$T_NAME")
    trans=${T_TRANSPORT^^}
    # For AmneziaWG the number worth showing is its own listening port, which
    # is the one somebody has to open. The carrier's port is inside the link
    # and nobody has to know it.
    if [ "$T_TRANSPORT" = awg ]; then
        trans="$trans  port ${T_AWG_PORT:-$(toml_get "$f" awg port)}"
    elif [ -n "$T_PORT" ]; then
        trans="$trans  port $T_PORT"
    fi
    case $T_TRANSPORT in
    tcp | ws | wss) trans="$trans  ${T_CONNS:-8} connections" ;;
    esac
    prof=${T_PROFILE:-balanced}
    blank
    panel_open "$T_NAME"
    panel_field "This server" "${T_SIDE^^}   $(addr_text "${T_HERE:-$([ "$T_SIDE" = iran ] && printf '%s' "$T_IRAN" || printf '%s' "$T_KHAREJ")}")"
    if [ "$T_SIDE" = iran ]; then
        panel_field "KHAREJ" "$(addr_text "$T_KHAREJ")"
    else
        panel_field "IRAN" "$(addr_text "$T_IRAN")"
    fi
    panel_field "Transport" "$trans"
    # Which end dials, said out loud, because for a WebSocket tunnel it is
    # worked out from the addresses rather than chosen - and the one thing a
    # person should be able to check on this screen is that it came out the
    # way they meant.
    local dialer=iran
    case $T_IRAN in *[a-zA-Z]*) case $T_KHAREJ in *[a-zA-Z]*) ;; *) dialer=kharej ;; esac ;; esac
    local target=$T_KHAREJ
    [ "$dialer" = kharej ] && target=$T_IRAN
    if [ "$T_SIDE" = "$dialer" ]; then
        panel_field "Dials" "out to $(addr_text "$target")"
    else
        panel_field "Waits" "${dialer^^} dials in"
    fi
    # "Link", not "Private link": it is the widest key any panel in the script
    # has, and one key a column wider than the rest puts one value out of line
    # with every other value in the box. The tunnel screen already calls it
    # this, so the two screens now agree as well.
    panel_field "Link" "10.$T_OCTET.10.1  $G_BOTH  10.$T_OCTET.10.2   $T_DEV"
    panel_field "Profile" "${prof^}   queue $(wiz_queue "$prof") packets"
    panel_field "Token" "${T_TOKEN:0:8}$G_CUT  (fingerprint $(wiz_fingerprint "$T_TOKEN"))"
    panel_close
    blank
}

# wiz_confirm shows the panel and asks, and both entrances use it.
#
# The only difference between them is whether the token may be retyped. On the
# paste path it may not: the token has to be the one the other server already
# has, and a different one produces a pair that links up never and explains
# itself never.
wiz_confirm() {
    local retype=${1:-no} go
    while :; do
        wiz_review
        ask go "create $T_NAME?" y v_wiz_review || return 1
        case $go in
        t | T)
            if [ "$retype" = yes ]; then
                ask T_TOKEN "security token" "" v_wiz_token || return 1
            else
                warn "the token has to match the other server; it came with the paste"
            fi
            continue
            ;;
        n | N | no | NO)
            blank
            dim "nothing was created"
            return 1
            ;;
        esac
        return 0
    done
}

# wiz_render writes the config to stdout.
#
# One space either side of every "=", because that is exactly what toml_set
# writes when it rewrites a line. The second server flips side through
# toml_set, and if the two shapes disagreed then a diff of the two servers'
# files would show a formatting change beside the one real difference - and
# that diff is how anybody checks the pair is a pair.
wiz_render() {
    printf '# Pingify %s\n' "$PINGIFY_VERSION"
    printf '#\n'
    printf '# The same file runs on both servers, but for the side and the name.\n'
    printf '\n[tunnel]\n'
    printf 'name = "%s"\n' "$T_NAME"
    printf 'side = "%s"\n' "$T_SIDE"
    printf 'mode = "tun"\n'
    printf '\n[transport]\n'
    printf 'type = "%s"\n' "$T_TRANSPORT"
    printf 'kharej = "%s"\n' "$T_KHAREJ"
    # Recorded, not dialled. KHAREJ never dials anything, so nothing uses this
    # - but both files carry it, so the operator of either server can see
    # which pair a tunnel belongs to without logging into the other one.
    [ -n "$T_IRAN" ] && printf 'iran = "%s"\n' "$T_IRAN"
    # No port key at all for icmp. Writing port = 0 would pass the core's check
    # and then sit in the file looking like a setting somebody chose.
    [ -n "$T_PORT" ] && printf 'port = %s\n' "$T_PORT"
    # Only a stream carrier opens more than one. On this path a single TCP
    # connection is shaped to nothing and eight together are not shaped at
    # all, which is the whole reason the number is here.
    case $T_TRANSPORT in
    tcp | ws | wss) printf 'connections = %s\n' "${T_CONNS:-8}" ;;
    esac
    [ -n "$T_PATH" ] && printf 'path = "%s"\n' "$T_PATH"
    # AmneziaWG's own half of the tunnel. The keys are both pairs, because
    # WireGuard needs a private key on each side and the other side's public
    # one - four values where every other transport has a single shared token -
    # and one file still has to describe the whole tunnel.
    if [ "$T_TRANSPORT" = awg ]; then
        printf '\n[awg]\n'
        printf 'name = "%s"\n' "$T_AWG_IFACE"
        printf 'iran = "10.%s.20.1/24"\n' "$T_OCTET"
        printf 'kharej = "10.%s.20.2/24"\n' "$T_OCTET"
        printf 'mtu = 1320\n'
        printf 'port = %s\n' "$T_AWG_PORT"
        printf 'iran_key = "%s"\n' "$T_AWG_IKEY"
        printf 'iran_pub = "%s"\n' "$T_AWG_IPUB"
        printf 'kharej_key = "%s"\n' "$T_AWG_KKEY"
        printf 'kharej_pub = "%s"\n' "$T_AWG_KPUB"
        printf 'jc = %s\n' "$T_AWG_JC"
        printf 'jmin = %s\n' "$T_AWG_JMIN"
        printf 'jmax = %s\n' "$T_AWG_JMAX"
        printf 's1 = %s\n' "$T_AWG_S1"
        printf 's2 = %s\n' "$T_AWG_S2"
        printf 'h1 = %s\n' "$T_AWG_H1"
        printf 'h2 = %s\n' "$T_AWG_H2"
        printf 'h3 = %s\n' "$T_AWG_H3"
        printf 'h4 = %s\n' "$T_AWG_H4"
    fi
    printf '\n[security]\n'
    printf 'token = "%s"\n' "$T_TOKEN"
    printf '\n[tuning]\n'
    printf 'profile = "%s"\n' "$T_PROFILE"
    printf '\n[tun]\n'
    printf 'name = "%s"\n' "$T_DEV"
    printf 'iran = "10.%s.10.1/24"\n' "$T_OCTET"
    printf 'kharej = "10.%s.10.2/24"\n' "$T_OCTET"
    # Not asked. 1320 works on every path we have measured, and Measure MTU on
    # the tunnel screen finds the real number properly.
    printf 'mtu = %s\n' "${T_MTU:-1320}"
    printf '\n[logging]\n'
    printf 'level = "info"\n'
    printf '\n[status]\n'
    printf 'port = %s\n' "${T_STATUS:-$STATUS_BASE}"
    # The same on both servers, and it stays that way: it is bound to this
    # tunnel's private address, which nothing else on either machine has.
    printf 'health_port = %s\n' "${T_HEALTH:-$HEALTH_PORT}"
}

# --------------------------------------------------------------------------
# writing it, and saying honestly what happened
# --------------------------------------------------------------------------

# tunnel_create NAME [FILE] - FILE is the finished config; with no FILE the
# config is read from stdin.
tunnel_create() {
    local name=$1 src=${2:-} f out
    [ -n "$name" ] || { bad "a tunnel needs a name"; return 1; }
    if ! ensure_dirs; then
        bad "could not create $CFG_DIR"
        fix "run this as root"
        return 1
    fi
    f=$(cfg_file "$name")
    [ -e "$f" ] && { bad "there is already a tunnel called $name here"; return 1; }
    if [ ! -x "$CORE_BIN" ]; then
        bad "the core is not installed at $CORE_BIN"
        fix "install Pingify first - nothing has been changed"
        return 1
    fi

    # The file is 0600 before a single byte of the token exists in it. Writing
    # first and fixing the mode afterwards leaves a window where anyone with an
    # account on the box can read it, and on a shared VPS that window is enough.
    if ! : >"$f"; then
        bad "could not write $f"
        return 1
    fi
    chmod 0600 "$f"
    # A failed copy used to return 1 with nothing on the screen, and both
    # wizards just passed that 1 up, so six answered questions ended in silence
    # - the only failure in this file that never said what went wrong. A full
    # disk and a read-only /etc both land here.
    if [ -n "$src" ]; then
        cat "$src" >"$f" || { bad "could not write $f"; rm -f "$f"; return 1; }
    else
        cat >"$f" || { bad "could not write $f"; rm -f "$f"; return 1; }
    fi

    if ! out=$("$CORE_BIN" -c "$f" -check 2>&1); then
        bad "the core will not accept that config - nothing created"
        printf '%s\n' "$out" | sed 's/^/       /'
        rm -f "$f"
        return 1
    fi
    # Cut to fit rather than run over the edge: a long tunnel name makes a long
    # path, and this is the one line in the wizard that carries one.
    ok "$(trunc_to "$f" $((UI_W - 30))) accepted by the core"

    # A repair, not a rewrite: the units are written once at install, and doing
    # it per tunnel is how the old script came to rewrite four units whenever
    # anybody added one.
    [ -f "$UNIT_DIR/pingify@.service" ] || unit_write

    # The AmneziaWG link is the wire this tunnel runs on, so it comes up
    # first. If it will not, the tunnel is not started: a carrier dialling an
    # address on a link that does not exist would sit there reporting nothing
    # is wrong except that the far end has never been seen.
    if [ "$(toml_get "$f" transport type)" = awg ]; then
        if ! awg_up "$name"; then
            rm -f "$f"
            return 1
        fi
        ok "the AmneziaWG link $(awg_iface "$name") is up"
    fi

    # svc_do enable returns the truth about is-active and prints the journal
    # when it failed. Returning its status is the point: the old caller printed
    # a green "is running" over a unit that had never started.
    svc_do enable "$name"
}

# --------------------------------------------------------------------------
# the setup token: PFY2. + base64 of "<sha256 of body>|<the TOML verbatim>"
# --------------------------------------------------------------------------

token_encode() {
    local file=$1 body sum out
    [ -f "$file" ] || { echo "there is no file at $file" >&2; return 1; }
    # Trailing newlines are dropped here and on the way back, on purpose: a
    # command substitution eats them anyway, so checksumming what survives the
    # journey is the only way the two sums can agree.
    body=$(cat "$file") || return 1
    sum=$(printf '%s\n' "$body" | wiz_sha256) || {
        echo "no sha256 tool here, so no token can be made" >&2
        return 1
    }
    out=$( { printf '%s|' "$sum"; printf '%s\n' "$body"; } | base64) || return 1
    printf 'PFY2.%s\n' "${out//$'\n'/}"
}

token_decode() {
    local line=$1 raw sum body have
    # Every kind of whitespace comes out first. The line is long enough to wrap
    # in any terminal, and a paste that picked up the wrap is the single most
    # common way this fails; base64 has no whitespace in it to lose.
    line=${line//[[:space:]]/}
    case $line in
    PFY2.*) ;;
    *) echo "that is not a Pingify token - the line starts with PFY2." >&2; return 1 ;;
    esac
    raw=$(printf '%s' "${line#PFY2.}" | base64 -d 2>/dev/null) || {
        echo "the token will not decode - copy the whole line" >&2
        return 1
    }
    # Split on the first pipe only: a hand-typed security token may contain
    # one, and a sha256 never does.
    sum=${raw%%|*}
    body=${raw#*|}
    [ "$sum" != "$raw" ] || {
        echo "the token will not decode - copy the whole line" >&2
        return 1
    }
    have=$(printf '%s\n' "$body" | wiz_sha256) || {
        echo "no sha256 tool here, so the token cannot be checked" >&2
        return 1
    }
    if [ "$have" != "$sum" ]; then
        echo "the token checksum does not match - copy the whole line" >&2
        return 1
    fi
    printf '%s\n' "$body"
}

# --------------------------------------------------------------------------
# build a new tunnel
# --------------------------------------------------------------------------

wizard_new() {
    local f other
    WIZ_QUIT=0
    T_SIDE= T_KHAREJ= T_IRAN= T_HERE= T_THERE= T_TRANSPORT= T_PORT= T_OCTET= T_PROFILE= T_HEALTH=
    T_PATH= T_AWG_PORT= T_AWG_IFACE=
    T_AWG_IKEY= T_AWG_IPUB= T_AWG_KKEY= T_AWG_KPUB=
    T_AWG_JC= T_AWG_JMIN= T_AWG_JMAX= T_AWG_S1= T_AWG_S2=
    T_AWG_H1= T_AWG_H2= T_AWG_H3= T_AWG_H4=
    T_NAME= T_DEV= T_TOKEN= T_MTU=1320 T_STATUS=
    WIZ_STEP=0

    screen_top
    blank
    rule "New tunnel"
    blank

    q_side || return 1
    # The third answer to the first question is not a side. It is the other
    # way in: on the second server everything this wizard would ask is already
    # inside the token the first one printed, so there is nothing to ask.
    if [ "$T_SIDE" = paste ]; then
        wizard_paste
        return $?
    fi
    blank
    q_addresses || return 1

    # Which of the two answers is which key. The file names both ends, and it
    # names them the same way on both servers, so the mapping happens once
    # here rather than at every place that reads them.
    if [ "$T_SIDE" = iran ]; then
        T_IRAN=$T_HERE
        T_KHAREJ=$T_THERE
    else
        T_KHAREJ=$T_HERE
        T_IRAN=$T_THERE
    fi

    blank
    q_transport || return 1
    blank
    q_port || return 1
    blank
    q_link || return 1
    blank
    q_profile || return 1

    # AmneziaWG carries two more things the tunnel network decides: the
    # addresses of the link itself, beside the tunnel's own, and the port the
    # carrier uses inside it - which is derived rather than asked because
    # nothing outside the link can reach it and the octet already makes it
    # unique on this host.
    if [ "$T_TRANSPORT" = awg ]; then
        T_PORT=$((20900 + T_OCTET))
        # The tunnel rides inside the AmneziaWG link, so its packets have to
        # fit in one of theirs: 1320 on the link, less 20 of IP, 8 of UDP and
        # the twelve this core puts in front of a packet.
        T_MTU=1280
        T_AWG_IFACE=$(awg_free_iface) || {
            bad "there is no free awg device left on this host"
            return 1
        }
        awg_generate || {
            bad "AmneziaWG would not generate a key here"
            return 1
        }
    fi

    T_NAME=$(default_name)

    # The health port is not asked for, and this is the reason: the only thing
    # that could be wrong with it is something else on this machine holding it
    # on every address, and that is a question the machine answers faster than
    # a person can. It goes in the shared file, so both servers get the number
    # this one settled on.
    if ! T_HEALTH=$(wiz_free_health); then
        T_HEALTH=$HEALTH_PORT
        warn "$HEALTH_PORT and the twenty above it are all taken on this server"
        fix "the tunnel will work; its round trip will not be measurable"
    elif [ "$T_HEALTH" != "$HEALTH_PORT" ]; then
        blank
        dim "$HEALTH_PORT is taken here, so the health port is $T_HEALTH on both servers"
    fi
    # Stop here rather than build a tunnel whose core cannot bind its status
    # port: the home screen reads every number through that endpoint, so a
    # tunnel without one is a tunnel nothing can report on.
    if ! T_STATUS=$(wiz_free_status_port); then
        bad "every status port from $STATUS_BASE is taken here"
        fix "delete a tunnel, or set [status] port by hand"
        return 1
    fi
    if ! T_TOKEN=$(wiz_token); then
        warn "no random source here, so the token has to be typed"
        ask T_TOKEN "security token" "" v_wiz_token || return 1
    fi

    wiz_confirm yes || return 1

    blank
    f=$(mktemp) || { bad "could not make a temporary file"; return 1; }
    wiz_render >"$f"
    if ! tunnel_create "$T_NAME" "$f"; then
        rm -f "$f"
        return 1
    fi
    rm -f "$f"

    other=KHAREJ
    [ "$T_SIDE" = kharej ] && other=IRAN
    wiz_handoff "$T_NAME" "$other"
}

wiz_handoff() {
    local name=$1 other=$2 line
    if ! line=$(token_encode "$(cfg_file "$name")"); then
        bad "the config is written, but the token could not be made"
        fix "copy the file to $other by hand and change side there"
        return 1
    fi
    blank
    rule "Now the other server"
    blank
    dim "Run Pingify on $other, pick \"Finish the pair\", and paste:"
    blank
    # Printed flush left with nothing around it, so a double click or a triple
    # click selects the token and only the token.
    say "$line"
    blank
    warn "treat that like a password: the token is inside it"
    blank
    return 0
}

# --------------------------------------------------------------------------
# finish the pair
# --------------------------------------------------------------------------

wizard_paste() {
    local line f err a own n clash moved
    WIZ_QUIT=0
    blank
    rule "Paste a token"
    blank
    dim "Paste the line the first server printed. It carries"
    dim "the whole config, so there is nothing left to answer."
    blank
    ask line "paste the line from the other server" "" v_wiz_paste || return 1

    f=$(mktemp) || { bad "could not make a temporary file"; return 1; }
    # stderr into the substitution, stdout into the file: the order matters,
    # because 2>&1 copies where stdout points *now*.
    if ! err=$(token_decode "$line" 2>&1 >"$f"); then
        blank
        bad "$err"
        fix "copy the whole line again from the first server"
        rm -f "$f"
        return 1
    fi

    T_NAME=$(toml_get "$f" tunnel name)
    T_SIDE=$(toml_get "$f" tunnel side)
    T_TRANSPORT=$(toml_get "$f" transport type)
    T_KHAREJ=$(toml_get "$f" transport kharej)
    T_IRAN=$(toml_get "$f" transport iran)
    T_PORT=$(toml_get "$f" transport port)
    T_PATH=$(toml_get "$f" transport path)
    T_TOKEN=$(toml_get "$f" security token)
    T_PROFILE=$(toml_get "$f" tuning profile)
    T_DEV=$(toml_get "$f" tun name)
    T_MTU=$(toml_get "$f" tun mtu)
    a=$(toml_get "$f" tun iran)
    T_OCTET=${a#10.}
    T_OCTET=${T_OCTET%%.*}

    # The checksum says the file arrived whole; it does not say it was a
    # Pingify config. Everything below indexes on these four, so they are
    # checked here rather than found missing halfway through the collision
    # checks with an arithmetic error for a message.
    if ! v_name "$T_NAME" >/dev/null 2>&1 ||
        ! v_octet "$T_OCTET" >/dev/null 2>&1 ||
        [ -z "$T_DEV" ] || [ -z "$T_TRANSPORT" ]; then
        bad "that token decoded, but it is not a Pingify config"
        fix "paste the line the other server printed"
        rm -f "$f"
        return 1
    fi

    # The side in the file is the *other* server's. This flip is the entire
    # second installation.
    case $T_SIDE in
    iran) T_SIDE=kharej ;;
    kharej) T_SIDE=iran ;;
    *) bad "that token does not say which server made it"; rm -f "$f"; return 1 ;;
    esac
    toml_set "$f" tunnel side "$T_SIDE"

    # And the name goes with it. The name begins with the side, so a file
    # pasted onto KHAREJ that still called itself iran-udp-8443 would be the
    # one thing on this server whose name was a lie about it.
    T_NAME=$(name_for_side "$T_NAME" "$T_SIDE")
    toml_set "$f" tunnel name "$T_NAME"

    # The file is shared, so a clash here can only be fixed on both servers.
    # This is the one thing the shared-file design costs, and it is the
    # manager's job to spell out, not the user's to work out.
    clash=0
    if [ -e "$(cfg_file "$T_NAME")" ]; then
        bad "there is already a tunnel called $T_NAME here"
        fix "delete that one first, or use a different octet"
        clash=1
    fi
    if own=$(wiz_link_owner "$T_OCTET"); then
        bad "10.$T_OCTET.10.0/24 is in use here by $own"
        fix "change the range on both servers, and paste again"
        clash=1
    fi
    if own=$(wiz_device_owner "$T_DEV"); then
        bad "the device $T_DEV is in use here by $own"
        fix "the device is in the shared file - change both"
        clash=1
    fi
    # The health port comes with the file and this server has to be able to
    # bind it too. It is a warning rather than a clash: the tunnel carries
    # traffic without it, and what is lost is the round trip measurement and
    # the check that asks the far end whether it is there.
    a=$(toml_get "$f" status health_port)
    case $a in '' | *[!0-9]*) a=$HEALTH_PORT ;; esac
    if wiz_health_bound "$a"; then
        warn "something here already holds port $a on every address"
        fix "the tunnel works; its round trip will not be measurable"
        fix "to fix it, set status.health_port to a free number on both servers"
    fi

    if [ "$T_SIDE" = kharej ] && [ "$T_TRANSPORT" != icmp ]; then
        if own=$(wiz_port_owner "$T_PORT"); then
            bad "port $T_PORT already belongs to $own"
            fix "change the port on both servers, and paste again"
            clash=1
        elif wiz_port_bound "$T_PORT"; then
            bad "something here already listens on $T_TRANSPORT/$T_PORT"
            fix "ss -lnup | grep :$T_PORT   shows what has it"
            clash=1
        fi
    fi
    if [ "$clash" = 1 ]; then
        blank
        dim "nothing was created"
        rm -f "$f"
        return 1
    fi

    # The status port is loopback-only and per host, so it is the one number
    # that may legitimately differ between the two files. It is checked again
    # here because this server does not have the same tunnels on it.
    T_STATUS=$(toml_get "$f" status port)
    # Anything that is not a port counts as absent, and the empty string is the
    # reason: a pasted file with no [status] port compared equal to every local
    # tunnel that also had none, so the screen read "status port  is taken here
    # by <n>" with a blank where the number belongs. An absent port is filled
    # in below instead of being reported as a clash.
    case $T_STATUS in '' | *[!0-9]*) T_STATUS= ;; esac
    moved=0
    if [ -n "$T_STATUS" ]; then
        while IFS= read -r n; do
            [ "$(toml_get "$(cfg_file "$n")" status port)" = "$T_STATUS" ] || continue
            warn "status port $T_STATUS is taken here by $n"
            T_STATUS=
            moved=1
            break
        done < <(cfg_list)
    fi
    if [ -z "$T_STATUS" ]; then
        if ! T_STATUS=$(wiz_free_status_port); then
            bad "every status port from $STATUS_BASE is taken here"
            fix "delete a tunnel, or set [status] port by hand"
            rm -f "$f"
            return 1
        fi
        [ "$moved" = 1 ] && dim "this file uses $T_STATUS, so the two differ there too"
        toml_set "$f" status port "$T_STATUS"
    fi

    wiz_confirm no || { rm -f "$f"; return 1; }

    blank
    if ! tunnel_create "$T_NAME" "$f"; then
        rm -f "$f"
        return 1
    fi
    rm -f "$f"
    blank
    ok "both ends are configured now - nothing else to paste"
    dim "give it a few seconds and look at it on the home screen"
    blank
    return 0
}

# --------------------------------------------------------------------------
# the way in
# --------------------------------------------------------------------------

# The two entrances, and nothing else.
#
# menu_key rather than pick, because 0 is a key here and pick only answers 1..N
# on purpose - a question with a numbered list of answers must not accept a
# number that is not one of them. Navigation screens have a Back key; questions
# do not.
# The way in, and there is only one now.
#
# There were two, on a menu of their own: build a tunnel, or finish the pair.
# It was a screen that asked which of two wizards you wanted before either had
# said anything, and the answer is the same thing the first question of the
# wizard asks anyway - which server am I sitting on. So the menu is gone and
# "Paste a token" is the third answer to that question.
screen_new() {
    wizard_new
    return 0
}
