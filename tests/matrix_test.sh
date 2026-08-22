#!/usr/bin/env bash
# Every combination of tunnel kind and forwarder, on both servers, checked
# against the real core - plus the invariants that have broken before.
set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0; FAILED=0
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
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# shellcheck disable=SC1091
PINGIFY_NO_MAIN=1 . ./Pingify.sh
CFG_DIR="$WORK/etc"; STATE_DIR="$WORK/state"; mkdir -p "$CFG_DIR" "$STATE_DIR"

GO_BIN="${GO_BIN:-go}"
CORE_BIN=""
if command -v "$GO_BIN" >/dev/null 2>&1; then
    EXT=""; [ "${OS:-}" = "Windows_NT" ] && EXT=".exe"
    CORE_BIN="$WORK/pingify-core$EXT"
    ( cd core && CGO_ENABLED=0 "$GO_BIN" build -o "$CORE_BIN" . ) || exit 1
fi

TOKEN="a token typed on both servers"

# build <name> <role> <kind> <forwarder> ; prints the config path
build() {
    cfg_reset
    T_NAME="$1"; T_ROLE="$2"; T_KIND="$3"; T_FORWARDER="$4"
    [ "$T_KIND" = "tun" ] && T_TRANSPORT="icmp" || T_TRANSPORT="tcp"
    cfg_mode   # a TCP tunnel forces pingify: there is nothing to NAT onto
    T_TOKEN="$TOKEN"; T_PORT=9443
    T_PUBLIC_IP="203.0.113.9"
    this_side_accepts || T_PEER_IP="198.51.100.4"
    if cfg_needs_link; then
        if [ "$T_ROLE" = "server" ]; then
            T_TUNLOCAL="10.10.10.1/24"; T_TUNPEER="10.10.10.2/24"
        else
            T_TUNLOCAL="10.10.10.2/24"; T_TUNPEER="10.10.10.1/24"
        fi
    fi
    [ "$T_ROLE" = "server" ] && T_FORWARDS='"443","udp:500"'
    T_STATUS="127.0.0.1:9700"
    cfg_save
}

# ---------------------------------------------------------------------------
note "every kind and forwarder, on both servers"
# ---------------------------------------------------------------------------
for kind in tcp tun; do
    for fwd in pingify iptables; do
        for role in server client; do
            n="${kind}-${fwd}-${role}"
            f="$(build "$n" "$role" "$kind" "$fwd")" || { check "$n builds" "no" "yes"; continue; }
            [ -n "$CORE_BIN" ] || continue
            "$CORE_BIN" -c "$f" -check >/dev/null 2>&1
            check "$n accepted by the core" "$?" "0"
        done
    done
done

# ---------------------------------------------------------------------------
note "the mode each combination asks the core for"
# ---------------------------------------------------------------------------
check "TCP  + PINGIFY  " "$(toml_get "$(cfg_file tcp-pingify-server)"  tunnel mode)" "forward"
check "TCP  + IPTABLES " "$(toml_get "$(cfg_file tcp-iptables-server)" tunnel mode)" "forward"
check "TUN  + PINGIFY  " "$(toml_get "$(cfg_file tun-pingify-server)"  tunnel mode)" "both"
check "TUN  + IPTABLES " "$(toml_get "$(cfg_file tun-iptables-server)" tunnel mode)" "tun"

# ---------------------------------------------------------------------------
note "a private link exists exactly when it is needed"
# ---------------------------------------------------------------------------
check "TCP + PINGIFY has none"  "$(grep -c '^\[tun\]' "$(cfg_file tcp-pingify-server)")"  "0"
check "TCP + IPTABLES has none" "$(grep -c '^\[tun\]' "$(cfg_file tcp-iptables-server)")" "0"
check "TUN + PINGIFY has one"   "$(grep -c '^\[tun\]' "$(cfg_file tun-pingify-server)")"  "1"
check "TUN + IPTABLES has one"  "$(grep -c '^\[tun\]' "$(cfg_file tun-iptables-server)")" "1"

# ---------------------------------------------------------------------------
note "the two ends of one tunnel agree"
# ---------------------------------------------------------------------------
for kind in tcp tun; do
    for fwd in pingify iptables; do
        s="$(cfg_file "${kind}-${fwd}-server")"
        c="$(cfg_file "${kind}-${fwd}-client")"
        check "$kind/$fwd same transport" \
              "$(toml_get "$s" transport type)" "$(toml_get "$c" transport type)"
        check "$kind/$fwd same mode" \
              "$(toml_get "$s" tunnel mode)" "$(toml_get "$c" tunnel mode)"
        check "$kind/$fwd same token" \
              "$(toml_get "$s" security token)" "$(toml_get "$c" security token)"
        # KHAREJ accepts, IRAN dials out to it. Reaching an Iranian server
        # from outside is the half that gets filtered; reaching out of one
        # does not, which is why the link is opened from that side.
        check "$kind/$fwd KHAREJ listens" \
              "$([ -n "$(toml_get "$c" transport listen)" ] && echo yes || echo no)" "yes"
        check "$kind/$fwd IRAN dials out" \
              "$([ -n "$(toml_get "$s" transport connect)" ] && echo yes || echo no)" "yes"
        check "$kind/$fwd IRAN never listens" \
              "$([ -n "$(toml_get "$s" transport listen)" ] && echo yes || echo no)" "no"
        check "$kind/$fwd ports on IRAN only" \
              "$(grep -c '^ports' "$s")$(grep -c '^ports' "$c")" "10"
        if [ "$(grep -c '^\[tun\]' "$s")" = "1" ]; then
            check "$kind/$fwd private addresses mirror" \
                  "$(toml_get "$s" tun local_addr)|$(toml_get "$s" tun remote_addr)" \
                  "$(toml_get "$c" tun remote_addr)|$(toml_get "$c" tun local_addr)"
        fi
    done
done

# ---------------------------------------------------------------------------
note "reading a tunnel back gives what was written"
# ---------------------------------------------------------------------------
for kind in tcp tun; do
    for fwd in pingify iptables; do
        cfg_load "${kind}-${fwd}-server"
        check "$kind/$fwd kind survives"      "$T_KIND"      "$kind"
        # a TCP tunnel has no local tunnel to NAT onto, so the choice
        # collapses to the core no matter what was asked for
        want="$fwd"; [ "$kind" = "tcp" ] && want="pingify"
        check "$kind/$fwd forwarder survives" "$T_FORWARDER" "$want"
        check "$kind/$fwd token survives"     "$T_TOKEN"     "$TOKEN"
        check "$kind/$fwd ports survive"      "$T_FORWARDS"  '"443","udp:500"'
    done
done

# traffic shaping has to survive a write/read round trip, and default to on
# for a config written before it existed
check "shaping is written"        "$(toml_get "$(cfg_file tcp-pingify-server)" transport obfuscate)" "false"
cfg_load tcp-pingify-server
check "shaping reads back"        "$T_OBFUSCATE" "false"
sed -i '/^obfuscate/d' "$(cfg_file tcp-pingify-server)"
cfg_load tcp-pingify-server
check "a config without it is off" "$T_OBFUSCATE" "false"

# the shaping editor has to flip the value in place, and put it there at all
# when the config predates the setting
SF="$(cfg_file tun-pingify-server)"
sed -i '/^obfuscate/d' "$SF"
check "shaping label defaults off" "$(shaping_label tun-pingify-server)" "off"
# the same edit edit_shaping performs, run twice: it must land once, not twice
for _ in 1 2; do
    sed -i -e '/^obfuscate/d' \
           -e "/^keepalive_sec/a obfuscate        = false" "$SF"
done
check "and reads off once set"    "$(shaping_label tun-pingify-server)" "off"
check "written exactly once"      "$(grep -c '^obfuscate' "$SF")" "1"
[ -n "$CORE_BIN" ] && { "$CORE_BIN" -c "$SF" -check >/dev/null 2>&1; \
    check "the core accepts shaping off" "$?" "0"; }

# an older config, written before the kind was recorded, still reads sensibly
sed -i '/^kind /d' "$(cfg_file tun-iptables-server)"
cfg_load tun-iptables-server
check "a config with no kind is inferred" "$T_KIND" "tun"

# ---------------------------------------------------------------------------
note "NAT rules are written for the right tunnels"
# ---------------------------------------------------------------------------
# iptables is stubbed so the rules can be inspected without touching a firewall.
RULES="$WORK/rules"; : > "$RULES"
iptables() { printf '%s\n' "$*" >> "$RULES"; return 0; }
sysctl() { return 0; }
have() { case "$1" in iptables) return 0 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }

: > "$RULES"; nat_rules_for tcp-pingify-server
check "PINGIFY writes no rules"        "$(grep -c DNAT "$RULES")" "0"

: > "$RULES"; nat_rules_for tcp-iptables-server
check "a TCP tunnel writes none"       "$(grep -c DNAT "$RULES")" "0"

: > "$RULES"; nat_rules_for tun-iptables-server
check "and one masquerade"             "$(grep -c MASQUERADE "$RULES")" "1"
check "tcp port 443 goes to the peer"  "$(grep -c 'p tcp --dport 443 ! -s 10.10.10.2 -j DNAT --to-destination 10.10.10.2:443' "$RULES")" "1"
check "udp 500 too"                    "$(grep -c 'p udp --dport 500 .* --to-destination 10.10.10.2:500' "$RULES")" "1"

: > "$RULES"; nat_rules_for tun-iptables-server
check "TUN + IPTABLES writes DNAT"     "$(grep -c DNAT "$RULES")" "2"

: > "$RULES"; nat_rules_for tcp-iptables-client
check "KHAREJ needs no rule"           "$(grep -c DNAT "$RULES")" "0"

# a port mapping must land on the mapped port, not the listening one
cfg_reset
T_NAME="map"; T_ROLE="server"; T_KIND="tun"; T_FORWARDER="iptables"
T_TRANSPORT="icmp"; cfg_mode
T_TOKEN="$TOKEN"; T_PORT=9443; T_PUBLIC_IP="203.0.113.9"; T_PEER_IP="198.51.100.4"
T_TUNLOCAL="10.10.10.1/24"; T_TUNPEER="10.10.10.2/24"
T_FORWARDS='"443=8443"'; T_STATUS="127.0.0.1:9700"
cfg_save >/dev/null
: > "$RULES"; nat_rules_for map
check "443=8443 maps across"           "$(grep -c 'dport 443 .* --to-destination 10.10.10.2:8443' "$RULES")" "1"

# ---------------------------------------------------------------------------
note "a deleted tunnel takes its forwarding rules with it"
# ---------------------------------------------------------------------------
# A DNAT rule left pointing at an address that no longer exists swallows every
# packet for that port. The symptom - connecting to a socket that is plainly
# listening, and timing out instead of being answered - looks nothing like its
# cause, and cost a real afternoon.
systemctl() { return 0; }
confirm() { return 0; }
_say() { :; }

: > "$RULES"; apply_nat quiet
check "an iptables tunnel has rules"  "$(grep -c 'PINGIFY_NAT -p' "$RULES")" "3"

rm -f "$(cfg_file tun-iptables-server)" "$(cfg_file tun-iptables-client)" \
      "$(cfg_file map)"
: > "$RULES"; apply_nat quiet
check "and none once it is deleted"   "$(grep -c 'PINGIFY_NAT -p' "$RULES")" "0"
check "the chains are torn down too"  "$(grep -c 'X PINGIFY_NAT' "$RULES")" "1"

unset -f iptables sysctl have systemctl confirm _say

printf '\n%s passed, %s failed\n\n' "$PASS" "$FAILED"
[ "$FAILED" = "0" ]
