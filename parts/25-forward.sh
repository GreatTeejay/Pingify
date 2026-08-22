
# ---------------------------------------------------------------------------
# forwarders
#
# Two ways to get a client on the IRAN server through to a service on KHAREJ.
#
#   pingify   The core does it. It accepts the connection, multiplexes it over
#             the carriers and opens the far side itself. Every byte is
#             encrypted end to end by the core, it works over any transport,
#             and it needs nothing from the kernel.
#
#   iptables  The kernel does it. A private layer-3 link is brought up between
#             the two servers and the traffic is NATed onto it, so a packet is
#             never copied into user space at all. Less CPU and more headroom
#             on a busy tunnel - at the cost of only working over a full-IP
#             link, and of touching the NAT table.
#
# Rules live in Pingify's own chains, so nothing your panel installed is
# disturbed, and a boot unit puts them back after a restart.
# ---------------------------------------------------------------------------

forwarder_label() {
    case "$1" in
        iptables) printf 'IPTABLES' ;;
        *)        printf 'PINGIFY' ;;
    esac
}

# nat_chains prepares the two chains and hooks them in once.
nat_chains() {
    local c
    for c in PINGIFY_NAT PINGIFY_POST; do
        iptables -t nat -N "$c" 2>/dev/null || iptables -t nat -F "$c" 2>/dev/null
    done
    iptables -t nat -C PREROUTING  -j PINGIFY_NAT  2>/dev/null || iptables -t nat -I PREROUTING 1  -j PINGIFY_NAT
    iptables -t nat -C OUTPUT      -j PINGIFY_NAT  2>/dev/null || iptables -t nat -I OUTPUT 1      -j PINGIFY_NAT
    iptables -t nat -C POSTROUTING -j PINGIFY_POST 2>/dev/null || iptables -t nat -I POSTROUTING 1 -j PINGIFY_POST
}

# The mangle chain, for the one rule that decides whether a tunnel is quick
# or merely connected.
mss_chain() {
    iptables -t mangle -N PINGIFY_MSS 2>/dev/null || iptables -t mangle -F PINGIFY_MSS 2>/dev/null
    iptables -t mangle -C FORWARD -j PINGIFY_MSS 2>/dev/null || iptables -t mangle -I FORWARD 1 -j PINGIFY_MSS
    iptables -t mangle -C OUTPUT  -j PINGIFY_MSS 2>/dev/null || iptables -t mangle -I OUTPUT 1  -j PINGIFY_MSS
}

mss_drop_chain() {
    iptables -t mangle -D FORWARD -j PINGIFY_MSS 2>/dev/null
    iptables -t mangle -D OUTPUT  -j PINGIFY_MSS 2>/dev/null
    iptables -t mangle -F PINGIFY_MSS 2>/dev/null
    iptables -t mangle -X PINGIFY_MSS 2>/dev/null
}

nat_drop_chains() {
    mss_drop_chain
    iptables -t nat -D PREROUTING  -j PINGIFY_NAT  2>/dev/null
    iptables -t nat -D OUTPUT      -j PINGIFY_NAT  2>/dev/null
    iptables -t nat -D POSTROUTING -j PINGIFY_POST 2>/dev/null
    local c
    for c in PINGIFY_NAT PINGIFY_POST; do
        iptables -t nat -F "$c" 2>/dev/null
        iptables -t nat -X "$c" 2>/dev/null
    done
}

# nat_rules_for writes the rules one tunnel needs. Both ends need a rule: the
# IRAN side sends the traffic across the private link, and the KHAREJ side
# turns it back towards whatever is listening on loopback.
nat_rules_for() {
    local name="$1"
    cfg_load "$name" || return 1
    [ "$T_FORWARDER" = "iptables" ] || return 0
    # a private link is what the rules route onto; forward-only has none
    [ "$T_MODE" != "forward" ] || return 0

    local peer_ip local_ip
    peer_ip="${T_TUNPEER%%/*}"
    local_ip="${T_TUNLOCAL%%/*}"
    [ -n "$peer_ip" ] && [ -n "$local_ip" ] || return 1

    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    # DNAT to a loopback address is refused unless this is on.
    sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null 2>&1

    local spec proto lport rport target
    for spec in $(printf '%s' "$T_FORWARDS" | tr -d '"' | tr ',' ' '); do
        proto=tcp
        case "$spec" in
            udp:*) proto=udp; spec="${spec#udp:}" ;;
            tcp:*) spec="${spec#tcp:}" ;;
        esac
        lport="${spec%%=*}"
        rport="${spec#*=}"
        [ "$rport" = "$spec" ] && rport="$lport"
        case "$lport$rport" in *[!0-9-]*) continue ;; esac

        # Only the IRAN side has rules: it sends the traffic straight to the
        # other server's private address. Nothing is needed over there, as
        # long as the service listens on 0.0.0.0 rather than loopback alone.
        if [ "$T_ROLE" = "server" ]; then
            target="$peer_ip:$rport"
            iptables -t nat -A PINGIFY_NAT -p "$proto" --dport "$lport" \
                     ! -s "$peer_ip" -j DNAT --to-destination "$target" 2>/dev/null
        fi
    done

    # Replies have to come back the way they came.
    iptables -t nat -A PINGIFY_POST -o "$T_TUNIF" -j MASQUERADE 2>/dev/null

    # And the rule that decides whether this is quick or merely connected.
    #
    # A tunnel carries a smaller packet than the path it rides on. Two ends
    # setting up a TCP session through it agree a segment size from what their
    # own interfaces can take, which is larger than the tunnel - so the first
    # real transfer sends a packet that will not fit and the session stalls
    # while both sides patiently retry it. It looks exactly like a slow link,
    # and no amount of tuning on either end helps, because nothing on either
    # end is wrong.
    #
    # Clamping the announced size to what the tunnel actually carries is the
    # fix, and it costs one rule.
    iptables -t mangle -A PINGIFY_MSS -o "$T_TUNIF" -p tcp --syn -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null

    # Asymmetric routing is normal on a tunnel - the reply comes back on a
    # different interface than the kernel would have chosen - and the reverse
    # path filter drops exactly that.
    sysctl -w "net.ipv4.conf.${T_TUNIF}.rp_filter=0" >/dev/null 2>&1
    return 0
}

# apply_nat rebuilds every tunnel's rules from its config.
apply_nat() {
    local quiet="${1:-}"
    have iptables || { [ "$quiet" = quiet ] || warn "iptables is not installed"; return 1; }
    local any=0 n
    for n in $(tunnel_names); do
        if [ "$(toml_get "$(cfg_file "$n")" forward forwarder)" = "iptables" ]; then
            any=1
        fi
    done
    if [ "$any" = "0" ]; then
        nat_drop_chains
        return 0
    fi
    nat_chains
    mss_chain
    # Each in its own shell. nat_rules_for reads a config with cfg_load, which
    # writes every T_ variable there is - and this is called from the middle of
    # the wizard, where those variables are the tunnel being built. It was
    # overwriting them with whichever config happened to be read last, so the
    # setup token described a different tunnel and the "is running" line named
    # one too.
    for n in $(tunnel_names); do ( nat_rules_for "$n" ); done
    [ "$quiet" = quiet ] || ok "forwarding rules applied"
    return 0
}

show_nat() {
    say ""
    if ! have iptables; then
        warn "iptables is not installed"
        return
    fi
    if iptables -t nat -S PINGIFY_NAT >/dev/null 2>&1; then
        iptables -t nat -S PINGIFY_NAT  2>/dev/null | sed 's/^/    /'
        iptables -t nat -S PINGIFY_POST 2>/dev/null | sed 's/^/    /'
    else
        dim "no iptables forwarding is set up"
    fi
}
