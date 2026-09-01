#!/usr/bin/env bash
#
# AmneziaWG: obfuscated WireGuard, from their packages rather than ours.
#
# This is the one transport Pingify does not implement. It is somebody else's
# careful cryptography with a deliberate junk-and-header layer on top of it,
# and the right thing to do with that is install it from the repository the
# people who wrote it publish - ppa:amnezia/ppa, the same one their own
# clients use - and drive it.
#
# What the tunnel does on top is unchanged. awg-quick brings up a private link
# between the two servers; the core then runs its ordinary UDP carrier inside
# that link, so the profile's queue depth, the socket buffers, the counters
# every screen reads, the status endpoint and the health port all work exactly
# as they do on every other transport. The obfuscation is theirs, the tuning
# is ours, and neither has to know about the other.
#
# The keys are the one thing that does not fit the shared-file design without
# help: WireGuard needs a private key on each side and the far side's public
# key, which is four values rather than one shared secret. Both keypairs are
# generated once, on the first server, and all four values travel in the file
# - so the second server still needs nothing but the paste, and each side
# picks out the half that is its own.

AWG_DIR=${PINGIFY_AWG_DIR:-/etc/amnezia/amneziawg}
AWG_PPA=${PINGIFY_AWG_PPA:-ppa:amnezia/ppa}

awg_ready() { have awg && have awg-quick; }

# awg_install adds their repository and installs from it.
#
# It is a network operation on a server that may not be able to reach a
# launchpad mirror, so the failure is reported as what it is rather than as a
# broken tunnel: the packages are missing, here is the command, and every
# other transport still works.
awg_install() {
    awg_ready && return 0
    blank
    dim "installing AmneziaWG from $AWG_PPA"
    if have add-apt-repository; then
        add-apt-repository -y "$AWG_PPA" >/dev/null 2>&1
    fi
    if have apt-get; then
        apt-get update >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            amneziawg amneziawg-tools >/dev/null 2>&1
    fi
    if awg_ready; then
        ok "AmneziaWG installed - $(awg --version 2>/dev/null | head -1)"
        return 0
    fi
    bad "AmneziaWG could not be installed on this server"
    fix "it needs $AWG_PPA, which a server in Iran often cannot reach"
    fix "install it from a server that can, or pick another transport"
    return 1
}

# --------------------------------------------------------------------------
# what the wizard generates
# --------------------------------------------------------------------------

# awg_rand is a number in a range, from the kernel's own random device.
awg_rand() {
    local lo=$1 hi=$2 n
    n=$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' \n')
    case $n in '' | *[!0-9]*) n=$((RANDOM * 32768 + RANDOM)) ;; esac
    printf '%s' $((lo + n % (hi - lo + 1)))
}

# awg_generate fills in the keys and the obfuscation for a new tunnel.
#
# The obfuscation numbers are what make an AmneziaWG packet not look like a
# WireGuard one: Jc junk packets of Jmin to Jmax bytes before the handshake,
# S1 and S2 bytes of junk inside the first two handshake packets, and H1 to H4
# in place of WireGuard's four fixed message types. They have to match on both
# servers, which they do, because they are generated once and travel in the
# file. The ranges are the ones Amnezia's own documentation gives.
awg_generate() {
    awg_ready || return 1
    T_AWG_IKEY=$(awg genkey)
    T_AWG_IPUB=$(printf '%s' "$T_AWG_IKEY" | awg pubkey)
    T_AWG_KKEY=$(awg genkey)
    T_AWG_KPUB=$(printf '%s' "$T_AWG_KKEY" | awg pubkey)
    [ -n "$T_AWG_IPUB" ] && [ -n "$T_AWG_KPUB" ] || return 1

    # Not generated. These five are the set that has been run on this path and
    # found stable - no periodic drops - and randomising them was how this
    # transport came to hand shake and then carry nothing. The documentation
    # gives ranges; the ranges contain combinations that do not work, and
    # finding out which is not something to do on somebody's live tunnel.
    #
    # S1 + 56 must not equal S2, and 68 and 91 do not.
    T_AWG_JC=5
    T_AWG_JMIN=50
    T_AWG_JMAX=1000
    T_AWG_S1=68
    T_AWG_S2=91

    # Four distinct header types, none of them the four WireGuard uses.
    local i h
    T_AWG_H1= T_AWG_H2= T_AWG_H3= T_AWG_H4=
    for i in 1 2 3 4; do
        while :; do
            h=$(awg_rand 5 2147483000)
            list_has "$h" "$T_AWG_H1" "$T_AWG_H2" "$T_AWG_H3" "$T_AWG_H4" || break
        done
        eval "T_AWG_H$i=\$h"
    done
    return 0
}

# --------------------------------------------------------------------------
# the link itself
# --------------------------------------------------------------------------

awg_iface() { toml_get "$(cfg_file "$1")" awg name; }

# awg_conf writes this server's half of the link.
#
# The file is built from the shared config every time rather than kept, so a
# change to the tunnel is a change to the interface without anybody having to
# remember there are two of them. 0600, because the private key is in it.
awg_conf() {
    local name=$1 f side iface mine peer_pub my_key peer_addr port endpoint
    f=$(cfg_file "$name")
    side=$(toml_get "$f" tunnel side)
    iface=$(toml_get "$f" awg name)
    [ -n "$iface" ] || return 1

    if [ "$side" = iran ]; then
        mine=$(toml_get "$f" awg iran)
        my_key=$(toml_get "$f" awg iran_key)
        peer_pub=$(toml_get "$f" awg kharej_pub)
        peer_addr=$(toml_get "$f" awg kharej)
    else
        mine=$(toml_get "$f" awg kharej)
        my_key=$(toml_get "$f" awg kharej_key)
        peer_pub=$(toml_get "$f" awg iran_pub)
        peer_addr=$(toml_get "$f" awg iran)
    fi
    port=$(toml_get "$f" awg port)

    # Both ends get an Endpoint and both get a ListenPort.
    #
    # WireGuard only needs one of them to know where the other is - the far
    # end learns the address from the first handshake that arrives. Setting
    # both anyway is what a working AmneziaWG deployment on this path does,
    # and the reason is the path: a side that has to learn the address has
    # nothing to send to until something arrives, and on a link where the
    # first packets are the ones most likely to be dropped that is a tunnel
    # that comes up only sometimes.
    if [ "$side" = iran ]; then
        endpoint="Endpoint = $(toml_get "$f" transport kharej):$port"
    else
        endpoint="Endpoint = $(toml_get "$f" transport iran):$port"
    fi

    mkdir -p "$AWG_DIR"
    umask 077
    cat >"$AWG_DIR/$iface.conf" <<CONF
# Written by Pingify for the tunnel $name. Edited here, it is overwritten on
# the next change: the tunnel's own file in $CFG_DIR is where it comes from.
[Interface]
PrivateKey = $my_key
Address = $mine
MTU = $(toml_get "$f" awg mtu)
ListenPort = $port
Jc = $(toml_get "$f" awg jc)
Jmin = $(toml_get "$f" awg jmin)
Jmax = $(toml_get "$f" awg jmax)
S1 = $(toml_get "$f" awg s1)
S2 = $(toml_get "$f" awg s2)
H1 = $(toml_get "$f" awg h1)
H2 = $(toml_get "$f" awg h2)
H3 = $(toml_get "$f" awg h3)
H4 = $(toml_get "$f" awg h4)

[Peer]
PublicKey = $peer_pub
AllowedIPs = ${peer_addr%.*}.0/24
$endpoint
PersistentKeepalive = 25
CONF
    chmod 0600 "$AWG_DIR/$iface.conf"
}

# awg_up writes the interface's config and starts it, and is safe to call
# again: awg-quick refuses a device that already exists, so the old one goes
# first. That is also what makes a settings change take effect.
awg_up() {
    local name=$1 iface
    iface=$(awg_iface "$name")
    [ -n "$iface" ] || return 0
    awg_conf "$name" || return 1
    systemctl disable --now "awg-quick@$iface" >/dev/null 2>&1
    ip link del "$iface" >/dev/null 2>&1
    if ! systemctl enable --now "awg-quick@$iface" >/dev/null 2>&1; then
        bad "the AmneziaWG link $iface would not come up"
        fix "journalctl -u awg-quick@$iface -n 20"
        return 1
    fi
    return 0
}

awg_down() {
    local name=$1 iface
    iface=$(awg_iface "$name")
    [ -n "$iface" ] || return 0
    systemctl disable --now "awg-quick@$iface" >/dev/null 2>&1
    ip link del "$iface" >/dev/null 2>&1
    rm -f "$AWG_DIR/$iface.conf"
    return 0
}

# awg_free_iface is the first awgN nothing on this host is using. The tunnel's
# own device is pfyN and this one is beside it, so a server with three tunnels
# has three of each and no two of them meet.
awg_free_iface() {
    local i=0
    while [ "$i" -lt 64 ]; do
        if ! ip link show "awg$i" >/dev/null 2>&1 &&
            [ ! -e "$AWG_DIR/awg$i.conf" ]; then
            printf 'awg%s' "$i"
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

# awg_handshake is how long ago the far end was last heard from, in seconds,
# or nothing when there has been no handshake at all. It is the one number
# that says whether the link underneath a tunnel is alive.
awg_handshake() {
    local iface=$1 t now
    have awg || return 1
    t=$(awg show "$iface" latest-handshakes 2>/dev/null | awk 'NR == 1 { print $2 }')
    case $t in '' | 0 | *[!0-9]*) return 1 ;; esac
    now=$(date +%s)
    printf '%s' $((now - t))
}
