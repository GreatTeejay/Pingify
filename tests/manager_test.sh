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
note "the IRAN side"
# ---------------------------------------------------------------------------
cfg_reset
T_NAME="ir"; T_ROLE="server"; T_TRANSPORT="tcp"; T_FORWARDER="iptables"
T_PORT=9443; T_PUBLIC_IP="203.0.113.9"; T_TOKEN="$TOKEN"
T_TUNLOCAL="10.10.10.1/24"; T_TUNPEER="10.10.10.2/24"
T_FORWARDS='"443","udp:500"'; T_STATUS="127.0.0.1:9700"
apply_preset throughput
iran="$(cfg_save)"

check "name"                 "$(toml_get "$iran" tunnel name)"           "ir"
check "role"                 "$(toml_get "$iran" tunnel role)"           "server"
check "mode carries both"    "$(toml_get "$iran" tunnel mode)"           "both"
check "protocol"             "$(toml_get "$iran" transport type)"        "tcp"
check "IRAN accepts the link" "$(toml_get "$iran" transport listen)"     "0.0.0.0:9443"
check "and does not dial"    "$(toml_get "$iran" transport connect)"     ""
check "token, not a key"     "$(toml_get "$iran" security token)"        "$TOKEN"
check "no psk is written"    "$(grep -c '^psk' "$iran")"                 "0"
check "forwarder"            "$(toml_get "$iran" forward forwarder)"     "iptables"
check "ports"                "$(toml_arr "$iran" ports)"                 '"443","udp:500"'
check "private address"      "$(toml_get "$iran" tun local_addr)"        "10.10.10.1/24"
check "peer private address" "$(toml_get "$iran" tun remote_addr)"       "10.10.10.2/24"
check "preset carried"       "$(toml_get "$iran" tuning profile)"        "throughput"
check "window from preset"   "$(toml_get "$iran" tuning window_kb)"      "2048"

cfg_load ir
check "cfg_load role"      "$T_ROLE"      "server"
check "cfg_load token"     "$T_TOKEN"     "$TOKEN"
check "cfg_load forwarder" "$T_FORWARDER" "iptables"
check "cfg_load ports"     "$T_FORWARDS"  '"443","udp:500"'
check "cfg_load port"      "$T_PORT"      "9443"
check "cfg_load accepts"   "$T_ACCEPTS"   "server"

# ---------------------------------------------------------------------------
note "the KHAREJ side"
# ---------------------------------------------------------------------------
cfg_reset
T_NAME="kh"; T_ROLE="client"; T_TRANSPORT="tcp"
T_PORT=9443; T_PEER_IP="203.0.113.9"; T_PUBLIC_IP="198.51.100.4"; T_TOKEN="$TOKEN"
T_TUNLOCAL="10.10.10.2/24"; T_TUNPEER="10.10.10.1/24"
T_STATUS="127.0.0.1:9701"
kharej="$(cfg_save)"

check "KHAREJ dials IRAN"    "$(toml_get "$kharej" transport connect)" "203.0.113.9:9443"
check "and does not listen"  "$(toml_get "$kharej" transport listen)"  ""
check "same token"           "$(toml_get "$kharej" security token)"    "$TOKEN"
check "no ports on KHAREJ"   "$(grep -c '^ports' "$kharej")"           "0"
check "its own address"      "$(toml_get "$kharej" tun local_addr)"    "10.10.10.2/24"

cfg_load kh
check "cfg_load peer"    "$T_PEER_IP" "203.0.113.9"
check "cfg_load accepts" "$T_ACCEPTS" "server"

# ---------------------------------------------------------------------------
note "ICMP needs no port"
# ---------------------------------------------------------------------------
cfg_reset
T_NAME="ic"; T_ROLE="server"; T_TRANSPORT="icmp"; T_TOKEN="$TOKEN"
T_TUNLOCAL="10.20.10.1/24"; T_TUNPEER="10.20.10.2/24"
T_FORWARDS='"443"'; T_STATUS="127.0.0.1:9702"
cfg_endpoints
check "IRAN listens without a port" "$CFG_LISTEN" "0.0.0.0"

T_ROLE="client"; T_PEER_IP="203.0.113.9"
cfg_endpoints
check "KHAREJ dials without a port" "$CFG_CONNECT" "203.0.113.9"
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

printf '\n%s passed, %s failed\n\n' "$PASS" "$FAILED"
[ "$FAILED" = "0" ]
