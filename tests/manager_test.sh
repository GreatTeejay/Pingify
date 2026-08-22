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

check "the file is TOML"      "$(basename "$file")"                         "t1.toml"
check "name round-trips"      "$(toml_get "$file" tunnel name)"             "t1"
check "role round-trips"      "$(toml_get "$file" tunnel role)"             "server"
check "connect round-trips"   "$(toml_get "$file" transport connect)"       "203.0.113.9:9443"
check "carriers round-trip"   "$(toml_get "$file" transport carriers)"      "6"
check "keepalive round-trips" "$(toml_get "$file" transport keepalive_sec)" "15"
check "window round-trips"    "$(toml_get "$file" tuning window_kb)"        "2048"
check "status round-trips"    "$(toml_get "$file" status addr)"             "127.0.0.1:9700"
check "no listen key written" "$(toml_get "$file" transport listen)"        ""
check "transport written"     "$(toml_get "$file" transport type)"          "direct"
check "ports are a list"      "$(toml_arr "$file" ports)"                   '"443","udp:500"'
check "every section present" "$(grep -c '^\[' "$file")"                    "7"
check "no empty tun section"  "$(grep -c '^\[tun\]' "$file")"                "0"

saved_psk="$T_PSK"
cfg_load t1
check "cfg_load role"     "$T_ROLE"     "server"
check "cfg_load psk"      "$T_PSK"      "$saved_psk"
check "cfg_load forwards" "$T_FORWARDS" '"443","udp:500"'
check "cfg_load carriers"  "$T_CARRIERS"  "6"
check "cfg_load transport" "$T_TRANSPORT" "direct"

# ---------------------------------------------------------------------------
note "the peer token"
# ---------------------------------------------------------------------------
# It is a short list of values, not a config document. Encoding the document
# tied the token to whatever format that document was in, and changing the
# format to TOML broke every token silently: the far end decoded it, read it
# with a JSON reader, found nothing, and said "the token is incomplete".
peer="$(cfg_peer_token | base64 -d)"
check "token is the short form"  "${peer%%|*}"                        "p1"
check "the far end accepts"      "$(printf '%s' "$peer" | cut -d'|' -f4)" "l=0.0.0.0:9443"
check "the key travels"          "$(printf '%s' "$peer" | cut -d'|' -f5)" "$saved_psk"
check "mode travels"             "$(printf '%s' "$peer" | cut -d'|' -f2)" "forward"
check "transport travels"        "$(printf '%s' "$peer" | cut -d'|' -f3)" "direct"
check "carriers travel"          "$(printf '%s' "$peer" | cut -d'|' -f6)" "6"
check "ports stay on IRAN"       "$(printf '%s' "$peer" | grep -c '443')" "1"
check "and it is short"          "$([ "$(cfg_peer_token | wc -c)" -lt 200 ] && echo yes || echo no)" "yes"

# a tun tunnel must hand the peer the other end of the /30
cfg_reset
T_NAME="t2"; T_ROLE="server"; T_MODE="tun"; T_LISTEN="0.0.0.0:9500"
T_PSK="$saved_psk"; T_STATUS="127.0.0.1:9701"; T_PUBLIC_IP="198.51.100.4"
T_TUNIF="pfy1"; T_TUNLOCAL="10.71.1.1/30"; T_TUNPEER="10.71.1.2"; T_TUNMTU=1380
peer2="$(cfg_peer_token | base64 -d)"
check "peer dials us"      "$(printf '%s' "$peer2" | cut -d'|' -f4)"  "c=198.51.100.4:9500"
check "peer takes .2/30"   "$(printf '%s' "$peer2" | cut -d'|' -f9)"  "10.71.1.2/30"
check "peer points at .1"  "$(printf '%s' "$peer2" | cut -d'|' -f10)" "10.71.1.1"

# ---------------------------------------------------------------------------
note "a token becomes a working config on the other server"
# ---------------------------------------------------------------------------
# The round trip nobody was testing: build a token on one end, read it on the
# other, and check the file that comes out is one the core will accept.
cfg_reset
T_NAME="ir"; T_ROLE="server"; T_MODE="forward"; T_TRANSPORT="direct"
T_LISTEN="0.0.0.0:9443"; T_PUBLIC_IP="203.0.113.9"; T_PSK="$saved_psk"
T_CARRIERS=8; T_WINDOW=2048; T_KEEPALIVE=15
T_FORWARDS='"6526"'; T_STATUS="127.0.0.1:9700"
tok="$(cfg_peer_token)"

# what import_tunnel does with it, without the prompts
raw="$(printf '%s' "$tok" | base64 -d)"
IFS='|' read -r _v _mode _tr _ep _psk _car _win _ka _tl _tp _mtu <<TOKEN
$raw
TOKEN
cfg_reset
T_MODE="$_mode"; T_TRANSPORT="$_tr"; T_PSK="$_psk"
T_CARRIERS="$_car"; T_WINDOW="$_win"; T_KEEPALIVE="$_ka"
T_CONNECT="${_ep#c=}"; T_ROLE="client"
T_NAME="kharej-${_ep##*:}"; T_STATUS="127.0.0.1:9702"
kh="$(cfg_save)"

check "the peer file is named"  "$(basename "$kh")"                        "kharej-9443.toml"
check "it dials IRAN"           "$(toml_get "$kh" transport connect)"      "203.0.113.9:9443"
check "it does not listen"      "$(toml_get "$kh" transport listen)"       ""
check "same key both ends"      "$(toml_get "$kh" security psk)"           "$saved_psk"
check "tuning came across"      "$(toml_get "$kh" transport carriers)"     "8"
check "no ports on KHAREJ"      "$(grep -c '^ports' "$kh")"                "0"
if [ -n "${CORE_BIN:-}" ] && [ -x "${CORE_BIN:-}" ]; then
    "$CORE_BIN" -c "$kh" -check >/dev/null 2>&1
    check "the core accepts it"  "$?"                                      "0"
fi

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

    # Build the peer's config the way the far server would: read the token,
    # set the same variables import_tunnel sets, and render through cfg_save.
    tok="$(cfg_peer_token)"
    saved_forwards="$T_FORWARDS"; saved_edge_name="$T_NAME"
    raw="$(printf '%s' "$tok" | base64 -d)"
    IFS='|' read -r _v _mode _tr _ep _psk _car _win _ka _tl _tp _mtu <<TOKEN
$raw
TOKEN
    cfg_reset
    T_MODE="$_mode"; T_TRANSPORT="$_tr"; T_PSK="$_psk"
    T_CARRIERS="$_car"; T_WINDOW="$_win"; T_KEEPALIVE="$_ka"
    case "$_ep" in
        c=*) T_CONNECT="${_ep#c=}" ;;
        l=*) T_LISTEN="${_ep#l=}" ;;
    esac
    T_ROLE="client"; T_NAME="origin"
    T_STATUS="127.0.0.1:$(( 55000 + RANDOM % 5000 ))"
    origin_cfg="$(cfg_save)"
    origin_status="$T_STATUS"

    "$CORE_BIN" -c "$edge_cfg"    -check >/dev/null 2>&1; check "edge config validates"   "$?" "0"
    "$CORE_BIN" -c "$origin_cfg"  -check >/dev/null 2>&1; check "origin config validates" "$?" "0"

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

    "$CORE_BIN" -c "$origin_cfg" >"$WORK/origin.log" 2>&1 &
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
