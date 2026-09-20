#!/usr/bin/env bash
#
# The wizard, driven through its stdin, the way a person drives it.
#
# The questions, in the order they are asked:
#
#   side  transport  [direction]  this address  other address  [port]
#   [octet  device  mtu]  [ports]  preset  logging  confirm
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

out=$(answers 1 7 185.31.8.129 46.247.109.83 "" "" "" "3030" 2 3 n | new_tunnel 2>&1)
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

out=$(answers 1 1 1 185.31.8.129 46.247.109.83 "" "" "443,udp:500" 2 3 n | new_tunnel 2>&1)
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
    out=$(answers 1 7 185.31.8.129 46.247.109.83 "" "" "" "3030" 2 3 y | new_tunnel 2>&1)
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
        check "IRAN dials out by default" "$(val "$f" transport dials)" "iran"
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
    out=$(answers 1 9 "" 185.31.8.129 46.247.109.83 "" 1 "" "" "" "3031" 2 3 n | new_tunnel 2>&1)
    check_contains "a taken network is listed" "$out" "10.1.10.0/24"
    check_contains "and refused" "$out" "already belongs to iran-icmp-1"
    check_contains "the next free one is taken" "$out" "10.2.10.1/24"
    check_contains "a forwarded port is listed as taken" "$out" "3030"

    # A port already forwarded by another tunnel is refused at the Ports question.
    out=$(answers 1 1 1 185.31.8.129 46.247.109.83 "" "" "3030" "3031" 2 3 n | new_tunnel 2>&1)
    check_contains "a port another tunnel forwards is refused" "$out" "already forwarded by the tunnel iran-icmp-1"
    check_contains "and the next answer is taken" "$out" "3031"

    # An empty ports answer is an error, not a tunnel with no ports.
    out=$(answers 1 1 1 185.31.8.129 46.247.109.83 "" "" "" "3032" 2 3 n | new_tunnel 2>&1)
    check_contains "no ports is refused" "$out" "at least one port is required"

    # A tunnel port another tunnel here waits on is refused for a second one.
    answers 1 1 2 185.31.8.129 46.247.109.83 8443 "" "3040" 2 3 y | new_tunnel >/dev/null 2>&1
    check "a tcp tunnel that waits here was built" "$(val "$CFG_DIR/iran-tcp-8443.toml" transport dials)" "kharej"
    out=$(answers 1 1 2 185.31.8.129 46.247.109.83 8443 8444 "" "3041" 2 3 n | new_tunnel 2>&1)
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

section "a KCP tunnel forwards ports, and its port is a udp one"

if [ -z "$CORE" ]; then
    skip "the kcp wizard" "no core could be built"
else
    out=$(answers 1 6 1 185.31.8.129 46.247.109.83 "" "" "3060" 2 3 y | new_tunnel 2>&1)
    f=$CFG_DIR/iran-kcp-8443.toml
    if [ ! -f "$f" ]; then
        FAIL=$((FAIL + 1))
        printf '    \033[31mx\033[0m no kcp config was written\n'
        printf '%s\n' "$out" | tail -15 | sed 's/^/        /'
    else
        check "the transport is kcp" "$(val "$f" transport type)" "kcp"
        check "it forwards rather than building a link" "$(val "$f" tunnel mode)" "forward"
        check "it has connections like the other stream transports" "$(val "$f" transport connections)" "8"
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
    out=$(answers 1 1 2 185.31.8.129 46.247.109.83 9443 "6,4" "3070" 2 3 y | new_tunnel 2>&1)
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

    out=$(answers 1 7 185.31.8.129 46.247.109.83 "" "" "" "3071" 2 3 n | new_tunnel 2>&1)
    check_missing "a private link is not asked for backups" "$out" "Backups"

    out=$(answers 1 1 2 185.31.8.129 46.247.109.83 9543 "1" "6,6" "6" "3072" 2 3 n | new_tunnel 2>&1)
    check_contains "the transport it already runs on is refused as a backup" "$out" "already runs on"
    check_contains "and so is a backup named twice" "$out" "in the list twice"
fi

section "a kernel-carried GRE FOU tunnel"

if [ -z "$CORE" ]; then
    skip "the grefou wizard" "no core could be built"
else
    out=$(answers 1 12 y 185.31.8.129 46.247.109.83 29501 "" "" "" "3080" 2 3 y | new_tunnel 2>&1)
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

report
