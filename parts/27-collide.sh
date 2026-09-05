#!/usr/bin/env bash
#
# What is already taken on this server, and by whom.
#
# Every question the wizard asks that names a number - a port, a private
# network, a device - is a number something else on this machine may already
# hold. Two tunnels on one network route into each other; two on one port
# means whichever bound it first wins and the other never sees a connection;
# and the symptom of either is traffic going somewhere it was not meant to
# with nothing on the server to explain it. So every such question says what
# is taken, offers something that is not, and refuses a repeat.
#
# Two sources, always: the tunnels this server knows about, from their files,
# and what the kernel itself reports - an address on an interface, a socket
# listening - because a docker bridge or another VPN is just as much in the
# way as one of ours.

cfg_files() {
    local f
    for f in "$CFG_DIR"/*."$CFG_EXT"; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done
    return 0
}

cfg_name() {
    local n
    n=$(toml_get "$1" tunnel name)
    if [ -z "$n" ]; then
        n=${1##*/}
        n=${n%.$CFG_EXT}
    fi
    printf '%s' "$n"
}

# --------------------------------------------------------------------------
# private networks
# --------------------------------------------------------------------------

# tun_nets [except] - "10.x.10 name" for every tunnel with a private link.
tun_nets() {
    local except=${1:-} f addr name
    cfg_files | while read -r f; do
        addr=$(toml_get "$f" tun iran)
        [ -n "$addr" ] || continue
        name=$(cfg_name "$f")
        [ -n "$except" ] && [ "$name" = "$except" ] && continue
        printf '%s %s\n' "${addr%.*}" "$name"
    done
    return 0
}

net_owner() {
    local want=$1 except=${2:-}
    tun_nets "$except" | while read -r net name; do
        if [ "$net" = "$want" ]; then
            printf '%s' "$name"
            break
        fi
    done
    return 0
}

# ip4_int turns a dotted quad into a number so two of them can be compared.
# The 10# prefixes are not decoration: bash reads a leading zero as octal.
ip4_int() {
    local a b c d rest x
    IFS=. read -r a b c d rest <<<"$1"
    [ -z "$rest" ] || return 1
    for x in "$a" "$b" "$c" "$d"; do
        case $x in '' | *[!0-9]*) return 1 ;; esac
        [ "$((10#$x))" -le 255 ] || return 1
    done
    printf '%s' $(((10#$a << 24) + (10#$b << 16) + (10#$c << 8) + 10#$d))
}

# net_overlap ADDR PLEN OCTET - does 10.<octet>.10.0/24 land inside an address
# already on this host. Comparing the top min(24, prefix) bits is what makes a
# docker bridge on 10.42.0.0/16 count as owning 10.42.10.0/24.
net_overlap() {
    local addr=$1 plen=$2 oct=$3 a b m
    a=$(ip4_int "$addr") || return 1
    case $plen in '' | *[!0-9]*) return 1 ;; esac
    case $oct in '' | *[!0-9]*) return 1 ;; esac
    b=$(((10 << 24) + ((10#$oct) << 16) + (10 << 8)))
    m=$plen
    [ "$m" -gt 24 ] && m=24
    [ "$m" -ge 1 ] || return 1
    [ "$((a >> (32 - m)))" -eq "$((b >> (32 - m)))" ]
}

# host_net_owner OCTET - prints "addr on dev" when an address on this host
# already covers 10.<octet>.10.0/24.
host_net_owner() {
    local oct=$1 dev addr plen
    have ip || return 1
    while read -r dev addr; do
        [ -n "$addr" ] || continue
        plen=${addr#*/}
        [ "$plen" = "$addr" ] && plen=32
        if net_overlap "${addr%%/*}" "$plen" "$oct"; then
            printf '%s on %s' "$addr" "$dev"
            return 0
        fi
    done < <(ip -4 -o addr 2>/dev/null | awk '$3 == "inet" { print $2, $4 }')
    return 1
}

host_has_net() { host_net_owner "$1" >/dev/null; }

# free_link_octet [except] - the lowest 1-254 nothing here owns.
free_link_octet() {
    local except=${1:-} x=1
    while [ "$x" -le 254 ]; do
        if [ -z "$(net_owner "10.${x}.10" "$except")" ] && ! host_has_net "$x"; then
            printf '%s' "$x"
            return 0
        fi
        x=$((x + 1))
    done
    return 1
}

show_taken_nets() {
    local except=${1:-} taken dev addr
    taken=$(tun_nets "$except")
    if [ -n "$taken" ]; then
        warn "private networks already used on this server"
        printf '%s\n' "$taken" | while read -r net name; do
            [ -n "$net" ] && dim "$(pad_to "${net}.0/24" 18)${BX_ARR} $name"
        done
    fi
    if have ip; then
        while read -r dev addr; do
            case ${addr%%/*} in
            10.*) dim "$(pad_to "$addr" 18)${BX_ARR} $dev, on this host" ;;
            esac
        done < <(ip -4 -o addr 2>/dev/null | awk '$3 == "inet" { print $2, $4 }')
    fi
    return 0
}

# --------------------------------------------------------------------------
# devices
# --------------------------------------------------------------------------

tun_ifaces() {
    local except=${1:-} f iface name
    cfg_files | while read -r f; do
        iface=$(toml_get "$f" tun name)
        [ -n "$iface" ] || continue
        name=$(cfg_name "$f")
        [ -n "$except" ] && [ "$name" = "$except" ] && continue
        printf '%s %s\n' "$iface" "$name"
    done
    return 0
}

iface_owner() {
    local want=$1 except=${2:-}
    tun_ifaces "$except" | while read -r iface name; do
        if [ "$iface" = "$want" ]; then
            printf '%s' "$name"
            break
        fi
    done
    return 0
}

host_has_iface() { [ -e "/sys/class/net/$1" ]; }

free_tun_iface() {
    local except=${1:-} n=0
    while [ "$n" -lt 64 ]; do
        if [ -z "$(iface_owner "pfy$n" "$except")" ] && ! host_has_iface "pfy$n"; then
            printf 'pfy%s' "$n"
            return 0
        fi
        n=$((n + 1))
    done
    return 1
}

# --------------------------------------------------------------------------
# the tunnel's own port
# --------------------------------------------------------------------------

# port_family says which kind of socket a transport binds. tcp and udp are
# separate: 9443/udp does not block 9443/tcp. ICMP and GRE have no port.
port_family() {
    case $1 in
    tcp | ws | wss | utls | fallback | rawtcp) printf 'tcp' ;;
    udp | awg) printf 'udp' ;;
    *) printf 'none' ;;
    esac
}

# tunnel_port_of FILE - "port family" for the port a tunnel's file names, on
# the side that waits for it. AmneziaWG's is the one somebody has to open.
tunnel_port_of() {
    local f=$1 t p fam
    t=$(toml_get "$f" transport type)
    fam=$(port_family "$t")
    [ "$fam" = none ] && return 1
    if [ "$t" = awg ]; then
        p=$(toml_get "$f" awg port)
    else
        p=$(toml_get "$f" transport port)
    fi
    case $p in '' | *[!0-9]*) return 1 ;; esac
    printf '%s %s' "$p" "$fam"
}

# tunnel_port_owner PORT TRANSPORT [except] - the tunnel that already carries
# on that port and family.
tunnel_port_owner() {
    local want=$1 fam except=${3:-} f name p
    fam=$(port_family "$2")
    case $want in '' | *[!0-9]*) return 0 ;; esac
    [ "$fam" = none ] && return 0
    cfg_files | while read -r f; do
        p=$(tunnel_port_of "$f") || continue
        [ "${p%% *}" = "$want" ] || continue
        [ "${p##* }" = "$fam" ] || continue
        name=$(cfg_name "$f")
        [ -n "$except" ] && [ "$name" = "$except" ] && continue
        printf '%s' "$name"
        break
    done
    return 0
}

show_taken_tunnel_ports() {
    local except=${1:-} listing
    listing=$(
        cfg_files | while read -r f; do
            p=$(tunnel_port_of "$f") || continue
            name=$(cfg_name "$f")
            [ -n "$except" ] && [ "$name" = "$except" ] && continue
            printf '%s %s %s\n' "$name" "${p%% *}" "${p##* }"
        done
    )
    [ -n "$listing" ] || return 0
    warn "tunnel ports this server already uses"
    printf '%s\n' "$listing" | while read -r name port fam; do
        [ -n "$name" ] && dim "$(pad_to "$name" 22)${BX_ARR} ${port}/${fam}"
    done
    dim "tcp and udp are separate: 9443/udp does not block 9443/tcp"
    blank
    return 0
}

# --------------------------------------------------------------------------
# forwarded ports
# --------------------------------------------------------------------------

# ports_of NAME - the tokens a tunnel forwards, as typed: the manager's state
# on the IRAN side, the [forward] table in the file otherwise.
ports_of() {
    local name=$1 list
    list=$(forwards_of "$name" 2>/dev/null | tr '\n' ' ')
    [ -n "${list// /}" ] || list=$(toml_arr "$(cfg_file "$name")" forward ports)
    printf '%s' "$(printf '%s' "$list" | tr -s ' ' | sed 's/^ //; s/ $//')"
}

show_taken_ports() {
    local except=${1:-} n list any=0
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        [ "$n" = "$except" ] && continue
        list=$(ports_of "$n")
        [ -n "$list" ] || continue
        [ "$any" = 0 ] && warn "ports already forwarded on this server"
        any=1
        dim "$(pad_to "$n" 22)${BX_ARR} $list"
    done < <(cfg_list)
    [ "$any" = 1 ] && blank
    return 0
}

# --------------------------------------------------------------------------
# the two ports the manager picks by itself
# --------------------------------------------------------------------------

# The status endpoint has to be unique per tunnel, and asking the kernel
# whether a port is free only answers for the tunnels running right now - so
# the files are consulted too, or a second tunnel built while the first was
# stopped is handed the same port and the two fight over it at boot.
status_owner() {
    local want=$1 except=${2:-} f name
    case $want in '' | *[!0-9]*) return 0 ;; esac
    cfg_files | while read -r f; do
        [ "$(toml_get "$f" status port)" = "$want" ] || continue
        name=$(cfg_name "$f")
        [ -n "$except" ] && [ "$name" = "$except" ] && continue
        printf '%s' "$name"
        break
    done
    return 0
}

pick_status_port() {
    local except=${1:-} p=$STATUS_BASE n=0
    while [ "$n" -lt 100 ]; do
        if [ -z "$(status_owner "$p" "$except")" ] && port_free "$p" tcp; then
            printf '%s' "$p"
            return 0
        fi
        p=$((p + 1))
        n=$((n + 1))
    done
    return 1
}

show_taken_status() {
    local except=${1:-} listing
    listing=$(
        cfg_files | while read -r f; do
            p=$(toml_get "$f" status port)
            [ -n "$p" ] || continue
            name=$(cfg_name "$f")
            [ -n "$except" ] && [ "$name" = "$except" ] && continue
            printf '%s %s\n' "$name" "$p"
        done
    )
    [ -n "$listing" ] || return 0
    warn "status ports already used on this server"
    printf '%s\n' "$listing" | while read -r name p; do
        [ -n "$name" ] && dim "$(pad_to "$name" 22)${BX_ARR} 127.0.0.1:$p"
    done
    blank
    return 0
}

# The health port is bound to the tunnel's own private address, so only a
# listener on every address is in the way of it - and on Linux an IPv6
# wildcard holds the IPv4 one along with it.
health_bound() {
    local p=$1 a
    have ss || return 1
    while read -r a; do
        case $a in
        "0.0.0.0:$p" | "*:$p" | "[::]:$p" | ":::$p") return 0 ;;
        esac
    done < <(ss -ltnH 2>/dev/null | awk '{ print $4 }')
    return 1
}

free_health_port() {
    local p=$HEALTH_PORT n=0
    while health_bound "$p"; do
        p=$((p + 1))
        n=$((n + 1))
        [ "$n" -gt 20 ] && return 1
    done
    printf '%s' "$p"
}

# --------------------------------------------------------------------------
# the token an ICMP tunnel is told apart by
# --------------------------------------------------------------------------

# An ICMP tunnel has no port: what tells it apart from another one on the
# same server is an identifier taken from its token. Two sharing a token
# read each other's packets, both flap, and the log blames the token.
icmp_token_owner() {
    local want=$1 except=${2:-} f name
    [ -n "$want" ] || return 0
    cfg_files | while read -r f; do
        [ "$(toml_get "$f" transport type)" = icmp ] || continue
        [ "$(toml_get "$f" security token)" = "$want" ] || continue
        name=$(cfg_name "$f")
        [ -n "$except" ] && [ "$name" = "$except" ] && continue
        printf '%s' "$name"
        break
    done
    return 0
}

show_taken_icmp_token() {
    local owner
    owner=$(icmp_token_owner "$1" "${2:-}")
    [ -n "$owner" ] || return 0
    warn "the tunnel \"$owner\" already carries ICMP with this token"
    dim "Both would put the same identifier on every packet, so each would"
    dim "read the other's. Give this one a different token."
    return 1
}
