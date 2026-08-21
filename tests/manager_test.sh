#!/usr/bin/env bash
# End-to-end check of the manager's config pipeline.
#
# It sources the generated Pingify.sh, drives the same functions the wizard
# uses, and then runs two real engines against the documents they produce -
# including the peer token, decoded exactly as the far server would decode it.
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

# ---------------------------------------------------------------------------
note "forward spec parsing"
# ---------------------------------------------------------------------------
check "single port"       "$(parse_forwards '443')"                '"443"'
check "comma separated"   "$(parse_forwards '443,2053')"           '"443","2053"'
check "spaces tolerated"  "$(parse_forwards '443, 2053 , udp:500')" '"443","2053","udp:500"'
check "ranges kept"       "$(parse_forwards '8000-8010=9000')"     '"8000-8010=9000"'
check "empty input"       "$(parse_forwards '')"                   ''

# ---------------------------------------------------------------------------
note "config rendering and read-back"
# ---------------------------------------------------------------------------
cfg_reset
T_NAME="t1"; T_ROLE="client"; T_MODE="forward"
T_ACCEPTS="server"; T_PEER_IP="203.0.113.9"; T_PORT=9443
T_PSK="$(printf 'ab%.0s' {1..32})"
T_CARRIERS=6; T_WINDOW=2048; T_KEEPALIVE=15
T_FORWARDS='"443","udp:500"'; T_STATUS="127.0.0.1:9700"
file="$(cfg_save)"

check "name round-trips"      "$(toml_get "$file" tunnel name)"          "t1"
check "role round-trips"      "$(toml_get "$file" tunnel role)"          "client"
check "connect round-trips"   "$(toml_get "$file" transport connect)"       "203.0.113.9:9443"
check "carriers round-trip"   "$(toml_get "$file" transport carriers)"      "6"
check "window round-trips"    "$(toml_get "$file" tuning window_kb)"     "2048"
check "status round-trips"    "$(toml_get "$file" status addr)"   "127.0.0.1:9700"
check "no listen key written" "$(toml_get "$file" transport listen)"        ""
check "transport written"     "$(toml_get "$file" transport type)"     "braid"

saved_psk="$T_PSK"
cfg_load t1
check "cfg_load role"     "$T_ROLE"     "client"
check "cfg_load psk"      "$T_PSK"      "$saved_psk"
check "cfg_load forwards" "$T_FORWARDS" '"443","udp:500"'
check "cfg_load carriers"  "$T_CARRIERS"  "6"
check "cfg_load transport" "$T_TRANSPORT" "braid"

# ---------------------------------------------------------------------------
note "the token carries settings, not addresses"
# ---------------------------------------------------------------------------
cfg_reset
T_NAME="t1"; T_ROLE="server"; T_MODE="forward"; T_TRANSPORT="braid"
T_PORT=9443; T_PUBLIC_IP="203.0.113.9"; T_PSK="$saved_psk"
T_FORWARDS='"443","udp:500"'; T_STATUS="127.0.0.1:9700"; apply_preset balanced

cfg_peer_token | base64 -d > "$WORK/tok"
check "token version"        "$(toml_get "$WORK/tok" "" v)"          "2"
check "role flips"           "$(toml_get "$WORK/tok" "" role)"       "client"
check "port is agreed"       "$(toml_get "$WORK/tok" "" port)"       "9443"
check "key is carried over"  "$(toml_get "$WORK/tok" "" psk)"        "$saved_psk"
check "transport carried"    "$(toml_get "$WORK/tok" "" transport)"  "braid"
check "address is a hint"    "$(toml_get "$WORK/tok" "" suggest_ip)" "203.0.113.9"

# The two things that must never travel: this server's endpoint, and the ports.
check "no listen in token"   "$(grep -c '^listen' "$WORK/tok")"      "0"
check "no connect in token"  "$(grep -c '^connect' "$WORK/tok")"     "0"
check "no ports in token"    "$(grep -c '^ports' "$WORK/tok")"       "0"

# What the far side ends up with after accepting the suggested address.
cfg_reset
T_NAME="t1"; T_ROLE="client"; T_MODE="forward"; T_TRANSPORT="braid"
T_ACCEPTS="server"; T_PORT=9443; T_PEER_IP="203.0.113.9"; T_PSK="$saved_psk"
T_STATUS="127.0.0.1:9700"
cfg_endpoints
check "far side dials"       "$CFG_CONNECT"  "203.0.113.9:9443"
check "far side does not listen" "$CFG_LISTEN" ""

# Echo has no port, and used to produce "ip:0.0.0.0" here.
T_TRANSPORT="echo"
cfg_endpoints
check "echo dials without a port" "$CFG_CONNECT" "203.0.113.9"
T_ROLE="server"
cfg_endpoints
check "echo listens without a port" "$CFG_LISTEN" "0.0.0.0"

# a tun tunnel hands the peer the other end of the /30
cfg_reset
T_NAME="t2"; T_ROLE="server"; T_MODE="tun"; T_TRANSPORT="braid"
T_PSK="$saved_psk"; T_STATUS="127.0.0.1:9701"; T_PUBLIC_IP="198.51.100.4"
T_TUNIF="pfy1"; T_TUNLOCAL="10.71.1.1/30"; T_TUNPEER="10.71.1.2"; T_TUNMTU=1380
cfg_peer_token | base64 -d > "$WORK/tok2"
check "peer takes .2/30"   "$(toml_get "$WORK/tok2" "" tun_local)" "10.71.1.2/30"
check "peer points at .1"  "$(toml_get "$WORK/tok2" "" tun_peer)"  "10.71.1.1"

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
note "the engine accepts what the manager writes"
# ---------------------------------------------------------------------------
GO_BIN="${GO_BIN:-go}"
if ! command -v "$GO_BIN" >/dev/null 2>&1; then
    printf '  \033[33mskip\033[0m live engine checks: no Go toolchain\n'
else
    EXT=""; [ "${OS:-}" = "Windows_NT" ] && EXT=".exe"
    CORE_BIN="$WORK/pingify-core$EXT"
    ( cd core && CGO_ENABLED=0 "$GO_BIN" build -o "$CORE_BIN" . ) || { echo "core build failed"; exit 1; }

    TP=$(( 20000 + RANDOM % 10000 ))   # tunnel carrier port
    LP=$(( 30000 + RANDOM % 10000 ))   # user-facing port on the edge
    EP=$(( 40000 + RANDOM % 10000 ))   # the "real service"

    # The IRAN side: accepts the link and owns the ports clients connect to.
    cfg_reset
    T_NAME="live"; T_ROLE="server"; T_MODE="forward"; T_TRANSPORT="braid"
    T_ACCEPTS="server"; T_PORT="$TP"; T_PUBLIC_IP="127.0.0.1"
    T_PSK="$("$CORE_BIN" -genpsk)"
    T_CARRIERS=4; T_WINDOW=1024; T_KEEPALIVE=10
    T_FORWARDS="$(parse_forwards "$LP=$EP")"
    T_STATUS="127.0.0.1:$(( 50000 + RANDOM % 5000 ))"
    iran_cfg="$(cfg_save)"
    iran_status="$T_STATUS"
    cfg_peer_token | base64 -d > "$WORK/tok.live"

    # The KHAREJ side, built from nothing but that token plus the address it
    # suggested - which is exactly what applying it does.
    cfg_reset
    T_NAME="$(toml_get "$WORK/tok.live" "" name)"
    T_ROLE="$(toml_get "$WORK/tok.live" "" role)"
    T_MODE="$(toml_get "$WORK/tok.live" "" mode)"
    T_TRANSPORT="$(toml_get "$WORK/tok.live" "" transport)"
    T_ACCEPTS="$(toml_get "$WORK/tok.live" "" accepts)"
    T_PORT="$(toml_get "$WORK/tok.live" "" port)"
    T_PSK="$(toml_get "$WORK/tok.live" "" psk)"
    T_CARRIERS="$(toml_get "$WORK/tok.live" "" carriers)"
    T_WINDOW="$(toml_get "$WORK/tok.live" "" window_kb)"
    T_KEEPALIVE="$(toml_get "$WORK/tok.live" "" keepalive)"
    T_PEER_IP="$(toml_get "$WORK/tok.live" "" suggest_ip)"
    T_STATUS="127.0.0.1:$(( 55000 + RANDOM % 5000 ))"
    CFG_DIR="$WORK/far"; mkdir -p "$CFG_DIR"
    kharej_cfg="$(cfg_save)"
    CFG_DIR="$WORK/etc"

    check "the token alone reaches the peer" "$(toml_get "$kharej_cfg" transport connect)" "127.0.0.1:$TP"
    check "and carries no ports"             "$(grep -c '^ports' "$kharej_cfg")"           "0"

    "$CORE_BIN" -c "$iran_cfg"   -check >/dev/null 2>&1; check "IRAN config validates"   "$?" "0"
    "$CORE_BIN" -c "$kharej_cfg" -check >/dev/null 2>&1; check "KHAREJ config validates" "$?" "0"

    python - "$EP" "$WORK/echo.ready" <<'PYEOF' &
import socket, sys, threading
port = int(sys.argv[1])
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port)); s.listen(16)
open(sys.argv[2], "w").close()
def serve(c):
    with c:
        while True:
            b = c.recv(65536)
            if not b: return
            c.sendall(b)
while True:
    c, _ = s.accept()
    threading.Thread(target=serve, args=(c,), daemon=True).start()
PYEOF
    ECHO_PID=$!
    for _ in $(seq 1 50); do [ -f "$WORK/echo.ready" ] && break; sleep 0.1; done

    "$CORE_BIN" -c "$kharej_cfg" >"$WORK/kharej.log" 2>&1 &
    KHAREJ_PID=$!
    "$CORE_BIN" -c "$iran_cfg" >"$WORK/iran.log" 2>&1 &
    IRAN_PID=$!

    up=1
    for _ in $(seq 1 60); do
        if "$CORE_BIN" -healthz "$iran_status" >/dev/null 2>&1; then up=0; break; fi
        sleep 0.2
    done
    check "carriers come up" "$up" "0"

    if [ "$up" = "0" ]; then
        # healthz turns green on the first carrier; give the rest a moment.
        for _ in $(seq 1 50); do
            set -- $("$CORE_BIN" -status "$iran_status" -brief)
            [ "${2:-0}" = "4" ] && break
            sleep 0.2
        done
        check "all 4 carriers connected" "${2:-0}" "4"

        python - "$LP" > "$WORK/xfer.out" 2>&1 <<'PYEOF'
import socket, sys, os, hashlib
port = int(sys.argv[1])
payload = os.urandom(1 << 20)
s = socket.create_connection(("127.0.0.1", port), timeout=15)
s.settimeout(20)
s.sendall(payload); s.shutdown(socket.SHUT_WR)
got = b""
while len(got) < len(payload):
    b = s.recv(65536)
    if not b: break
    got += b
print("match" if got == payload else "mismatch %d/%d" % (len(got), len(payload)))
PYEOF
        check "1 MiB round trip through the tunnel" "$(cat "$WORK/xfer.out")" "match"

        set -- $("$CORE_BIN" -status "$iran_status" -brief)
        check "still healthy afterwards" "$1" "up"
    else
        printf '  edge log:\n'; sed 's/^/    /' "$WORK/edge.log" | tail -n 10
        printf '  origin log:\n'; sed 's/^/    /' "$WORK/origin.log" | tail -n 10
    fi

    kill "$IRAN_PID" "$KHAREJ_PID" "$ECHO_PID" 2>/dev/null
    wait "$IRAN_PID" "$KHAREJ_PID" 2>/dev/null
fi


# ---------------------------------------------------------------------------
note "forwarders"
# ---------------------------------------------------------------------------
cfg_reset
T_NAME="fw"; T_ROLE="server"; T_MODE="forward"; T_TRANSPORT="braid"
T_PORT=9443; T_PUBLIC_IP="203.0.113.9"; T_PSK="$saved_psk"
T_FORWARDS='"443"'; T_STATUS="127.0.0.1:9700"
f="$(cfg_save)"
check "pingify is the default"   "$(toml_get "$f" forward forwarder)" "pingify"
check "mode stays forward"       "$(toml_get "$f" tunnel mode)"       "forward"
check "forwarder is in the token" "$(cfg_peer_token | base64 -d | sed -n 's/^forwarder = "\(.*\)"/\1/p')" "pingify"

# The far side needs to know the forwarder even though it has no ports.
cfg_reset
T_NAME="fw2"; T_ROLE="client"; T_MODE="tun"; T_TRANSPORT="braid"
T_FORWARDER="iptables"; T_ACCEPTS="server"; T_PEER_IP="203.0.113.9"; T_PORT=9443
T_PSK="$saved_psk"; T_STATUS="127.0.0.1:9701"
T_TUNIF="pfy1"; T_TUNLOCAL="10.71.1.2/30"; T_TUNPEER="10.71.1.1"; T_TUNMTU=1380
g="$(cfg_save)"
check "far side knows the forwarder" "$(toml_get "$g" forward forwarder)" "iptables"
check "far side has no ports"        "$(grep -c '^ports' "$g")"           "0"
cfg_load fw2
check "cfg_load reads the forwarder" "$T_FORWARDER" "iptables"

# ---------------------------------------------------------------------------
note "an incomplete tunnel is named, not just rejected"
# ---------------------------------------------------------------------------
cfg_reset
T_NAME="broken"; T_MODE="forward"; T_TRANSPORT="braid"; T_PSK="$saved_psk"
# T_ROLE deliberately left empty - this is what reached the core before
out="$(cfg_save 2>&1)"; rc=$?
check "cfg_save refuses"        "$rc"                                        "1"
check "and says which field"    "$(printf '%s' "$out" | grep -c 'role')"     "1"
check "and writes nothing"      "$([ -f "$(cfg_file broken)" ] && echo yes || echo no)" "no"

# ---------------------------------------------------------------------------
note "the core has to match the script"
# ---------------------------------------------------------------------------
# A core left behind by an older install reads a sectioned config as if half of
# it were missing, and the only symptom was the core rejecting a config that is
# in fact correct.
if [ -n "${CORE_BIN:-}" ] && [ -x "$CORE_BIN" ]; then
    check "the shipped core matches" "$("$CORE_BIN" -version | awk '{print $2}')" "$PINGIFY_VERSION"
    real="$PINGIFY_VERSION"
    PINGIFY_VERSION="0.0.0-not-this"
    if core_matches_script; then r=matched; else r=differs; fi
    check "a mismatch is detected" "$r" "differs"
    PINGIFY_VERSION="$real"
    if core_matches_script; then r=matched; else r=differs; fi
    check "a match is detected"    "$r" "matched"
fi

printf '\n%s passed, %s failed\n\n' "$PASS" "$FAILED"
[ "$FAILED" = "0" ]
