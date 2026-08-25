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
    # Ports the machine says are actually free, rather than a random number
    # and hope. CI once picked one a runner service already held: the core
    # logged "address already in use", its status endpoint never came up, and
    # a test about typed tokens failed for a reason that had nothing to do
    # with tokens. The probe binds 0.0.0.0 with no SO_REUSEADDR, which is the
    # strictest question available - it fails if anything holds that port on
    # any address, including a socket still in TIME_WAIT.
    free_port() {
        python - "$1" "$2" <<'PYEOF'
import random, socket, sys
lo, span = int(sys.argv[1]), int(sys.argv[2])
for _ in range(400):
    p = lo + random.randrange(span)
    s = socket.socket()
    try:
        s.bind(("0.0.0.0", p))
    except OSError:
        continue
    finally:
        s.close()
    print(p)
    sys.exit(0)
sys.exit(1)
PYEOF
    }

    TP=$(free_port 20000 10000)
    LP=$(free_port 30000 10000)
    EP=$(free_port 40000 10000)
    LIVE_TOKEN="a token typed on both servers"

    cfg_reset
    T_MODE="forward"
    T_NAME="live-ir"; T_ROLE="server"; T_TRANSPORT="tcp"
    T_ACCEPTS="server"; T_PORT="$TP"; T_PUBLIC_IP="127.0.0.1"
    T_TOKEN="$LIVE_TOKEN"; T_CARRIERS=4; T_WINDOW=1024
    T_FORWARDS="$(parse_forwards "$LP=$EP")"
    iran_status="127.0.0.1:$(free_port 50000 5000)"
    T_STATUS="$iran_status"
    iran_cfg="$(cfg_save)"

    cfg_reset
    T_MODE="forward"
    T_NAME="live-kh"; T_ROLE="client"; T_TRANSPORT="tcp"
    T_ACCEPTS="server"; T_PORT="$TP"; T_PEER_IP="127.0.0.1"
    T_TOKEN="$LIVE_TOKEN"; T_CARRIERS=4; T_WINDOW=1024
    T_STATUS="127.0.0.1:$(free_port 55000 5000)"
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
dc() { awk '/^download_core\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh; }
check "core download also accepts wget" "$(dc | grep -c 'have curl || have wget')" "1"

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
    IFS='|' read -r TOK_V TOK_KIND TOK_TR TOK_MODE TOK_FWD TOK_DIAL TOK_HOST TOK_PORT TOK_TOKEN TOK_CAR TOK_WIN TOK_KA TOK_SND TOK_RCV TOK_TL TOK_TP TOK_MTU TOK_TTL TOK_AWGPORT TOK_AWGPRIV TOK_AWGPUB TOK_AWGOBF TOK_FEC_DATA TOK_FEC_PARITY TOK_PACKET_MTU TOK_KCP_INTERVAL TOK_PCK_FLAGS TOK_PROFILE TOK_OBF TOK_SUM <<EOF
$raw
EOF
    if [ "$TOK_V" = "p5" ]; then
        TOK_HOST="$(setup_token_text_decode "$TOK_HOST")"
        TOK_TOKEN="$(setup_token_text_decode "$TOK_TOKEN")"
        TOK_TL="$(setup_token_text_decode "$TOK_TL")"
        TOK_TP="$(setup_token_text_decode "$TOK_TP")"
        TOK_AWGPRIV="$(setup_token_text_decode "$TOK_AWGPRIV")"
        TOK_AWGPUB="$(setup_token_text_decode "$TOK_AWGPUB")"
        TOK_AWGOBF="$(setup_token_text_decode "$TOK_AWGOBF")"
        TOK_PCK_FLAGS="$(setup_token_text_decode "$TOK_PCK_FLAGS")"
    fi
}

# --- TCP, reverse: IRAN accepts, so the peer is told to dial us -------------
cfg_reset
T_NAME="ir"; T_ROLE="server"; T_KIND="tcp"; T_TRANSPORT="tcp"; T_ACCEPTS="server"
cfg_mode
T_TOKEN="$TOKEN"; T_PORT=9443; T_PUBLIC_IP="203.0.113.9"
T_CARRIERS=14; T_WINDOW=1024; T_KEEPALIVE=10; T_SNDBUF=1024; T_RCVBUF=1024
T_FORWARDS='"6526"'; T_STATUS="127.0.0.1:9700"
decode "$(cfg_setup_token)"
check "token version"           "$TOK_V"      "p5"
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
T_FEC_DATA="$TOK_FEC_DATA"; T_FEC_PARITY="$TOK_FEC_PARITY"
T_PACKET_MTU="$TOK_PACKET_MTU"; T_KCP_INTERVAL="$TOK_KCP_INTERVAL"
T_PCK_FLAGS="$TOK_PCK_FLAGS"
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
note "every transport makes one matching Iran / Kharej pair"
# ---------------------------------------------------------------------------
# This uses the production decoder, not positional test parsing. Each source
# config is written first, its actual setup token is imported, and the KHAREJ
# config is then written from those decoded values. A password containing all
# three characters that broke the old format (pipe, quote and hash) must make
# the round trip unchanged too.
PAIR="$WORK/token-pairs"; mkdir -p "$PAIR"
(
    CFG_DIR="$PAIR"
    have() { case "$1" in ss | ip | tc) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
    secret='sec|ret"#\path'
    for tr in tcp udp kcp pck icmp ws wss gre awg; do
        cfg_reset
        T_ROLE="server"; T_TRANSPORT="$tr"; T_ACCEPTS="server"
        case "$tr" in icmp) T_KIND="tun" ;; esac
        cfg_mode
        T_PORT=8543
        if [ "$tr" = "wss" ]; then T_PUBLIC_IP="iran.example.com"
        else T_PUBLIC_IP="203.0.113.9"; fi
        T_PEER_IP="198.51.100.4"; T_TOKEN="$secret"; T_FORWARDS='"8010"'
        T_TUNLOCAL="10.77.10.1/24"; T_TUNPEER="10.77.10.2/24"; T_TUNMTU=1320
        T_GRE_TTL=64; T_AWG_PORT=51888
        T_AWG_PRIV="IRAN-PRIVATE"; T_AWG_PUB="KHAREJ-PUBLIC"
        awg_peer_priv="KHAREJ-PRIVATE"; awg_self_pub="IRAN-PUBLIC"
        T_AWG_OBF="5,50,1000,68,91,101,102,103,104"
        if kernel_transport; then T_PRESET="kernel"
        else apply_preset throughput; T_OBFUSCATE="true"; fi
        T_NAME="$(tunnel_default_name)"
        oct="$(link_octet)" && T_NAME="$(tunnel_default_name "$oct")"
        cfg_needs_link && T_TUNIF="$(link_iface "$T_NAME")"
        kernel_transport && T_STATUS="" || T_STATUS="127.0.0.1:9700"
        iran_name="$T_NAME"
        iran_file="$(cfg_save)" || { echo "$tr.read=no"; continue; }
        if kernel_transport; then iran_core="kernel"
        elif [ -x "$CORE_BIN" ] && "$CORE_BIN" -c "$iran_file" -check >/dev/null 2>&1; then iran_core="yes"
        else iran_core="no"; fi

        expected="$T_CARRIERS/$T_WINDOW/$T_KEEPALIVE/$T_SNDBUF/$T_RCVBUF/$T_FEC_DATA/$T_FEC_PARITY/$T_PACKET_MTU/$T_KCP_INTERVAL/$T_PRESET/$T_OBFUSCATE"
        setup="$(cfg_setup_token)"
        if ! setup_token_read "$setup"; then
            echo "$tr.read=no"
            continue
        fi
        got="$T_CARRIERS/$T_WINDOW/$T_KEEPALIVE/$T_SNDBUF/$T_RCVBUF/$T_FEC_DATA/$T_FEC_PARITY/$T_PACKET_MTU/$T_KCP_INTERVAL/$T_PRESET/$T_OBFUSCATE"
        [ "$got" = "$expected" ] && mirror=yes || mirror=no
        [ "$T_TOKEN" = "$secret" ] && secret_ok=yes || secret_ok=no
        [ "$T_ROLE" = "client" ] && role_ok=yes || role_ok=no
        T_PUBLIC_IP="198.51.100.4"
        T_NAME="$(tunnel_default_name)"
        oct="$(link_octet)" && T_NAME="$(tunnel_default_name "$oct")"
        cfg_needs_link && T_TUNIF="$(link_iface "$T_NAME")"
        kernel_transport && T_STATUS="" || T_STATUS="127.0.0.1:9701"
        kh_name="$T_NAME"
        kh_file="$(cfg_save)" || { echo "$tr.read=no"; continue; }
        if kernel_transport; then
            kh_core="kernel"
            grep -q '^\[tuning\]' "$kh_file" && clean_kernel=no || clean_kernel=yes
        elif [ -x "$CORE_BIN" ] && "$CORE_BIN" -c "$kh_file" -check >/dev/null 2>&1; then
            kh_core="yes"; clean_kernel="n/a"
        else
            kh_core="no"; clean_kernel="n/a"
        fi
        cfg_load "$kh_name"
        [ "$T_TOKEN" = "$secret" ] && reload=yes || reload=no

        echo "$tr.read=yes"
        echo "$tr.role=$role_ok"
        echo "$tr.secret=$secret_ok/$reload"
        echo "$tr.mirror=$mirror"
        echo "$tr.names=$iran_name/$kh_name"
        echo "$tr.core=$iran_core/$kh_core"
        echo "$tr.kernel-clean=$clean_kernel"
    done

    # A token whose payload changed after it was printed must be rejected
    # before any variables from it are trusted.
    cfg_reset; T_ROLE=server; T_TRANSPORT=tcp; T_ACCEPTS=server; cfg_mode
    T_PUBLIC_IP=203.0.113.9; T_TOKEN="$secret"; T_PORT=9443; apply_preset balanced
    good="$(cfg_setup_token)"; raw="$(printf '%s' "$good" | base64 -d)"
    raw="${raw/|balanced|/|gaming|}"
    bad="$(printf '%s' "$raw" | base64 | tr -d '\n')"
    if setup_token_read "$bad"; then echo "tamper=accepted"
    else echo "tamper=$SETUP_TOKEN_ERROR"; fi
) > "$WORK/token-pairs.out" 2>&1
pair() { grep -m1 "^$1=" "$WORK/token-pairs.out" | cut -d= -f2-; }

for tr in tcp udp kcp pck icmp ws wss gre awg; do
    check "$tr token imports"       "$(pair "$tr.read")"   "yes"
    check "$tr becomes KHAREJ"      "$(pair "$tr.role")"   "yes"
    check "$tr keeps the secret"    "$(pair "$tr.secret")" "yes/yes"
    check "$tr mirrors its tuning"  "$(pair "$tr.mirror")" "yes"
    case "$tr" in
        tcp) want_names="iran-8543/kharej-8543" ;;
        icmp | gre | awg) want_names="iran-tun-$tr-77/kharej-tun-$tr-77" ;;
        *) want_names="iran-$tr-8543/kharej-$tr-8543" ;;
    esac
    check "$tr names start with side" "$(pair "$tr.names")" "$want_names"
    if [ "$tr" = "gre" ] || [ "$tr" = "awg" ]; then
        check "$tr uses the kernel only" "$(pair "$tr.core")" "kernel/kernel"
        check "$tr has no fake core tuning" "$(pair "$tr.kernel-clean")" "yes"
    else
        check "$tr configs validate" "$(pair "$tr.core")" "yes/yes"
    fi
done
check "a changed token is rejected" "$(pair tamper)" "the token checksum does not match"


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
    awk '/^import_tunnel\(\) \{/{f=1} f&&/^}/{exit} f&&/pick side "select"/{print}' Pingify.sh
}
check "the wizard offers three ways in" \
      "$(first_q | grep -c '1 2 3')" "1"
# The importer used to ask which server this was. It never had to: a setup
# token is printed by IRAN and nowhere else, so a machine pasting one is
# KHAREJ. Asking invited the wrong answer, and the wrong answer built a
# tunnel with no address to dial and no explanation of why it would not run.
check "the importer asks nothing" "$(importer_q | wc -l | tr -d ' ')" "0"
imp() { awk '/^import_tunnel\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh; }
check "it knows this is KHAREJ" "$(awk '/^setup_token_read\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh | grep -c 'T_ROLE="client"')" "1"
check "and never asks for ports" "$(imp | grep -c 'ports, comma separated')" "0"
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
# "nothing came back at all" and "a port could not be reached" are different
# faults on different machines. Reported as one, the advice sent the reader to
# check a listening socket that was listening perfectly well.
hcp() { awk '/^health_check\(\) \{/{f=1} f&&/^\}/{exit} f' Pingify.sh; }
check "a one-way path is its own verdict" "$(hcp | grep -c 'rc" = "3"')" "1"
check "and does not blame the service"    "$(hcp | grep -c 'nothing is coming back from the other server at all')" "1"
check "a port failure still says so"      "$(hcp | grep -c 'did not reach the service on the other server')" "1"
check "the core has a code for it"        "$(grep -c 'probeOneWay = 3' Pingify.sh)" "1"

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
check "and nine at most" "$(menu_block | grep -oE 'item [1-9]' | sort -u | wc -l | tr -d ' ')" "9"
check "no letter keys"   "$(menu_block | grep -c 'item d ')"                     "0"
check "the core menu is gone"     "$(grep -c 'Core options' Pingify.sh)"         "0"
check "and nothing still calls it" "$(grep -c 'update_menu' Pingify.sh)"         "0"

# ---------------------------------------------------------------------------
note "the tuning a token carries has a name"
# ---------------------------------------------------------------------------
# "from token" is not a profile. The numbers came from a preset on the other
# server and this one should call it what that one calls it.
# Every preset must name itself back. Written as a round trip rather than a
# table of numbers, because a table is a second copy - and when the presets
# were retuned, the copy in the test went stale at the same moment the copy in
# preset_name did.
for _p in gaming latency balanced throughput extreme; do
    ( cfg_reset; apply_preset "$_p" ) >/dev/null 2>&1
    cfg_reset; apply_preset "$_p" >/dev/null 2>&1
    check "$_p names itself back" "$(preset_name "$T_CARRIERS" "$T_WINDOW" "$T_KEEPALIVE" "$T_SNDBUF" "$T_RCVBUF")" "$_p"
done
check "hand-set numbers are custom" "$(preset_name 11 700 10 700 700)" "custom"
check "nothing assigns it" "$(grep -c 'T_PRESET="from token"' Pingify.sh)" "0"

# WebSockets keep the familiar names, but their presets describe the shape
# they really have: one multiplexed connection with enough aggregate socket
# room for all the logical streams sharing it.
T_TRANSPORT="wss"
for _p in gaming latency balanced throughput extreme; do
    apply_preset "$_p" >/dev/null 2>&1
    check "wss $_p stays one carrier" "$T_CARRIERS" "1"
    check "wss $_p names itself back" \
        "$(preset_name "$T_CARRIERS" "$T_WINDOW" "$T_KEEPALIVE" "$T_SNDBUF" "$T_RCVBUF")" "$_p"
done
apply_preset balanced >/dev/null 2>&1
check "wss balanced window"       "$T_WINDOW" "2048"
check "wss balanced send room"    "$T_SNDBUF" "8192"
check "wss balanced receive room" "$T_RCVBUF" "8192"
apply_preset extreme >/dev/null 2>&1
check "wss extreme window"  "$T_WINDOW" "8192"
check "wss extreme buffers" "$T_SNDBUF/$T_RCVBUF" "32768/32768"

# Packet presets include more than carriers and a credit window. Their FEC,
# MTU and KCP tick have to round-trip too; otherwise a hand-edited FEC ratio
# can be labelled Balanced and silently select the wrong receive profile.
T_TRANSPORT="kcp"
for _p in gaming latency balanced throughput extreme; do
    apply_preset "$_p" >/dev/null 2>&1
    check "kcp $_p names all packet tuning back" \
        "$(preset_name "$T_CARRIERS" "$T_WINDOW" "$T_KEEPALIVE" "$T_SNDBUF" "$T_RCVBUF" \
            "$T_FEC_DATA" "$T_FEC_PARITY" "$T_PACKET_MTU" "$T_KCP_INTERVAL")" "$_p"
done
apply_preset balanced >/dev/null 2>&1
T_FEC_PARITY=$((T_FEC_PARITY + 1))
check "hand-set KCP FEC is custom" \
    "$(preset_name "$T_CARRIERS" "$T_WINDOW" "$T_KEEPALIVE" "$T_SNDBUF" "$T_RCVBUF" \
        "$T_FEC_DATA" "$T_FEC_PARITY" "$T_PACKET_MTU" "$T_KCP_INTERVAL")" "custom"

T_TRANSPORT="icmp"
apply_preset balanced >/dev/null 2>&1
check "icmp balanced uses four sessions" "$T_CARRIERS" "4"
check "icmp balanced has burst room" "$T_SNDBUF/$T_RCVBUF" "16384/16384"
T_TRANSPORT="tcp"

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
    # the switch is the source of truth now, not the kernel flag: the block
    # is done with a rule so the private links can be exempted from it
    block_state() { [ "$1" = "icmp" ] && printf 'on' || printf 'off'; }
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
    block_state() { printf 'off'; }
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


# ---------------------------------------------------------------------------
note "kernel tunnels: GRE and AmneziaWG"
# ---------------------------------------------------------------------------
# These two are not carried by our engine at all - the kernel carries them and
# the manager only describes the link. Everything that used to ask the core a
# question has to ask the kernel instead, and everything else has to keep
# working without knowing which kind it is holding.
check "gre is a kernel transport"  "$(T_TRANSPORT=gre;  kernel_transport && echo y)" "y"
check "awg is one too"             "$(T_TRANSPORT=awg;  kernel_transport && echo y)" "y"
check "tcp is not"                 "$(T_TRANSPORT=tcp;  kernel_transport && echo y)" ""
check "and neither is icmp"        "$(T_TRANSPORT=icmp; kernel_transport && echo y)" ""

# The label goes in front of the name, so a list reads as what it is
check "gre wears the TUN label"    "$(transport_label gre)"  "TUN-GRE"
check "awg too"                    "$(transport_label awg)"  "TUN-AWG"

# The interface is named after the tunnel and has to stay readable and under
# the fifteen characters Linux allows.
# One link is not a twenty-fourth of twenty-four - it is a transport that has
# nothing to count, and printing 1/1 next to 24/24 read as weakness.
lk() { awk '/^tunnel_row\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh; }
check "a kernel tunnel says up, not 1/1" "$(lk | grep -c 'links="up"')"      "1"
check "and down rather than 0/1"         "$(lk | grep -c 'links="down"')"    "1"
check "the others still count"           "$(lk | grep -c 'links="\$up/\$total"')" "1"

check "the interface reads plainly" "$(T_TRANSPORT=gre; link_iface iran-tun-gre)"   "gre-iran"
check "on both sides"               "$(T_TRANSPORT=awg; link_iface kharej-tun-awg)" "awg-kharej"
long="$(T_TRANSPORT=gre; link_iface a-very-long-tunnel-name-indeed)"
check "a long name still fits"      "$([ "${#long}" -le 15 ] && echo y)"            "y"

# A kernel tunnel is always a private link, always forwarded by the kernel,
# and never has a socket for anything to listen on.
cfg_reset
T_NAME="iran-tun-gre"; T_ROLE="server"; T_TRANSPORT="gre"
cfg_mode
check "it is a TUN kind"      "$T_KIND"      "tun"
check "in tun mode"           "$T_MODE"      "tun"
check "the kernel forwards"   "$T_FORWARDER" "iptables"
cfg_endpoints
check "nothing listens"       "$CFG_LISTEN"  ""
check "and nothing dials"     "$CFG_CONNECT" ""

# --- a GRE tunnel, written out and carried across ---------------------------
T_PUBLIC_IP="203.0.113.9"; T_PEER_IP="198.51.100.4"; T_TOKEN="$TOKEN"
T_TUNIF="$(link_iface "$T_NAME")"
T_TUNLOCAL="10.10.10.1/24"; T_TUNPEER="10.10.10.2/24"; T_TUNMTU=1400
T_FORWARDS='"443"'
gre_file="$(cfg_save)"
check "the config is written"   "$(basename "$gre_file")"                 "iran-tun-gre.toml"
check "with no status endpoint" "$(toml_get "$gre_file" status addr)"     ""
check "the ttl is recorded"     "$(toml_get "$gre_file" gre ttl)"         "255"
check "and both addresses"      "$(toml_get "$gre_file" gre peer_public)" "198.51.100.4"
check "the interface is named"  "$(toml_get "$gre_file" tun name)"        "gre-iran"

decode "$(cfg_setup_token)"
check "the token is p5"          "$TOK_V"     "p5"
check "gre travels"              "$TOK_TR"    "gre"
check "the ttl travels"          "$TOK_TTL"   "255"
check "and our address, always"  "$TOK_HOST"  "203.0.113.9"
check "the link swaps over"      "$TOK_TL"    "10.10.10.2/24"
check "and points back at us"    "$TOK_TP"    "10.10.10.1/24"

# the far end builds itself from that
cfg_reset
T_KIND="$TOK_KIND"; T_TRANSPORT="$TOK_TR"; T_MODE="$TOK_MODE"; T_FORWARDER="$TOK_FWD"
T_TOKEN="$TOK_TOKEN"; T_TUNLOCAL="$TOK_TL"; T_TUNPEER="$TOK_TP"; T_TUNMTU="$TOK_MTU"
T_GRE_TTL="$TOK_TTL"; T_PEER_IP="$TOK_HOST"
T_ROLE="client"; T_ACCEPTS="server"; T_PUBLIC_IP="198.51.100.4"
T_NAME="kharej-tun-gre"; T_TUNIF="$(link_iface "$T_NAME")"
kh_file="$(cfg_save)"
check "the far end writes too"   "$(basename "$kh_file")"                   "kharej-tun-gre.toml"
check "its own address"          "$(toml_get "$kh_file" gre local_public)"  "198.51.100.4"
check "and ours as the peer"     "$(toml_get "$kh_file" gre peer_public)"   "203.0.113.9"
check "its end of the link"      "$(toml_get "$kh_file" tun local_addr)"    "10.10.10.2/24"
check "no ports over there"      "$(grep -c '^ports' "$kh_file")"           "0"

# --- the unit, which is what actually builds the link -----------------------
UNIT_DIR="$WORK/units"; mkdir -p "$UNIT_DIR"
(
    systemctl() { :; }
    cfg_load iran-tun-gre >/dev/null 2>&1
    write_link_unit iran-tun-gre
)
gre_unit="$UNIT_DIR/pingify@iran-tun-gre.service"
check "a unit is written"          "$([ -f "$gre_unit" ] && echo y)"                    "y"
check "it builds the tunnel"       "$(grep -c 'ip tunnel add gre-iran mode gre' "$gre_unit")" "1"
check "from both addresses"        "$(grep -c 'local 203.0.113.9 remote 198.51.100.4' "$gre_unit")" "1"
check "it clears a leftover first" "$(grep -c 'ip link del gre-iran' "$gre_unit")"      "2"
check "and tears it down on stop"  "$(grep -c '^ExecStop' "$gre_unit")"                 "1"
check "it holds the state"         "$(grep -c 'RemainAfterExit=yes' "$gre_unit")"       "1"

# --- AmneziaWG: two keypairs made once, so one token still does it ----------
# WireGuard needs a real pair on each side and each side needs the other's
# public half. Making both here is what keeps this to a single trip.
awgn="$WORK/awgn"; echo 0 > "$awgn"
awg() {
    local n k
    case "$1" in
        genkey) n=$(( $(cat "$awgn") + 1 )); echo "$n" > "$awgn"; printf 'PRIV%d\n' "$n" ;;
        pubkey) read -r k; printf 'PUBof%s\n' "$k" ;;
    esac
}
mine="$(awg_keypair)"; theirs="$(awg_keypair)"
check "a pair is private then public" "$mine"   "PRIV1 PUBofPRIV1"
check "and the second is distinct"    "$theirs" "PRIV2 PUBofPRIV2"

obf="$(awg_new_obf)"
check "the tested values are kept"  "$(printf '%s' "$obf" | cut -d, -f1-5)" "5,50,1000,68,91"
check "and there are nine of them"  "$(printf '%s' "$obf" | tr ',' ' ' | wc -w | tr -d ' ')" "9"
# H1..H4 are drawn per tunnel rather than hardcoded: four fixed numbers shared
# by every install would be a better signature than the header they hide.
other="$(awg_new_obf)"
check "the headers differ per tunnel" \
      "$([ "$(printf '%s' "$obf" | cut -d, -f6-9)" != "$(printf '%s' "$other" | cut -d, -f6-9)" ] && echo y)" "y"
h1="$(obf_field 6 "$obf")"
check "and never collide with real wireguard" "$([ "$h1" -gt 4 ] && echo y)" "y"

AWG_DIR="$WORK/awg"
cfg_reset
T_NAME="iran-tun-awg"; T_ROLE="server"; T_TRANSPORT="awg"; cfg_mode
T_PUBLIC_IP="203.0.113.9"; T_PEER_IP="198.51.100.4"; T_TOKEN="$TOKEN"
T_TUNIF="$(link_iface "$T_NAME")"
T_TUNLOCAL="10.20.10.1/24"; T_TUNPEER="10.20.10.2/24"; T_TUNMTU=1320
T_FORWARDS='"443"'
T_AWG_PRIV="${mine%% *}"; T_AWG_PUB="${theirs##* }"
awg_peer_priv="${theirs%% *}"; awg_self_pub="${mine##* }"
T_AWG_OBF="$obf"
cfg_save >/dev/null
awg_write_conf "$T_NAME" "$T_TUNIF" "$(awg_conf_path "$T_TUNIF")"
ic="$(awg_conf_path "$T_TUNIF")"
check "IRAN keeps its own key"     "$(grep -c 'PrivateKey = PRIV1' "$ic")"    "1"
check "and lists the other's"      "$(grep -c 'PublicKey = PUBofPRIV2' "$ic")" "1"
check "the obfuscation is written" "$(grep -c "H1 = $h1" "$ic")"              "1"
# The end that waits has no endpoint to dial - it learns the address from the
# first handshake, which is what lets it sit behind whatever the path does.
check "the waiting end has no endpoint" "$(grep -c 'Endpoint' "$ic")"         "0"

decode "$(cfg_setup_token)"
check "the port travels"       "$TOK_AWGPORT" "51820"
check "the other half travels" "$TOK_AWGPRIV" "PRIV2"
check "with our public half"   "$TOK_AWGPUB"  "PUBofPRIV1"
check "and the obfuscation"    "$TOK_AWGOBF"  "$obf"
check "our own key never travels" \
      "$(printf '%s' "$(cfg_setup_token)" | base64 -d | grep -c 'PRIV1 ')" "0"

# and the far end builds a conf that matches it
cfg_reset
T_TRANSPORT="$TOK_TR"; T_MODE="$TOK_MODE"; T_KIND="$TOK_KIND"
T_TUNLOCAL="$TOK_TL"; T_TUNPEER="$TOK_TP"; T_TUNMTU="$TOK_MTU"
T_AWG_PORT="$TOK_AWGPORT"; T_AWG_PRIV="$TOK_AWGPRIV"; T_AWG_PUB="$TOK_AWGPUB"
T_AWG_OBF="$TOK_AWGOBF"; T_PEER_IP="$TOK_HOST"
T_ROLE="client"; T_ACCEPTS="server"
T_NAME="kharej-tun-awg"; T_TUNIF="$(link_iface "$T_NAME")"
awg_write_conf "$T_NAME" "$T_TUNIF" "$(awg_conf_path "$T_TUNIF")"
kc="$(awg_conf_path "$T_TUNIF")"
check "KHAREJ gets the other key"  "$(grep -c 'PrivateKey = PRIV2' "$kc")"     "1"
check "and lists IRAN's"           "$(grep -c 'PublicKey = PUBofPRIV1' "$kc")" "1"
check "the two agree on H1"        "$(grep -c "H1 = $h1" "$kc")"               "1"
# reverse, like every other Pingify tunnel: KHAREJ is the end that dials
check "KHAREJ dials IRAN"          "$(grep -c 'Endpoint = 203.0.113.9:51820' "$kc")" "1"
check "at its end of the link"     "$(grep -c 'Address = 10.20.10.2/24' "$kc")"      "1"
unset -f awg


# ---------------------------------------------------------------------------
note "the tuning says what the numbers buy"
# ---------------------------------------------------------------------------
# A window in kilobytes means nothing on its own. A stream may have at most
# one window in flight, so it cannot beat window / round-trip whatever the
# path underneath can do - and that is the number worth reading.
check "1024 KB at 90 ms"  "$(stream_ceiling 1024 90)"    "91"
check "4096 KB at 90 ms"  "$(stream_ceiling 4096 90)"    "364"
check "the same window on a near path goes further" \
      "$([ "$(stream_ceiling 1024 30)" -gt "$(stream_ceiling 1024 90)" ] && echo y)" "y"
check "a decimal round trip is fine" "$(stream_ceiling 1024 89.4)" "92"
check "no round trip, no answer"     "$(stream_ceiling 1024 '-')"  "-"
check "and no window either"         "$(stream_ceiling '' 90)"     "-"

# --- the buffers are settable now, and checked -----------------------------
# They were derived from the window and capped, with no way to reach them.
# Too small and the window above is a fiction; too large and a busy server
# spends real memory on carriers that are idle.
cfg_reset
T_NAME="tw"; T_ROLE="server"; T_KIND="tcp"; T_TRANSPORT="tcp"; T_ACCEPTS="server"
cfg_mode
T_TOKEN="$TOKEN"; T_PORT=9443; T_PUBLIC_IP="203.0.113.9"; T_FORWARDS='"443"'
T_CARRIERS=14; T_WINDOW=1024; T_SNDBUF=1024; T_RCVBUF=1024
T_STATUS="127.0.0.1:9700"
twf="$(cfg_save)"

(
    pause() { :; }
    systemctl() { :; }
    CORE_BIN=/bin/true
    tuning_write tw 20 2048 10 3072 3072
) > /dev/null 2>&1
check "carriers are written"   "$(toml_get "$twf" transport carriers)"  "20"
check "the window too"         "$(toml_get "$twf" tuning window_kb)"    "2048"
check "and both buffers"       "$(toml_get "$twf" tuning sndbuf_kb)"    "3072"
check "receive as well"        "$(toml_get "$twf" tuning rcvbuf_kb)"    "3072"
# A preset is the whole set of numbers, not only carrier/window. Hand-edited
# buffers must say custom instead of claiming they are still Download.
check "the profile follows"    "$(toml_get "$twf" tuning profile)"      "custom"

# and cfg_load has to read them back, or the screen shows a default that is
# not what is in the file
cfg_load tw >/dev/null 2>&1
check "the buffers are read back" "$T_SNDBUF" "3072"
check "and the receive one"       "$T_RCVBUF" "3072"

# --- what it refuses -------------------------------------------------------
(
    pause() { :; }
    systemctl() { :; }
    CORE_BIN=/bin/true
    tuning_write tw 20 2048 10 999999 3072
) > /dev/null 2>&1
check "a buffer over 64 MB is refused" "$(toml_get "$twf" tuning sndbuf_kb)" "3072"
(
    pause() { :; }
    systemctl() { :; }
    CORE_BIN=/bin/true
    tuning_write tw 20 4 10 3072 3072
) > /dev/null 2>&1
check "and a window that would stall"  "$(toml_get "$twf" tuning window_kb)" "2048"


# ---------------------------------------------------------------------------
note "nothing gets handed out twice"
# ---------------------------------------------------------------------------
# Two tunnels on one private network route into each other; two forwarding one
# port means whichever bound it first wins. Both fail quietly - the traffic
# goes somewhere, just not where it was meant to - so both are caught at the
# question rather than discovered later.
COL="$WORK/collide"; mkdir -p "$COL"
(
    CFG_DIR="$COL"
    # no ip and no ss here, so the answers come from the configs alone and the
    # test does not depend on what this machine happens to have bound
    have() { case "$1" in ip | ss) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
    mkt() {
        cfg_reset
        T_ROLE="server"; T_KIND="tun"; T_TRANSPORT="icmp"; cfg_mode
        T_NAME="$1"; T_TOKEN="$TOKEN"; T_PUBLIC_IP="203.0.113.9"; T_PEER_IP="198.51.100.4"
        T_TUNLOCAL="$2.1/24"; T_TUNPEER="$2.2/24"
        T_FORWARDS="$(parse_forwards "$3")"; T_STATUS="127.0.0.1:9700"
        cfg_save >/dev/null
    }
    mkt tun-a 10.10.10 "443,8080"
    mkt tun-b 10.20.10 "2053,9000-9003"

    # --- private networks --------------------------------------------------
    echo "owner-a=$(net_owner 10.10.10)"
    echo "owner-b=$(net_owner 10.20.10)"
    echo "owner-free=$(net_owner 10.30.10)"
    echo "free-octet=$(free_link_octet)"
    # a tunnel is allowed to keep its own network when its settings are edited
    echo "own-net=$(net_owner 10.10.10 tun-a)"

    # --- ports -------------------------------------------------------------
    echo "port443=$(port_owner 443)"
    echo "port9002=$(port_owner 9002)"
    echo "port1234=$(port_owner 1234)"
    echo "own-port=$(port_owner 443 tun-a)"

    # --- the whole answer, the way the wizard asks it ----------------------
    if forwards_clash "7000,7001"; then echo "clean=yes"; else echo "clean=no"; fi
    if forwards_clash "443"; then echo "dirty=no"; else echo "dirty=yes"; fi
    echo "why=$(forwards_clash "443,9002" | wc -l | tr -d ' ')"
    if forwards_clash "443" tun-a; then echo "own=allowed"; else echo "own=blocked"; fi

    # A tunnel being edited has its own ports bound by its own service, so
    # the "something is listening" check has to let those through or the
    # port list could never be edited without being emptied first.
    listening_ports() { printf '443
8080
'; }
    if forwards_clash "443" tun-a; then echo "own-bound=allowed"; else echo "own-bound=blocked"; fi
    if forwards_clash "5000" tun-a; then echo "free-port=allowed"; else echo "free-port=blocked"; fi
    listening_ports() { printf '5000
'; }
    if forwards_clash "5000" tun-a; then echo "others-bound=allowed"; else echo "others-bound=blocked"; fi
) > "$WORK/collide.out" 2>&1
col() { grep -m1 "^$1=" "$WORK/collide.out" | cut -d= -f2-; }

check "the first network has an owner"  "$(col owner-a)"     "tun-a"
check "and so does the second"          "$(col owner-b)"     "tun-b"
check "an unused one has none"          "$(col owner-free)"  ""
# the first free x, counting up from 10 - not the first unmentioned one
check "the default offered is free"     "$(col free-octet)"  "11"
check "a tunnel may keep its own"       "$(col own-net)"     ""

check "a forwarded port has an owner"   "$(col port443)"     "tun-a"
check "a port inside a range too"       "$(col port9002)"    "tun-b"
check "an unused port has none"         "$(col port1234)"    ""
check "and a tunnel may keep its own"   "$(col own-port)"    ""

check "a clean answer passes"           "$(col clean)"       "yes"
check "a taken one does not"            "$(col dirty)"       "yes"
check "every clash is named, not just one" "$(col why)"      "2"
check "editing a tunnel keeps its ports"   "$(col own)"      "allowed"
check "even when its own service has them bound" "$(col own-bound)"    "allowed"
check "a free port is still free"                "$(col free-port)"    "allowed"
check "but somebody else's listener is not"      "$(col others-bound)" "blocked"

# --- and the wizard actually uses them --------------------------------------
# The check is worth nothing if the question does not ask it.
wz() { awk '/^new_tunnel\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh; }
check "the link question lists what is taken" "$(wz | grep -c 'show_taken_nets')"  "1"
check "and refuses a repeat"                  "$(wz | grep -c 'net_owner')"        "1"
check "and a network the host already has"    "$(wz | grep -c 'host_has_net')"     "1"
check "the ports question lists them too"     "$(wz | grep -c 'show_taken_ports')" "1"
check "and refuses a clash"                   "$(wz | grep -c 'forwards_clash')"   "1"
ef() { awk '/^edit_forwards\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh; }
check "changing ports later checks too"       "$(ef | grep -c 'forwards_clash')"   "1"


# ---------------------------------------------------------------------------
note "the wizard's own state survives what it calls"
# ---------------------------------------------------------------------------
# apply_nat reads every config with cfg_load, which writes every T_ variable
# there is - and it is called from the middle of the wizard, where those
# variables are the tunnel being built. It was overwriting them with whichever
# config happened to be read last, so the setup token described a different
# tunnel, the private link came out as somebody else's, and the line that said
# which tunnel was running named the wrong one.
STA="$WORK/state"; mkdir -p "$STA"
(
    CFG_DIR="$STA"
    have() { case "$1" in iptables) return 0 ;; ip | ss) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
    iptables() { return 0; }
    sysctl() { return 0; }
    nat_chains() { :; }; mss_chain() { :; }; nat_drop_chains() { :; }

    # a tunnel already here, which apply_nat will read
    cfg_reset
    T_ROLE="server"; T_KIND="tun"; T_TRANSPORT="icmp"; cfg_mode
    T_NAME="iran-tun-icmp"; T_TOKEN="somebody-elses"; T_PUBLIC_IP="203.0.113.9"
    T_PEER_IP="198.51.100.4"; T_TUNLOCAL="10.99.10.1/24"; T_TUNPEER="10.99.10.2/24"
    T_FORWARDS='"443"'; T_STATUS="127.0.0.1:9700"; T_FORWARDER="iptables"
    cfg_save >/dev/null

    # and now one being built, on a different network with a different secret
    cfg_reset
    T_ROLE="server"; T_TRANSPORT="gre"; cfg_mode
    T_NAME="$(tunnel_default_name)"; T_TUNIF="$(link_iface "$T_NAME")"
    T_TOKEN="mine"; T_PUBLIC_IP="185.31.8.93"; T_PEER_IP="2.26.26.37"
    T_TUNLOCAL="10.20.10.1/24"; T_TUNPEER="10.20.10.2/24"; T_TUNMTU=1400
    T_FORWARDS='"8007"'
    cfg_save >/dev/null

    apply_nat quiet
    echo "name=$T_NAME"
    echo "net=$T_TUNLOCAL"
    echo "token=$T_TOKEN"
    printf 'carried=%s\n' "$(cfg_setup_token | base64 -d | cut -d'|' -f15 | base64 -d)"
) > "$WORK/state.out" 2>&1
st() { grep -m1 "^$1=" "$WORK/state.out" | cut -d= -f2-; }

check "the name survives"        "$(st name)"    "iran-tun-gre"
check "the private link too"     "$(st net)"     "10.20.10.1/24"
check "and the secret"           "$(st token)"   "mine"
check "so the token is its own"  "$(st carried)" "10.20.10.2/24"

# ---------------------------------------------------------------------------
note "one name, derived one way"
# ---------------------------------------------------------------------------
# The wizard and the importer both name tunnels, and each had its own copy of
# how. They drifted the moment one was edited, and an AmneziaWG tunnel came
# out called iran-9443 - after a TCP port it does not use.
nm() { ( T_ROLE="$1"; T_TRANSPORT="$2"; T_PORT="${3:-9443}"; tunnel_default_name ); }
check "tcp is named for its port" "$(nm server tcp 9443)"  "iran-9443"
check "on the other side too"     "$(nm client tcp 9443)"  "kharej-9443"
check "icmp wears the label"      "$(nm server icmp)"      "iran-tun-icmp"
check "gre as well"               "$(nm server gre)"       "iran-tun-gre"
check "and awg"                   "$(nm client awg)"       "kharej-tun-awg"
check "no port sneaks into a udp tunnel" \
      "$(printf '%s' "$(nm server awg)" | grep -c 9443)" "0"
check "both callers use the one function" \
      "$(grep -c 'T_NAME="\$(tunnel_default_name)"' Pingify.sh)" "2"

# ---------------------------------------------------------------------------
note "the security token does something on a kernel tunnel"
# ---------------------------------------------------------------------------
# The kernel has never heard of our token, so it cannot key a GRE or an
# AmneziaWG tunnel the way it keys our own. It can become the one secret each
# of those does understand - and it is derived on both servers rather than
# carried, so it never enters the setup token at all.
if [ -x "$CORE_BIN" ]; then
    k1="$("$CORE_BIN" -derivekey "one")"
    k2="$("$CORE_BIN" -derivekey "one")"
    k3="$("$CORE_BIN" -derivekey "two")"
    check "the same token gives the same keys" "$k1" "$k2"
    check "a different one does not"           "$([ "$k1" != "$k3" ] && echo y)" "y"
    check "a wireguard key is 32 bytes"        "$(printf '%s' "${k1%% *}" | base64 -d | wc -c | tr -d ' ')" "32"
    check "and the gre key is a number"        "$(printf '%s' "${k1##* }" | tr -d '0-9' )" ""
fi

# --- and both transports actually use them ---------------------------------
AWG_DIR="$WORK/awg2"
awgn2="$WORK/awgn2"; echo 0 > "$awgn2"
awg() {
    local n k
    case "$1" in
        genkey) n=$(( $(cat "$awgn2") + 1 )); echo "$n" > "$awgn2"; printf 'PRIV%d\n' "$n" ;;
        pubkey) read -r k; printf 'PUBof%s\n' "$k" ;;
    esac
}
cfg_reset
T_NAME="iran-tun-awg"; T_ROLE="server"; T_TRANSPORT="awg"; cfg_mode
T_TOKEN="a-real-secret"; T_PUBLIC_IP="203.0.113.9"; T_PEER_IP="198.51.100.4"
T_TUNIF="$(link_iface "$T_NAME")"
T_TUNLOCAL="10.40.10.1/24"; T_TUNPEER="10.40.10.2/24"; T_TUNMTU=1320
T_AWG_PRIV="PRIV1"; T_AWG_PUB="PUBofPRIV2"; T_AWG_OBF="$(awg_new_obf)"
awg_write_conf "$T_NAME" "$T_TUNIF" "$(awg_conf_path "$T_TUNIF")"
ac="$(awg_conf_path "$T_TUNIF")"
if [ -x "$CORE_BIN" ]; then
    want_psk="$("$CORE_BIN" -derivekey "a-real-secret" | awk '{print $1}')"
    check "wireguard gets a pre-shared key" "$(grep -c "PresharedKey = $want_psk" "$ac")" "1"
fi
# it is derived on both ends, so it must never travel
check "and it never enters the token" \
      "$(printf '%s' "$(cfg_setup_token)" | base64 -d | grep -c 'PresharedKey')" "0"

UNIT_DIR="$WORK/units2"; mkdir -p "$UNIT_DIR"
cfg_reset
T_NAME="iran-tun-gre"; T_ROLE="server"; T_TRANSPORT="gre"; cfg_mode
T_TOKEN="a-real-secret"; T_PUBLIC_IP="203.0.113.9"; T_PEER_IP="198.51.100.4"
T_TUNIF="$(link_iface "$T_NAME")"
T_TUNLOCAL="10.41.10.1/24"; T_TUNPEER="10.41.10.2/24"; T_TUNMTU=1400
( systemctl() { :; }; write_link_unit iran-tun-gre )
gu="$UNIT_DIR/pingify@iran-tun-gre.service"
if [ -x "$CORE_BIN" ]; then
    want_gre="$("$CORE_BIN" -derivekey "a-real-secret" | awk '{print $2}')"
    check "gre stamps the derived key" "$(grep -c "key $want_gre" "$gu")" "1"
fi
unset -f awg

# ---------------------------------------------------------------------------
note "the forwarding does the one thing that makes it quick"
# ---------------------------------------------------------------------------
# A tunnel carries a smaller packet than the path it rides on, so two ends
# setting up a TCP session through it agree a segment size the tunnel cannot
# take - and then stall on the first real transfer while both patiently retry
# a packet that never fits. It reads as a slow link with nothing wrong at
# either end.
fw() { awk '/^nat_rules_for\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh; }
check "the announced segment is clamped" "$(fw | grep -c 'clamp-mss-to-pmtu')" "1"
check "only on the tunnel interface"     "$(fw | grep -c 'PINGIFY_MSS -o "\$T_TUNIF"')" "1"
check "and only on the handshake"        "$(fw | grep -c 'tcp --syn')" "1"
check "the reverse path filter is off"   "$(fw | grep -c 'rp_filter=0')" "1"
check "the chain is hooked in"           "$(grep -c 'mangle -I FORWARD 1 -j PINGIFY_MSS' Pingify.sh)" "1"
check "and taken out again on uninstall" "$(grep -c 'mss_drop_chain' Pingify.sh)" "2"


# ---------------------------------------------------------------------------
note "the health check asks the right question of the right forwarder"
# ---------------------------------------------------------------------------
# What "bound" means depends on who forwards. Our core binds the port and
# accepts on it; the kernel binds nothing at all - a DNAT rule rewrites the
# destination in PREROUTING, before any socket is consulted. Asking whether
# something is listening reported a fault on every working iptables tunnel,
# and offered a restart that could not help.
hcf() { awk '/^health_check\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh; }
check "it splits on the forwarder"   "$(hcf | grep -c 'T_FORWARDER" = "iptables"')" "3"
check "and looks for a rule instead" "$(hcf | grep -c 'no forwarding rule for')"    "1"
check "the core probe is skipped for kernel tunnels" \
      "$(hcf | grep -c '! kernel_transport')" "1"
check "which get their own instead"  "$(hcf | grep -c 'kernel_probe')"              "1"

# The kernel probe crosses the private link, the way real traffic does.
kp() { awk '/^kernel_probe\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh; }
check "it opens the far port"        "$(kp | grep -c 'tcp_reaches')"                "1"
check "and says where to look"       "$(kp | grep -c 'ss -ltnp')"                   "1"
check "including the 0.0.0.0 trap"   "$(kp | grep -c '0.0.0.0, not on 127.0.0.1')"  "1"

# ---------------------------------------------------------------------------
note "a device is named after its tunnel, and never twice"
# ---------------------------------------------------------------------------
# pfy0 said nothing: not which tunnel it belonged to, not what it carried, and
# on a server with two of them not even which was which. It was also the same
# answer every time, so a second ICMP tunnel took the first one's name and
# then could not create its interface.
DEV="$WORK/dev"; mkdir -p "$DEV"
(
    CFG_DIR="$DEV"
    have() { case "$1" in ip | ss | tc) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
    nmi() { ( T_ROLE="$1"; T_TRANSPORT="$2"; link_iface "$3" ); }
    echo "icmp=$(nmi server icmp iran-tun-icmp)"
    echo "gre=$(nmi server gre iran-tun-gre)"
    echo "awg=$(nmi client awg kharej-tun-awg)"

    mkd() {
        cfg_reset
        T_ROLE="server"; T_KIND="tun"; T_TRANSPORT="icmp"; cfg_mode
        T_NAME="$1"; T_TUNIF="$2"; T_TOKEN="$TOKEN"
        T_PUBLIC_IP="203.0.113.9"; T_PEER_IP="198.51.100.4"
        T_TUNLOCAL="10.$3.10.1/24"; T_TUNPEER="10.$3.10.2/24"
        T_FORWARDS='"443"'; T_STATUS="127.0.0.1:9700"
        cfg_save >/dev/null
    }
    T_TRANSPORT="icmp"
    echo "first=$(free_tun_iface iran-tun-icmp)"
    mkd iran-tun-icmp icmp-iran 10
    echo "second=$(free_tun_iface iran-tun-icmp)"
    echo "owner=$(iface_owner icmp-iran)"
    echo "own=$(iface_owner icmp-iran iran-tun-icmp)"
    echo "spare=$(iface_owner icmp-nobody)"
) > "$WORK/dev.out" 2>&1
dv() { grep -m1 "^$1=" "$WORK/dev.out" | cut -d= -f2-; }
check "an icmp device says so"          "$(dv icmp)"   "icmp-iran"
check "and a gre one"                   "$(dv gre)"    "gre-iran"
check "and an awg one, on its own side" "$(dv awg)"    "awg-kharej"
check "the name is offered when free"   "$(dv first)"  "icmp-iran"
check "and counted up when taken"       "$(dv second)" "icmp-iran2"
check "a taken device names its owner"  "$(dv owner)"  "iran-tun-icmp"
check "a tunnel may keep its own"       "$(dv own)"    ""
check "an unused one is free"           "$(dv spare)"  ""
check "the wizard refuses a taken device"       "$(awk '/^new_tunnel\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh | grep -c 'iface_owner "')" "1"

# ---------------------------------------------------------------------------
note "the queue on a tunnel is not one deep pipe"
# ---------------------------------------------------------------------------
# A single FIFO is what makes a loaded tunnel feel bad rather than merely
# full: one large download fills it and every small packet behind it - the
# next video chunk request, a chat message, an ACK - waits behind the whole
# backlog. It reads as stalling while the throughput graph looks fine.
nrf() { awk '/^nat_rules_for\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh; }
check "each flow gets its own queue" "$(nrf | grep -c 'root fq_codel')" "1"
check "on the tunnel interface"      "$(nrf | grep -c 'tc qdisc replace dev "\$T_TUNIF"')" "1"
check "and only when tc is there"    "$(nrf | grep -c 'have tc')" "1"

# ---------------------------------------------------------------------------
note "enter leaves a menu instead of choosing from it"
# ---------------------------------------------------------------------------
pt() { awk '/^pick_tunnel\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh; }
check "the picker offers no default" "$(pt | grep -c 'ask sel "select"$')" "1"
check "so an empty answer goes back" "$(pt | grep -c "''|\*\[!0-9\]\*) return 1")" "1"


# ---------------------------------------------------------------------------
note "the speed test measures the tunnel, not the path beside it"
# ---------------------------------------------------------------------------
# Measuring to the other server's public address would measure the public
# path, which is the one thing here that is not the tunnel - and it would give
# a confident wrong answer to the only question this feature exists to settle.
(
    cfg_reset
    T_TUNLOCAL="10.30.10.1/24"; T_TUNPEER="10.30.10.2/24"; T_PEER_IP="198.51.100.4"
    T_FORWARDS='"8007"'
    speed_over_link && echo "link=yes" || echo "link=no"

    cfg_reset
    T_TUNLOCAL=""; T_TUNPEER=""; T_PEER_IP="198.51.100.4"
    T_FORWARDS='"8007=9007"'
    speed_over_link && echo "nolink=wrong" || echo "nolink=port"
    echo "ports=$(speed_first_port)"

    cfg_reset
    T_FORWARDS='"8000-8010=9000"'
    echo "range=$(speed_first_port)"

    cfg_reset
    T_FORWARDS='"udp:500"'
    if speed_first_port >/dev/null 2>&1; then echo "udp=accepted"; else echo "udp=refused"; fi
) > "$WORK/speed.out" 2>&1
sp() { grep -m1 "^$1=" "$WORK/speed.out" | cut -d= -f2-; }

check "a private link is measured across"  "$(sp link)"   "yes"
check "without one it goes through a port" "$(sp nolink)" "port"
check "the near and far ports both travel" "$(sp ports)"  "8007 9007"
check "a range is measured at its first"   "$(sp range)"  "8000 9000"
check "udp is not measurable this way"     "$(sp udp)"    "refused"
# the public address must never become the target
sr() { awk '/^speed_run\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh; }
check "the public address is never the target" "$(sr | grep -c 'T_PEER_IP')" "0"


# ---------------------------------------------------------------------------
note "ten tunnels of one kind stay in order"
# ---------------------------------------------------------------------------
# A GRE tunnel has no port to be named after, so with more than one of them
# something else has to tell them apart. A counter says only which was second.
# The private network says which one it is - and both servers agreed on that,
# so both ends of one tunnel reach the same name without being told it.
#
# Always, not only on a clash: ten tunnels where one is bare and nine are
# numbered is not an order, it is an exception with nine examples.
nmo() { ( T_ROLE="$1"; T_TRANSPORT="$2"; T_PORT=9443; tunnel_default_name "$3" ); }
check "a gre tunnel carries its network"  "$(nmo server gre 10)"  "iran-tun-gre-10"
check "and the next one"                  "$(nmo server gre 20)"  "iran-tun-gre-20"
check "the far end reaches the same"      "$(nmo client gre 20)"  "kharej-tun-gre-20"
check "icmp is named the same way"        "$(nmo server icmp 35)" "iran-tun-icmp-35"
check "and awg"                           "$(nmo client awg 44)"  "kharej-tun-awg-44"
# TCP already had a shared number of its own - the port both ends agreed on
check "tcp keeps its port"                "$(nmo server tcp 20)"  "iran-9443"

# the octet is read back out of the address, which is where both ends get it
oct() { ( T_TUNLOCAL="$1"; link_octet ); }
check "the network reads out of the address" "$(oct 10.20.10.1/24)" "20"
check "on either side of it"                 "$(oct 10.20.10.2/24)" "20"
check "a three digit one too"                "$(oct 10.144.10.1/24)" "144"
check "a hand-set network outside 10 has none" \
      "$(oct 172.16.5.1/24 || echo none)" "none"

# and the device follows the tunnel, with the transport not said twice
dvo() { ( T_TRANSPORT="$1"; link_iface "$2" ); }
check "the device carries it too"    "$(dvo gre iran-tun-gre-20)"     "gre-iran-20"
check "on the far side"              "$(dvo gre kharej-tun-gre-35)"   "gre-kharej-35"
check "and for icmp"                 "$(dvo icmp iran-tun-icmp-10)"   "icmp-iran-10"
check "the transport is not repeated" \
      "$(printf '%s' "$(dvo gre iran-tun-gre-20)" | grep -c 'gre.*gre')" "0"
long="$(dvo awg kharej-tun-awg-144)"
check "and it still fits in fifteen"  "$([ "${#long}" -le 15 ] && echo y)" "y"

# ---------------------------------------------------------------------------
note "the health port is one per tunnel, and says whose is whose"
# ---------------------------------------------------------------------------
# It has to be one each: a tunnel is a process, and two processes cannot bind
# one port. What it should not be is invisible.
HP="$WORK/health"; mkdir -p "$HP"
(
    CFG_DIR="$HP"
    have() { case "$1" in ip | ss | tc) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
    mkh() {
        cfg_reset
        T_ROLE="server"; T_KIND="tcp"; T_TRANSPORT="tcp"; T_ACCEPTS="server"; cfg_mode
        T_NAME="$1"; T_PORT="$2"; T_STATUS="127.0.0.1:$3"
        T_TOKEN="$TOKEN"; T_PUBLIC_IP="203.0.113.9"; T_FORWARDS='"443"'
        cfg_save >/dev/null
    }
    mkh hp-a 9443 9700
    mkh hp-b 9444 9701
    echo "a=$(health_owner 9700)"
    echo "b=$(health_owner 9701)"
    echo "free=$(health_owner 9702)"
    echo "own=$(health_owner 9700 hp-a)"
    echo "lines=$(show_taken_health | grep -c 9700)"
) > "$WORK/health.out" 2>&1
hp() { grep -m1 "^$1=" "$WORK/health.out" | cut -d= -f2-; }
check "a taken health port names its tunnel" "$(hp a)"    "hp-a"
check "and the next one"                     "$(hp b)"    "hp-b"
check "an unused one is free"                "$(hp free)" ""
check "a tunnel may keep its own"            "$(hp own)"  ""
check "and the listing shows them"           "$(hp lines)" "1"
eh() { awk '/^edit_health\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh; }
check "changing one lists the others"        "$(eh | grep -c 'show_taken_health')" "1"
check "and refuses a taken one"              "$(eh | grep -c 'health_owner')"      "1"


# ---------------------------------------------------------------------------
note "blocking ping does not blind the tunnels to each other"
# ---------------------------------------------------------------------------
# icmp_echo_ignore_all is global, and a private link is not public. A server
# told to ignore every echo also ignored the one its own health check sent
# across the link - so building an ICMP tunnel, which turns the block on, made
# every GRE tunnel on the same pair read as down while carrying traffic.
#
# A rule can tell the two apart; the kernel flag cannot.
BLK="$WORK/blk"; mkdir -p "$BLK"
(
    CFG_DIR="$BLK"; STATE_DIR="$BLK/.s"; mkdir -p "$STATE_DIR"
    systemctl() { :; }; sysctl() { :; }
    have() { case "$1" in iptables) return 0 ;; ip | ss | tc) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
    iptables() { echo "RULE $*"; }
    mkb() {
        cfg_reset
        T_ROLE="server"; T_TRANSPORT="$1"; [ "$1" = "icmp" ] && T_KIND="tun"; cfg_mode
        T_TUNLOCAL="10.$2.10.1/24"; T_TUNPEER="10.$2.10.2/24"
        T_NAME="$(tunnel_default_name "$(link_octet)")"; T_TUNIF="$(link_iface "$T_NAME")"
        T_TOKEN="$TOKEN"; T_PUBLIC_IP="203.0.113.9"; T_PEER_IP="198.51.100.4"
        T_FORWARDS='"443"'
        kernel_transport || T_STATUS="127.0.0.1:9700"
        cfg_save >/dev/null
    }
    mkb icmp 10
    mkb gre 20
    : > "$STATE_DIR/block-icmp"
    apply_blocking quiet > "$BLK/on.txt" 2>&1
    rm -f "$STATE_DIR/block-icmp"
    apply_blocking quiet > "$BLK/off.txt" 2>&1
) > /dev/null 2>&1

check "the private links are let through" \
      "$(grep -c 'icmp-type echo-request -j ACCEPT' "$BLK/on.txt")" "2"
check "the gre link by name"  "$(grep -c -- '-i gre-iran-20 .*ACCEPT' "$BLK/on.txt")"   "1"
check "and the icmp one"      "$(grep -c -- '-i icmp-iran-10 .*ACCEPT' "$BLK/on.txt")"  "1"
check "everything else is dropped" \
      "$(grep -c 'icmp-type echo-request -j DROP' "$BLK/on.txt")" "1"
check "the accepts come before the drop" \
      "$([ "$(grep -n 'ACCEPT' "$BLK/on.txt" | tail -1 | cut -d: -f1)" -lt "$(grep -n 'DROP' "$BLK/on.txt" | head -1 | cut -d: -f1)" ] && echo y)" "y"
check "and with the switch off, no icmp rule at all" \
      "$(grep -c 'icmp' "$BLK/off.txt")" "0"

# The blunt kernel flag is only for a server with no firewall to be selective
# with, and it must not be left behind when the rule can do the job.
ab() { awk '/^apply_blocking\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh; }
check "the kernel flag is the fallback only" \
      "$(ab | grep -c 'have iptables; then')" "1"
check "and is cleared when the rule takes over" \
      "$(ab | grep -c 'rm -f /etc/sysctl.d/99-pingify-block.conf')" "2"
# Our own ICMP transport rides in echo replies, which none of this matches.
check "nothing here touches an echo reply" \
      "$(ab | grep -c 'echo-reply')" "0"


# ---------------------------------------------------------------------------
note "the table stays a table when a name gets long"
# ---------------------------------------------------------------------------
# The name column was a fixed 13 characters. The moment a name grew past that -
# which it did as soon as the private network went into it, iran-tun-icmp-11 -
# that row alone slid right and every column after it stopped lining up.
lt() { awk '/^list_tunnels\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh; }
tr_() { awk '/^tunnel_row\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh; }
check "the width is measured"        "$(lt | grep -c '\${#n}" -gt "\$w"')"     "1"
check "the header uses it"           "$(lt | grep -c 'pad_to "NAME" "\$w"')"   "1"
check "and every row is told it"     "$(lt | grep -c 'tunnel_row "\$n" "\$w"')" "1"
check "the row pads to what it was told" "$(tr_ | grep -c 'nw="\${2:-13}"')"   "1"
check "nothing is hardcoded to 13 any more" \
      "$(tr_ | grep -c 'C_OFF}" 13')" "0"

# rendered for real, at both extremes
ALN="$WORK/align"; mkdir -p "$ALN"
(
    CFG_DIR="$ALN"
    svc_state() { printf 'active'; }
    link_up() { return 0; }; link_rtt() { printf '84.0'; }; awg_handshake_age() { return 1; }
    CORE_BIN="$ALN/c"; printf '#!/bin/sh\necho "up 16 16 78.9 3 900"\n' > "$ALN/c"; chmod +x "$ALN/c"
    mka() {
        cfg_reset
        T_ROLE="server"; T_TRANSPORT="$2"; [ "$2" = "icmp" ] && T_KIND="tun"; cfg_mode
        T_TUNLOCAL="10.$3.10.1/24"; T_TUNPEER="10.$3.10.2/24"
        T_NAME="$1"; T_TUNIF="$(link_iface "$T_NAME")"
        T_TOKEN="$TOKEN"; T_PUBLIC_IP="203.0.113.9"; T_PEER_IP="198.51.100.4"
        T_FORWARDS='"443"'
        kernel_transport || T_STATUS="127.0.0.1:9700"
        cfg_save >/dev/null
    }
    mka iran-9443 tcp 12
    mka iran-tun-icmp-11 icmp 11
    list_tunnels
) 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' > "$WORK/align.out"

# every SIDE cell must start in the same column, header included
cols="$(awk '{ i = index($0, "IRAN"); if (i == 0) i = index($0, "SIDE"); if (i) print i }' "$WORK/align.out" | sort -u | wc -l | tr -d ' ')"
check "every row lines up with the header" "$cols" "1"


# ---------------------------------------------------------------------------
note "the MTU is measured, not guessed"
# ---------------------------------------------------------------------------
# A tunnel wraps what it carries, so it carries less than the path allows. Too
# high and every full-size packet is fragmented or silently dropped - which
# reads as "connects fine, then stalls on anything large". Too low and every
# packet wastes room forever. The right number is the path's, minus what this
# transport wraps it in, and the path's is a property of today's route.
check "gre wraps 28 bytes"   "$(transport_overhead gre)"  "28"
check "awg wraps more"       "$(transport_overhead awg)"  "80"
check "and icmp the same"    "$(transport_overhead icmp)" "80"

# The binary search, against a path with a known ceiling.
(
    prev=""
    ping() {
        local sz=0 a
        for a in "$@"; do
            [ "$prev" = "-s" ] && sz="$a"
            prev="$a"
        done
        [ "$((sz + 28))" -le "$FAKE_MTU" ]
    }
    have() { case "$1" in ping) return 0 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }

    for FAKE_MTU in 1500 1432 1280 900; do
        echo "m$FAKE_MTU=$(path_mtu 10.0.0.2)"
    done
    # a path that answers nothing at all is not a small path - it is no answer
    ping() { return 1; }
    if path_mtu 10.0.0.2 >/dev/null 2>&1; then echo "dead=claimed"; else echo "dead=refused"; fi
) > "$WORK/mtu.out" 2>&1
mt() { grep -m1 "^$1=" "$WORK/mtu.out" | cut -d= -f2-; }

check "it finds a full path"        "$(mt m1500)" "1500"
check "and one inside another tunnel" "$(mt m1432)" "1432"
check "and a small one"             "$(mt m1280)" "1280"
check "and one below the floor it searches" "$(mt m900)" "900"
check "a silent path yields nothing" "$(mt dead)" "refused"

# The number people reach for by hand turns out to be the right answer for one
# specific path - which is the argument for measuring rather than copying it.
check "1320 is what awg gets on a 1400 path" \
      "$((1400 - $(transport_overhead awg)))" "1320"

mm() { awk '/^mtu_menu\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh; }
check "it refuses tunnels with no device" "$(mm | grep -c 'cfg_needs_link')" "1"
check "it says when the path is short"    "$(mm | grep -c 'less than a full 1500')" "1"
check "and that both ends must match"     "$(mm | grep -c 'the smaller of the two')" "1"
check "the ping block is named as the reason a path goes silent" \
      "$(mm | grep -c 'ignore ICMP')" "1"


# ---------------------------------------------------------------------------
note "the end that accepts still knows who it is talking to"
# ---------------------------------------------------------------------------
# IRAN does not dial, so there is no connect line in its config and no address
# to read - which is why Find the MTU on the IRAN side said it had no peer to
# measure to. Something did arrive, though, and the core knows what: that is
# the only place on that machine where the far address exists at all.
SP="$WORK/speer"; mkdir -p "$SP"
(
    CFG_DIR="$SP"; CORE_BIN="$SP/c"
    cfg_reset
    T_ROLE="server"; T_KIND="tun"; T_TRANSPORT="icmp"; cfg_mode
    T_NAME="sp"; T_TOKEN="$TOKEN"; T_PUBLIC_IP="185.31.8.93"
    T_TUNLOCAL="10.11.10.1/24"; T_TUNPEER="10.11.10.2/24"; T_TUNIF="icmp-iran-11"
    T_FORWARDS='"443"'; T_STATUS="127.0.0.1:9700"
    cfg_save >/dev/null

    cfg_load sp >/dev/null 2>&1
    echo "config=$T_PEER_IP"

    { echo '#!/bin/sh'; echo 'cat <<JSON';
      echo '{"name":"sp","peer":"2.26.26.37","carriers_up":16}'; echo 'JSON'; } > "$SP/c"
    chmod +x "$SP/c"
    echo "attached=$(status_peer sp)"

    # nothing has connected: the core reports the address it listens on, which
    # is this machine's own and no use to anyone asking
    { echo '#!/bin/sh'; echo 'cat <<JSON';
      echo '{"peer":"listen 185.31.8.93"}'; echo 'JSON'; } > "$SP/c"
    chmod +x "$SP/c"
    echo "idle=$(status_peer sp)"

    # and a core that will not answer at all
    { echo '#!/bin/sh'; echo 'exit 1'; } > "$SP/c"; chmod +x "$SP/c"
    echo "down=$(status_peer sp)"
) > "$WORK/speer.out" 2>&1
sp() { grep -m1 "^$1=" "$WORK/speer.out" | cut -d= -f2-; }

check "the accepting config names no peer" "$(sp config)"   ""
check "but the running tunnel does"        "$(sp attached)" "2.26.26.37"
check "an idle listen address is not one"  "$(sp idle)"     ""
check "and a core that is down says nothing" "$(sp down)"   ""

mm() { awk '/^mtu_menu\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh; }
check "the MTU page asks the tunnel"  "$(mm | grep -c 'status_peer')" "1"
check "and explains itself when it cannot" \
      "$(mm | grep -c 'accepts rather than dials')" "1"

# The extraction has no backslash escapes in it, because this file is
# assembled into one script by a build that has eaten a backslash before -
# turning a sed backreference into a literal control byte.
check "no stray control bytes in the build" \
      "$(grep -c "$(printf '\001')" Pingify.sh)" "0"


# ---------------------------------------------------------------------------
note "an update cannot hand you a core that does not match"
# ---------------------------------------------------------------------------
# The script came from the branch and the core from the latest release, and
# those are not the same thing at the same moment: a push changes the raw file
# instantly, while the release carrying the matching core is built afterwards.
# Updating inside that window took a new script and an old core - and then the
# tool reported "core does not match the script" about a fault it had just
# caused itself.
su() { awk '/^self_update\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh; }
check "the script comes from the release" "$(su | grep -c 'release_base.*Pingify.sh')" "1"
check "the branch is only a fallback"     "$(su | grep -c 'trying the branch')"        "1"
check "and it is tried second"                  "$([ "$(su | grep -n 'release_base' | cut -d: -f1)" -lt "$(su | grep -n 'RAW_BASE' | cut -d: -f1)" ] && echo y)" "y"
# and whatever happens, a mismatched core is corrected on the next run. The
# full install ladder is intentional: matching release, embedded offline build,
# then the existing recovery paths rather than download-only.
ec() { awk '/^ensure_core_current\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh; }
check "a mismatch installs a matching core" "$(ec | grep -c 'install_core')" "1"
check "and it names no menu that is gone" "$(ec | grep -c 'Update core in the menu')" "0"

# ---------------------------------------------------------------------------
note "the speed test says what the number means"
# ---------------------------------------------------------------------------
# It ran, printed iperf's own output, and stopped. 412 Mbit/s is excellent on a
# path that carries 460 and dreadful on one that carries 900, and only the pair
# tells you which you have - so it measures both and compares them.
# The names have to say what they are: one is iperf3 between the two servers,
# the other is a speedtest of this machine on its own. Calling the first one
# "Speed test" hid the second, which is the one that actually is one.
check "the iperf option is named for it"   "$(grep -c 'item 3 "iperf3"' Pingify.sh)"  "1"
check "and the other says speedtest"       "$(grep -c 'Benchmark & Speedtest' Pingify.sh)" "2"
check "neither is called just Speed test"  "$(grep -c 'item [0-9] "Speed test"' Pingify.sh)" "0"

# Two steps, in order, and the screen says which server each belongs on -
# with the one you are standing on marked, since that is the question a person
# actually has in front of them.
sm() { awk '/^speed_menu\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh; }
check "the listener is placed on KHAREJ" "$(sm | grep -c 'on KHAREJ, first')"    "1"
check "the test on IRAN"                 "$(sm | grep -c 'on IRAN, after that')" "1"
check "this server is marked"            "$(sm | grep -c 'this server')"         "2"
check "and there are only two steps"     "$(sm | grep -cE 'say "  \$\{C_B\}[12]')" "2"
check "which side we are on is read from the tunnels"       "$(sm | grep -c 'this_side')" "1"
ts() { ( CFG_DIR="$WORK/nothing-here"; this_side ); }
check "with no tunnels it claims nothing" "$(ts)" ""

check "twenty parallel streams" "$IPERF_STREAMS" "20"
check "ten seconds each way"    "$IPERF_SECONDS" "10"

# the [SUM] line is the only number that means anything in a 20-stream run
SUMOUT="[SUM]   0.00-10.00  sec  1.09 GBytes   938 Mbits/sec  120   sender
[SUM]   0.00-10.00  sec  1.08 GBytes   931 Mbits/sec        receiver"
check "the sender total is read"   "$(iperf_bitrate "$SUMOUT" sender)"   "938 Mbits/sec"
check "and the receiver total"     "$(iperf_bitrate "$SUMOUT" receiver)" "931 Mbits/sec"
check "a per-stream line is ignored" \
      "$(iperf_bitrate '[  5]  0.00-10.00  sec  50.0 MBytes  42.0 Mbits/sec  sender' sender)" ""

check "megabits stay megabits"  "$(mbits '938 Mbits/sec')" "938"
check "gigabits are converted"  "$(mbits '2.4 Gbits/sec')" "2400"
check "kilobits too"            "$(mbits '4000 Kbits/sec')" "4"
check "and nonsense is zero"    "$(mbits 'no reading')"    "0"

# the verdict, which is the part iperf cannot give you
rep() { ( banner() { :; }; pause() { :; }; PICKED=t; speed_report "$1" "$2" "$3" "$4" ) 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }
check "a tunnel keeping up is called good" \
      "$(rep '412 Mbits/sec' '388 Mbits/sec' '460 Mbits/sec' '450 Mbits/sec' | grep -c 'as good as this gets')" "1"
check "one losing most of it is not" \
      "$(rep '90 Mbits/sec' '85 Mbits/sec' '460 Mbits/sec' '450 Mbits/sec' | grep -c 'only 19%')" "1"
check "and it says where to look next" \
      "$(rep '90 Mbits/sec' '85 Mbits/sec' '460 Mbits/sec' '450 Mbits/sec' | grep -c 'Find the MTU')" "1"
check "a middling one suggests the window" \
      "$(rep '300 Mbits/sec' '290 Mbits/sec' '460 Mbits/sec' '450 Mbits/sec' | grep -c 'Tuning')" "1"
check "with only one measurement it asks for the other" \
      "$(rep '412 Mbits/sec' '388 Mbits/sec' '' '' | grep -c 'Run it against the raw path too')" "1"

# ---------------------------------------------------------------------------
note "the firewall page does not claim Pingify is an iptables tool"
# ---------------------------------------------------------------------------
# A tunnel is carried by the engine or by the kernel. The firewall is involved
# only when a tunnel's forwarder is IPTABLES, or when something under Blocking
# is on - so an empty list is a normal state, not a fault.
sn() { awk '/^show_nat\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh; }
check "it shows the forwarding chain"  "$(sn | grep -c 'PINGIFY_NAT')"  "1"
check "the segment-size chain too"     "$(sn | grep -c 'PINGIFY_MSS')"  "1"
check "and the blocking chains"        "$(sn | grep -c 'PINGIFY_IN')"   "2"
check "empty is reported as normal"    "$(sn | grep -c 'Which is normal')" "1"
check "and it says when PINGIFY forwards instead" \
      "$(sn | grep -c 'forwarded by')" "3"
check "the menu no longer says iptables does Pingify" \
      "$(grep -c 'what iptables is doing for Pingify' Pingify.sh)" "0"

# ---------------------------------------------------------------------------
note "ping the other end asks the tunnel before asking a person"
# ---------------------------------------------------------------------------
# Same fault the MTU page had: the accepting side has no configured peer, so it
# gave up and asked you to type it - when the running tunnel knew.
dp() { awk '/^diag_ping\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh; }
check "it asks the running tunnel" "$(dp | grep -c 'status_peer')" "1"
check "and only then a person"     "$(dp | grep -c 'ask host')"    "1"

# ---------------------------------------------------------------------------
note "the benchmark is honest about what it runs"
# ---------------------------------------------------------------------------
# It fetches a script written by somebody else and runs it as root. That is a
# reasonable thing to want and an unreasonable thing to do quietly.
bm() { awk '/^bench_menu\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh; }
check "the address is on screen first" "$(bm | grep -c 'BENCH_URL')"        "2"
check "it warns whose script it is"    "$(bm | grep -c 'written by someone else')" "1"
check "and nothing runs unasked"       "$(bm | grep -c 'confirm ')"         "1"
check "it downloads before running"    "$(bm | grep -c 'fetch "\$BENCH_URL"')" "1"


# ---------------------------------------------------------------------------
note "a transport is a seam now, not a branch"
# ---------------------------------------------------------------------------
# The pool used to switch on transport in two places - one in start, one in
# dialCarrier - so a fifth transport meant a fifth branch in each. It asks an
# interface for three things now, and adding one is writing those three.
check "udp has a label"        "$(transport_label udp)"  "UDP"
check "and is offered"         "$(grep -c 'choice 6 "UDP ARQ"' Pingify.sh)" "1"
check "nine protocols"         "$(grep -c 'pick proto "select" 1 2 3 4 5 6 7 8 9' Pingify.sh)" "1"

# It carries ports like TCP does, so it is named and addressed like TCP
nu() { ( T_ROLE="$1"; T_TRANSPORT="udp"; T_PORT=9443; tunnel_default_name ); }
# a udp tunnel says so: tcp and udp can hold 9443 at the same time
check "named for its port and protocol" "$(nu server)" "iran-udp-9443"
check "on the far side too"             "$(nu client)" "kharej-udp-9443"
ep() { ( cfg_reset; T_ROLE="$1"; T_TRANSPORT="udp"; T_PORT=9443
         T_PUBLIC_IP="203.0.113.9"; T_PEER_IP="198.51.100.4"
         T_ACCEPTS="server"; cfg_endpoints
         printf '%s|%s' "$CFG_LISTEN" "$CFG_CONNECT" ); }
check "IRAN accepts on the port" "$(ep server)" "0.0.0.0:9443|"
check "KHAREJ dials it"          "$(ep client)" "|198.51.100.4:9443"

# and the core accepts the config it writes
UDPC="$WORK/udpcfg"; mkdir -p "$UDPC"
(
    CFG_DIR="$UDPC"
    cfg_reset
    T_ROLE="server"; T_TRANSPORT="udp"; T_ACCEPTS="server"; cfg_mode
    T_NAME="iran-9443"; T_PORT=9443; T_TOKEN="$TOKEN"
    T_PUBLIC_IP="203.0.113.9"; T_FORWARDS='"443"'; T_STATUS="127.0.0.1:9700"
    f="$(cfg_save)" && echo "file=$f"
) > "$WORK/udpcfg.out" 2>&1
uf="$(grep -m1 '^file=' "$WORK/udpcfg.out" | cut -d= -f2-)"
check "a udp config is written" "$(basename "${uf:-none}")" "iran-9443.toml"
check "with the transport set"  "$(toml_get "$uf" transport type)" "udp"
if [ -n "${CORE_BIN:-}" ] && [ -x "${CORE_BIN:-}" ]; then
    "$CORE_BIN" -c "$uf" -check >/dev/null 2>&1
    check "and the core accepts it" "$?" "0"
fi

# KCP+FEC and PCK share the low-latency packet engine, but claim different
# socket families and are never silently rendered as legacy UDP/TCP.
check "kcp has its own label" "$(transport_label kcp)" "KCP+FEC"
check "pck has its own label" "$(transport_label pck)" "TCP+PCK"
check "kcp is offered first" "$(grep -c 'choice 1 "KCP + FEC"' Pingify.sh)" "1"
check "pck is offered"       "$(grep -c 'choice 5 "TCP + PCK"' Pingify.sh)" "1"
check "pck source port matches core" "$(pck_source_port "$TOKEN" 443)" "28817"
check "pck avoids the remote port" "$(pck_source_port "$TOKEN" 28817)" "28818"
check "pck health checks outbound NOTRACK" "$(grep -c 'iptables -t raw -C OUTPUT -p tcp --sport.*NOTRACK' Pingify.sh)" "1"

PKTC="$WORK/packetcfg"; mkdir -p "$PKTC"
for tr in kcp pck; do
    (
        CFG_DIR="$PKTC"
        cfg_reset
        T_ROLE="server"; T_TRANSPORT="$tr"; T_ACCEPTS="server"; cfg_mode
        T_NAME="iran-$tr-9443"; T_PORT=9443; T_TOKEN="$TOKEN"
        T_PUBLIC_IP="203.0.113.9"; T_FORWARDS='"443"'; T_STATUS="127.0.0.1:9700"
        cfg_save >/dev/null
    )
done
kf="$PKTC/iran-kcp-9443.toml"; pf="$PKTC/iran-pck-9443.toml"
check "kcp writes real FEC data shards" "$(toml_get "$kf" kcp data_shards)" "10"
check "kcp writes parity shards" "$(toml_get "$kf" kcp parity_shards)" "3"
check "kcp writes its packet MTU" "$(toml_get "$kf" kcp mtu)" "1200"
check "pck writes its TCP flags" "$(toml_get "$pf" pck flags)" "PA"
if [ -n "${CORE_BIN:-}" ] && [ -x "${CORE_BIN:-}" ]; then
    "$CORE_BIN" -c "$kf" -check >/dev/null 2>&1
    check "the core accepts kcp+fec" "$?" "0"
    "$CORE_BIN" -c "$pf" -check >/dev/null 2>&1
    check "the core accepts tcp+pck" "$?" "0"
fi

T_TRANSPORT="kcp"; apply_preset balanced >/dev/null
check "balanced kcp uses a small pool" "$T_CARRIERS" "4"
T_TRANSPORT="pck"; apply_preset gaming >/dev/null
check "gaming pck stays one session" "$T_CARRIERS" "1"


# ---------------------------------------------------------------------------
note "the tunnel's own port is claimed too"
# ---------------------------------------------------------------------------
# Only the forwarded ports were ever checked. The port the two servers meet on
# was not, so a second tunnel could take one the first was already accepting
# on, and only the second one's log would say why it would not start.
#
# TCP 9443 and UDP 9443 are two different sockets and neither blocks the other,
# so the protocol is half the question - and the names have to say which is
# which, or the second is iran-9443-2 and tells you nothing.
TPO="$WORK/tport"; mkdir -p "$TPO"
(
    CFG_DIR="$TPO"
    have() { case "$1" in ss | ip | tc) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
    mkp() {
        cfg_reset
        T_ROLE="$1"; T_TRANSPORT="$2"; T_ACCEPTS="server"; cfg_mode
        T_PORT="$3"; T_NAME="$(tunnel_default_name)"; T_TOKEN="$TOKEN"
        T_PUBLIC_IP="203.0.113.9"; T_PEER_IP="198.51.100.4"
        T_FORWARDS='"443"'; T_STATUS="127.0.0.1:9700"
        cfg_save >/dev/null
        echo "name=$T_NAME"
    }
    mkp server udp 9443
    mkp server tcp 9443
    echo "udp9443=$(tunnel_port_owner 9443 udp)"
    echo "tcp9443=$(tunnel_port_owner 9443 tcp)"
    echo "tcp9444=$(tunnel_port_owner 9444 tcp)"
    echo "own=$(tunnel_port_owner 9443 udp iran-udp-9443)"
    # a tunnel that dials binds nothing here, so it cannot be the owner
    cfg_reset
    T_ROLE="client"; T_TRANSPORT="tcp"; T_ACCEPTS="server"; cfg_mode
    T_PORT=7000; T_NAME="kharej-7000"; T_TOKEN="$TOKEN"
    T_PUBLIC_IP="198.51.100.4"; T_PEER_IP="203.0.113.9"; T_STATUS="127.0.0.1:9701"
    cfg_save >/dev/null
    echo "dialled=$(tunnel_port_owner 7000 tcp)"
) > "$WORK/tport.out" 2>&1
tp() { grep -m1 "^$1=" "$WORK/tport.out" | cut -d= -f2-; }

check "a udp tunnel names itself"     "$(grep -m1 '^name=' "$WORK/tport.out" | cut -d= -f2-)" "iran-udp-9443"
check "and tcp keeps the plain name"  "$(grep '^name=' "$WORK/tport.out" | sed -n 2p | cut -d= -f2-)" "iran-9443"
# What collides is the SOCKET, not the transport name. WS and WSS are HTTP
# over TCP, so a plain TCP tunnel blocks a WS one on the same port - while a
# UDP tunnel on that port does not. Asking by name got that backwards and
# called a real clash free.
check "ws is a tcp socket"   "$(port_family ws)"   "tcp"
check "and wss too"          "$(port_family wss)"  "tcp"
check "pck is TCP-shaped"    "$(port_family pck)"  "tcp"
check "udp is its own"       "$(port_family udp)"  "udp"
check "kcp binds UDP"        "$(port_family kcp)"  "udp"
check "awg binds udp"        "$(port_family awg)"  "udp"
check "icmp binds no port"   "$(port_family icmp)" "none"
check "and neither does gre" "$(port_family gre)"  "none"

check "a taken udp port names its owner" "$(tp udp9443)" "iran-udp-9443"
check "and the tcp one is separate"      "$(tp tcp9443)" "iran-9443"
check "an unused port is free"           "$(tp tcp9444)" ""
check "a tunnel may keep its own"        "$(tp own)"     ""
check "a dialled port binds nothing here" "$(tp dialled)" ""

# the cases the family mapping exists for
FAM="$WORK/fam"; mkdir -p "$FAM"
(
    CFG_DIR="$FAM"
    have() { case "$1" in ss | ip | tc) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
    mkf() {
        cfg_reset
        T_ROLE="server"; T_TRANSPORT="$1"; T_ACCEPTS="server"
        [ "$1" = "icmp" ] && T_KIND="tun"
        cfg_mode
        T_PORT="$2"; T_NAME="$(tunnel_default_name)"; T_TOKEN="$TOKEN"
        T_PUBLIC_IP="203.0.113.9"; T_PEER_IP="198.51.100.4"; T_FORWARDS='"443"'
        T_TUNLOCAL="10.11.10.1/24"; T_TUNPEER="10.11.10.2/24"
        kernel_transport || T_STATUS="127.0.0.1:9700"
        cfg_save >/dev/null
    }
    mkf tcp 8443
    mkf udp 9443
    mkf icmp 0
    echo "ws_on_tcp=$(tunnel_port_owner 8443 ws)"
    echo "wss_on_tcp=$(tunnel_port_owner 8443 wss)"
    echo "udp_on_tcp=$(tunnel_port_owner 8443 udp)"
    echo "ws_on_udp=$(tunnel_port_owner 9443 ws)"
    echo "lines=$(show_taken_tunnel_ports | grep -c 'icmp')"
) > "$WORK/fam.out" 2>&1
fm() { grep -m1 "^$1=" "$WORK/fam.out" | cut -d= -f2-; }

check "a tcp tunnel blocks a ws one"     "$(fm ws_on_tcp)"  "iran-8443"
check "and a wss one"                    "$(fm wss_on_tcp)" "iran-8443"
check "but not a udp one"                "$(fm udp_on_tcp)" ""
check "and a udp tunnel does not block ws" "$(fm ws_on_udp)" ""
# ICMP has no port, so listing one was reading an address as a port number
check "a portless tunnel is not listed"  "$(fm lines)"      "0"

wz() { awk '/^new_tunnel\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh; }
check "the wizard lists what is taken" "$(wz | grep -c 'show_taken_tunnel_ports')" "1"
check "and refuses a repeat"           "$(wz | grep -c 'tunnel_port_owner')"       "1"
# by socket family, so a ws tunnel is checked against tcp listeners
check "and a port the host has bound"  "$(wz | grep -c 'port_free "\$T_PORT" "\$(port_family')" "1"
check "only the end that binds is asked" "$(wz | grep -c 'this_side_accepts && show_taken_tunnel_ports')" "1"
# udp and tcp are different sockets, and port_free has to know that
check "port_free takes a protocol" "$(grep -c 'udp) ! ss -Hlun' Pingify.sh)" "1"


# ---------------------------------------------------------------------------
note "WebSocket goes where the web goes"
# ---------------------------------------------------------------------------
# The only family with no equivalent here before: everything else looks like
# what it is, and on a path that passes 80 and nothing else, none of them go
# anywhere. This one is an HTTP request that becomes a WebSocket.
#
check "ws has a label"      "$(transport_label ws)"  "WS"
check "wss has a label"     "$(transport_label wss)" "WSS"
check "nine protocols now"  "$(grep -c 'pick proto "select" 1 2 3 4 5 6 7 8 9' Pingify.sh)" "1"
check "wss is offered"      "$(grep -c 'choice 3 "WSS MUX"' Pingify.sh)" "1"
check "ws is offered"       "$(grep -c 'choice 7 "WS MUX"' Pingify.sh)" "1"

# Each names itself, since several can hold 443 at once on one server
nw() { ( T_ROLE="$1"; T_TRANSPORT="$2"; T_PORT=443; tunnel_default_name ); }
check "a ws tunnel says so"   "$(nw server ws)" "iran-ws-443"
check "and a ws one"          "$(nw client ws)"  "kharej-ws-443"
check "a wss tunnel says so"  "$(nw server wss)" "iran-wss-443"
check "tcp keeps the plain name" "$(nw server tcp)" "iran-443"

# they carry a port, so the port question and its clash check must cover them
wz() { awk '/^new_tunnel\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh; }
check "the port question covers them" "$(wz | grep -c 'tcp | udp | kcp | pck | ws | wss) has_port=1')" "1"

# ---------------------------------------------------------------------------
note "a name says which server first"
# ---------------------------------------------------------------------------
# Which end, then what it is, then which one of those. A list of tunnels is
# read to find out which side you are looking at, and a name that leads with
# the protocol sorts the two halves of one tunnel apart.
nm() { ( T_ROLE="$1"; T_TRANSPORT="$2"; T_PORT="${3:-9443}"; tunnel_default_name "${4:-}" ); }
check "tcp is the plain case"   "$(nm server tcp 9443)"   "iran-9443"
check "ws says so"              "$(nm server ws 9453)"    "iran-ws-9453"
check "and on the other side"   "$(nm client ws 9050)"    "kharej-ws-9050"
check "wss says so"             "$(nm client wss 443)"    "kharej-wss-443"
check "and udp"                 "$(nm server udp 9443)"   "iran-udp-9443"
check "gre leads with the side" "$(nm server gre 0 10)"   "iran-tun-gre-10"
check "icmp as well"            "$(nm client icmp 0 11)"  "kharej-tun-icmp-11"
check "and awg"                 "$(nm server awg 0 12)"   "iran-tun-awg-12"

# The device keeps the protocol first: that is what ip link is read for.
li() { ( T_TRANSPORT="$1"; link_iface "$2" ); }
check "the device reads protocol first" "$(li gre iran-tun-gre)"        "gre-iran"
check "with its network when it has one" "$(li gre iran-tun-gre-20)"    "gre-iran-20"
check "and on the far side"             "$(li icmp kharej-tun-icmp-35)" "icmp-kharej-35"

# ---------------------------------------------------------------------------
note "a wizard can be left"
# ---------------------------------------------------------------------------
# Half a wizard is not a tunnel. Before this the only way out of twenty
# questions was ctrl-c, which leaves the terminal to guess what happened.
(
    wiz_reset
    ask v "anything" <<< "q"; echo "rc=$?"
    echo "quit=$WIZ_QUIT"
    # and every question after it returns without waiting for an answer
    ask v2 "and this one" < /dev/null; echo "after=$?"
    pick p2 "select" 1 2 3 < /dev/null; echo "pick=$?"
    confirm_yes "sure?" < /dev/null; echo "confirm=$?"
    wiz_end
    echo "cleared=$WIZ_QUIT"
) > "$WORK/quit.out" 2>&1
qz() { grep -m1 "^$1=" "$WORK/quit.out" | cut -d= -f2-; }
check "q ends the question"        "$(qz rc)"      "1"
check "and marks the wizard done"  "$(qz quit)"    "1"
check "the next one does not ask"  "$(qz after)"   "1"
check "nor does a pick"            "$(qz pick)"    "1"
check "nor a confirmation"         "$(qz confirm)" "1"
check "and leaving clears it"      "$(qz cleared)" "0"

# outside a wizard, q is just an answer - a token or a name may well be "q"
(
    wiz_end
    ask v "anything" <<< "q"; echo "rc=$?"
    echo "val=$v"
) > "$WORK/noquit.out" 2>&1
nq() { grep -m1 "^$1=" "$WORK/noquit.out" | cut -d= -f2-; }
check "q outside a wizard answers" "$(nq rc)"  "0"
check "and keeps the value"        "$(nq val)" "q"

# a closed stdin is not an answer either. This used to spin: read failed, ask
# returned success with nothing in it, and pick asked again.
(
    wiz_end
    pick p3 "select" 1 2 3 < /dev/null
    echo "eof_pick=$?"
    ask v3 "anything" < /dev/null
    echo "eof_ask=$?"
) > "$WORK/eof.out" 2>&1
ez() { grep -m1 "^$1=" "$WORK/eof.out" | cut -d= -f2-; }
check "a closed stdin stops a pick" "$(ez eof_pick)" "1"
check "and a question"              "$(ez eof_ask)"  "1"

# every question in the wizard has to unwind, not just the first
wzf() { awk '/^new_tunnel\(\) \{/{f=1} f&&/^\}/{exit} f' Pingify.sh; }
# Asserted as an equality rather than a count, so a question added later is
# covered without anybody remembering to come back here.
check "every wizard question can be left"       "$(wzf | grep -cE '^\s*(ask|pick) ')"       "$(wzf | grep -cE '^\s*(ask|pick) .*wiz_end; return 0')"
imf() { awk '/^import_tunnel\(\) \{/{f=1} f&&/^\}/{exit} f' Pingify.sh; }
check "and every importer question too"       "$(imf | grep -cE '^\s*(ask|pick) ')"       "$(imf | grep -cE '^\s*(ask|pick) .*wiz_end; return 0')"
# and there is at least one of each, or the check above passes on nothing
check "the wizard does ask things"  "$([ "$(wzf | grep -cE '^\s*(ask|pick) ')" -gt 10 ] && echo yes)" "yes"
check "and so does the importer"    "$([ "$(imf | grep -cE '^\s*(ask|pick) ')" -gt 1 ] && echo yes)" "yes"
check "and the menu resets it"        "$(grep -c '1) new_tunnel; wiz_end ;;' Pingify.sh)" "1"

# ---------------------------------------------------------------------------
note "the token carries the port, whatever the transport"
# ---------------------------------------------------------------------------
# It used to carry it only for tcp. For udp, ws and wss the field went out
# empty and the far end filled it with 9443 - so a ws tunnel built on any
# other port had one end listening where the other was not dialling, and
# neither end said anything. It reported "0 of 16 carriers" and nothing else.
TOKPORT="$WORK/tokport"; mkdir -p "$TOKPORT"
(
    CFG_DIR="$TOKPORT"
    have() { case "$1" in ss | ip | tc) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
    for tr in tcp udp kcp pck ws wss icmp; do
        cfg_reset
        T_ROLE="server"; T_TRANSPORT="$tr"; T_ACCEPTS="server"
        [ "$tr" = "icmp" ] && T_KIND="tun"
        cfg_mode
        T_PORT=9553; T_PUBLIC_IP="203.0.113.9"; T_PEER_IP="198.51.100.4"
        T_TOKEN="$TOKEN"; T_FORWARDS='"443"'
        T_TUNLOCAL="10.11.10.1/24"; T_TUNPEER="10.11.10.2/24"
        raw="$(cfg_setup_token | base64 -d)"
        IFS='|' read -r _v _k _t _m _f _d _h port _rest <<TOK
$raw
TOK
        echo "$tr=${port:-EMPTY}"
    done
) > "$WORK/tokport.out" 2>&1
tkp() { grep -m1 "^$1=" "$WORK/tokport.out" | cut -d= -f2-; }

check "tcp carries its port"  "$(tkp tcp)"  "9553"
check "and so does udp"       "$(tkp udp)"  "9553"
check "and kcp"               "$(tkp kcp)"  "9553"
check "and pck"               "$(tkp pck)"  "9553"
check "and ws"                "$(tkp ws)"   "9553"
check "and wss"               "$(tkp wss)"  "9553"
# icmp has none to carry, and inventing one would be a lie the far end acts on
check "icmp carries none"     "$(tkp icmp)" "EMPTY"

# ---------------------------------------------------------------------------
note "WSS behind a CDN, which is only an address and one extra"
# ---------------------------------------------------------------------------
# For WSS the address IS the domain: it is what gets dialled, what the CDN
# routes on, and what travels in the token like any other address. There is no
# second field for it, and the config says it once, in connect.
#
# An edge is the only genuinely extra thing - an address to dial that is not
# the peer. The name still travels, so it still arrives; only the address
# changes, and it never names the IRAN server.
check "a domain is a name"      "$(is_name tunnel.example.com && echo yes || echo no)" "yes"
check "an address is not"       "$(is_name 203.0.113.9 && echo yes || echo no)"        "no"
check "nor is an v6 address"    "$(is_name 2001:db8::1 && echo yes || echo no)"        "no"
check "nor is nothing"          "$(is_name '' && echo yes || echo no)"                 "no"

check "a CDN proxies these"  "$(cdn_ports)" "443 2053 2083 2087 2096 8443"
check "443 is one of them"   "$(cdn_port_ok 443 && echo yes || echo no)"  "yes"
check "8443 too"             "$(cdn_port_ok 8443 && echo yes || echo no)" "yes"
check "9553 is not"          "$(cdn_port_ok 9553 && echo yes || echo no)" "no"

EDGE="$WORK/edge"; mkdir -p "$EDGE"
(
    CFG_DIR="$EDGE"
    have() { case "$1" in ss | ip | tc) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
    server_info() { :; }

    # IRAN gives its domain where it would give its address. Nothing else.
    cfg_reset
    T_ROLE="server"; T_TRANSPORT="wss"; T_ACCEPTS="server"; cfg_mode
    T_PORT=8443; T_PUBLIC_IP="tunnel.example.com"; T_PEER_IP="198.51.100.4"
    T_TOKEN="$TOKEN"; T_FORWARDS='"443"'
    T_NAME="$(tunnel_default_name)"; T_STATUS="127.0.0.1:9700"
    cfg_save > /dev/null
    raw="$(cfg_setup_token | base64 -d)"
    echo "token_host=$(printf '%s' "$raw" | awk -F'|' '{print $7}' | base64 -d)"
    echo "token_port=$(printf '%s' "$raw" | awk -F'|' '{print $8}')"
    echo "token_fields=$(printf '%s' "$raw" | awk -F'|' '{print NF}')"

    # KHAREJ dials the domain it was given, and says so once
    cfg_reset
    T_ROLE="client"; T_TRANSPORT="wss"; T_ACCEPTS="server"; cfg_mode
    T_PORT=8443; T_PUBLIC_IP="198.51.100.4"; T_PEER_IP="tunnel.example.com"
    T_TOKEN="$TOKEN"; T_NAME="$(tunnel_default_name)"; T_STATUS="127.0.0.1:9701"
    cfg_save > /dev/null
    pf="$(cfg_file "$T_NAME")"
    echo "plain_connect=$(toml_get "$pf" transport connect)"
    echo "plain_host=$(toml_get "$pf" transport host)"
    echo "plain_keys=$(grep -c '^host\|^edge\|^peer' "$pf")"

    # and with an edge, connect holds the way in and host the name to present
    T_EDGE="speedtest.net"; cfg_save > /dev/null
    ef="$(cfg_file "$T_NAME")"
    echo "edge_connect=$(toml_get "$ef" transport connect)"
    echo "edge_host=$(toml_get "$ef" transport host)"

    # an edit gets both back the right way round
    en="$T_NAME"; cfg_reset; cfg_load "$en"
    echo "reload_peer=$T_PEER_IP"
    echo "reload_edge=$T_EDGE"
    cfg_endpoints; echo "reload_dials=$CFG_CONNECT"

    # ws is a different tunnel: an address, and no CDN anywhere near it
    cfg_reset
    T_ROLE="client"; T_TRANSPORT="ws"; T_ACCEPTS="server"; cfg_mode
    T_PORT=8080; T_PUBLIC_IP="198.51.100.4"; T_PEER_IP="203.0.113.9"
    T_TOKEN="$TOKEN"; T_NAME="$(tunnel_default_name)"; T_STATUS="127.0.0.1:9702"
    T_EDGE="speedtest.net"
    cfg_save > /dev/null
    wf="$(cfg_file "$T_NAME")"
    echo "ws_connect=$(toml_get "$wf" transport connect)"
    echo "ws_host=$(toml_get "$wf" transport host)"
) > "$WORK/edge.out" 2>&1
eg() { grep -m1 "^$1=" "$WORK/edge.out" | cut -d= -f2-; }

check "the address travels as the address" "$(eg token_host)"   "tunnel.example.com"
check "with its port beside it"            "$(eg token_port)"   "8443"
# no field was added for the domain, because the address already was one
check "and the token carries all tuning" "$(eg token_fields)" "30"

check "KHAREJ dials the domain"       "$(eg plain_connect)" "tunnel.example.com:8443"
check "and says it only once"         "$(eg plain_host)"    ""
check "no extra keys at all"          "$(eg plain_keys)"    "0"

check "an edge changes the address"   "$(eg edge_connect)"  "speedtest.net:8443"
check "and only then names the peer"  "$(eg edge_host)"     "tunnel.example.com"
check "an edit reads the peer back"   "$(eg reload_peer)"   "tunnel.example.com"
check "and the edge"                  "$(eg reload_edge)"   "speedtest.net"
check "and still dials the edge"      "$(eg reload_dials)"  "speedtest.net:8443"

# WS is not WSS. It has no TLS, so nothing carries a name a CDN could route on
check "ws dials its address"          "$(eg ws_connect)"    "203.0.113.9:8080"
check "and never writes a host"       "$(eg ws_host)"       ""

# the edge is offered on the end that dials, for wss, and nowhere else
ae() { awk '/^ask_edge\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh; }
check "an edge is wss only"     "$(ae | grep -c 'T_TRANSPORT" = "wss" \] || return 0')" "1"
# It still needs a name to present - it just says so now instead of vanishing
check "and needs a name to present" "$(ae | grep -c 'if ! is_name "\$T_PEER_IP"; then')" "1"
im() { awk '/^import_tunnel\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh; }
check "the importer offers it"  "$(im | grep -c 'ask_edge')" "1"

# The end that DIALS is the end an edge belongs to. This read
# "this_side_accepts && ask_edge", which on KHAREJ - the only place it was
# ever meant to run - is false, so the question never appeared at all.
check "and asks the end that dials"       "$(im | grep -c 'this_side_accepts || ask_edge')" "1"
check "not the end that accepts"       "$(im | grep -c 'this_side_accepts && ask_edge')" "0"

# And the accepting end is told what WSS wants in the address field, because
# it is the only place anybody types it - the other end reads it from the
# token. The hint used to be on the dialling end, where nobody types it.
check "IRAN is asked for a domain"       "$(wzf | grep -c 'domain or address of this IRAN server')" "1"
check "and only for wss"        "$(wzf | grep -c 'T_TRANSPORT" = "wss" \] && this_side_accepts')" "1"

# a question that silently does not appear reads as one that was forgotten
ae2() { awk '/^ask_edge\(\) \{/{f=1} f&&/^\}/{exit} f' Pingify.sh; }
check "an edge says why it cannot help"       "$(ae2 | grep -c 'an address rather than a name')" "1"

# WS is not encrypted by itself and the screen has to say so, because the name
# looks like WSS with one letter missing
check "ws warns it is in the clear" "$(wz | grep -c 'WS is not encrypted by itself')" "1"
check "and points to WSS"            "$(wz | grep -c 'Choose WSS when TLS or a CDN is available')" "1"

# One connection is the whole point of the transport, so the wizard must not
# offer a number that the core will then ignore, and the preset it lands on
# must not leave sixteen behind either.
pm() { awk '/^preset_menu\(\) \{/{f=1} f&&/^}/{exit} f' Pingify.sh; }
check "websockets are pinned to one" "$(pm | grep -c 'ws | wss) T_CARRIERS=1')" "1"
check "and both skip the number"     "$(pm | grep -c 'T_TRANSPORT" = "wss"')" "1"

printf '\n%s passed, %s failed\n\n' "$PASS" "$FAILED"
[ "$FAILED" = "0" ]
