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
T_NAME="t1"; T_ROLE="server"; T_MODE="forward"
T_CONNECT="203.0.113.9:9443"; T_PSK="$(printf 'ab%.0s' {1..32})"
T_CARRIERS=6; T_WINDOW=2048; T_KEEPALIVE=15
T_FORWARDS='"443","udp:500"'; T_STATUS="127.0.0.1:9700"
file="$(cfg_save)"

check "name round-trips"      "$(toml_str "$file" name)"          "t1"
check "role round-trips"      "$(toml_str "$file" role)"          "server"
check "connect round-trips"   "$(toml_str "$file" connect)"       "203.0.113.9:9443"
check "carriers round-trip"   "$(toml_num "$file" carriers)"      "6"
check "window round-trips"    "$(toml_num "$file" window_kb)"     "2048"
check "status round-trips"    "$(toml_str "$file" status_addr)"   "127.0.0.1:9700"
check "no listen key written" "$(toml_str "$file" listen)"        ""
check "transport written"     "$(toml_str "$file" transport)"     "braid"

saved_psk="$T_PSK"
cfg_load t1
check "cfg_load role"     "$T_ROLE"     "server"
check "cfg_load psk"      "$T_PSK"      "$saved_psk"
check "cfg_load forwards" "$T_FORWARDS" '"443","udp:500"'
check "cfg_load carriers"  "$T_CARRIERS"  "6"
check "cfg_load transport" "$T_TRANSPORT" "braid"

# ---------------------------------------------------------------------------
note "peer token mirrors the tunnel"
# ---------------------------------------------------------------------------
peer="$(cfg_peer_token | base64 -d)"
printf '%s\n' "$peer" > "$WORK/peer.toml"
check "role flips"           "$(toml_str "$WORK/peer.toml" role)"     "client"
check "dialler becomes host" "$(toml_str "$WORK/peer.toml" listen)"   "0.0.0.0:9443"
check "peer does not dial"   "$(toml_str "$WORK/peer.toml" connect)"  ""
check "key is carried over"  "$(toml_str "$WORK/peer.toml" psk)"      "$saved_psk"
check "transport mirrored"   "$(toml_str "$WORK/peer.toml" transport)" "braid"
check "ports stay on client" "$(grep -c '^forwards' "$WORK/peer.toml")"  "0"

# a tun tunnel must hand the peer the other end of the /30
cfg_reset
T_NAME="t2"; T_ROLE="server"; T_MODE="tun"; T_LISTEN="0.0.0.0:9500"
T_PSK="$saved_psk"; T_STATUS="127.0.0.1:9701"; T_PUBLIC_IP="198.51.100.4"
T_TUNIF="pfy1"; T_TUNLOCAL="10.71.1.1/30"; T_TUNPEER="10.71.1.2"; T_TUNMTU=1380
cfg_peer_token | base64 -d > "$WORK/peer2.toml"
check "peer dials us"      "$(toml_str "$WORK/peer2.toml" connect)" "198.51.100.4:9500"
check "peer takes .2/30"   "$(toml_tun "$WORK/peer2.toml" local)" "10.71.1.2/30"
check "peer points at .1"  "$(toml_tun "$WORK/peer2.toml" peer)"  "10.71.1.1"

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

    cfg_reset
    T_NAME="live"; T_ROLE="server"; T_MODE="forward"
    T_CONNECT="127.0.0.1:$TP"
    T_PSK="$("$CORE_BIN" -genpsk)"
    T_CARRIERS=4; T_WINDOW=1024; T_KEEPALIVE=10
    T_FORWARDS="$(parse_forwards "$LP=$EP")"
    T_STATUS="127.0.0.1:$(( 50000 + RANDOM % 5000 ))"
    edge_cfg="$(cfg_save)"

    # decode the token exactly as the peer server would
    cfg_peer_token | base64 -d > "$WORK/origin.toml"
    sed -i "s#^status_addr.*#status_addr   = \"127.0.0.1:$(( 55000 + RANDOM % 5000 ))\"#" "$WORK/origin.toml"

    "$CORE_BIN" -c "$edge_cfg"          -check >/dev/null 2>&1; check "edge config validates"   "$?" "0"
    "$CORE_BIN" -c "$WORK/origin.toml"  -check >/dev/null 2>&1; check "origin config validates" "$?" "0"

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

    "$CORE_BIN" -c "$WORK/origin.toml" >"$WORK/origin.log" 2>&1 &
    ORIGIN_PID=$!
    "$CORE_BIN" -c "$edge_cfg" >"$WORK/edge.log" 2>&1 &
    EDGE_PID=$!

    up=1
    for _ in $(seq 1 60); do
        if "$CORE_BIN" -healthz "$T_STATUS" >/dev/null 2>&1; then up=0; break; fi
        sleep 0.2
    done
    check "carriers come up" "$up" "0"

    if [ "$up" = "0" ]; then
        brief="$("$CORE_BIN" -status "$T_STATUS" -brief)"
        set -- $brief
        check "all 4 carriers connected" "$2" "4"

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

        set -- $("$CORE_BIN" -status "$T_STATUS" -brief)
        check "still healthy afterwards" "$1" "up"
    else
        printf '  edge log:\n'; sed 's/^/    /' "$WORK/edge.log" | tail -n 10
        printf '  origin log:\n'; sed 's/^/    /' "$WORK/origin.log" | tail -n 10
    fi

    kill "$EDGE_PID" "$ORIGIN_PID" "$ECHO_PID" 2>/dev/null
    wait "$EDGE_PID" "$ORIGIN_PID" 2>/dev/null
fi

printf '\n%s passed, %s failed\n\n' "$PASS" "$FAILED"
[ "$FAILED" = "0" ]
