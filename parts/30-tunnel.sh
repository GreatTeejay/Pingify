#!/usr/bin/env bash
#
# The wizard: the questions on the first server, one paste on the second.
#
# The config file is the same on both servers but for the side and the name
# that carries it, so the second server does not answer questions at all: it
# takes a short setup token the first one printed, flips the side, checks
# that nothing on it is in the way, and writes the file.
#
# Every question is its own function reading into a T_* variable, so a test
# can drive the real wizard through its stdin. The steps run down one page
# and nothing is cleared between them, so the answers already given stay on
# screen above the question being asked.

# ---------------------------------------------------------------------------
# what a tunnel is made of
# ---------------------------------------------------------------------------

cfg_reset() {
    T_NAME= T_SIDE= T_TRANSPORT=tcp T_MODE=forward T_KIND=tcp
    # Which end opens the connection. IRAN dials out by default, because on a
    # real Iranian line that is the one that survives: a connection dialled
    # INTO Iran is commonly allowed to complete, carry a few exchanges, and
    # then be blackholed with no reset and no error - measured, repeatedly,
    # on this tool's own test pair. Ports still live on IRAN either way.
    T_DIALS=iran
    T_PUBLIC_IP= T_PEER_IP= T_IRAN= T_KHAREJ=
    T_PORT=8443 T_PATH= T_CONNS=8
    T_TOKEN= T_PRESET=balanced T_LOG=info
    T_STATUS= T_HEALTH=
    T_FORWARDS=
    T_OCTET= T_TUNIF= T_TUNLOCAL= T_TUNPEER= T_TUNMTU=1320
    T_FEC= T_QUEUE=
    T_AWG_PORT=51820 T_AWG_IFACE= T_AWG_IKEY= T_AWG_IPUB= T_AWG_KKEY= T_AWG_KPUB=
    T_AWG_JC= T_AWG_JMIN= T_AWG_JMAX= T_AWG_S1= T_AWG_S2=
    T_AWG_H1= T_AWG_H2= T_AWG_H3= T_AWG_H4=
}

# mode_of is the kind a transport makes: streams forward ports, packets need
# a private link. The core refuses the other pairing.
mode_of() {
    case $1 in
    tcp | ws | wss | utls | fallback) printf 'forward' ;;
    *) printf 'tun' ;;
    esac
}
cfg_mode() {
    T_MODE=$(mode_of "$T_TRANSPORT")
    [ "$T_MODE" = tun ] && T_KIND=tun || T_KIND=tcp
}
cfg_needs_link() { [ "$(mode_of "${1:-$T_TRANSPORT}")" = tun ]; }

side_label() {
    case $1 in
    iran | server) printf 'IRAN' ;;
    kharej | client) printf 'KHAREJ' ;;
    *) printf '%s' "${1^^}" ;;
    esac
}
other_side() { [ "$1" = iran ] && printf 'kharej' || printf 'iran'; }

transport_label() {
    case $1 in
    tcp) printf 'TCP MUX' ;;
    ws) printf 'WS MUX' ;;
    wss) printf 'WSS MUX' ;;
    utls) printf 'TCP UTLS' ;;
    fallback) printf 'TLS FALLBACK' ;;
    icmp) printf 'ICMP' ;;
    gre) printf 'GRE' ;;
    udp) printf 'UDP' ;;
    rawtcp) printf 'Raw TCP' ;;
    awg) printf 'AmneziaWG' ;;
    *) printf '%s' "${1^^}" ;;
    esac
}

# kind_label wears the [TUN] tag on the transports that build a link.
kind_label() {
    if cfg_needs_link "$1"; then printf 'TUN %s' "$(transport_label "$1")"
    else transport_label "$1"; fi
}

# The side that waits for the connection. A bound port only matters there.
waits_side() { other_side "${T_DIALS:-iran}"; }
this_side_waits() { [ "$T_SIDE" = "$(waits_side)" ]; }

# The name a tunnel is given, which is also the name of its file. It starts
# with the side, so `ls /root/pingify` says which end of the border each
# file is; then the transport, then the one number that tells two of the
# same kind apart - the port, or for ICMP and GRE, which have none, the
# private link's octet. iran-tcp-8443, iran-udp-8446, kharej-icmp-20.
tunnel_default_name() {
    local side=${1:-$T_SIDE} trans=${2:-$T_TRANSPORT} num
    case $trans in
    awg) num=$T_AWG_PORT ;;
    icmp | gre) num=$T_OCTET ;;
    *) num=$T_PORT ;;
    esac
    printf '%s-%s-%s' "$side" "$trans" "${num:-1}"
}

# The same tunnel's name on the other server: the first word is the side.
name_for_side() {
    local name=$1 side=$2
    case $name in
    iran-* | kharej-*) printf '%s-%s' "$side" "${name#*-}" ;;
    *) printf '%s' "$name" ;;
    esac
}

unique_name() {
    local base=$1 n=$1 i=2
    while [ -e "$(cfg_file "$n")" ]; do
        n="$base-$i"
        i=$((i + 1))
        [ "$i" -gt 50 ] && break
    done
    printf '%s' "$n"
}

# ---------------------------------------------------------------------------
# the security token
#
# Generated rather than asked for: eighteen random bytes are twenty-four
# base64 characters, which removes a question and the whole class of bug
# where one server has the token with a trailing space and the other does
# not. Both servers print the same fingerprint when the token matches, which
# is the only way to tell a wrong token apart from a broken network.
# ---------------------------------------------------------------------------

wiz_sha256() {
    if have sha256sum; then sha256sum | cut -d' ' -f1
    elif have shasum; then shasum -a 256 | cut -d' ' -f1
    elif have openssl; then openssl dgst -sha256 | sed 's/.*= *//'
    else return 1
    fi
}

wiz_token() {
    local t
    t=$(head -c 18 /dev/urandom 2>/dev/null | base64 2>/dev/null) || t=
    t=${t//$'\n'/}
    [ "${#t}" -ge 16 ] || return 1
    printf '%s' "$t"
}

token_print() {
    local t h
    t=$(printf '%s' "${1:-}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -n "$t" ] || { printf 'none'; return; }
    h=$(printf '%s' "$t" | wiz_sha256) || { printf 'unknown'; return; }
    printf '%s' "${h:0:8}"
}
wiz_fingerprint() { token_print "$1"; }

# ---------------------------------------------------------------------------
# performance presets
#
# Everything the tunnel tunes was measured to have one right answer whatever
# it carries - the socket buffers, the batching, a pacing rate it works out
# for itself. What trades is how deep the queues may get: a deep one absorbs
# bursts and carries more; a shallow one is emptier when a small packet
# arrives, so that packet waits less. Measured on the real path, Tehran to
# Frankfurt, restarted fresh at each depth:
#
#   profile     queue    16 streams   one stream   under load
#   gaming        600     397 Mbit/s   167 Mbit/s   84.5 / 92.5 ms
#   balanced      900     448          254          93.3 / 106.5
#   download     1500     466          253         115.8 / 139.3
# ---------------------------------------------------------------------------

preset_rcvbuf() {
    case $1 in
    download) printf '3072' ;;
    *) printf '256' ;;
    esac
}

preset_queue() {
    case $1 in
    gaming) printf '600' ;;
    download) printf '1500' ;;
    *) printf '900' ;;
    esac
}

preset_menu() {
    CHOICE_DEF=2
    choice 1 "Gaming" "shallow queues - lowest delay under load"
    choice 2 "Balanced" "the one to pick if unsure"
    choice 3 "Download" "deep queues - most throughput for many streams"
    CHOICE_DEF=
    blank
    dim "Deeper queues carry more; shallower ones answer faster. Changeable later."
    blank
    local n
    pick n "select" 2 3 || return 1
    case $n in
    1) T_PRESET=gaming ;;
    3) T_PRESET=download ;;
    *) T_PRESET=balanced ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# reading a tunnel back
# ---------------------------------------------------------------------------

cfg_load() {
    local f
    f=$(cfg_file "$1")
    [ -f "$f" ] || return 1
    cfg_reset
    T_NAME=$(toml_get "$f" tunnel name)
    [ -n "$T_NAME" ] || T_NAME=$1
    T_SIDE=$(toml_get "$f" tunnel side)
    T_TRANSPORT=$(toml_get "$f" transport type)
    [ -n "$T_TRANSPORT" ] || T_TRANSPORT=udp
    T_MODE=$(toml_get "$f" tunnel mode)
    [ -n "$T_MODE" ] || T_MODE=$(mode_of "$T_TRANSPORT")
    [ "$T_MODE" = tun ] && T_KIND=tun || T_KIND=tcp
    T_DIALS=$(toml_get "$f" transport dials)
    [ -n "$T_DIALS" ] || T_DIALS=kharej
    T_IRAN=$(toml_get "$f" transport iran)
    T_KHAREJ=$(toml_get "$f" transport kharej)
    if [ "$T_SIDE" = iran ]; then T_PUBLIC_IP=$T_IRAN T_PEER_IP=$T_KHAREJ
    else T_PUBLIC_IP=$T_KHAREJ T_PEER_IP=$T_IRAN; fi
    T_PORT=$(toml_get "$f" transport port)
    T_PATH=$(toml_get "$f" transport path)
    T_CONNS=$(toml_get "$f" transport connections)
    [ -n "$T_CONNS" ] || T_CONNS=8
    T_TOKEN=$(toml_get "$f" security token)
    T_PRESET=$(toml_get "$f" tuning profile)
    [ -n "$T_PRESET" ] || T_PRESET=balanced
    T_FEC=$(toml_get "$f" tuning fec)
    T_QUEUE=$(toml_get "$f" tuning queue_packets)
    T_LOG=$(toml_get "$f" logging level)
    [ -n "$T_LOG" ] || T_LOG=info
    T_STATUS=$(toml_get "$f" status port)
    T_HEALTH=$(toml_get "$f" status health_port)
    T_FORWARDS=$(ports_of "$1")
    if [ "$T_MODE" = tun ]; then
        T_TUNIF=$(toml_get "$f" tun name)
        [ -n "$T_TUNIF" ] || T_TUNIF=pfy0
        local a b
        a=$(toml_get "$f" tun iran)
        b=$(toml_get "$f" tun kharej)
        if [ "$T_SIDE" = iran ]; then T_TUNLOCAL=$a T_TUNPEER=$b; else T_TUNLOCAL=$b T_TUNPEER=$a; fi
        T_OCTET=${a#10.}
        T_OCTET=${T_OCTET%%.*}
        T_TUNMTU=$(toml_get "$f" tun mtu)
        [ -n "$T_TUNMTU" ] || T_TUNMTU=1320
    fi
    if [ "$T_TRANSPORT" = awg ]; then
        T_AWG_IFACE=$(toml_get "$f" awg name)
        T_AWG_PORT=$(toml_get "$f" awg port)
        T_AWG_IKEY=$(toml_get "$f" awg iran_key)
        T_AWG_IPUB=$(toml_get "$f" awg iran_pub)
        T_AWG_KKEY=$(toml_get "$f" awg kharej_key)
        T_AWG_KPUB=$(toml_get "$f" awg kharej_pub)
        T_AWG_JC=$(toml_get "$f" awg jc)
        T_AWG_JMIN=$(toml_get "$f" awg jmin)
        T_AWG_JMAX=$(toml_get "$f" awg jmax)
        T_AWG_S1=$(toml_get "$f" awg s1)
        T_AWG_S2=$(toml_get "$f" awg s2)
        T_AWG_H1=$(toml_get "$f" awg h1)
        T_AWG_H2=$(toml_get "$f" awg h2)
        T_AWG_H3=$(toml_get "$f" awg h3)
        T_AWG_H4=$(toml_get "$f" awg h4)
    fi
    return 0
}

# ---------------------------------------------------------------------------
# the file
#
# Every setting the core reads, written out with its value, in two columns
# and nothing else - what a person expects to find when they open it, and
# what the Tuning screen edits in place. The values a preset chooses are in
# the file as numbers, so what the tunnel runs with is what the file says.
# ---------------------------------------------------------------------------

fwd_toml_list() {
    local first=1 t
    for t in "$@"; do
        [ "$first" = 1 ] || printf ', '
        printf '"%s"' "$t"
        first=0
    done
}

cfg_render() {
    local mode=${T_MODE:-$(mode_of "$T_TRANSPORT")}
    kv() { printf '%-16s = %s\n' "$1" "$2"; }
    q() { printf '"%s"' "$1"; }

    printf '[tunnel]\n'
    kv name "$(q "$T_NAME")"
    kv side "$(q "$T_SIDE")"
    kv mode "$(q "$mode")"

    printf '\n[transport]\n'
    kv type "$(q "$T_TRANSPORT")"
    kv kharej "$(q "$T_KHAREJ")"
    kv iran "$(q "$T_IRAN")"
    case $T_TRANSPORT in
    icmp | gre) ;;
    *) kv port "$T_PORT" ;;
    esac
    kv dials "$(q "$T_DIALS")"
    case $T_TRANSPORT in
    tcp | ws | wss | utls | fallback) kv connections "${T_CONNS:-8}" ;;
    esac
    kv keepalive_sec 10
    case $T_TRANSPORT in
    ws | wss) kv path "$(q "$T_PATH")" ;;
    esac
    case $T_TRANSPORT in
    wss | utls | fallback)
        kv cert '""'
        kv key '""'
        kv insecure false
        ;;
    esac

    if [ "$T_TRANSPORT" = awg ]; then
        printf '\n[awg]\n'
        kv name "$(q "$T_AWG_IFACE")"
        kv iran "$(q "10.$T_OCTET.20.1/24")"
        kv kharej "$(q "10.$T_OCTET.20.2/24")"
        kv mtu 1320
        kv port "$T_AWG_PORT"
        kv iran_key "$(q "$T_AWG_IKEY")"
        kv iran_pub "$(q "$T_AWG_IPUB")"
        kv kharej_key "$(q "$T_AWG_KKEY")"
        kv kharej_pub "$(q "$T_AWG_KPUB")"
        kv jc "$T_AWG_JC"
        kv jmin "$T_AWG_JMIN"
        kv jmax "$T_AWG_JMAX"
        kv s1 "$T_AWG_S1"
        kv s2 "$T_AWG_S2"
        kv h1 "$T_AWG_H1"
        kv h2 "$T_AWG_H2"
        kv h3 "$T_AWG_H3"
        kv h4 "$T_AWG_H4"
    fi

    printf '\n[security]\n'
    kv token "$(q "$T_TOKEN")"

    printf '\n[tuning]\n'
    kv profile "$(q "$T_PRESET")"
    kv queue_packets "${T_QUEUE:-$(preset_queue "$T_PRESET")}"
    kv rcvbuf_kb "$(preset_rcvbuf "$T_PRESET")"
    kv sndbuf_kb 16384
    if [ "$mode" = tun ]; then
        kv send_batch 32
        kv pace true
        kv pace_mbit 0
    fi
    kv dscp 0
    if [ "$mode" = tun ] && [ "$T_TRANSPORT" != gre ]; then
        kv fec "${T_FEC:-0}"
    fi

    printf '\n[forward]\n'
    # shellcheck disable=SC2086
    kv ports "[$(fwd_toml_list $T_FORWARDS)]"
    if [ "$mode" = forward ]; then
        kv bind_addr '"0.0.0.0"'
        kv allow "[]"
    fi

    if [ "$mode" = tun ]; then
        printf '\n[tun]\n'
        kv name "$(q "$T_TUNIF")"
        kv iran "$(q "10.$T_OCTET.10.1/24")"
        kv kharej "$(q "10.$T_OCTET.10.2/24")"
        kv mtu "${T_TUNMTU:-1320}"
        kv txqueuelen 1000
        kv write_workers 0
        kv queues 1
    fi

    printf '\n[logging]\n'
    kv level "$(q "${T_LOG:-info}")"

    printf '\n[status]\n'
    kv port "${T_STATUS:-$STATUS_BASE}"
    if [ "$mode" = forward ]; then
        kv health_port -1
    else
        kv health_port "${T_HEALTH:-$HEALTH_PORT}"
    fi
}

# ---------------------------------------------------------------------------
# writing it, and saying honestly what happened
# ---------------------------------------------------------------------------

# tunnel_create NAME FILE - FILE is the finished config. It is checked by
# the core before anything is started, and nothing is left behind when the
# core refuses it.
tunnel_create() {
    local name=$1 src=$2 f out
    [ -n "$name" ] || { fail "a tunnel needs a name"; return 1; }
    ensure_dirs || { fail "could not create $CFG_DIR"; return 1; }
    f=$(cfg_file "$name")
    [ -e "$f" ] && { fail "there is already a tunnel called $name here"; return 1; }
    if [ ! -x "$CORE_BIN" ]; then
        fail "the core is not installed at $CORE_BIN"
        fix "install Pingify first - nothing has been changed"
        return 1
    fi
    # The file is 0600 before a single byte of the token exists in it.
    : >"$f" || { fail "could not write $f"; return 1; }
    chmod 0600 "$f"
    cat "$src" >"$f" || { fail "could not write $f"; rm -f "$f"; return 1; }

    if ! out=$("$CORE_BIN" -c "$f" -check 2>&1); then
        fail "the core rejected this configuration - nothing created"
        core_matches_script || dim "the core is $(core_version) and this script is $PINGIFY_VERSION - update the core"
        printf '%s\n' "$out" | sed 's/^/       /'
        rm -f "$f"
        return 1
    fi
    ok "$(trunc_to "$f" $((UI_W - 30))) accepted by the core"

    # A [TUN] tunnel's ports live in its file so that they travel in the
    # token, and in the forwards state on IRAN so that the firewall has them.
    if [ "$(toml_get "$f" tunnel mode)" = tun ] && [ "$(toml_get "$f" tunnel side)" = iran ] &&
        [ ! -s "$(fwd_file "$name")" ]; then
        local ports
        ports=$(toml_arr "$f" forward ports)
        if [ -n "$ports" ]; then
            if ! forwards_set "$name" "$ports"; then
                warn "the ports in the file could not be kept; set them on the Ports screen"
            elif have iptables; then
                nat_apply "$name" || warn "the ports are kept but not yet in the firewall; set them again on the Ports screen"
            fi
        fi
    fi

    [ -f "$UNIT_DIR/pingify@.service" ] || unit_write

    case $(toml_get "$f" transport type) in
    awg)
        # The AmneziaWG link is the wire this tunnel runs on, so it comes up
        # first. If it will not, the tunnel is not started.
        if ! awg_up "$name"; then
            rm -f "$f"
            return 1
        fi
        ok "the AmneziaWG link $(awg_iface "$name") is up"
        ;;
    rawtcp)
        # Without this the kernel answers our own segments with an RST and
        # the tunnel resets itself every few seconds.
        if ! rawtcp_guard "$(toml_get "$f" transport port)"; then
            fail "could not tell the firewall to stop answering for this port"
            fix "iptables is needed for a raw tcp tunnel"
            rm -f "$f"
            return 1
        fi
        ok "the kernel will not answer on tcp/$(toml_get "$f" transport port)"
        ;;
    esac

    svc_do enable "$name"
}

# ---------------------------------------------------------------------------
# the setup token
#
# Short, so it survives a paste over a phone: the fields of the tunnel joined
# with pipes, text fields wrapped in base64 so a pipe or a space inside one
# cannot split it, a checksum on the end, and the whole thing base64 again
# with PFY3. in front so a paste can be told apart from anything else.
# ---------------------------------------------------------------------------

tok_enc() { printf '%s' "$1" | base64 | tr -d '\n'; }
tok_dec() { printf '%s' "$1" | base64 -d 2>/dev/null; }
setup_token_bad() { SETUP_TOKEN_ERROR=$1; return 1; }

cfg_setup_token() {
    local body sum
    body=$(printf 'p6|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' \
        "$T_NAME" "$T_TRANSPORT" "$T_MODE" "$T_DIALS" \
        "$(tok_enc "$T_KHAREJ")" "$(tok_enc "$T_IRAN")" "$T_PORT" "$(tok_enc "$T_PATH")" "$T_CONNS" \
        "$(tok_enc "$T_TOKEN")" "$T_PRESET" "$T_LOG" "$T_HEALTH" \
        "$T_OCTET" "$T_TUNIF" "$T_TUNMTU" "$(tok_enc "$T_FORWARDS")" \
        "$T_AWG_IFACE" "$T_AWG_PORT" "$(tok_enc "$T_AWG_IKEY")" "$(tok_enc "$T_AWG_IPUB")" \
        "$(tok_enc "$T_AWG_KKEY")" "$(tok_enc "$T_AWG_KPUB")" \
        "$T_AWG_JC" "$T_AWG_JMIN" "$T_AWG_JMAX" "$T_AWG_S1" "$T_AWG_S2" \
        "$T_AWG_H1" "$T_AWG_H2" "$T_AWG_H3" "$T_AWG_H4" \
        "$T_FEC" "$T_QUEUE" "$PINGIFY_VERSION")
    sum=$(printf '%s' "$body" | wiz_sha256) || return 1
    printf 'PFY3.%s' "$(printf '%s|%s' "$body" "${sum:0:16}" | base64 | tr -d '\n')"
}

# setup_token_read TOKEN - fills the T_* variables from a token printed by
# the other server, and flips the side to this one. The name follows.
setup_token_read() {
    local line raw body sum want fields
    local v name tr mode dials kh ir port path conns tok preset lg health
    local oct tunif mtu fwd aif aport ikey ipub kkey kpub jc jmin jmax s1 s2 h1 h2 h3 h4 fec queue ver
    SETUP_TOKEN_ERROR=
    line=${1//[[:space:]]/}
    case $line in
    PFY3.*) ;;
    PFY2.*) setup_token_read_file "$line"; return $? ;;
    *) setup_token_bad "that is not a Pingify setup token - it starts with PFY3."; return 1 ;;
    esac
    raw=$(tok_dec "${line#PFY3.}") || { setup_token_bad "the token will not decode - copy the whole line"; return 1; }
    case $raw in p6\|*) ;; *) setup_token_bad "the token will not decode - copy the whole line"; return 1 ;; esac
    body=${raw%|*}
    sum=${raw##*|}
    want=$(printf '%s' "$body" | wiz_sha256) || { setup_token_bad "no sha256 tool here, so the token cannot be checked"; return 1; }
    [ "${want:0:16}" = "$sum" ] || { setup_token_bad "the token checksum does not match - copy the whole line"; return 1; }
    fields=$(printf '%s' "$body" | awk -F'|' '{ print NF }')
    [ "$fields" = 36 ] || { setup_token_bad "the token is incomplete"; return 1; }
    IFS='|' read -r v name tr mode dials kh ir port path conns tok preset lg health \
        oct tunif mtu fwd aif aport ikey ipub kkey kpub jc jmin jmax s1 s2 h1 h2 h3 h4 fec queue ver <<<"$body"

    cfg_reset
    T_NAME=$name T_TRANSPORT=$tr T_MODE=$mode T_DIALS=$dials
    T_KHAREJ=$(tok_dec "$kh") || { setup_token_bad "the address field is damaged"; return 1; }
    T_IRAN=$(tok_dec "$ir") || { setup_token_bad "the address field is damaged"; return 1; }
    T_PORT=$port
    T_PATH=$(tok_dec "$path") || T_PATH=
    T_CONNS=${conns:-8}
    T_TOKEN=$(tok_dec "$tok") || { setup_token_bad "the security field is damaged"; return 1; }
    T_PRESET=${preset:-balanced} T_LOG=${lg:-info} T_HEALTH=$health
    T_OCTET=$oct T_TUNIF=$tunif T_TUNMTU=${mtu:-1320}
    T_FORWARDS=$(tok_dec "$fwd") || T_FORWARDS=
    T_AWG_IFACE=$aif T_AWG_PORT=${aport:-51820}
    T_AWG_IKEY=$(tok_dec "$ikey") T_AWG_IPUB=$(tok_dec "$ipub")
    T_AWG_KKEY=$(tok_dec "$kkey") T_AWG_KPUB=$(tok_dec "$kpub")
    T_AWG_JC=$jc T_AWG_JMIN=$jmin T_AWG_JMAX=$jmax T_AWG_S1=$s1 T_AWG_S2=$s2
    T_AWG_H1=$h1 T_AWG_H2=$h2 T_AWG_H3=$h3 T_AWG_H4=$h4
    T_FEC=$fec T_QUEUE=$queue
    TOKEN_VERSION=$ver
    setup_token_check
}

# A token made by a 2.2.0 manager carries the whole file. It is read the
# same way, from a temporary copy, so a pair started on the old manager can
# still be finished on this one.
setup_token_read_file() {
    local line=$1 raw sum body have tmp
    raw=$(tok_dec "${line#PFY2.}") || { setup_token_bad "the token will not decode - copy the whole line"; return 1; }
    sum=${raw%%|*}
    body=${raw#*|}
    [ "$sum" != "$raw" ] || { setup_token_bad "the token will not decode - copy the whole line"; return 1; }
    have=$(printf '%s\n' "$body" | wiz_sha256) || { setup_token_bad "no sha256 tool here"; return 1; }
    [ "$have" = "$sum" ] || { setup_token_bad "the token checksum does not match - copy the whole line"; return 1; }
    local dir keep=$CFG_DIR rc
    dir=$(mktemp -d) || return 1
    tmp=$dir/pasted.toml
    printf '%s
' "$body" >"$tmp"
    CFG_DIR=$dir
    cfg_load pasted
    rc=$?
    CFG_DIR=$keep
    T_NAME=$(toml_get "$tmp" tunnel name)
    T_FORWARDS=$(toml_arr "$tmp" forward ports)
    rm -rf "$dir"
    [ "$rc" = 0 ] || { setup_token_bad "the token did not carry a readable config"; return 1; }
    TOKEN_VERSION=$(sed -n 's/^# Pingify \([0-9.]*\).*/\1/p' <<<"$body" | head -1)
    setup_token_check
}

# setup_token_check refuses a token that describes a tunnel this manager
# cannot build, before a single question is asked about it.
setup_token_check() {
    case $T_TRANSPORT in
    tcp | ws | wss | utls | fallback | icmp | gre | udp | rawtcp | awg) ;;
    *) setup_token_bad "unknown transport $T_TRANSPORT"; return 1 ;;
    esac
    [ "$T_MODE" = "$(mode_of "$T_TRANSPORT")" ] || { setup_token_bad "transport and mode disagree"; return 1; }
    [ "$T_MODE" = tun ] && T_KIND=tun || T_KIND=tcp
    case $T_DIALS in iran | kharej) ;; *) setup_token_bad "the token does not say which end dials"; return 1 ;; esac
    case $T_SIDE in iran | kharej) ;; *) T_SIDE= ;; esac
    [ -n "$T_TOKEN" ] || { setup_token_bad "the security token is empty"; return 1; }
    [ -n "$T_IRAN" ] && [ -n "$T_KHAREJ" ] || { setup_token_bad "an address is missing"; return 1; }
    case $T_TRANSPORT in
    icmp | gre) T_PORT= ;;
    *)
        case $T_PORT in '' | *[!0-9]*) setup_token_bad "the tunnel port is invalid"; return 1 ;; esac
        [ "$T_PORT" -ge 1 ] && [ "$T_PORT" -le 65535 ] || { setup_token_bad "the tunnel port is out of range"; return 1; }
        ;;
    esac
    if [ "$T_MODE" = tun ]; then
        v_octet "$T_OCTET" >/dev/null 2>&1 || { setup_token_bad "the private link is incomplete"; return 1; }
        [ -n "$T_TUNIF" ] || T_TUNIF=pfy0
        v_mtu "$T_TUNMTU" >/dev/null 2>&1 || { setup_token_bad "the private MTU is out of range"; return 1; }
    fi
    if [ "$T_TRANSPORT" = awg ]; then
        [ -n "$T_AWG_IKEY" ] && [ -n "$T_AWG_KKEY" ] && [ -n "$T_AWG_IPUB" ] && [ -n "$T_AWG_KPUB" ] ||
            { setup_token_bad "the AmneziaWG key material is incomplete"; return 1; }
        v_port "$T_AWG_PORT" >/dev/null 2>&1 || { setup_token_bad "the AmneziaWG port is invalid"; return 1; }
    fi
    case $T_PRESET in gaming | balanced | download) ;; *) T_PRESET=balanced ;; esac
    case $T_LOG in debug | info | warn | error) ;; *) T_LOG=info ;; esac
    return 0
}

# ---------------------------------------------------------------------------
# what is said about a transport before it is chosen
# ---------------------------------------------------------------------------

# The public addresses of this server, one to a line. The private ranges are
# struck out, carrier grade NAT included: an address in 100.64/10 is one the
# provider handed out behind a shared public one.
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

# is_name says "this is a domain and not an address".
is_name() { case $1 in *[a-zA-Z]*) return 0 ;; *) return 1 ;; esac; }

# A path nobody scans for: six hex characters.
wiz_path() {
    local h
    h=$(head -c 3 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')
    [ -n "$h" ] || h=$(printf '%06x' $((RANDOM * RANDOM % 16777216)))
    printf '/%s' "$h"
}

# Cloudflare proxies only a handful of ports; a WebSocket on any other one
# is not behind the CDN at all.
cdn_ports() { printf '80 8080 8880 2052 2082 2086 2095 443 2053 2083 2087 2096 8443'; }
cdn_port_warn() {
    case $T_TRANSPORT in ws | wss) ;; *) return 0 ;; esac
    local p ok=0
    for p in $(cdn_ports); do [ "$p" = "$T_PORT" ] && ok=1; done
    [ "$ok" = 1 ] && return 0
    blank
    warn "Cloudflare does not proxy port $T_PORT"
    dim "behind the CDN, use one of: $(cdn_ports)"
    dim "direct, without a CDN, any port works"
}

# ---------------------------------------------------------------------------
# the questions
# ---------------------------------------------------------------------------

ask_side() {
    wiz "Which server is this?"
    choice 1 "IRAN" "clients connect here, and the ports live here"
    choice 2 "KHAREJ" "your panel and inbounds run here"
    choice 3 "Paste a token" "finish this server from the other one"
    blank
    dim "q at any question leaves without building anything"
    blank
    local side
    pick side "select" "" 3 || return 1
    case $side in
    1) T_SIDE=iran ;;
    2) T_SIDE=kharej ;;
    3) T_SIDE=paste ;;
    esac
    return 0
}

ask_transport() {
    wiz "Transport"
    group "FORWARDING - your ports, carried over a connection"
    choice 1 "TCP MUX" "plain TCP, several connections multiplexed"
    choice 2 "WS MUX" "WebSocket on port 80 - a CDN can front it"
    choice 3 "WSS MUX" "WebSocket inside TLS - a domain or Cloudflare"
    choice 4 "TCP UTLS" "TLS that looks like Chrome on the wire"
    choice 5 "TLS FALLBACK" "UTLS, and a real website for anyone probing"
    group "TUN - a private link between the two servers"
    choice 6 "ICMP" "inside ping packets - no port at all"
    choice 7 "GRE" "IP protocol 47 - fast, not hidden, no port"
    choice 8 "UDP" "plain UDP on one port"
    choice 9 "Raw TCP" "TCP-shaped packets, no connection to throttle"
    choice 10 "AmneziaWG" "obfuscated WireGuard - encrypted"
    blank
    local proto
    pick proto "select" "" 10 || return 1
    case $proto in
    1) T_TRANSPORT=tcp ;;
    2) T_TRANSPORT=ws
        blank
        warn "WS is not encrypted by itself - choose WSS when TLS or a CDN is available" ;;
    3) T_TRANSPORT=wss ;;
    4) T_TRANSPORT=utls ;;
    5) T_TRANSPORT=fallback ;;
    6) T_TRANSPORT=icmp
        blank
        dim "This server stops answering ordinary pings while the tunnel runs." ;;
    7) T_TRANSPORT=gre
        blank
        warn "GRE is not encrypted and not hidden - anything on the path can read it"
        confirm_yes "use GRE?" || return 1 ;;
    8) T_TRANSPORT=udp
        blank
        warn "needs UDP to pass between the two servers, which many Iranian lines stop" ;;
    9) T_TRANSPORT=rawtcp ;;
    10) T_TRANSPORT=awg
        blank
        warn "rides on UDP, which many Iranian lines stop"
        awg_install || return 1 ;;
    esac
    cfg_mode
    return 0
}

# Only transports that bind a port have a direction to choose. ICMP has no
# port to be reachable on, GRE is its own protocol, and AmneziaWG names both
# ends itself; on all three IRAN sends first.
# Only transports that bind a port have a direction to choose. ICMP has no
# port to be reachable on, GRE is its own protocol, and AmneziaWG names both
# ends itself; on all three IRAN sends first.
ask_direction() {
    T_DIALS=iran
    case $T_TRANSPORT in icmp | gre | awg) return 0 ;; esac
    wiz "Link direction"
    CHOICE_DEF=1
    choice 1 "Direct" "IRAN connects out to KHAREJ"
    choice 2 "Reverse" "KHAREJ connects in - a CDN in front of IRAN, or NAT"
    CHOICE_DEF=
    blank
    dim "Users and ports stay on IRAN either way; this is only who opens the connection."
    blank
    local dir
    pick dir "select" 1 2 || return 1
    [ "$dir" = 2 ] && T_DIALS=kharej
    return 0
}

# Both addresses, always. The far one is obvious - somebody has to be dialled
# or answered. The near one matters on a server with more than one address:
# a reply that leaves from an address the far end is not expecting is a reply
# the far end throws away.
ask_addresses() {
    local other n i=0 def=
    local -a addrs=()
    other=$(side_label "$(other_side "$T_SIDE")")
    wiz "Addresses"
    while IFS= read -r n; do addrs+=("$n"); done < <(wiz_public_ips)
    case $T_TRANSPORT in
    ws | wss) dim "The public IP of each server, or a domain for the end a CDN fronts." ;;
    *) dim "The public IP of each server." ;;
    esac
    blank
    if [ "${#addrs[@]}" -gt 1 ]; then
        dim "this server answers on more than one address - pick the right one"
        blank
        while [ "$i" -lt "${#addrs[@]}" ]; do
            choice "$((i + 1))" "$(addr_tint "${addrs[i]}")"
            i=$((i + 1))
        done
        choice "$((i + 1))" "Something else" "a domain, or one not listed"
        blank
        pick n "select" "" $((i + 1)) || return 1
        [ "$n" -le "${#addrs[@]}" ] && T_PUBLIC_IP=${addrs[n - 1]}
        blank
    elif [ "${#addrs[@]}" = 1 ]; then
        def=${addrs[0]}
        dim "this machine answers on ${C_OFF}${def}${C_DIM} - press enter to take it"
        blank
    fi
    if [ -z "$T_PUBLIC_IP" ]; then
        if [ "$T_TRANSPORT" = wss ] || [ "$T_TRANSPORT" = ws ]; then
            ask T_PUBLIC_IP "domain or address of this $(side_label "$T_SIDE") server" "$def" v_host || return 1
        else
            ask T_PUBLIC_IP "address of this $(side_label "$T_SIDE") server" "$def" v_host || return 1
        fi
    fi
    blank
    if [ "$T_TRANSPORT" = wss ] || [ "$T_TRANSPORT" = ws ]; then
        ask T_PEER_IP "domain or address of the $other server" "" v_host || return 1
    else
        ask T_PEER_IP "address of the $other server" "" v_host || return 1
    fi
    if [ "$T_SIDE" = iran ]; then T_IRAN=$T_PUBLIC_IP T_KHAREJ=$T_PEER_IP
    else T_KHAREJ=$T_PUBLIC_IP T_IRAN=$T_PEER_IP; fi
    case $T_TRANSPORT in ws | wss) T_PATH=$(wiz_path) ;; esac
    return 0
}

# v_wiz_port refuses a port another tunnel here already carries on, and - on
# the side that waits - one something else already listens on.
v_wiz_port() {
    local who fam
    v_port "$1" || return 1
    fam=$(port_family "$T_TRANSPORT")
    who=$(tunnel_port_owner "$1" "$T_TRANSPORT" "${WIZ_KEEP:-}")
    if [ -n "$who" ]; then
        echo "$1/$fam is already the tunnel port of $who - pick another, or delete that tunnel first"
        return 1
    fi
    if this_side_waits && ! port_free "$1" "$fam"; then
        echo "something is already listening on $1/$fam - check with:  ss -lnp | grep :$1"
        return 1
    fi
    return 0
}

v_awg_port() {
    v_port "$1" || return 1
    if ! port_free "$1" udp; then
        echo "something here already listens on udp/$1 - see: ss -lunp | grep :$1"
        return 1
    fi
    return 0
}

ask_port() {
    local fam def
    case $T_TRANSPORT in
    icmp | gre) T_PORT=; return 0 ;;
    awg)
        wiz "Port" "AmneziaWG listens on this. The same number on both servers."
        ask T_AWG_PORT "UDP port for the tunnel, same on both" "$T_AWG_PORT" v_awg_port || return 1
        dim "leave ${T_AWG_PORT}/udp open in this server's firewall"
        return 0
        ;;
    esac
    fam=$(port_family "$T_TRANSPORT")
    wiz "Port" "The port the two servers meet on. Only the end that waits binds it."
    this_side_waits && show_taken_tunnel_ports
    case $T_TRANSPORT in
    ws) def=80 ;;
    wss) def=443 ;;
    *) def=8443 ;;
    esac
    while [ -n "$(tunnel_port_owner "$def" "$T_TRANSPORT")" ] ||
        { this_side_waits && ! port_free "$def" "$fam"; }; do
        def=$((def + 1))
        [ "$def" -gt 8500 ] && break
    done
    ask T_PORT "port for the tunnel itself, same on both" "$def" v_wiz_port || return 1
    this_side_waits && dim "leave ${T_PORT}/${fam} open in this server's firewall"
    cdn_port_warn
    return 0
}

v_wiz_octet() {
    local who
    v_octet "$1" || return 1
    who=$(net_owner "10.$1.10" "${WIZ_KEEP:-}")
    if [ -n "$who" ]; then
        echo "10.$1.10.0/24 already belongs to $who - pick another x, or delete that tunnel first"
        return 1
    fi
    if who=$(host_net_owner "$1"); then
        echo "this server already has $who on that network - docker, or another VPN"
        return 1
    fi
    return 0
}

v_wiz_iface() {
    local who
    case $1 in '' | *[!a-zA-Z0-9_-]*) echo "letters, digits, dash and underscore"; return 1 ;; esac
    [ "${#1}" -le 15 ] || { echo "linux stops at 15 characters"; return 1; }
    who=$(iface_owner "$1" "${WIZ_KEEP:-}")
    [ -z "$who" ] || { echo "$1 already belongs to $who"; return 1; }
    host_has_iface "$1" && { echo "this server already has an interface called $1"; return 1; }
    return 0
}

# One question decides the network; both addresses are worked out from it
# and shown rather than re-asked, so a hand edit cannot walk past the checks
# that guarded the question.
ask_link() {
    cfg_needs_link || return 0
    wiz "Private link" "Both servers get an address on a small network of their own."
    show_taken_nets
    local def
    def=$(free_link_octet) || def=
    [ -n "$def" ] || warn "every 10.x.10.0/24 is inside an address on this host"
    ask T_OCTET "range 10.x.10.0/24 - pick x" "$def" v_wiz_octet || return 1
    if [ "$T_SIDE" = iran ]; then
        T_TUNLOCAL="10.$T_OCTET.10.1/24" T_TUNPEER="10.$T_OCTET.10.2/24"
    else
        T_TUNLOCAL="10.$T_OCTET.10.2/24" T_TUNPEER="10.$T_OCTET.10.1/24"
    fi
    blank
    field "IRAN" "$(addr_tint "10.$T_OCTET.10.1/24")"
    field "KHAREJ" "$(addr_tint "10.$T_OCTET.10.2/24")"
    blank
    ask T_TUNIF "device name" "$(free_tun_iface)" v_wiz_iface || return 1
    case $T_TRANSPORT in
    awg) T_TUNMTU=1280 ;;
    *) T_TUNMTU=1320 ;;
    esac
    ask T_TUNMTU "MTU" "$T_TUNMTU" v_mtu || return 1
    return 0
}

# The IRAN side owns the ports. Two tunnels forwarding one port means
# whichever bound it first wins and the other never sees a connection, so
# what is taken is listed and a repeat is refused - and so is a port
# something else on this server already listens on.
ask_forwards() {
    [ "$T_SIDE" = iran ] || return 0
    wiz "Ports" "The ports your clients will connect to, here on IRAN."
    show_taken_ports
    dim "one port 443   a range 8000-8010   udp udp:500   elsewhere 443=8443"
    blank
    local raw clashes
    while :; do
        ask raw "ports, comma separated" "" v_forwards_needed || return 1
        if clashes=$(forwards_clash "" "$raw"); then
            T_FORWARDS=$(fwd_tokens "$raw" | tr '\n' ' ')
            T_FORWARDS=${T_FORWARDS% }
            return 0
        fi
        printf '%s\n' "$clashes" | while read -r line; do [ -n "$line" ] && fail "$line"; done
        dim "pick another port, or free that one first"
        blank
    done
}

v_forwards_needed() {
    [ -n "$1" ] || { echo "at least one port is required - it is what users connect to"; return 1; }
    v_forwards "$1"
}

ask_preset() {
    wiz "Performance" "The shape of your traffic. You can change it later."
    preset_menu
}

ask_logging() {
    wiz "How much to log" "Each level includes the ones above it."
    CHOICE_DEF=3
    choice 1 "error" "only what is broken"
    choice 2 "warn" "and what is wrong but survivable"
    choice 3 "info" "and what a healthy tunnel does"
    choice 4 "debug" "and why each connection and packet did what it did"
    CHOICE_DEF=
    blank
    local lg
    pick lg "select" 3 4 || return 1
    case $lg in
    1) T_LOG=error ;;
    2) T_LOG=warn ;;
    4) T_LOG=debug ;;
    *) T_LOG=info ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# the review, and the creation both entrances share
# ---------------------------------------------------------------------------

dials_text() {
    if [ "$T_SIDE" = "$T_DIALS" ]; then
        printf 'direct - connects to %s' "$(addr_tint "$T_PEER_IP")"
    else
        printf 'reverse - accepts from %s' "$(addr_tint "$T_PEER_IP")"
    fi
}

review_panel() {
    local trans
    trans=$(kind_label "$T_TRANSPORT")
    case $T_TRANSPORT in
    awg) trans="$trans, udp/$T_AWG_PORT" ;;
    icmp | gre) ;;
    *) trans="$trans, $(port_family "$T_TRANSPORT")/$T_PORT" ;;
    esac
    panel "$T_NAME"
    panel_field "This server" "$(side_label "$T_SIDE")"
    panel_field "Address" "$(addr_tint "$T_PUBLIC_IP")"
    panel_field "Type" "$trans"
    panel_field "Link" "$(dials_text)"
    [ -n "$T_PATH" ] && panel_field "Web path" "$T_PATH"
    if cfg_needs_link; then
        panel_field "Private link" "$(addr_tint "${T_TUNLOCAL%%/*}") ${G_BOTH} $(addr_tint "${T_TUNPEER%%/*}")   $T_TUNIF   mtu $T_TUNMTU"
    fi
    [ -n "$T_FORWARDS" ] && panel_field "Ports" "$T_FORWARDS"
    panel_field "Token" "$(token_print "$T_TOKEN")"
    panel_field "Tuning" "${T_PRESET^}, queue $(preset_queue "$T_PRESET") packets"
    panel_field "Logging" "$T_LOG"
    panel_end
}

# wiz_create writes the file, starts the tunnel, and reports. Everything
# after the last question, on both entrances.
wiz_create() {
    local tmp
    blank
    tmp=$(mktemp) || { fail "could not make a temporary file"; return 1; }
    cfg_render >"$tmp"
    if ! tunnel_create "$T_NAME" "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
    enable_watchdog quiet
    dim "$(cfg_file "$T_NAME")"
    return 0
}

# ---------------------------------------------------------------------------
# build a new tunnel
# ---------------------------------------------------------------------------

new_tunnel() {
    banner
    head2 "New tunnel"
    wiz_end
    ensure_core || { pause; return 1; }
    cfg_reset
    wiz_reset

    ask_side || { wiz_end; return 0; }
    if [ "$T_SIDE" = paste ]; then
        import_tunnel
        local rc=$?
        wiz_end
        return $rc
    fi

    ask_transport || { wiz_end; return 0; }
    ask_direction || { wiz_end; return 0; }
    ask_addresses || { wiz_end; return 0; }
    ask_port || { wiz_end; return 0; }
    ask_link || { wiz_end; return 0; }
    ask_forwards || { wiz_end; return 0; }
    ask_preset || { wiz_end; return 0; }
    ask_logging || { wiz_end; return 0; }

    # -- the things nobody has to be asked ---------------------------------
    if [ "$T_TRANSPORT" = awg ]; then
        # The carrier inside the link gets a port of its own, worked out from
        # the octet, where nothing outside can reach it.
        T_PORT=$((20900 + T_OCTET))
        T_AWG_IFACE=$(awg_free_iface) || { fail "there is no free awg device left on this host"; pause; wiz_end; return 1; }
        awg_generate || { fail "AmneziaWG would not generate a key here"; pause; wiz_end; return 1; }
    fi
    T_NAME=$(unique_name "$(tunnel_default_name)")
    if ! T_TOKEN=$(wiz_token); then
        warn "no random source here, so the token has to be typed"
        ask T_TOKEN "security token" "" v_token || { wiz_end; return 0; }
    fi
    if [ "$T_MODE" = tun ]; then
        if ! T_HEALTH=$(free_health_port); then
            T_HEALTH=$HEALTH_PORT
            warn "$HEALTH_PORT and the twenty above it are all taken on this server"
            dim "the tunnel will work; its round trip will not be measurable"
        fi
    else
        T_HEALTH=-1
    fi
    if ! T_STATUS=$(pick_status_port); then
        fail "every status port from $STATUS_BASE is taken here"
        pause; wiz_end; return 1
    fi

    # -- review ------------------------------------------------------------
    blank
    ok "this tunnel is called ${C_B}${T_NAME}${C_OFF}"
    ok "security token generated - fingerprint ${C_YEL}$(token_print "$T_TOKEN")${C_OFF}"
    banner
    head2 "Ready to create"
    review_panel
    blank
    if ! confirm_yes "create the tunnel ${C_B}${T_NAME}${C_OFF}?"; then
        warn "cancelled, nothing was written"
        pause; wiz_end
        return 1
    fi

    wiz_create || { pause; wiz_end; return 1; }
    blank

    # -- the other server --------------------------------------------------
    local other
    other=$(side_label "$(other_side "$T_SIDE")")
    head2 "Now the $other server"
    dim "run Pingify there and choose  New tunnel ${BX_ARR} Paste a token"
    blank
    rule
    printf '%s\n' "${C_YEL}$(cfg_setup_token)${C_OFF}"
    rule
    blank
    warn "treat it like a password - it carries the security token"
    blank
    tunnel_status_block "$T_NAME"
    pause
    wiz_end
    return 0
}

# ---------------------------------------------------------------------------
# finish the pair from a token
# ---------------------------------------------------------------------------

v_wiz_paste() {
    local s=${1//[[:space:]]/}
    case $s in
    '') echo "paste the whole line the other server printed"; return 1 ;;
    PFY3.* | PFY2.*) return 0 ;;
    esac
    echo "that is not a Pingify token - the line starts with PFY3."
    return 1
}

import_tunnel() {
    banner
    head2 "Paste the setup token"
    dim "Printed by the other server when its tunnel was made. It carries the"
    dim "whole config, so there is nothing left to answer."
    blank
    local token
    ask token "token" "" v_wiz_paste || return 1
    if ! setup_token_read "$token"; then
        fail "$SETUP_TOKEN_ERROR"
        pause; return 1
    fi
    if [ -n "${TOKEN_VERSION:-}" ] && [ "$TOKEN_VERSION" != "$PINGIFY_VERSION" ]; then
        warn "that token came from Pingify $TOKEN_VERSION and this is $PINGIFY_VERSION"
        dim "the two servers should run the same version; update the other one after this"
    fi

    # The side in the token is the other server's. This flip is the entire
    # second installation, and the name goes with it.
    local from
    from=$(printf '%s' "$T_NAME" | cut -d- -f1)
    case $from in
    iran) T_SIDE=kharej ;;
    kharej) T_SIDE=iran ;;
    *) fail "that token does not say which server made it"; pause; return 1 ;;
    esac
    T_NAME=$(name_for_side "$T_NAME" "$T_SIDE")
    if [ "$T_SIDE" = iran ]; then T_PUBLIC_IP=$T_IRAN T_PEER_IP=$T_KHAREJ
    else T_PUBLIC_IP=$T_KHAREJ T_PEER_IP=$T_IRAN; fi
    if cfg_needs_link; then
        if [ "$T_SIDE" = iran ]; then T_TUNLOCAL="10.$T_OCTET.10.1/24" T_TUNPEER="10.$T_OCTET.10.2/24"
        else T_TUNLOCAL="10.$T_OCTET.10.2/24" T_TUNPEER="10.$T_OCTET.10.1/24"; fi
    fi
    [ "$T_TRANSPORT" = awg ] && { awg_install || { pause; return 1; }; }

    blank
    head2 "This server"
    dim "the token came from $(side_label "$(other_side "$T_SIDE")"), so this is the $(side_label "$T_SIDE") side"
    blank

    # -- what is in the way here -------------------------------------------
    local clash=0 own
    if [ -e "$(cfg_file "$T_NAME")" ]; then
        warn "a tunnel named $T_NAME already exists on this server"
        if confirm "replace it?"; then
            svc_do stop "$T_NAME" >/dev/null 2>&1
            systemctl disable "pingify@$T_NAME" >/dev/null 2>&1
            nat_drop "$T_NAME" >/dev/null 2>&1 || true
            awg_down "$T_NAME" >/dev/null 2>&1 || true
            rm -f "$(cfg_file "$T_NAME")" "$(fwd_file "$T_NAME")"
        else
            clash=1
        fi
    fi
    if cfg_needs_link; then
        own=$(net_owner "10.$T_OCTET.10")
        if [ -n "$own" ]; then
            fail "10.$T_OCTET.10.0/24 is already used here by $own"
            dim "change the range on the first server, and paste again"
            clash=1
        elif own=$(host_net_owner "$T_OCTET"); then
            fail "this server already has $own on 10.$T_OCTET.10.0/24"
            dim "change the range on the first server, and paste again"
            clash=1
        fi
        if [ -n "$(iface_owner "$T_TUNIF")" ] || host_has_iface "$T_TUNIF"; then
            local alt
            alt=$(free_tun_iface)
            warn "the device $T_TUNIF is in use here; this side will use $alt"
            dim "the device name is local to each server, so the two may differ"
            T_TUNIF=$alt
        fi
    fi
    if [ "$T_TRANSPORT" = awg ]; then
        if ! port_free "$T_AWG_PORT" udp; then
            fail "something here already listens on udp/$T_AWG_PORT"
            dim "ss -lunp | grep :$T_AWG_PORT   shows what has it"
            clash=1
        fi
        T_AWG_IFACE=$(awg_free_iface) || { fail "no free awg device here"; clash=1; }
    elif [ -n "$T_PORT" ] && this_side_waits; then
        local fam
        fam=$(port_family "$T_TRANSPORT")
        own=$(tunnel_port_owner "$T_PORT" "$T_TRANSPORT")
        if [ -n "$own" ]; then
            fail "${T_PORT}/$fam is already $own's tunnel port here"
            dim "change the port on the first server, and paste again"
            clash=1
        elif ! port_free "$T_PORT" "$fam"; then
            fail "something here already listens on ${T_PORT}/$fam"
            dim "ss -lnp | grep :$T_PORT   shows what has it"
            clash=1
        fi
    fi
    if [ "$clash" = 1 ]; then
        blank
        dim "nothing was created"
        pause
        return 1
    fi
    if [ "$T_MODE" = tun ] && [ "$T_HEALTH" != -1 ] && health_bound "${T_HEALTH:-$HEALTH_PORT}"; then
        warn "something here already holds port ${T_HEALTH:-$HEALTH_PORT} on every address"
        dim "the tunnel works; its round trip will not be measurable from the other end"
    fi
    if ! T_STATUS=$(pick_status_port); then
        fail "every status port from $STATUS_BASE is taken here"
        pause; return 1
    fi
    [ -n "$T_PORT" ] && this_side_waits && dim "leave ${T_PORT}/$(port_family "$T_TRANSPORT") open in this server's firewall"
    [ "$T_TRANSPORT" = awg ] && dim "leave ${T_AWG_PORT}/udp open in this server's firewall"

    banner
    head2 "Ready to create"
    review_panel
    blank
    confirm_yes "create the tunnel ${C_B}${T_NAME}${C_OFF}?" || { warn "cancelled"; pause; return 1; }

    wiz_create || { pause; return 1; }
    blank
    head2 "Both servers are set up"
    dim "this end was built from the other server's token, so there is nothing to carry back"
    dim "give it a few seconds and look at it under Manage tunnels"
    blank
    tunnel_status_block "$T_NAME"
    pause
    return 0
}

# The names the menus and the tests reach the wizard by.
wizard_new() { new_tunnel; }
screen_new() { new_tunnel; return 0; }
