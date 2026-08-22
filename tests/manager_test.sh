#!/usr/bin/env bash
# End-to-end check of the manager's config pipeline.
#
# It sources the generated Pingify.sh, drives the same functions the wizard
# uses, and then runs two real cores against the documents they produce.
# Runs anywhere bash and the Go toolchain do; no root and no Linux needed.
set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0
FAILED=0
check() {
    if [ "$2" = "$3" ]; then
        printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS+1))
    else
        printf '  \033[31mFAIL\033[0m %s\n       want: %s\n       got:  %s\n' "$1" "$3" "$2"
        FAILED=$((FAILED+1))
    fi
}
note() { printf '\n\033[1m%s\033[0m\n' "$*"; }

[ -f Pingify.sh ] || { echo "run build.sh first"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; jobs -p | xargs -r kill 2>/dev/null' EXIT

# shellcheck disable=SC1091
PINGIFY_NO_MAIN=1 . ./Pingify.sh

CFG_DIR="$WORK/etc"
STATE_DIR="$WORK/state"
mkdir -p "$CFG_DIR" "$STATE_DIR"

TOKEN="a shared secret phrase"

# ---------------------------------------------------------------------------
note "forward spec parsing"
# ---------------------------------------------------------------------------
check "single port"      "$(parse_forwards '443')"                 '"443"'
check "comma separated"  "$(parse_forwards '443,2053')"            '"443","2053"'
check "spaces tolerated" "$(parse_forwards '443, 2053 , udp:500')" '"443","2053","udp:500"'
check "ranges kept"      "$(parse_forwards '8000-8010=9000')"      '"8000-8010=9000"'
check "empty input"      "$(parse_forwards '')"                    ''

# ---------------------------------------------------------------------------
note "a TCP tunnel - IRAN side"
# ---------------------------------------------------------------------------
# A TCP tunnel adds nothing to the machine: no private link, no extra
# interface, ports carried by the core over its own connections.
cfg_reset
T_NAME="ir"; T_ROLE="server"; T_KIND="tcp"; T_TRANSPORT="tcp"
T_MODE="forward"; T_FORWARDER="pingify"
T_PORT=9443; T_PUBLIC_IP="203.0.113.9"; T_PEER_IP="198.51.100.4"; T_TOKEN="$TOKEN"
T_FORWARDS='"443","udp:500"'; T_STATUS="127.0.0.1:9700"
apply_preset throughput
iran="$(cfg_save)"

check "name"                  "$(toml_get "$iran" tunnel name)"       "ir"
check "role"                  "$(toml_get "$iran" tunnel role)"       "server"
check "no private link"       "$(toml_get "$iran" tunnel mode)"       "forward"
check "and no [tun] section"  "$(grep -c '^\[tun\]' "$iran")"         "0"
check "protocol"              "$(toml_get "$iran" transport type)"    "tcp"
check "IRAN accepts the link" "$(toml_get "$iran" transport listen)"  "0.0.0.0:9443"
check "and does not dial"     "$(toml_get "$iran" transport connect)" ""
check "token, not a key"      "$(toml_get "$iran" security token)"    "$TOKEN"
check "no psk is written"     "$(grep -c '^psk' "$iran")"             "0"
check "forwarded by the core" "$(toml_get "$iran" forward forwarder)" "pingify"
check "ports"                 "$(toml_arr "$iran" ports)"             '"443","udp:500"'
check "preset carried"        "$(toml_get "$iran" tuning profile)"    "throughput"
check "window from preset"    "$(toml_get "$iran" tuning window_kb)"  "2048"

cfg_load ir
check "cfg_load role"      "$T_ROLE"      "server"
check "cfg_load token"     "$T_TOKEN"     "$TOKEN"
check "cfg_load forwarder" "$T_FORWARDER" "pingify"
check "cfg_load ports"     "$T_FORWARDS"  '"443","udp:500"'
check "cfg_load port"      "$T_PORT"      "9443"
check "cfg_load accepts"   "$T_ACCEPTS"   "server"

# ---------------------------------------------------------------------------
note "a TUN tunnel - the private link"
# ---------------------------------------------------------------------------
cfg_reset
T_NAME="tn"; T_ROLE="server"; T_KIND="tun"; T_TRANSPORT="icmp"
T_MODE="tun"; T_FORWARDER="iptables"
T_PUBLIC_IP="203.0.113.9"; T_PEER_IP="198.51.100.4"; T_TOKEN="$TOKEN"
T_TUNLOCAL="10.10.10.1/24"; T_TUNPEER="10.10.10.2/24"
T_FORWARDS='"443"'; T_STATUS="127.0.0.1:9702"
tun="$(cfg_save)"

check "mode is tun"           "$(toml_get "$tun" tunnel mode)"        "tun"
check "carried over ICMP"     "$(toml_get "$tun" transport type)"     "icmp"
# ICMP has no port, so listen carries the address to answer from. On a
# server with several addresses the kernel would otherwise pick one, and a
# reply from an address the far end is not expecting is thrown away.
check "listens on its own address" "$(toml_get "$tun" transport listen)"  "203.0.113.9"
check "private address"       "$(toml_get "$tun" tun local_addr)"     "10.10.10.1/24"
check "peer private address"  "$(toml_get "$tun" tun remote_addr)"    "10.10.10.2/24"
check "forwarded by iptables" "$(toml_get "$tun" forward forwarder)"  "iptables"

cfg_load tn
check "cfg_load private addr" "$T_TUNLOCAL"  "10.10.10.1/24"
check "cfg_load transport"    "$T_TRANSPORT" "icmp"

# ---------------------------------------------------------------------------
note "the KHAREJ side"
# ---------------------------------------------------------------------------
cfg_reset
T_NAME="kh"; T_ROLE="client"; T_KIND="tcp"; T_TRANSPORT="tcp"; T_MODE="forward"
T_PORT=9443; T_PEER_IP="203.0.113.9"; T_PUBLIC_IP="198.51.100.4"; T_TOKEN="$TOKEN"
T_STATUS="127.0.0.1:9701"
kharej="$(cfg_save)"

check "KHAREJ dials IRAN"   "$(toml_get "$kharej" transport connect)" "203.0.113.9:9443"
check "and does not listen" "$(toml_get "$kharej" transport listen)"  ""
check "same token"          "$(toml_get "$kharej" security token)"    "$TOKEN"
check "no ports on KHAREJ"  "$(grep -c '^ports' "$kharej")"           "0"

cfg_load kh
check "cfg_load accepts" "$T_ACCEPTS" "server"

# ---------------------------------------------------------------------------
note "ICMP needs no port"
# ---------------------------------------------------------------------------
cfg_reset
T_NAME="ic"; T_ROLE="server"; T_TRANSPORT="icmp"; T_TOKEN="$TOKEN"
T_TUNLOCAL="10.20.10.1/24"; T_TUNPEER="10.20.10.2/24"; T_PUBLIC_IP="203.0.113.9"
T_FORWARDS='"443"'; T_STATUS="127.0.0.1:9702"
cfg_endpoints
check "IRAN answers from its own address" "$CFG_LISTEN" "203.0.113.9"

cfg_reset
T_NAME="ic2"; T_ROLE="client"; T_TRANSPORT="icmp"; T_TOKEN="$TOKEN"
T_PEER_IP="203.0.113.9"
cfg_endpoints
check "KHAREJ sends without a port" "$CFG_CONNECT" "203.0.113.9"
check "and nothing is appended"     "$CFG_LISTEN"  ""

# ---------------------------------------------------------------------------
note "an incomplete tunnel names what is missing"
# ---------------------------------------------------------------------------
cfg_reset
T_NAME="broken"; T_ROLE="server"; T_TRANSPORT="tcp"
T_TUNLOCAL="10.10.10.1/24"; T_FORWARDS='"443"'
out="$(cfg_save 2>&1)"; rc=$?
check "refuses without a token" "$rc"                                  "1"
check "and says so"             "$(printf '%s' "$out" | grep -c token)" "1"
check "and writes nothing"      "$([ -f "$(cfg_file broken)" ] && echo yes || echo no)" "no"

cfg_reset
T_NAME="broken2"; T_ROLE="server"; T_TRANSPORT="tcp"; T_TOKEN="$TOKEN"
T_TUNLOCAL="10.10.10.1/24"
out="$(cfg_save 2>&1)"; rc=$?
check "IRAN needs ports"        "$rc"                                   "1"
check "and says which"          "$(printf '%s' "$out" | grep -c ports)" "1"

# ---------------------------------------------------------------------------
note "the core has to match the script"
# ---------------------------------------------------------------------------
GO_BIN="${GO_BIN:-go}"
if ! command -v "$GO_BIN" >/dev/null 2>&1; then
    printf '  \033[33mskip\033[0m live core checks: no Go toolchain\n'
else
    EXT=""; [ "${OS:-}" = "Windows_NT" ] && EXT=".exe"
    CORE_BIN="$WORK/pingify-core$EXT"
    ( cd core && CGO_ENABLED=0 "$GO_BIN" build -o "$CORE_BIN" . ) || { echo "core build failed"; exit 1; }

    check "the shipped core matches" "$("$CORE_BIN" -version | awk '{print $2}')" "$PINGIFY_VERSION"
    real="$PINGIFY_VERSION"
    PINGIFY_VERSION="0.0.0-not-this"
    if core_matches_script; then r=matched; else r=differs; fi
    check "a mismatch is detected" "$r" "differs"
    PINGIFY_VERSION="$real"

    # ---------------------------------------------------------------------
    note "two cores, one token, real traffic"
    # ---------------------------------------------------------------------
    # forward mode rather than both: a private link needs /dev/net/tun, which
    # a developer machine does not necessarily have.
    TP=$(( 20000 + RANDOM % 10000 ))
    LP=$(( 30000 + RANDOM % 10000 ))
    EP=$(( 40000 + RANDOM % 10000 ))
    LIVE_TOKEN="a token typed on both servers"

    cfg_reset
    T_MODE="forward"
    T_NAME="live-ir"; T_ROLE="server"; T_TRANSPORT="tcp"
    T_ACCEPTS="server"; T_PORT="$TP"; T_PUBLIC_IP="127.0.0.1"
    T_TOKEN="$LIVE_TOKEN"; T_CARRIERS=4; T_WINDOW=1024
    T_FORWARDS="$(parse_forwards "$LP=$EP")"
    iran_status="127.0.0.1:$(( 50000 + RANDOM % 5000 ))"
    T_STATUS="$iran_status"
    iran_cfg="$(cfg_save)"

    cfg_reset
    T_MODE="forward"
    T_NAME="live-kh"; T_ROLE="client"; T_TRANSPORT="tcp"
    T_ACCEPTS="server"; T_PORT="$TP"; T_PEER_IP="127.0.0.1"
    T_TOKEN="$LIVE_TOKEN"; T_CARRIERS=4; T_WINDOW=1024
    T_STATUS="127.0.0.1:$(( 55000 + RANDOM % 5000 ))"
    kharej_cfg="$(cfg_save)"

    "$CORE_BIN" -c "$iran_cfg"   -check >/dev/null 2>&1; check "IRAN config validates"   "$?" "0"
    "$CORE_BIN" -c "$kharej_cfg" -check >/dev/null 2>&1; check "KHAREJ config validates" "$?" "0"

    cat > "$WORK/echo.py" <<'PYEOF'
import socket, sys, threading
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(16)
open(sys.argv[2], "w").close()
def serve(c):
    with c:
        while True:
            b = c.recv(65536)
            if not b: return
            c.sendall(b)
while True:
    c, _ = s.accept(); threading.Thread(target=serve, args=(c,), daemon=True).start()
PYEOF
    rm -f "$WORK/ready"
    python "$WORK/echo.py" "$EP" "$WORK/ready" &
    for _ in $(seq 1 50); do [ -f "$WORK/ready" ] && break; sleep 0.1; done

    "$CORE_BIN" -c "$kharej_cfg" >"$WORK/kharej.log" 2>&1 &
    KHAREJ_PID=$!
    "$CORE_BIN" -c "$iran_cfg" >"$WORK/iran.log" 2>&1 &
    IRAN_PID=$!

    up=1
    for _ in $(seq 1 60); do
        if "$CORE_BIN" -healthz "$iran_status" >/dev/null 2>&1; then up=0; break; fi
        sleep 0.2
    done
    check "the link comes up on a typed token" "$up" "0"

    if [ "$up" = "0" ]; then
        for _ in $(seq 1 50); do
            set -- $("$CORE_BIN" -status "$iran_status" -brief)
            [ "${2:-0}" = "4" ] && break
            sleep 0.2
        done
        check "all 4 connections" "${2:-0}" "4"

        cat > "$WORK/xfer.py" <<'PYEOF'
import socket, sys, os
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=15); s.settimeout(20)
payload = os.urandom(1 << 20)
s.sendall(payload); s.shutdown(socket.SHUT_WR)
got = b""
while len(got) < len(payload):
    b = s.recv(65536)
    if not b: break
    got += b
print("match" if got == payload else "mismatch")
PYEOF
        check "1 MiB round trip" "$(python "$WORK/xfer.py" "$LP")" "match"

        # A different token must not get in.
        cfg_reset
        T_MODE="forward"
        T_NAME="live-bad"; T_ROLE="client"; T_TRANSPORT="tcp"
        T_ACCEPTS="server"; T_PORT="$TP"; T_PEER_IP="127.0.0.1"
        T_TOKEN="a completely different token"; T_CARRIERS=1
        T_STATUS="127.0.0.1:$(( 58000 + RANDOM % 1000 ))"
        bad_status="$T_STATUS"
        bad_cfg="$(cfg_save)"
        "$CORE_BIN" -c "$bad_cfg" >"$WORK/bad.log" 2>&1 &
        BAD_PID=$!
        sleep 3
        "$CORE_BIN" -healthz "$bad_status" >/dev/null 2>&1 && r=up || r=refused
        check "a wrong token is refused" "$r" "refused"
        kill "$BAD_PID" 2>/dev/null
    else
        printf '  iran log:\n';   sed 's/^/    /' "$WORK/iran.log"   | tail -n 8
        printf '  kharej log:\n'; sed 's/^/    /' "$WORK/kharej.log" | tail -n 8
    fi

    kill "$IRAN_PID" "$KHAREJ_PID" 2>/dev/null
    wait "$IRAN_PID" "$KHAREJ_PID" 2>/dev/null
fi

# ---------------------------------------------------------------------------
note "downloads work without curl"
# ---------------------------------------------------------------------------
# The install line is written with wget, so wget is the tool most likely to be
# present and curl the one most likely to be missing. Reaching for curl alone
# left a server running an old script beside a core that had just updated -
# the one pairing the two of them cannot work in.
have() { case "$1" in curl) return 1 ;; wget) return 0 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
wget() {
    local out=""
    while [ $# -gt 0 ]; do case "$1" in -O) out="$2"; shift 2 ;; *) shift ;; esac; done
    printf 'downloaded\n' > "$out"
}
fetch "http://example.invalid/x" "$WORK/fetched" 5
check "fetch falls back to wget" "$(cat "$WORK/fetched" 2>/dev/null)" "downloaded"

have() { case "$1" in curl|wget) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
fetch "http://example.invalid/x" "$WORK/none" 5
check "and fails when neither is here" "$?" "1"
unset -f have wget


# ---------------------------------------------------------------------------
note "the setup token carries a whole tunnel"
# ---------------------------------------------------------------------------
# Build one end, decode the token the way the other end decodes it, and check
# the second config comes out right. Both transports, because the endpoint is
# the part that differs and an earlier token silently mangled ICMP - it has no
# port, and the builder was slicing one off the address.

# decode <token> ; fills the TOK_* variables
decode() {
    local raw
    raw="$(printf '%s' "$1" | base64 -d)"
    IFS='|' read -r TOK_V TOK_KIND TOK_TR TOK_MODE TOK_FWD TOK_DIAL TOK_HOST \
                   TOK_PORT TOK_TOKEN TOK_CAR TOK_WIN TOK_KA TOK_SND TOK_RCV \
                   TOK_TL TOK_TP TOK_MTU <<EOF
$raw
EOF
}

# --- TCP, reverse: IRAN accepts, so the peer is told to dial us -------------
cfg_reset
T_NAME="ir"; T_ROLE="server"; T_KIND="tcp"; T_TRANSPORT="tcp"; T_ACCEPTS="server"
cfg_mode
T_TOKEN="$TOKEN"; T_PORT=9443; T_PUBLIC_IP="203.0.113.9"
T_CARRIERS=14; T_WINDOW=1024; T_KEEPALIVE=10; T_SNDBUF=1024; T_RCVBUF=1024
T_FORWARDS='"6526"'; T_STATUS="127.0.0.1:9700"
decode "$(cfg_setup_token)"
check "token version"           "$TOK_V"      "p2"
check "transport travels"       "$TOK_TR"     "tcp"
check "forwarder travels"       "$TOK_FWD"    "pingify"
check "the peer is told to dial" "$TOK_DIAL"  "1"
check "and where"               "$TOK_HOST"   "203.0.113.9"
check "with the port"           "$TOK_PORT"   "9443"
check "the secret travels"      "$TOK_TOKEN"  "$TOKEN"
check "carriers travel"         "$TOK_CAR"    "14"
check "buffers travel"          "$TOK_SND"    "1024"
check "no ports in the token"   "$(printf '%s' "$(cfg_setup_token)" | base64 -d | grep -c 6526)" "0"
check "and it is one line"      "$(cfg_setup_token | wc -l)" "0"

# --- TCP, direct: IRAN dials, so the peer is told to accept -----------------
T_ACCEPTS="client"
decode "$(cfg_setup_token)"
check "direct: peer accepts"    "$TOK_DIAL"   "0"
check "and needs no address"    "$TOK_HOST"   ""

# --- ICMP: no port anywhere -------------------------------------------------
cfg_reset
T_NAME="ic"; T_ROLE="server"; T_KIND="tun"; T_TRANSPORT="icmp"; T_ACCEPTS="server"
cfg_mode
T_TOKEN="$TOKEN"; T_PUBLIC_IP="203.0.113.9"
T_CARRIERS=14; T_WINDOW=1024; T_KEEPALIVE=10; T_SNDBUF=1024; T_RCVBUF=1024
T_TUNLOCAL="10.20.10.1/24"; T_TUNPEER="10.20.10.2/24"; T_TUNMTU=1380
T_FORWARDS='"443"'; T_STATUS="127.0.0.1:9701"
decode "$(cfg_setup_token)"
check "icmp transport travels"  "$TOK_TR"     "icmp"
check "icmp carries no port"    "$TOK_PORT"   ""
check "the address is intact"   "$TOK_HOST"   "203.0.113.9"
check "the private link swaps"  "$TOK_TL"     "10.20.10.2/24"
check "and points back at us"   "$TOK_TP"     "10.20.10.1/24"
check "mtu travels"             "$TOK_MTU"    "1380"

# --- and the config the far end builds from it ------------------------------
cfg_reset
T_KIND="$TOK_KIND"; T_TRANSPORT="$TOK_TR"; T_MODE="$TOK_MODE"
T_FORWARDER="$TOK_FWD"; T_TOKEN="$TOK_TOKEN"
T_CARRIERS="$TOK_CAR"; T_WINDOW="$TOK_WIN"; T_KEEPALIVE="$TOK_KA"
T_SNDBUF="$TOK_SND"; T_RCVBUF="$TOK_RCV"
T_TUNLOCAL="$TOK_TL"; T_TUNPEER="$TOK_TP"; T_TUNMTU="$TOK_MTU"
T_ROLE="client"; T_ACCEPTS="server"; T_PEER_IP="$TOK_HOST"
T_NAME="kharej-icmp"; T_PUBLIC_IP="198.51.100.4"; T_STATUS="127.0.0.1:9702"
kh="$(cfg_save)"
check "the peer file is written" "$(basename "$kh")"                    "kharej-icmp.toml"
check "it sends to IRAN"         "$(toml_get "$kh" transport connect)"  "203.0.113.9"
check "it does not listen"       "$(toml_get "$kh" transport listen)"   ""
check "same secret both ends"    "$(toml_get "$kh" security token)"     "$TOKEN"
check "its end of the link"      "$(toml_get "$kh" tun local_addr)"     "10.20.10.2/24"
check "no ports on KHAREJ"       "$(grep -c '^ports' "$kh")"            "0"
if [ -n "${CORE_BIN:-}" ] && [ -x "${CORE_BIN:-}" ]; then
    "$CORE_BIN" -c "$kh" -check >/dev/null 2>&1
    check "the core accepts it"  "$?"                                   "0"
fi


# ---------------------------------------------------------------------------
note "the wizard's first question"
# ---------------------------------------------------------------------------
# Both new_tunnel and import_tunnel ask which server this is, and an edit that
# meant the wizard landed in the importer instead - which offered a way into
# itself, while the wizard people actually reach offered nothing.
first_q() {
    awk '/^new_tunnel\(\) \{/{f=1} f&&/pick side "select"/{print; exit}' Pingify.sh
}
importer_q() {
    awk '/^import_tunnel\(\) \{/{f=1} f&&/pick side "select"/{print; exit}' Pingify.sh
}
check "the wizard offers three ways in" \
      "$(first_q | grep -c '1 2 3')" "1"
check "the importer offers two"        \
      "$(importer_q | grep -c '1 2$')" "1"
check "and three is the token"         \
      "$(awk '/^new_tunnel\(\) \{/{f=1} f&&/side" = "3"/{print; exit}' Pingify.sh | grep -c import_tunnel)" "1"

# pick has to survive an empty answer and a wrong one without looping forever.
# It shares a name space with ask, and when their locals collided it rejected
# every answer including the right ones.
picked=""
# a pipe would run pick in a subshell and the answer would not come back
pick picked "select" 1 2 >/dev/null 2>&1 < <(printf 'x

2
')
check "pick takes the valid answer" "$picked" "2"


# ---------------------------------------------------------------------------
note "the health check prints a fix under every problem"
# ---------------------------------------------------------------------------
# A report that says something is wrong and stops there leaves you where you
# started. Every failing check has to carry the command or the menu entry that
# addresses it.
HC="$WORK/hc.out"
hc_run() {
    (
        banner() { :; }; pause() { :; }
        svc_state() { printf '%s' "$1_state_stub"; }
        "$@"
    ) > "$HC" 2>&1
}

# a stopped service, a stale core, an unbound port
cfg_reset
T_NAME="sick"; T_ROLE="server"; T_KIND="tcp"; T_TRANSPORT="tcp"; T_ACCEPTS="server"
cfg_mode
T_TOKEN="$TOKEN"; T_PORT=9443; T_PUBLIC_IP="203.0.113.9"; T_PEER_IP="198.51.100.4"
T_FORWARDS='"6526"'; T_STATUS="127.0.0.1:9700"
cfg_save >/dev/null
(
    banner() { :; }; pause() { :; }
    svc_state() { printf 'stopped'; }
    core_matches_script() { return 1; }
    core_version() { printf '1.0.0'; }
    CORE_BIN=/bin/false
    have() { case "$1" in iptables) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
    port_free() { return 0; }
    health_check sick
) > "$HC" 2>&1

check "it reports the stopped service" "$(grep -c 'the service is stopped' "$HC")"   "1"
check "and says how to start it"       "$(grep -c 'systemctl start pingify@sick' "$HC")" "1"
check "it reports the stale core"      "$(grep -c 'against script' "$HC")"           "1"
check "and points at the update"       "$(grep -c 'Update Pingify' "$HC")"           "1"
check "it reports the unbound port"    "$(grep -c 'nothing is listening on :6526' "$HC")" "1"
# the failure marker is ASCII when the console is not talking UTF-8, so count
# the problems off the summary line rather than matching the glyph
hc_probs="$(grep -oE "[0-9]+ problem" "$HC" | head -1 | cut -d" " -f1)"
check "every failure has a fix"        "$hc_probs" "$(grep -c "fix:" "$HC")"
check "and it counts them"             "$(grep -c 'problems' "$HC")"                 "1"

# a healthy tunnel says so and stops
(
    banner() { :; }; pause() { :; }
    svc_state() { printf 'active'; }
    core_matches_script() { return 0; }
    have() { case "$1" in iptables) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
    port_free() { return 1; }
    CORE_BIN="$WORK/hcore"
    printf '#!/bin/sh\ncase "$*" in *-brief*) echo "up 14 14 78.0 0 900";; *-probe*) exit 0;; esac\nexit 0\n' > "$CORE_BIN"
    chmod +x "$CORE_BIN"
    health_check sick
) > "$HC" 2>&1
check "a healthy tunnel says nothing is wrong" "$(grep -c 'nothing wrong on this server' "$HC")" "1"
check "and prints no fixes"                    "$(grep -c 'fix:' "$HC")"                         "0"
check "it names the carriers and the rtt"      "$(grep -c '14 of 14 carriers up' "$HC")"         "1"


# ---------------------------------------------------------------------------
note "the shape of the menus"
# ---------------------------------------------------------------------------
# Nine entries is the cap, service first: the things done most often should
# not be below the things done once.
menu_block() { awk '/^tunnel_menu\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh; }
check "the tunnel menu leads with service" \
      "$(menu_block | grep -m1 -o 'group "[A-Za-z]*"')" 'group "Service"'
check "restart is 1"     "$(menu_block | grep -c 'item 1 "Restart"')"            "1"
check "delete is 4"      "$(menu_block | grep -c 'item 4 "Delete this tunnel"')" "1"
check "and nine at most" "$(menu_block | grep -cE '^        item [1-9] ')"       "9"
check "no letter keys"   "$(menu_block | grep -c 'item d ')"                     "0"
check "the core menu is gone"     "$(grep -c 'Core options' Pingify.sh)"         "0"
check "and nothing still calls it" "$(grep -c 'update_menu' Pingify.sh)"         "0"

# ---------------------------------------------------------------------------
note "the tuning a token carries has a name"
# ---------------------------------------------------------------------------
# "from token" is not a profile. The numbers came from a preset on the other
# server and this one should call it what that one calls it.
check "extreme"  "$(preset_name 24 4096)" "extreme"
check "balanced" "$(preset_name 14 1024)" "balanced"
check "gaming"   "$(preset_name 8 256)"   "gaming"
check "hand-set numbers are custom" "$(preset_name 11 700)" "custom"
check "nothing assigns it" "$(grep -c 'T_PRESET="from token"' Pingify.sh)" "0"

# ---------------------------------------------------------------------------
note "an ICMP tunnel wants the kernel quiet, not loud"
# ---------------------------------------------------------------------------
# This was backwards: the check called a blocked ping a fault and told people
# to turn it off. The transport reads a raw socket, which the kernel copies to
# us whatever icmp_echo_ignore_all says, and both ends send echo replies,
# which the kernel never answers by itself. So the block is wanted.
cfg_reset
T_NAME="ic"; T_ROLE="server"; T_KIND="tun"; T_TRANSPORT="icmp"; T_ACCEPTS="server"
cfg_mode
T_TOKEN="$TOKEN"; T_PUBLIC_IP="203.0.113.9"; T_STATUS="127.0.0.1:9701"
T_TUNLOCAL="10.20.10.1/24"; T_TUNPEER="10.20.10.2/24"; T_TUNMTU=1380
T_FORWARDS='"443"'
cfg_save >/dev/null
(
    banner() { :; }; pause() { :; }
    svc_state() { printf 'stopped'; }
    core_matches_script() { return 0; }
    have() { return 1; }
    port_free() { return 1; }
    sysctl() { printf '1'; }
    CORE_BIN=/bin/true
    health_check ic
) > "$HC" 2>&1
check "a blocked ping is not a fault" "$(grep -c 'which is what we want' "$HC")" "1"
check "and never asks to undo it"     "$(grep -c 'turn the ICMP block off' "$HC")" "0"
(
    banner() { :; }; pause() { :; }
    svc_state() { printf 'stopped'; }
    core_matches_script() { return 0; }
    have() { return 1; }
    port_free() { return 1; }
    sysctl() { printf '0'; }
    CORE_BIN=/bin/true
    health_check ic
) > "$HC" 2>&1
check "an answering server is only a warning" "$(grep -c 'still answers ordinary pings' "$HC")" "1"
check "with the switch that fixes it"         "$(grep -c 'Blocking' "$HC")"                     "1"

# ---------------------------------------------------------------------------
note "a full uninstall takes the rules with it"
# ---------------------------------------------------------------------------
# A DNAT rule pointing at an address that has gone swallows every packet for
# that port in silence, so leaving one behind is worse than leaving a file.
un() { awk '/^full_uninstall\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh; }
check "it drops the forwarding chains" "$(un | grep -c 'nat_drop_chains')"   "1"
check "and the blocking ones"          "$(un | grep -c 'remove_blocking')"   "1"
check "and the boot-time unit"         "$(un | grep -c 'pingify-firewall')"  "1"
check "and says so before asking"      "$(un | grep -c 'PINGIFY_NAT')"       "1"

# ---------------------------------------------------------------------------
note "the live dashboard lets go"
# ---------------------------------------------------------------------------
# read -n1 returns an empty key both when enter is pressed and when the two
# seconds run out, so without testing its exit status enter did nothing and
# the only way out was to kill the script.
db() { awk '/^live_dashboard\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh; }
check "it tests whether a key arrived" "$(db | grep -c 'if read -rsn1')" "1"
check "and enter is one of the ways out" "$(db | grep -c 'q|Q|0|""')"    "1"


# ---------------------------------------------------------------------------
note "the round trip has a colour"
# ---------------------------------------------------------------------------
# The number alone tells most people nothing. What they want to know is
# whether it is normal for this path, and the bands say so at a glance.
grn=$'\033[32m'; yel=$'\033[33m'; red=$'\033[31m'; dimc=$'\033[2m'
C_GRN="$grn"; C_YEL="$yel"; C_RED="$red"; C_DIM="$dimc"
check "a nearby datacentre is green"  "$(rtt_colour '42.1ms')"  "$grn"
check "just under the line is green"  "$(rtt_colour '99.9ms')"  "$grn"
check "europe on a bad day is yellow" "$(rtt_colour '137.4ms')" "$yel"
check "the far side of the world is red" "$(rtt_colour '243.9ms')" "$red"
check "exactly 200 is red"            "$(rtt_colour '200ms')"   "$red"
check "no round trip is dim, not red" "$(rtt_colour '-')"       "$dimc"
check "and so is an empty one"        "$(rtt_colour '')"        "$dimc"
check "it reads a bare number too"    "$(rtt_colour '42')"      "$grn"
check "slow is only past 200"         "$(rtt_slow '150ms'; echo $?)" "1"
check "and 250 is slow"               "$(rtt_slow '250ms'; echo $?)" "0"
check "a missing one is never slow"   "$(rtt_slow '-'; echo $?)"     "1"
C_GRN=""; C_YEL=""; C_RED=""; C_DIM=""

# ---------------------------------------------------------------------------
note "following the log does not close the manager"
# ---------------------------------------------------------------------------
# ctrl-c reaches every process in the foreground group, so the key the screen
# tells you to press to stop following was also killing the script.
ll() { awk '/^live_log\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh; }
check "it catches the interrupt"   "$(ll | grep -c "trap ':' INT")" "1"
check "and puts it back after"     "$(ll | grep -c 'trap - INT')"   "1"
check "diagnostics follows the same way" \
      "$(grep -c 'live_log "$PICKED"' Pingify.sh)" "1"
check "nothing follows the journal raw any more" \
      "$(grep -c 'journalctl.*-f --no-pager -o cat' Pingify.sh)" "1"


# ---------------------------------------------------------------------------
note "two tunnels never share a status port"
# ---------------------------------------------------------------------------
# Asking the kernel whether a port is free only answers for tunnels that are
# running. Build a second tunnel while the first is stopped and both used to
# be handed 9700, which they then fought over at the next boot - and the loser
# reported no carriers to a health check that could find nothing wrong.
(
    # a config dir of its own: the suite's own tunnels have already claimed
    # the first few, which is the fix working rather than a failure
    CFG_DIR="$WORK/ports"; mkdir -p "$CFG_DIR"
    port_free() { return 0; }   # nothing running: every port looks free
    a="$(pick_status_port 9700)"
    cfg_reset
    T_NAME="pa"; T_ROLE="server"; T_KIND="tcp"; T_TRANSPORT="tcp"; T_ACCEPTS="server"
    cfg_mode; T_TOKEN="$TOKEN"; T_PORT=9443; T_PUBLIC_IP="203.0.113.9"
    T_FORWARDS='"5650"'; T_STATUS="127.0.0.1:$a"
    cfg_save >/dev/null
    b="$(pick_status_port 9700)"
    printf '%s %s\n' "$a" "$b"
) > "$WORK/ports.out"
read -r first second < "$WORK/ports.out"
check "the first tunnel takes 9700" "$first"  "9700"
check "the second moves along"      "$second" "9701"

printf '\n%s passed, %s failed\n\n' "$PASS" "$FAILED"
[ "$FAILED" = "0" ]
