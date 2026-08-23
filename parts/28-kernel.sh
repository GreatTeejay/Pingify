
# ---------------------------------------------------------------------------
# kernel tunnels: GRE and AmneziaWG
#
# Everything up to here is carried by our own engine: a Go process holds the
# carriers open and moves the bytes. These two are not. The kernel carries
# them, and Pingify's job is to describe the link, write the unit that brings
# it up, and then answer the same questions about it that it answers about
# every other tunnel - is it up, how far away is the other end, what is wrong.
#
# Both build a private link between the two servers, so both wear the TUN
# label, and both hand their forwarding to the iptables forwarder that already
# exists for that case: DNAT onto the other server's private address, and
# masquerade back out of the tunnel interface.
#
# The instance unit is a concrete pingify@<name>.service, which systemd
# prefers over the pingify@.service template. That is deliberate: every place
# in this manager that starts, stops, watches or deletes a tunnel keeps
# working without knowing which kind it is holding.
# ---------------------------------------------------------------------------

# The kernel carries these; there is no core process and no status endpoint.
kernel_transport() {
    case "${1:-$T_TRANSPORT}" in
        gre | awg) return 0 ;;
        *)         return 1 ;;
    esac
}

# One interface name per tunnel, derived so two tunnels never collide and a
# person can still read it. Linux stops at 15 characters, and the tunnel's own
# name already carries the transport at both ends - tun-iran-gre - so strip
# what the prefix is about to say again and the result is gre-iran.
link_iface() {
    local name="$1" pfx short
    case "$T_TRANSPORT" in
        gre)  pfx="gre" ;;
        awg)  pfx="awg" ;;
        icmp) pfx="icmp" ;;
        *)    pfx="pfy" ;;
    esac
    # tun-iran-gre     -> iran        (the transport is the tail)
    # tun-iran-gre-20   -> iran-20      (it is in the middle, once the network
    #                                    has been added to tell two apart)
    short="${name#tun-}"
    short="${short%-$pfx}"
    short="${short//-$pfx-/-}"
    if [ -n "$short" ] && [ "${#short}" -le 11 ]; then
        printf '%s-%s' "$pfx" "$short"
    else
        # Nothing readable left that fits: a hash keeps them apart, which is
        # the one thing the name has to do.
        printf '%s-%s' "$pfx" "$(printf '%s' "$name" | cksum | cut -d' ' -f1)"
    fi
}

# ---------------------------------------------------------------------------
# what the kernel needs to have
# ---------------------------------------------------------------------------

gre_ready() {
    have ip || return 1
    # ip_gre is usually a module and usually not loaded until something asks.
    modprobe ip_gre >/dev/null 2>&1
    return 0
}

awg_ready() { have awg && have awg-quick; }

# The install is a best effort: an Iran server with no route to the PPA cannot
# do this, and saying so plainly beats a unit that fails at boot.
awg_install() {
    awg_ready && return 0
    say ""
    dim "installing amneziawg-tools"
    if have add-apt-repository; then
        add-apt-repository -y ppa:amnezia/ppa >/dev/null 2>&1
    fi
    if have apt-get; then
        apt-get update >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y amneziawg amneziawg-tools >/dev/null 2>&1
    fi
    awg_ready && { ok "amneziawg-tools installed"; return 0; }

    fail "amneziawg could not be installed on this server"
    dim "it needs the Amnezia PPA, which an Iran server often cannot reach."
    dim "install it from a server that can, or use TUN-GRE, which needs nothing."
    return 1
}

# ---------------------------------------------------------------------------
# AmneziaWG keys and obfuscation
# ---------------------------------------------------------------------------

# One keypair, printed as "private public". WireGuard needs a real asymmetric
# pair on each side, and each side needs the other's public half.
awg_keypair() {
    local priv pub
    priv="$(awg genkey 2>/dev/null)" || return 1
    pub="$(printf '%s' "$priv" | awg pubkey 2>/dev/null)" || return 1
    printf '%s %s' "$priv" "$pub"
}

# The obfuscation parameters, as one comma-separated field:
#
#   Jc          how many junk packets go before the handshake
#   Jmin Jmax   how big each of them is
#   S1 S2       padding added to the two handshake messages
#   H1..H4      what the four WireGuard message types are called on the wire
#
# Jc/Jmin/Jmax/S1/S2 are the values that were measured stable on this path and
# are kept. H1..H4 are not: the script this idea came from hardcodes four
# numbers, which means every tunnel built by it answers to the same four
# values - a signature, and a better one than the plain WireGuard header it
# was meant to hide. Ours are drawn per tunnel and travel in the setup token,
# so the two servers agree and no two tunnels look alike.
awg_new_obf() {
    local h1 h2 h3 h4
    h1="$(awg_rand_header)"; h2="$(awg_rand_header)"
    h3="$(awg_rand_header)"; h4="$(awg_rand_header)"
    printf '5,50,1000,68,91,%s,%s,%s,%s' "$h1" "$h2" "$h3" "$h4"
}

# A header value has to be above 4, because 1-4 are what real WireGuard uses
# and reusing one would make the tunnel answer to its own obfuscation.
awg_rand_header() {
    local n
    n="$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' \n')"
    case "$n" in '' | *[!0-9]*) n="$(( ($$ * 2654435761) % 2147483647 ))" ;; esac
    printf '%s' "$(( (n % 2147483600) + 5 ))"
}

# ---------------------------------------------------------------------------
# what the security token buys here
#
# The kernel has never heard of our token, so it cannot key a GRE or an
# AmneziaWG tunnel the way it keys our own transports. What it can do is
# become the one secret each of them does understand, derived the same way on
# both servers from the same answer:
#
#   AmneziaWG   a pre-shared key, mixed into every handshake on top of the
#               keypair. Real: without a matching one the tunnel does not form.
#
#   GRE         the 32-bit key GRE stamps on each packet. Not protection - it
#               travels in the clear - but two tunnels built from different
#               tokens will not talk to each other by accident.
#
# Derived rather than carried, so neither ever enters the setup token.
# ---------------------------------------------------------------------------

# kernel_keys TOKEN - "presharedkey grekey", or nothing if the core cannot
# be asked. Both servers reach the same values from the same token.
kernel_keys() {
    [ -n "$1" ] || return 1
    [ -x "$CORE_BIN" ] || return 1
    "$CORE_BIN" -derivekey "$1" 2>/dev/null
}

awg_psk_for() { kernel_keys "$1" | awk '{print $1}'; }
gre_key_for() { kernel_keys "$1" | awk '{print $2}'; }

# obf_field N FIELDS - pull one value out of that comma-separated list
obf_field() { printf '%s' "$2" | cut -d, -f"$1"; }

awg_write_conf() {
    local name="$1" iface="$2" conf="$3"
    local obf="$T_AWG_OBF"
    mkdir -p "$(dirname "$conf")"
    {
        printf '# Pingify %s - written by the manager\n' "$name"
        printf '[Interface]\n'
        printf 'PrivateKey = %s\n' "$T_AWG_PRIV"
        printf 'Address = %s\n' "$T_TUNLOCAL"
        printf 'ListenPort = %s\n' "$T_AWG_PORT"
        printf 'MTU = %s\n' "$T_TUNMTU"
        printf 'Jc = %s\n'   "$(obf_field 1 "$obf")"
        printf 'Jmin = %s\n' "$(obf_field 2 "$obf")"
        printf 'Jmax = %s\n' "$(obf_field 3 "$obf")"
        printf 'S1 = %s\n'   "$(obf_field 4 "$obf")"
        printf 'S2 = %s\n'   "$(obf_field 5 "$obf")"
        printf 'H1 = %s\n'   "$(obf_field 6 "$obf")"
        printf 'H2 = %s\n'   "$(obf_field 7 "$obf")"
        printf 'H3 = %s\n'   "$(obf_field 8 "$obf")"
        printf 'H4 = %s\n'   "$(obf_field 9 "$obf")"
        printf '\n[Peer]\n'
        printf 'PublicKey = %s\n' "$T_AWG_PUB"
        # Only the end that dials needs an endpoint. The other one learns the
        # address from the first handshake that arrives, which is what lets
        # the listening side sit behind whatever the path does to it.
        if ! this_side_accepts && [ -n "$T_PEER_IP" ]; then
            printf 'Endpoint = %s:%s\n' "$T_PEER_IP" "$T_AWG_PORT"
        fi
        printf 'AllowedIPs = %s/32\n' "${T_TUNPEER%%/*}"
        # The security token, as the one secret WireGuard understands.
        # Without a matching one the handshake never completes, so the
        # answer to that question is doing real work here.
        local psk; psk="$(awg_psk_for "$T_TOKEN")"
        [ -n "$psk" ] && printf 'PresharedKey = %s\n' "$psk"
        printf 'PersistentKeepalive = 25\n'
    } > "$conf"
    chmod 600 "$conf"
}

awg_conf_path() { printf '%s/%s.conf' "$AWG_DIR" "$1"; }

# ---------------------------------------------------------------------------
# the units
#
# A concrete instance unit, so systemd uses it in place of the template and
# the rest of the manager never has to know the difference.
# ---------------------------------------------------------------------------

write_link_unit() {
    local name="$1" iface unit
    iface="$(link_iface "$name")"
    unit="$UNIT_DIR/pingify@$name.service"

    case "$T_TRANSPORT" in
        gre) write_gre_unit "$name" "$iface" "$unit" ;;
        awg) write_awg_unit "$name" "$iface" "$unit" ;;
        *)   return 1 ;;
    esac
    systemctl daemon-reload
}

write_gre_unit() {
    local name="$1" iface="$2" unit="$3" gkey keyarg=""
    # GRE's own key: two tunnels built from different tokens then refuse to
    # talk to each other. It rides in the clear, so it is not protection -
    # but it is the only thing GRE has, and it makes the token mean something.
    gkey="$(gre_key_for "$T_TOKEN")"
    case "$gkey" in '' | *[!0-9]*) : ;; *) keyarg=" key $gkey" ;; esac
    # One shot, held open: the interface is the state, so systemd has nothing
    # to supervise once it exists. ExecStart deletes any leftover first, which
    # is what makes a restart work rather than fail on "file exists".
    cat > "$unit" <<UNIT
[Unit]
Description=Pingify tunnel $name (GRE)
Documentation=https://github.com/GreatTeejay/Pingify
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '\\
  ip link del $iface 2>/dev/null; \\
  ip tunnel add $iface mode gre local $T_PUBLIC_IP remote $T_PEER_IP ttl $T_GRE_TTL$keyarg; \\
  ip link set $iface mtu $T_TUNMTU; \\
  ip addr add $T_TUNLOCAL dev $iface; \\
  ip link set $iface up; \\
  sysctl -w net.ipv4.conf.$iface.rp_filter=0 >/dev/null 2>&1 || true'
ExecStop=/bin/sh -c 'ip link del $iface 2>/dev/null || true'
SyslogIdentifier=pingify-$name

[Install]
WantedBy=multi-user.target
UNIT
}

write_awg_unit() {
    local name="$1" iface="$2" unit="$3" conf
    conf="$(awg_conf_path "$iface")"
    cat > "$unit" <<UNIT
[Unit]
Description=Pingify tunnel $name (AmneziaWG)
Documentation=https://github.com/GreatTeejay/Pingify
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go
ExecStart=/usr/bin/env awg-quick up $conf
ExecStop=/usr/bin/env awg-quick down $conf
SyslogIdentifier=pingify-$name

[Install]
WantedBy=multi-user.target
UNIT
}

# ---------------------------------------------------------------------------
# what the manager asks about any tunnel
# ---------------------------------------------------------------------------

# link_up NAME - the interface exists and is up
link_up() {
    local iface; iface="$(link_iface "$1")"
    ip link show "$iface" 2>/dev/null | grep -q 'state \(UP\|UNKNOWN\)'
}

# link_rtt NAME - milliseconds to the other end of the private link, or "-".
# One packet, one second: this is called from a list that redraws often.
link_rtt() {
    local peer="${T_TUNPEER%%/*}" out
    [ -n "$peer" ] || { printf '%s' '-'; return 1; }
    out="$(ping -c1 -W1 -n "$peer" 2>/dev/null | sed -n 's/.*time=\([0-9.]*\).*/\1/p')"
    [ -n "$out" ] || { printf '%s' '-'; return 1; }
    printf '%s' "$out"
}

# awg_handshake_age IFACE - seconds since the last completed handshake, or
# nothing when it cannot be asked. AmneziaWG knows for itself whether the far
# end is there, without a packet being sent - and unlike a ping, it still
# knows on a server that has been told to stop answering them.
awg_handshake_age() {
    local iface="$1" last now
    have awg || return 1
    last="$(awg show "$iface" latest-handshakes 2>/dev/null | awk '{print $2; exit}')"
    case "$last" in '' | 0 | *[!0-9]*) return 1 ;; esac
    now="$(date +%s 2>/dev/null)"
    case "$now" in '' | *[!0-9]*) return 1 ;; esac
    printf '%s' "$((now - last))"
}

# A WireGuard peer keeps talking every 25 seconds, so anything older than a
# few minutes of silence is a link that has stopped.
AWG_STALE_AFTER=180

# The same five-field line the core prints for -brief, so the tunnel list and
# the health check can read one shape for every kind of tunnel:
#   state up total rtt streams uptime
kernel_brief() {
    local name="$1" rtt age
    if ! link_up "$name"; then
        printf 'down 0 1 0.0 0 0'
        return
    fi

    # AmneziaWG is asked directly. This is both faster than a ping and more
    # honest: a peer that has been told to stop answering pings - which is
    # exactly what an ICMP tunnel on the same server turns on - is still a
    # peer that is handshaking.
    if [ "$T_TRANSPORT" = "awg" ] && age="$(awg_handshake_age "$T_TUNIF")"; then
        if [ "$age" -gt "$AWG_STALE_AFTER" ]; then
            printf 'down 0 1 0.0 0 0'
            return
        fi
        rtt="$(link_rtt "$name")"
        [ "$rtt" = "-" ] && rtt="0.0"
        printf 'up 1 1 %s 0 0' "$rtt"
        return
    fi

    rtt="$(link_rtt "$name")"
    if [ "$rtt" = "-" ]; then
        # The interface is up but nothing answers on it, which for a kernel
        # tunnel is the same news as a carrier that will not connect.
        printf 'down 0 1 0.0 0 0'
        return
    fi
    printf 'up 1 1 %s 0 0' "$rtt"
}

# status_peer NAME - the other server's address, as the running tunnel sees it.
#
# The accepting end is told nothing about the far side: it does not dial, so
# there is no connect line in its config and no address to read. But something
# arrived, and the core knows what - so this is the only place on that machine
# where the other server's address exists at all.
#
# Written with cut rather than a sed backreference on purpose: this file is
# assembled into one script by a build that has eaten a backslash before.
status_peer() {
    local name="$1" f addr doc
    f="$(cfg_file "$name")" || return 1
    addr="$(toml_get "$f" status addr)"
    [ -n "$addr" ] && [ -x "$CORE_BIN" ] || return 1
    doc="$("$CORE_BIN" -status "$addr" 2>/dev/null)" || return 1
    # one field out of the JSON, and only when it is an address - the core
    # falls back to "listen <our own>" when nothing has connected, which is
    # this machine's address and no use to anyone asking
    printf '%s' "$doc" | tr ',' '\n' | grep '"peer"' | cut -d'"' -f4 \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1
}

# tunnel_is_up NAME - one answer for every kind of tunnel, so the list and the
# status panel cannot disagree. The panel used to ask the core's status
# endpoint, which a kernel tunnel does not have, so GRE and AmneziaWG could
# never be counted and "3 of 4 up" read as 2.
tunnel_is_up() {
    local name="$1" f addr brief
    f="$(cfg_file "$name")"
    [ -f "$f" ] || return 1
    [ "$(svc_state "$name")" = "active" ] || return 1
    if kernel_transport "$(toml_get "$f" transport type)"; then
        brief="$(cfg_load "$name" >/dev/null 2>&1 && kernel_brief "$name")"
        case "$brief" in up\ *) return 0 ;; *) return 1 ;; esac
    fi
    addr="$(toml_get "$f" status addr)"
    [ -n "$addr" ] && [ -x "$CORE_BIN" ] || return 1
    "$CORE_BIN" -healthz "$addr" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# health
#
# The questions are different from an engine tunnel's. There is no handshake
# to fail and no carrier to count: either the kernel built the interface or it
# did not, and either the other end answers on it or it does not.
# ---------------------------------------------------------------------------

# Can this kernel still do what the config asks for at all?
kernel_ready_check() {
    case "$T_TRANSPORT" in
        gre)
            if gre_ready; then
                hc_ok "the kernel has GRE"
            else
                hc_bad "this kernel cannot do GRE"
                hc_note "the ip_gre module is missing, which some VPS kernels ship without"
                hc_fix "modprobe ip_gre     (and ask the provider if it fails)"
            fi ;;
        awg)
            if awg_ready; then
                hc_ok "amneziawg is installed"
            else
                hc_bad "amneziawg is not installed here"
                hc_note "the tunnel cannot come up without awg and awg-quick"
                hc_fix "add-apt-repository -y ppa:amnezia/ppa && apt install -y amneziawg amneziawg-tools"
            fi ;;
    esac
}

# The link is not carrying: say which half of it is missing.
kernel_link_check() {
    local name="$1" iface="$T_TUNIF" peer="${T_TUNPEER%%/*}"

    if ! ip link show "$iface" >/dev/null 2>&1; then
        hc_bad "the interface $iface does not exist"
        hc_note "the unit ran but the kernel did not build the link"
        hc_fix "journalctl -u pingify@$name -n 20 --no-pager -o cat"
        return
    fi
    if ! link_up "$name"; then
        hc_bad "$iface exists but is down"
        hc_fix "systemctl restart pingify@$name"
        return
    fi

    # Up, addressed, and silent. For GRE that is almost always the other end
    # not built yet or the path dropping protocol 47; for AmneziaWG it is a
    # handshake that never completed, which has its own reasons.
    hc_bad "$iface is up but ${peer:-the other end} does not answer"
    # The false alarm this used to raise, and it was easy to walk into:
    # building an ICMP tunnel turns the ping block on, and a server answering
    # no pings answers none on its private links either - so a GRE tunnel
    # carrying traffic perfectly well read as down.
    #
    # The block exempts tunnel interfaces now, so this only survives where
    # there is no firewall to be selective with. The far server is the one
    # that has to answer, and it may be older than this fix.
    if [ "$T_TRANSPORT" = "gre" ] && [ "$(block_state icmp)" = "on" ] && ! have iptables; then
        hc_note "this server has no iptables, so its ping block is the blunt"
        hc_note "kind - and a GRE link is tested by pinging across it"
        hc_fix "test it by hand instead:  curl --interface $iface -sI http://$peer"
    fi
    if [ "$T_TRANSPORT" = "gre" ]; then
        hc_note "GRE is IP protocol 47, not a port - a firewall that only"
        hc_note "knows about ports will drop it without saying so"
        hc_fix "on the other server:  ip a show $iface     (it must exist there too)"
        hc_note "and check both public addresses match what each side was told"
    else
        hc_note "no handshake has completed with the other server"
        hc_fix "awg show $iface     (look for a recent handshake)"
        hc_note "the two ends must agree on the token, the port, and the"
        hc_note "obfuscation values - all of which travel in the setup token"
        hc_fix "check ${T_AWG_PORT}/udp is open here and on the other server"
    fi
}

# ---------------------------------------------------------------------------
# reaching the far end
#
# The core's probe belongs to the core, and a kernel tunnel has none. What can
# be done instead is the same thing the DNAT rule does for real traffic: open
# the forwarded port on the other server's private address and see whether
# anything is there. If that works, every part of the path works - the link,
# the routing, and the service at the end of it.
# ---------------------------------------------------------------------------

# tcp_reaches HOST PORT - true when something accepts there within a moment
tcp_reaches() {
    local host="$1" port="$2"
    timeout 5 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null
}

kernel_probe() {
    local name="$1" peer="${T_TUNPEER%%/*}" spec p lport rport proto bad=0 any=0
    [ -n "$peer" ] || return 0
    [ -n "$T_FORWARDS" ] || return 0

    for spec in $(printf '%s' "$T_FORWARDS" | tr -d '"' | tr ',' ' '); do
        proto=tcp
        case "$spec" in
            udp:*) proto=udp; spec="${spec#udp:}" ;;
            tcp:*) spec="${spec#tcp:}" ;;
        esac
        lport="${spec%%=*}"
        rport="${spec#*=}"
        [ "$rport" = "$spec" ] && rport="$lport"
        # a range is described by its first port; testing all of them would
        # take longer than anybody will wait
        lport="${lport%%-*}"; rport="${rport%%-*}"
        case "$rport" in '' | *[!0-9]*) continue ;; esac
        if [ "$proto" = "udp" ]; then
            hc_note "udp :$lport cannot be tested this way"
            continue
        fi
        any=1
        if tcp_reaches "$peer" "$rport"; then
            hc_ok ":$lport reaches $peer:$rport across the link"
        else
            hc_bad ":$lport does not reach $peer:$rport"
            hc_note "the link is up, so this is the far end rather than the path"
            hc_fix "on the KHAREJ server:  ss -ltnp | grep :$rport"
            hc_note "and it must listen on 0.0.0.0, not on 127.0.0.1 alone -"
            hc_note "the traffic arrives there addressed to $peer"
            bad=1
        fi
    done
    [ "$any" = "0" ] && return 0
    return "$bad"
}
