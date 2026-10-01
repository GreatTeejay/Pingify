#!/usr/bin/env bash
#
# The wizard, driven through its stdin, the way a person drives it.
#
# The questions, in the order they are asked:
#
#   side  transport  [direction]  this address  other address  [port]
#   [octet  device  mtu]  [ports]  preset (3 = balanced)  logging  confirm
#
# and on the second server: side 3, the token, confirm. Every test here
# answers the real questions and reads the real file that came out, so a
# wizard that stops producing a config the core accepts fails here rather
# than on a server.

cd "$(dirname "$0")/.." || exit 1
. tests/lib.sh
load_parts .
sandbox
trap sandbox_clean EXIT

# Nothing here may reach systemd, the firewall, or an interface.
systemctl() { return 0; }
journalctl() { return 0; }
nat_apply() { return 0; }
nat_drop() { return 0; }
awg_install() { return 0; }
# a kernel link's own commands: this machine has neither them nor root
# route get answers with a device, as the kernel would: the kernel link
# needs an interface to turn GRO off on and refuses to come up without one.
ip() { case "${1:-} ${2:-}" in "route get") echo "1.2.3.4 via 10.0.0.1 dev eth0 src 10.0.0.2 uid 0" ;; esac; return 0; }
modprobe() { return 0; }
ethtool() { return 0; }
iptables() { return 0; }
sleep() { :; }
srv_info() { SRV_IP=1.2.3.4 SRV_LOC=x SRV_ORG=y; }
wiz_public_ips() { return 1; }
curl() { return 1; }

# Nor may it read the machine it runs on. The wizard asks the host which
# networks, devices and ports are already taken, and a test that let it ask
# got a different answer on every machine: on a laptop with no tunnels the
# first free network is 10.1, on a server already running five it is 10.6,
# and the file the wizard wrote then failed every check below. Here the host
# is empty, so the answers are the same everywhere.
host_net_owner() { return 1; }
host_has_iface() { return 1; }
health_bound() { return 1; }
port_free() { return 0; }

answers() { printf '%s\n' "$@"; }

# the core, so the wizard's file can be judged by the real reader
CORE=
if have go && [ -f go.mod ]; then
    CORE=$SANDBOX/pingify-core
    go build -o "$CORE" ./cmd/pingify 2>/dev/null || CORE=
fi
CORE_BIN=${CORE:-/nonexistent/pingify-core}
ensure_core() { [ -x "$CORE_BIN" ]; }

# The value of a key with the note stripped; toml_get does that already.
val() { toml_get "$1" "$2" "$3"; }

section "the questions come in the order they were designed in"

out=$(answers 1 12 185.31.8.129 46.247.109.83 "" "" "" "3030" 3 3 n | new_tunnel 2>&1)
check_contains "which server comes first" "$out" "1 . Which server is this?"
check_contains "then the transport" "$out" "2 . Transport"
check_contains "an ICMP tunnel is not asked its direction" "$out" "3 . Addresses"
check_contains "the private link comes after the addresses" "$out" "4 . Private link"
check_contains "then the ports" "$out" "5 . Ports"
check_contains "then the preset" "$out" "6 . Performance"
check_contains "then the logging" "$out" "7 . How much to log"
check_contains "the review panel names the tunnel" "$out" "Ready to create"
check_contains "and says no when told no" "$out" "cancelled, nothing was written"
check "nothing was written on no" "$(ls "$CFG_DIR" | wc -l | tr -d ' ')" "0"

section "a TCP tunnel is asked its direction and its port, and no link"

out=$(answers 1 1 1 185.31.8.129 46.247.109.83 "" "" "443,udp:500" 3 3 n | new_tunnel 2>&1)
check_contains "the direction question comes after the transport" "$out" "3 . Link direction"
check_contains "then the addresses" "$out" "4 . Addresses"
check_contains "then the port" "$out" "5 . Port"
check_missing "a forward tunnel has no private link" "$out" "Private link"
check_contains "the review shows the ports" "$out" "443 udp:500"

section "q leaves without building anything"

out=$(answers 1 1 q | new_tunnel 2>&1)
check "nothing was written on q" "$(ls "$CFG_DIR" | wc -l | tr -d ' ')" "0"
check_missing "and no later question was asked" "$out" "Addresses"

section "the first server builds a [TUN] ICMP tunnel"

if [ -z "$CORE" ]; then
    skip "the icmp wizard" "no core could be built"
else
    out=$(answers 1 12 185.31.8.129 46.247.109.83 "" "" "" "3030" 3 3 y | new_tunnel 2>&1)
    f=$CFG_DIR/iran-icmp-1.toml
    if [ ! -f "$f" ]; then
        FAIL=$((FAIL + 1))
        printf '    \033[31mx\033[0m no config was written\n'
        printf '%s\n' "$out" | tail -15 | sed 's/^/        /'
    else
        check "the name carries the side, the transport and the octet" "$(val "$f" tunnel name)" "iran-icmp-1"
        check "the side is iran" "$(val "$f" tunnel side)" "iran"
        check "the mode is tun" "$(val "$f" tunnel mode)" "tun"
        check "the transport is icmp" "$(val "$f" transport type)" "icmp"
        check "iran's address" "$(val "$f" transport iran)" "185.31.8.129"
        check "kharej's address" "$(val "$f" transport kharej)" "46.247.109.83"
        check "icmp is not asked its direction, and IRAN sends first" "$(val "$f" transport dials)" "iran"
        check "there is no port line for icmp" "$(val "$f" transport port)" ""
        check "the link addresses come from the octet" "$(val "$f" tun iran)" "10.1.10.1/24"
        check "on both sides" "$(val "$f" tun kharej)" "10.1.10.2/24"
        check "the device" "$(val "$f" tun name)" "pfy0"
        check "the mtu default" "$(val "$f" tun mtu)" "1320"
        check "the ports went into the file" "$(val "$f" forward ports)" '["3030"]'
        check "and into the forwards state on IRAN" "$(forwards_of iran-icmp-1 | tr '\n' ' ')" "3030 "
        check "the preset" "$(val "$f" tuning profile)" "balanced"
        check "the logging level" "$(val "$f" logging level)" "info"
        check "the status port" "$(val "$f" status port)" "19900"
        check "the health port" "$(val "$f" status health_port)" "19999"
        tok=$(val "$f" security token)
        check "the token was generated" "$([ "${#tok}" -ge 16 ] && echo long)" "long"
        check "the core accepts it" "$("$CORE" -c "$f" -check >/dev/null 2>&1 && echo yes || echo no)" "yes"
        check_contains "the wizard printed a token for the other server" "$out" "PFY3."
        check_contains "and said which server to take it to" "$out" "Now the KHAREJ server"
        TOKEN=$(printf '%s\n' "$out" | grep -o 'PFY3\.[A-Za-z0-9+/=]*' | head -1)
        check "the token is short enough to paste over a phone" "$([ "${#TOKEN}" -lt 700 ] && echo short)" "short"
    fi
fi

section "the second server finishes the pair from the token"

if [ -z "$CORE" ] || [ -z "${TOKEN:-}" ]; then
    skip "the paste path" "no token from the first half"
else
    IRAN_FILE=$CFG_DIR/iran-icmp-1.toml
    IRAN_DIR=$CFG_DIR
    KH_DIR=$SANDBOX/etc2
    mkdir -p "$KH_DIR" "$SANDBOX/var2"
    CFG_DIR=$KH_DIR STATE_DIR=$SANDBOX/var2
    out=$(answers 3 "$TOKEN" y | new_tunnel 2>&1)
    kf=$KH_DIR/kharej-icmp-1.toml
    if [ ! -f "$kf" ]; then
        FAIL=$((FAIL + 1))
        printf '    \033[31mx\033[0m the paste wrote no config\n'
        printf '%s\n' "$out" | tail -15 | sed 's/^/        /'
    else
        check "the side flipped" "$(val "$kf" tunnel side)" "kharej"
        check "and the name with it" "$(val "$kf" tunnel name)" "kharej-icmp-1"
        check "the token is the same" "$(val "$kf" security token)" "$(val "$IRAN_FILE" security token)"
        check "the core accepts it too" "$("$CORE" -c "$kf" -check >/dev/null 2>&1 && echo yes || echo no)" "yes"
        d=$(diff <(sed 's/[[:space:]]*#.*$//; s/ *= */ = /' "$IRAN_FILE") <(sed 's/[[:space:]]*#.*$//; s/ *= */ = /' "$kf") | grep '^>' | sed 's/^> //' | tr '
' '|')
        check "only the side and the name differ" "$d" 'name = "kharej-icmp-1"|side = "kharej"|'
        check_contains "the paste told the person which side this is" "$out" "this is the KHAREJ side"
        check_contains "and said both are done" "$out" "Both servers are set up"
    fi
    CFG_DIR=$IRAN_DIR STATE_DIR=$SANDBOX/var
fi

section "what is taken is refused"

if [ -z "$CORE" ]; then
    skip "collisions" "no core could be built"
else
    # The octet 1 belongs to the tunnel above; the wizard must refuse it and
    # offer the next one as the default.
    out=$(answers 1 9 "" 185.31.8.129 46.247.109.83 "" 1 "" "" "" "3031" 3 3 n | new_tunnel 2>&1)
    check_contains "a taken network is listed" "$out" "10.1.10.0/24"
    check_contains "and refused" "$out" "already belongs to iran-icmp-1"
    check_contains "the next free one is taken" "$out" "10.2.10.1/24"
    check_contains "a forwarded port is listed as taken" "$out" "3030"

    # A port already forwarded by another tunnel is refused at the Ports question.
    out=$(answers 1 1 1 185.31.8.129 46.247.109.83 "" "" "3030" "3031" 3 3 n | new_tunnel 2>&1)
    check_contains "a port another tunnel forwards is refused" "$out" "already forwarded by the tunnel iran-icmp-1"
    check_contains "and the next answer is taken" "$out" "3031"

    # An empty ports answer is an error, not a tunnel with no ports.
    out=$(answers 1 1 1 185.31.8.129 46.247.109.83 "" "" "" "3032" 3 3 n | new_tunnel 2>&1)
    check_contains "no ports is refused" "$out" "at least one port is required"

    # A tunnel port another tunnel here waits on is refused for a second one.
    answers 1 1 2 185.31.8.129 46.247.109.83 8443 "" "3040" 3 3 y | new_tunnel >/dev/null 2>&1
    check "a tcp tunnel that waits here was built" "$(val "$CFG_DIR/iran-tcp-8443.toml" transport dials)" "kharej"
    out=$(answers 1 1 2 185.31.8.129 46.247.109.83 8443 8444 "" "3041" 3 3 n | new_tunnel 2>&1)
    check_contains "its port is listed as taken" "$out" "8443/tcp"
    check_contains "and refused for a second tunnel" "$out" "already the tunnel port of iran-tcp-8443"
fi

section "the token survives the trip"

if [ -z "$CORE" ]; then
    skip "token round trip" "no core could be built"
else
    cfg_load iran-tcp-8443
    t=$(cfg_setup_token)
    cfg_reset
    setup_token_read "$t" || { FAIL=$((FAIL + 1)); printf '    \033[31mx\033[0m %s\n' "$SETUP_TOKEN_ERROR"; }
    check "the transport came back" "$T_TRANSPORT" "tcp"
    check "the dials came back" "$T_DIALS" "kharej"
    check "the port came back" "$T_PORT" "8443"
    check "the forwards came back" "$T_FORWARDS" "3040"
    check "the addresses came back" "$T_IRAN/$T_KHAREJ" "185.31.8.129/46.247.109.83"
    check "the token came back" "$T_TOKEN" "$(val "$CFG_DIR/iran-tcp-8443.toml" security token)"
    check_rc "a damaged token is refused" 1 setup_token_read "${t:0:60}"
    check_rc "a line that is not a token is refused" 1 setup_token_read "hello there"

    # A 2.2.0 token carries the whole file; it is still accepted.
    body=$(cat "$CFG_DIR/iran-tcp-8443.toml")
    sum=$(printf '%s\n' "$body" | wiz_sha256)
    old="PFY2.$( { printf '%s|' "$sum"; printf '%s\n' "$body"; } | base64 | tr -d '\n')"
    cfg_reset
    setup_token_read "$old" || { FAIL=$((FAIL + 1)); printf '    \033[31mx\033[0m %s\n' "$SETUP_TOKEN_ERROR"; }
    check "an old full-file token is read" "$T_NAME/$T_TRANSPORT/$T_PORT" "iran-tcp-8443/tcp/8443"
fi

section "the file reads back into the same values"

if [ -z "$CORE" ]; then
    skip "cfg_load" "no core could be built"
else
    cfg_load iran-icmp-1
    check "the octet" "$T_OCTET" "1"
    check "this server's link address" "$T_TUNLOCAL" "10.1.10.1/24"
    check "the other one's" "$T_TUNPEER" "10.1.10.2/24"
    check "the forwards" "$T_FORWARDS" "3030"
    check "the health port" "$T_HEALTH" "19999"
    check "the public addresses by side" "$T_PUBLIC_IP/$T_PEER_IP" "185.31.8.129/46.247.109.83"
fi

section "enter takes Reverse, and only a transport with a direction is asked"

if [ -z "$CORE" ]; then
    skip "the direction default" "no core could be built"
else
    out=$(answers 1 1 "" 185.31.8.129 46.247.109.83 9643 "" "3090" 3 3 y | new_tunnel 2>&1)
    f=$CFG_DIR/iran-tcp-9643.toml
    check "enter at the direction question makes KHAREJ dial" "$(val "$f" transport dials)" "kharej"
    check_contains "Reverse is the one marked as the default" "$out" "KHAREJ connects in to IRAN  (default)"
    check_contains "the port question says who listens" "$out" "IRAN listens, KHAREJ connects"
    check_contains "the review names the direction and what this end does" "$out" "Reverse - waits for 46.247.109.83"
    check "the core accepts it" "$("$CORE" -c "$f" -check >/dev/null 2>&1 && echo yes || echo no)" "yes"
    TOKEN=$(printf '%s\n' "$out" | grep -o 'PFY3\.[A-Za-z0-9+/=]*' | head -1)
    KEEP_CFG=$CFG_DIR KEEP_STATE=$STATE_DIR
    mkdir -p "$SANDBOX/etc3" "$SANDBOX/var3"
    CFG_DIR=$SANDBOX/etc3 STATE_DIR=$SANDBOX/var3
    out=$(answers 3 "$TOKEN" y n | new_tunnel 2>&1)
    check_contains "the other server says the same word for the same tunnel" "$out" "Reverse - connects to 185.31.8.129"
    CFG_DIR=$KEEP_CFG STATE_DIR=$KEEP_STATE

    out=$(answers 1 7 185.31.8.129 46.247.109.83 "" "" "" "3091" 3 3 n | new_tunnel 2>&1)
    check_missing "GRE is not asked which end dials" "$out" "Link direction"

    # The Tuning screen marks what runs as the default, so enter has to keep
    # it - and keep it without the restart an applied change costs. Items on
    # a TCP tunnel: 1 profile, 5 link direction, 0 back.
    f=$CFG_DIR/iran-tcp-9643.toml
    out=$(answers 1 5 "" 5 "" "" 1 "" "" 0 | tuning_menu iran-tcp-9643 2>&1)
    check "a profile chosen under Tuning is applied" "$(val "$f" tuning profile)" "max"
    check_contains "the direction is offered with the running one marked" "$out" "KHAREJ connects in to IRAN  (default)"
    check "enter at the direction keeps Reverse" "$(val "$f" transport dials)" "kharej"
    check "enter at the profile keeps max, rather than putting back balanced" "$(val "$f" tuning profile)" "max"
    check "and both said nothing changed" "$(printf '%s\n' "$out" | grep -c 'unchanged')" "2"
    answers 5 1 "" 0 | tuning_menu iran-tcp-9643 >/dev/null 2>&1
    check "a direction chosen under Tuning is applied" "$(val "$f" transport dials)" "iran"
fi

section "a WSS tunnel behind a Cloudflare domain, either way round"

if [ -z "$CORE" ]; then
    skip "the domain wizard" "no core could be built"
else
    # Reverse: the domain fronts IRAN, which waits on 80 behind the edge. Its
    # backups cannot go where it goes - Cloudflare carries WebSocket alone -
    # so they go to IRAN's own IP: another protocol on another road, which is
    # what is left the day WebSocket or the domain is blocked.
    out=$(answers 1 3 "" wd.example.com 46.247.109.83 "" "5,4" 198.51.100.15 "3092" 3 3 y | new_tunnel 2>&1)
    f=$CFG_DIR/iran-wss-443.toml
    check_contains "the addresses step says IRAN's may be the domain" "$out" "IRAN's may be a Cloudflare domain"
    check_contains "and how Cloudflare has to be set" "$out" "SSL/TLS on Flexible"
    check_contains "IRAN is told it listens on 80" "$out" "behind Cloudflare this end listens on 80"
    check_contains "backups are offered behind a domain too" "$out" "In the order to try them"
    check_contains "and why they go to an IP" "$out" "backups skip Cloudflare and go to the server's own IP"
    check "IRAN's address is the domain" "$(val "$f" transport iran)" "wd.example.com"
    check "the waiting end listens on 80" "$(val "$f" transport listen_port)" "80"
    check "KHAREJ dials" "$(val "$f" transport dials)" "kharej"
    check "the backups go to IRAN's IP, and skip 445, which providers filter" "$(toml_arr "$f" failover backups)" "fallback:444@198.51.100.15 utls:446@198.51.100.15"
    check_contains "the review says where they go" "$out" "Decoy TLS MUX 444/tcp to 198.51.100.15"
    check "the core accepts it" "$("$CORE" -c "$f" -check >/dev/null 2>&1 && echo yes || echo no)" "yes"
    cfg_load iran-wss-443
    t=$(cfg_setup_token)
    cfg_reset
    setup_token_read "$t" || { FAIL=$((FAIL + 1)); printf '    [31mx[0m %s
' "$SETUP_TOKEN_ERROR"; }
    check "the IP travels in the token" "$T_BACKUPS" "fallback:444@198.51.100.15 utls:446@198.51.100.15"
    check "a backup with an IP still holds its port here" "$(tunnel_port_owner 446 utls)" "iran-wss-443"
    # Manage > Failover asks again, the IP it had offered as the default and
    # a backup kept keeping its port.
    out=$(answers 1 4 "" "" 0 | failover_menu iran-wss-443 2>&1)
    check "a backup chosen again keeps its port and its IP" "$(toml_arr "$f" failover backups)" "utls:446@198.51.100.15"
    out=$(answers 1 4 wd.example.com "" 0 | failover_menu iran-wss-443 2>&1)
    check_contains "the domain itself is refused as the backups' IP" "$out" "a name may lead to Cloudflare again"

    # Direct: the domain fronts KHAREJ, which waits - and the paste there has
    # to name 80, the port the core really binds, not the one dialled.
    out=$(answers 1 3 1 185.31.8.129 wd2.example.com 2053 "" "3093" 3 3 y | new_tunnel 2>&1)
    f=$CFG_DIR/iran-wss-2053.toml
    check_contains "Direct says KHAREJ's may be the domain" "$out" "KHAREJ's may be a Cloudflare domain"
    check "KHAREJ's address is the domain" "$(val "$f" transport kharej)" "wd2.example.com"
    check "the waiting end listens on 80" "$(val "$f" transport listen_port)" "80"
    check "the core accepts it" "$("$CORE" -c "$f" -check >/dev/null 2>&1 && echo yes || echo no)" "yes"
    TOKEN=$(printf '%s\n' "$out" | grep -o 'PFY3\.[A-Za-z0-9+/=]*' | head -1)
    KEEP_CFG=$CFG_DIR KEEP_STATE=$STATE_DIR
    mkdir -p "$SANDBOX/etc4" "$SANDBOX/var4"
    CFG_DIR=$SANDBOX/etc4 STATE_DIR=$SANDBOX/var4
    out=$(answers 3 "$TOKEN" y n | new_tunnel 2>&1)
    check_contains "the KHAREJ paste says to open 80, where it listens" "$out" "leave 80/tcp open"
    check_missing "and not the port dialled" "$out" "leave 2053/tcp open"
    CFG_DIR=$KEEP_CFG STATE_DIR=$KEEP_STATE

    out=$(answers 1 3 "" wd3.example.com 46.247.109.83 8080 "3094" 3 3 n | new_tunnel 2>&1)
    check_contains "WSS on a port Cloudflare serves no TLS on is warned about" "$out" "Cloudflare does not carry WSS MUX on port 8080"
    check_contains "with the ports that work" "$out" "use one of: 443 2053 2083 2087 2096 8443"
    out=$(answers 1 3 "" 185.31.8.129 46.247.109.83 29443 "" "3095" 3 3 n | new_tunnel 2>&1)
    check_missing "between bare addresses any port is fine" "$out" "Cloudflare does not carry"
    check_contains "and backups are offered" "$out" "In the order to try them"
fi

section "a KCP tunnel forwards ports, and its port is a udp one"

if [ -z "$CORE" ]; then
    skip "the kcp wizard" "no core could be built"
else
    out=$(answers 1 6 1 185.31.8.129 46.247.109.83 "" "" "3060" 3 3 y | new_tunnel 2>&1)
    f=$CFG_DIR/iran-kcp-8443.toml
    if [ ! -f "$f" ]; then
        FAIL=$((FAIL + 1))
        printf '    \033[31mx\033[0m no kcp config was written\n'
        printf '%s\n' "$out" | tail -15 | sed 's/^/        /'
    else
        check "the transport is kcp" "$(val "$f" transport type)" "kcp"
        check "it forwards rather than building a link" "$(val "$f" tunnel mode)" "forward"
        # Sixteen since 1.1.0: measured, a small stream under an eight stream
        # download answers in 160 ms with sixteen and stalls with eight
        # (docs/measured.md section 39).
        check "it has connections like the other stream transports" "$(val "$f" transport connections)" "16"
        check_contains "the review names it" "$out" "KCP MUX"
        check_contains "and says its port is udp" "$out" "udp/8443"
        check "the core accepts it" "$("$CORE" -c "$f" -check >/dev/null 2>&1 && echo yes || echo no)" "yes"
        check "its port is a udp port, apart from tcp/8443" "$(port_family kcp)" "udp"
        cfg_load iran-kcp-8443
        t=$(cfg_setup_token)
        cfg_reset
        setup_token_read "$t" || { FAIL=$((FAIL + 1)); printf '    \033[31mx\033[0m %s\n' "$SETUP_TOKEN_ERROR"; }
        check "a kcp token is read back" "$T_TRANSPORT/$T_MODE" "kcp/forward"
    fi
fi

section "a forward tunnel can be given backups, and they travel in the token"

if [ -z "$CORE" ]; then
    skip "the failover wizard" "no core could be built"
else
    out=$(answers 1 1 2 185.31.8.129 46.247.109.83 9443 "6,4" "3070" 3 3 y | new_tunnel 2>&1)
    f=$CFG_DIR/iran-tcp-9443.toml
    if [ ! -f "$f" ]; then
        FAIL=$((FAIL + 1))
        printf '    \033[31mx\033[0m no config with backups was written\n'
        printf '%s\n' "$out" | tail -15 | sed 's/^/        /'
    else
        check_contains "the backups question is asked of a forward tunnel" "$out" "Backups"
        check "kcp shares the tunnel's number, being udp; chrome tls takes the next" "$(toml_arr "$f" failover backups)" "kcp:9443 utls:9444"
        check "the timings are written as numbers" "$(val "$f" failover switch_after_sec)/$(val "$f" failover return_after_sec)" "25/120"
        check_contains "the review shows the order" "$out" "KCP MUX 9443/udp, then Chrome TLS MUX 9444/tcp"
        check "the core accepts it" "$("$CORE" -c "$f" -check >/dev/null 2>&1 && echo yes || echo no)" "yes"
        check "the backup ports count as taken" "$(tunnel_port_owner 9444 utls)" "iran-tcp-9443"
        check "and a udp backup only in its own family" "$(tunnel_port_owner 9443 kcp)/$(tunnel_port_owner 9443 tcp)" "iran-tcp-9443/iran-tcp-9443"
        cfg_load iran-tcp-9443
        t=$(cfg_setup_token)
        cfg_reset
        setup_token_read "$t" || { FAIL=$((FAIL + 1)); printf '    \033[31mx\033[0m %s\n' "$SETUP_TOKEN_ERROR"; }
        check "the backups came back from the token" "$T_BACKUPS" "kcp:9443 utls:9444"
    fi

    out=$(answers 1 12 185.31.8.129 46.247.109.83 "" "" "" "3071" 3 3 n | new_tunnel 2>&1)
    check_missing "a private link is not asked for backups" "$out" "Backups"

    out=$(answers 1 1 2 185.31.8.129 46.247.109.83 9543 "1" "6,6" "6" "3072" 3 3 n | new_tunnel 2>&1)
    check_contains "the transport it already runs on is refused as a backup" "$out" "already runs on"
    check_contains "and so is a backup named twice" "$out" "in the list twice"
fi

section "the failover screen says what carries, checks the backups, and moves the tunnel"

# A KHAREJ tunnel shaped like the user's pair: Decoy TLS straight to Iran, a
# WSS backup through a domain and a Chrome TLS one. The core's status port is
# a stub that answers the way the core does, and writes down what it was
# asked, so what is checked is what the screen sends and shows.
fo_file() { # side
    cat > "$CFG_DIR/fo-$1.toml" <<EOF
[tunnel]
name = "fo-$1"
side = "$1"
mode = "forward"
[transport]
type = "fallback"
iran = "198.51.100.15"
kharej = "203.0.113.167"
port = 443
dials = "kharej"
[security]
token = "a token for the failover screen"
[forward]
ports = ["8002"]
[status]
port = 19998
[failover]
backups = ["wss:2083@edge.example.com", "utls:2053"]
enabled = true
prefer = "order"
switch_after_sec = 25
return_after_sec = 120
EOF
}
fo_file kharej
fo_file iran
_fo_asked=$SANDBOX/fo-asked
curl() {
    local a
    for a in "$@"; do case $a in http://*) printf '%s' "$a" >>"$_fo_asked" ;; esac; done
    case "$*" in *" -d "*) printf ' %s' "$(printf '%s\n' "$@" | grep -A1 -x -- -d | tail -1)" >>"$_fo_asked" ;; esac
    printf '\n' >>"$_fo_asked"
    case "$*" in
    *"/failover/check"*) printf '2 of 2 answered\n0 fallback 443 - use - 0 ok 71\n\n200' ;;
    *"/failover/use"*) printf 'moved to wss, and held there\n\n200' ;;
    *"/failover/auto"*) printf 'deciding alone again\n\n200' ;;
    *"/failover"*) printf '%b' "$_fo_lines" ;;
    *) return 1 ;;
    esac
}
# The side that dials tries members and knows how they did; the side that
# waits only knows which one carries.
_fo_lines='0 fallback 443 - use - 0 ok 71\n1 wss 2083 edge.example.com - - 190 ok 98\n2 utls 2053 - - - 400 no -\n'
: >"$_fo_asked"

fo_live fo-kharej
check "the core's lines are read, a member to each" "${#FO_KIND[@]}/${FO_KIND[1]}/${FO_HOST[1]}/${FO_RTT[0]}" "3/wss/edge.example.com/71"
check "the member in use says so, with the tunnel's own round trip" "$(fo_state 0)" "carrying now, 71 ms round trip"
check "a backup that answered says when and how fast" "$(fo_state 1)" "answered in 98 ms, 3 min ago"
check "and one that did not, says that" "$(fo_state 2)" "did not answer, 6 min ago"
check "each is named where it goes" "$(fo_label 1)" "WSS MUX 2083/tcp to edge.example.com"
ST_ACTIVE=fallback
check "the tunnel's menu says what carries" "$(failover_hint "$CFG_DIR/fo-kharej.toml")" "on Decoy TLS MUX - 2 backups"
ST_ACTIVE=

out=$(answers 0 | failover_menu fo-kharej 2>&1)
check_contains "the screen shows what carries now" "$out" "carrying now, 71 ms round trip"
check_contains "and offers to check the backups" "$out" "Check them now"
check_contains "and to move" "$out" "Move now"

: >"$_fo_asked"
out=$(answers 6 2 y "" 0 | failover_menu fo-kharej 2>&1)
check_contains "moving to backup 1, held, asks the core for member 1 held" "$(cat "$_fo_asked")" "/failover/use to=1&stay=1"
check_contains "and says what the core answered" "$out" "moved to wss, and held there"

: >"$_fo_asked"
out=$(answers 5 "" 0 | failover_menu fo-kharej 2>&1)
check_contains "checking asks the core to" "$(cat "$_fo_asked")" "/failover/check"
check_contains "and says what came of it" "$out" "2 of 2 answered"

_fo_lines='0 fallback 443 - use - - - -\n1 wss 2083 - - - - - -\n2 utls 2053 - - - - - -\n'
out=$(answers 0 | failover_menu fo-iran 2>&1)
check_contains "the side that waits says the other side decides" "$out" "KHAREJ dials, and decides which of them carries"
check_missing "and offers no move of its own" "$out" "Move now"
check_contains "its backups are listening" "$out" "listening here"

# Choosing the backups again keeps each one's address of its own: the WSS one
# through the domain lost it before, beside a primary that dials an IP.
cfg_load fo-kharej
BK_HOST=
backups_from "4,3"
check "a backup chosen again keeps its domain" "$T_BACKUPS" "utls:2053 wss:2083@edge.example.com"
cfg_reset
unset -f curl
curl() { return 1; }
rm -f "$CFG_DIR/fo-kharej.toml" "$CFG_DIR/fo-iran.toml"

section "a kernel-carried GRE FOU tunnel"

if [ -z "$CORE" ]; then
    skip "the grefou wizard" "no core could be built"
else
    out=$(answers 1 8 y 185.31.8.129 46.247.109.83 29501 "" "" "" "3080" 3 3 y | new_tunnel 2>&1)
    f=$CFG_DIR/iran-grefou-29501.toml
    if [ ! -f "$f" ]; then
        FAIL=$((FAIL + 1))
        printf '    \033[31mx\033[0m no grefou config was written\n'
        printf '%s\n' "$out" | tail -15 | sed 's/^/        /'
    else
        check "the transport is grefou" "$(val "$f" transport type)" "grefou"
        check "it is a private link" "$(val "$f" tunnel mode)" "tun"
        check "the port is the one the kernel wraps it in" "$(val "$f" transport port)" "29501"
        check "the mtu is the one this encapsulation fits" "$(val "$f" tun mtu)" "1400"
        check "its port is a udp port" "$(port_family grefou)" "udp"
        check_contains "the wizard says what it gives up" "$out" "no token on the wire"
        check_contains "and what it changes on the server" "$out" "generic receive offload"
        check_missing "a kernel link is not asked which end dials" "$out" "Link direction"
        check "the core accepts it" "$("$CORE" -c "$f" -check >/dev/null 2>&1 && echo yes || echo no)" "yes"
        cfg_load iran-grefou-29501
        t=$(cfg_setup_token)
        cfg_reset
        setup_token_read "$t" || { FAIL=$((FAIL + 1)); printf '    \033[31mx\033[0m %s\n' "$SETUP_TOKEN_ERROR"; }
        check "it survives the token" "$T_TRANSPORT/$T_MODE/$T_PORT" "grefou/tun/29501"
    fi
fi

section "each key is written only where something reads it"

# The file's own promise is that what the tunnel runs with is what the file
# says, and in 1.1.0 that meant taking keys out of files that never read them
# and, twice in the same week, putting send_batch back where a carrier had
# started to. Pinned here so the next change to any of it is deliberate. The
# reasons are docs/measured.md sections 7, 35, 36 and 37.
_render() {
    cfg_reset
    T_NAME=t T_SIDE=iran T_TRANSPORT=$1 T_MODE=$(mode_of "$1") T_PRESET=throughput
    T_IRAN=198.51.100.7 T_KHAREJ=203.0.113.9 T_PORT=443 T_DIALS=iran T_PATH=/p
    T_TOKEN=t T_OCTET=9 T_TUNIF=pfy0 T_FORWARDS=443 T_LOG=info T_CONNS=16 T_AWG_PORT=20909
    cfg_render
}
for t in gre icmp rawtcp udp; do
    check_contains "$t is told how many packets to batch" "$(_render $t)" "send_batch"
done
# awg runs the udp carrier but is held at one per call until it is measured.
for t in awg grefou tcp ws wss utls fallback kcp; do
    check_missing "$t is not told a batch it would not use" "$(_render $t)" "send_batch"
done
# The profile's receive queue reaches a socket only on the datagram carriers;
# a TCP socket keeps the kernel's own auto-tuning, and kcp states its floor.
for t in tcp ws wss utls fallback grefou; do
    check_missing "$t has no receive queue in its file" "$(_render $t)" "rcvbuf_kb"
done
check_contains "kcp's file says the floor it really gets" "$(_render kcp)" "8192"
check_contains "udp's file says the throughput profile's queue" "$(_render udp)" "3072"
_renderw() { _render wss >/dev/null; T_INSECURE=true; cfg_render; }
check_contains "a wss file that said insecure = true keeps it through a rewrite" "$(_renderw)" "insecure         = true"
check_contains "and one that said nothing gets false" "$(_render wss)" "insecure         = false"
# The two profiles of 1.1.0: what they choose is in the file, where read.
_renderp() { local t=$1 pr=$2; T_PRESET_OVERRIDE=$pr; cfg_reset; T_NAME=t T_SIDE=iran T_TRANSPORT=$t T_MODE=$(mode_of "$t") T_PRESET=$pr T_CONNS=$(preset_conns "$pr") T_FEC=$(preset_fec "$pr") T_IRAN=198.51.100.7 T_KHAREJ=203.0.113.9 T_PORT=443 T_DIALS=iran T_TOKEN=t T_OCTET=9 T_TUNIF=pfy0 T_FORWARDS=443 T_LOG=info; cfg_render; }
check_contains "max gives a TCP carrier 32 connections" "$(_renderp tcp max)" "connections      = 32"
check_contains "stable gives it 24" "$(_renderp tcp stable)" "connections      = 24"
check_contains "stable turns parity on for udp" "$(_renderp udp stable)" "fec              = 10"
check_missing "but not for gre, where parity stops it dead" "$(_renderp gre stable)" "fec"
check_contains "max gives a private link the deep receive queue" "$(_renderp udp max)" "rcvbuf_kb        = 3072"
check_contains "balanced stays at 16 and 256" "$(_renderp udp balanced)" "rcvbuf_kb        = 256"
# Parity where a carrier can rebuild from it: not gre, whose header parity
# stops dead, not grefou, whose bytes this core never touches.
for t in udp icmp rawtcp awg kcp; do
    check_contains "$t can be given parity" "$(_render $t)" "fec"
done
for t in gre grefou tcp ws wss utls fallback; do
    check_missing "$t is not offered parity it cannot use" "$(_render $t)" "fec"
done
# GRE FOU: the kernel moves it, so its whole [tuning] table is the profile.
_g=$(_render grefou)
for k in queue_packets pace dscp keepalive_sec write_workers; do
    check_missing "grefou has no $k" "$_g" "$k"
done
check_contains "grefou keeps the profile the two ends compare" "$_g" "profile"
check_contains "grefou keeps the device queue it now applies" "$_g" "txqueuelen"
# The TLS keys only where they are read, and with the value they run with.
check_missing "fallback carries no insecure line" "$(_render fallback)" "insecure"
check_contains "utls says verification is off, which it is" "$(_render utls)" "insecure         = true"
# Where a CDN can front it, the port the waiting end really binds.
check_contains "ws writes the port it binds" "$(_render ws)" "listen_port"
check_missing "tcp has no second port to state" "$(_render tcp)" "listen_port"

section "a file from 2.x is rewritten in the current shape on upgrade"

# The file in the operator's editor: a 2.3.0 header, a note beside every key,
# the keys at their defaults commented out. Rewritten, it has to be two
# columns and nothing else, with every value it carried still in it.
if [ -z "$CORE" ]; then
    skip "config rewrite" "no core could be built"
else
    _old=$CFG_DIR/kharej-icmp-1.toml
    cat >"$_old" <<'TOML'
# Pingify 2.3.0
#
# The same file runs on both servers; only side and name differ.

[tunnel]
name = "kharej-icmp-1"                # what the manager and the logs call this tunnel
side = "kharej"                       # which server this file is on
mode = "tun"                          # tun: a private network between the two servers

[transport]
type = "icmp"                         # forward: tcp ws wss utls fallback   tun: icmp gre udp rawtcp awg
kharej = "144.31.63.245"              # the server abroad
iran = "185.31.8.129"                 # the Iran server
# port                    # none: this transport has no port and nothing to open
dials = "iran"                        # which side opens the connection
# keepalive_sec = 10                  # seconds between keepalives

[security]
token = "q7Wm2xRt9LpKc4Zv8NhBd3Ys"    # the same on both servers

[tuning]
profile = "balanced"                  # gaming | balanced | download
queue_packets = 900 # the queue depth the profile chose
rcvbuf_kb = 256 # the carrier socket's receive queue
# sndbuf_kb = 16384                   # its send buffer
# fec = 0                             # one parity packet per this many

[forward]
ports = ["3036"]

[tun]
name = "pfy0"                         # the device on this server
iran = "10.1.10.1/24"                 # IRAN's address on the link
kharej = "10.1.10.2/24"               # KHAREJ's
mtu = 1320                            # inner packet size

[logging]
level = "info"                        # debug | info | warn | error
TOML
    check "it is recognised as the old shape" "$(cfg_old "$_old" && echo old || echo new)" "old"
    # A second old file, the one profile whose name changed in 1.1.0.
    _old2=$CFG_DIR/kharej-icmp-2.toml
    sed 's/kharej-icmp-1/kharej-icmp-2/; s/profile = "balanced"/profile = "download"/' "$_old" > "$_old2"
    cfg_modernise >/dev/null 2>&1
    check "a file that said download now says throughput" "$(val "$_old2" tuning profile)" "throughput"
    check "and got the deep queue that name means" "$(val "$_old2" tuning rcvbuf_kb)" "3072"
    check "the old file is kept beside it" "$([ -f "$_old.old" ] && echo kept || echo gone)" "kept"
    check "it is no longer the old shape" "$(cfg_old "$_old" && echo old || echo new)" "new"
    check "the one note is the line under [tuning]" "$(grep -c '#' "$_old")" "1"
    check "no value carries a note" "$(grep -cE '^[a-z_]+ *=.*#' "$_old")" "0"
    check "[tun] sits under [transport]" "$(grep -nE '^\[(transport|tun|security)\]' "$_old" | cut -d: -f2 | tr '\n' ' ')" "[transport] [tun] [security] "
    check "every value line is two columns" "$(grep -vE '^\[|^$|^#' "$_old" | grep -vcE '^[a-z_]+ += ')" "0"
    check "the token is kept" "$(val "$_old" security token)" "q7Wm2xRt9LpKc4Zv8NhBd3Ys"
    check "the side is kept" "$(val "$_old" tunnel side)" "kharej"
    check "the ports are kept" "$(val "$_old" forward ports)" '["3036"]'
    check "the link addresses are kept" "$(val "$_old" tun iran)/$(val "$_old" tun kharej)" "10.1.10.1/24/10.1.10.2/24"
    check "the mtu is kept" "$(val "$_old" tun mtu)" "1320"
    check "the direction is kept" "$(val "$_old" transport dials)" "iran"
    check "a key nothing reads on icmp is not written" "$(val "$_old" transport connections)" ""
    check "the core accepts what came out" "$("$CORE" -c "$_old" -check >/dev/null 2>&1 && echo yes || echo no)" "yes"
    check "a file already in the current shape is left alone" "$(cfg_old "$CFG_DIR/iran-icmp-1.toml" 2>/dev/null && echo old || echo new)" "new"
fi

report
