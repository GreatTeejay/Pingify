#!/usr/bin/env bash
#
# Does every part call functions that exist?
#
# This is the test that was missing, and the class of bug it catches is the
# worst kind in a shell script: nothing complains until a person presses the
# key. The home screen's "New tunnel" called screen_new, the wizard defined
# wizard_menu, and the two were written by different hands on the same
# afternoon. `bash -n` is happy with it. Every other test passed, because they
# all drove the wizard directly and never went through the menu.
#
# Nine parts concatenated into one file means nine chances to name the same
# thing two ways, and the shell will not say a word about it until it happens
# in front of somebody.

cd "$(dirname "$0")/.." || exit 1
. tests/lib.sh
load_parts .

section "every function that is called is defined"

defined=$(mktemp)
called=$(mktemp)
trap 'rm -f "$defined" "$called"' EXIT

declare -F | awk '{ print $3 }' | LC_ALL=C sort -u >"$defined"

# Read the source rather than declare -f, which reformats and folds lines, and
# take the places a call can only be a call.
#
# Narrowing matters more than it sounds. The first version took every word at a
# command position and produced eighty findings, none of them real: a case arm
# (`amd64)`) looks exactly like a call, and so does every name in a `local`
# line. A test whose output has to be filtered by eye is a test nobody runs
# twice.
#
# What is left is three shapes, and every one of them is unambiguous:
#
#   somewhere)  name ...       a menu dispatching a keystroke
#       name                   a call alone on its line
#       name arg               a call with arguments, at the start of a command
#
# and a name of ours always has an underscore and never starts with one, which
# removes every bare word and every _pk_ local in one rule.
sed 's/#.*//' parts/*.sh |
    grep -vE '^[[:space:]]*(local|declare|readonly|export)[[:space:]]' |
    grep -oE '(^|[;)&|]|\|\|)[[:space:]]*[a-z][a-z0-9]*(_[a-z0-9]+)+([[:space:]][^|]|$)' |
    grep -oE '[a-z][a-z0-9]*(_[a-z0-9]+)+' |
    LC_ALL=C sort -u >"$called"

# Everything the shell itself provides, everything a Linux server has, and the
# words bash's own reserved grammar puts at the start of a line.
known='^(if|then|else|elif|fi|for|while|until|do|done|case|esac|in|function|select|time|coproc|
local|return|declare|typeset|readonly|export|unset|shift|set|eval|exec|exit|trap|wait|kill|
printf|echo|read|test|true|false|command|builtin|source|type|hash|alias|umask|ulimit|jobs|
cat|sed|awk|grep|egrep|cut|tr|sort|uniq|head|tail|wc|tee|xargs|find|basename|dirname|realpath|
mkdir|rmdir|rm|cp|mv|ln|chmod|chown|touch|stat|cmp|diff|install|mktemp|df|du|sync|
date|sleep|seq|expr|bc|env|id|whoami|uname|hostname|nproc|uptime|free|ps|pgrep|pkill|top|
systemctl|journalctl|loginctl|sysctl|modprobe|lsmod|dmesg|
ip|ifconfig|route|ss|netstat|iptables|ip6tables|nft|tc|ping|ping6|traceroute|mtr|nc|ncat|socat|dig|host|nslookup|
curl|wget|ssh|scp|tar|gzip|gunzip|zcat|base64|sha256sum|md5sum|openssl|
go|gofmt|python3|perl|
apt|apt-get|yum|dnf|pacman|apk|
getent|logger|nohup|setsid|disown|timeout|stdbuf|flock|
b|c|d|e|f|g|h|i|j|k|l|m|n|o|p|q|r|s|t|u|v|w|x|y|z)$'

missing=$(LC_ALL=C comm -23 "$called" "$defined" | grep -vE "$(printf '%s' "$known" | tr -d '\n')")

if [ -z "$missing" ]; then
    PASS=$((PASS + 1))
else
    # Report each separately so the count means something and so a second one
    # is not hidden behind the first.
    for m in $missing; do
        FAIL=$((FAIL + 1))
        printf '    \033[31mx\033[0m %s is called but nothing defines it\n' "$m"
        grep -n "\b$m\b" parts/*.sh | grep -vE '^\S+: *#' | head -2 |
            sed 's/^/          /'
    done
fi

section "nothing is defined twice"

# Nine files concatenated into one: the last definition of a name wins, and
# silently. Two people writing a helper called the same thing is how a screen
# starts calling somebody else's idea of it.
dup=$(grep -hoE '^[a-z_][a-z_0-9]*\(\)' parts/*.sh | LC_ALL=C sort | uniq -d)
check "no function is defined in two parts" "$dup" ""

section "the menus reach what they claim to"

# Every key on the home screen and the tunnel screen must land somewhere. The
# dispatch is a case statement, so a key that goes nowhere is not an error, it
# is a keystroke that does nothing at all - which reads as the tool being
# broken rather than the key being wrong.
for fn in screen_home screen_tunnel main_menu; do
    if declare -F "$fn" >/dev/null; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf '    \033[31mx\033[0m %s is not defined, so the menu cannot draw\n' "$fn"
    fi
done

section "the two halves of the health port agree"

# The core binds it and the manager knocks on it, and they are two files in
# two languages that have to hold the same number. Nothing at runtime would
# notice them drifting: the knock would simply never be answered, and every
# ICMP tunnel would go back to showing a dash where its round trip belongs.
go_hp=$(grep -oE 'DefaultHealthPort = [0-9]+' core/internal/config/config.go 2>/dev/null ||
    grep -oE 'DefaultHealthPort = [0-9]+' internal/config/config.go 2>/dev/null)
check "the core's default and the script's are one number" \
    "$go_hp" "DefaultHealthPort = $HEALTH_PORT"

section "the unit names the paths this script uses"

# It wrote them out again instead, inside a quoted heredoc, so the unit named
# wherever the core and the configs were on the day it was written. Moving
# either of them left every tunnel's ExecStart pointing at a file that was not
# there any more, and systemd's whole answer to that is "203/EXEC".
_ud=$(mktemp -d)
_old_unit=$UNIT_DIR _old_core=$CORE_BIN _old_cfg=$CFG_DIR
UNIT_DIR=$_ud
CORE_BIN=/somewhere/else/pingify-core
CFG_DIR=/somewhere/else/tunnels
systemctl() { :; }
unit_write
u=$(cat "$_ud/pingify@.service" 2>/dev/null)
check_contains "ExecStart names the core this script would run" "$u" "$CORE_BIN "
check_contains "and the directory the configs are in" "$u" "$CFG_DIR/%i.toml"

# systemd reads these in [Unit] and says "Unknown key name" when they are in
# [Service] - and then quietly applies its own default instead.
check_contains "the restart limit is in the Unit section" \
    "$(printf '%s\n' "$u" | sed -n '/^\[Unit\]/,/^\[Service\]/p')" "StartLimitIntervalSec"
UNIT_DIR=$_old_unit CORE_BIN=$_old_core CFG_DIR=$_old_cfg
rm -rf "$_ud"
unset -f systemctl

section "parity is not offered where the core ignores it"

# Measured, on the Tehran path: a GRE tunnel with parity turned on carries
# nothing at all in either direction, because our GRE payload is a bare IP
# packet and four bytes of parity header in front of it is not one. GRE FOU is
# the other one: the kernel carries it and this core never touches its bytes,
# so parity there is a switch with nothing behind it. The core ignores both;
# these two screens must not go on offering them, and the check must never
# advise turning it on for either.
# Both places the screen mentions parity: the menu item, which must not exist
# for either, and the panel above it, which must not print a Parity field.
check_contains "the Tuning menu leaves gre and grefou out of Parity"     "$(grep -c 'gre | grefou) ;;' parts/40-manage.sh)" "1"
check_contains "and so does the panel above it"     "$(grep -c 'gre | grefou) panel_field' parts/40-manage.sh)" "1"
check_contains "and the check does not advise it on either"     "$(grep -B4 'turn on Parity' parts/45-health.sh)" "gre | grefou"

# The other half of the same rule: KCP rebuilds a lost packet from parity
# below its own stream instead of resending it, and reads the very same key.
# It was the one forward transport that could use it and had no way of being
# told - the wizard wrote no fec line and the screen offered no item.
check_contains "the wizard writes fec for kcp"     "$(grep -A2 'udp | icmp | rawtcp | awg | kcp' parts/30-tunnel.sh)" "kv fec"
check_contains "and the Tuning screen offers it"     "$(grep -A2 'T_TRANSPORT" = kcp' parts/40-manage.sh)" "tm parity"

section "a core carried over is checked before it is installed"

# The server in Iran is the one that cannot build - too small, or cut off
# from go.dev - and until 1.1.0 the only way a core got there without a
# compiler was scp by hand, over a running binary. Export writes the hash
# beside the file; import refuses anything that is not that file, not this
# architecture or not this script's version, and installs beside then over.
_cd=$(mktemp -d)
_old_core=$CORE_BIN _old_unit=$UNIT_DIR _old_cfgd=$CFG_DIR _old_cored=$CORE_DIR _old_src=$SRC_DIR _old_state=$STATE_DIR
CORE_BIN=$_cd/core/pingify-core UNIT_DIR=$_cd/units CFG_DIR=$_cd/cfg CORE_DIR=$_cd/core SRC_DIR=$_cd/src STATE_DIR=$_cd/state CORE_EXPORT_DIR=$_cd
mkdir -p "$_cd/core" "$_cd/units"
require_root() { :; }
systemctl() { :; }
_fake() { printf '#!/bin/sh\n[ "$1" = -version ] && echo "pingify-core %s"\n' "$2" > "$1"; chmod +x "$1"; }
_arch=$(arch_go)
_fake "$CORE_BIN" "$PINGIFY_VERSION"
# Through the command line, as a person types it: the parser used to refuse
# the word outright, and nothing noticed because these tests called the
# functions directly.
argv core import /root/pingify-core-x-linux-amd64
check "the command line takes: pingify core import FILE" "$ARG_MODE" "core"
argv core export
check "and: pingify core export" "$ARG_MODE" "core"
argv --status
check "and still reads a flag after it is fixed" "$ARG_MODE" "status"
check_rc "export writes the core beside its hash" 0 core_export
_exp=$_cd/pingify-core-$PINGIFY_VERSION-linux-$_arch
check "and the hash is the file's" "$(cut -c1-64 < "$_exp.sha256" 2>/dev/null)" "$(sha256sum "$_exp" 2>/dev/null | cut -c1-64)"
rm -f "$CORE_BIN"
check_rc "import refuses a file that is not there" 1 core_import "$_cd/nowhere"
cp "$_exp" "$_cd/bare-linux-$_arch"
check_rc "and one without its hash beside it" 1 core_import "$_cd/bare-linux-$_arch"
cp "$_exp" "$_cd/changed-linux-$_arch"; cp "$_exp.sha256" "$_cd/changed-linux-$_arch.sha256"; echo tampered >> "$_cd/changed-linux-$_arch"
check_rc "and one whose hash does not match" 1 core_import "$_cd/changed-linux-$_arch"
cp "$_exp" "$_cd/other-linux-mips"; sha256sum "$_cd/other-linux-mips" | cut -c1-64 > "$_cd/other-linux-mips.sha256"
check_rc "and one built for another architecture" 1 core_import "$_cd/other-linux-mips"
_fake "$_cd/old-linux-$_arch" "1.0.2"; sha256sum "$_cd/old-linux-$_arch" | cut -c1-64 > "$_cd/old-linux-$_arch.sha256"
check_rc "and one of another version" 1 core_import "$_cd/old-linux-$_arch"
check "nothing was installed by the refusals" "$([ -e "$CORE_BIN" ] && echo installed || echo nothing)" "nothing"
check_rc "the exported one installs" 0 core_import "$_exp"
check "and is the core now" "$(core_version)" "$PINGIFY_VERSION"
check "and the unit was written for it" "$(grep -c "$CORE_BIN " "$UNIT_DIR/pingify@.service" 2>/dev/null)" "1"
CORE_BIN=$_old_core UNIT_DIR=$_old_unit CFG_DIR=$_old_cfgd CORE_DIR=$_old_cored SRC_DIR=$_old_src STATE_DIR=$_old_state
unset CORE_EXPORT_DIR
unset -f require_root systemctl _fake
rm -rf "$_cd"

section "the Go toolchain comes from wherever the server can reach"

# go.dev answers a server in Iran with a 404, so the tarball is fetched from
# the first place that has it, and kept only if its sha256 is go.dev's own.
if [ -f go.mod ]; then
    _gv=$(awk '/^go [0-9]/ { print $2; exit }' go.mod)
    case $_gv in *.*.*) ;; *) _gv=$_gv.0 ;; esac
    for _a in amd64 arm64; do
        check "the script carries go.dev's sum for go$_gv.linux-$_a.tar.gz" \
            "$(go_sum "go$_gv.linux-$_a.tar.gz" | grep -cE '^[0-9a-f]{64}$')" "1"
    done
else
    skip "a sum for every tarball the go.mod asks for" "no go.mod here"
fi
check "go.dev is tried first" "$(go_sources | head -n 1)" "https://go.dev/dl"
check "then the copy this release carries" "$(go_sources | sed -n 2p)" \
    "https://github.com/$PINGIFY_REPO/releases/download/v$PINGIFY_VERSION"
check "and PINGIFY_GO_URL before all of them" \
    "$(PINGIFY_GO_URL=https://mine.example/go/ go_sources | head -n 1)" "https://mine.example/go"
_gf=$(mktemp -d)
_right=$(printf 'the right bytes' | wiz_sha256)
out=$(
    STATE_DIR=$_gf
    go_sources() { printf '%s\n' https://one.example/dl https://two.example/dl https://three.example/dl https://four.example/dl; }
    go_sum() { printf '%s' "$_right"; }
    spin() { shift; "$@"; }
    curl() {
        local o= u=
        while [ $# -gt 0 ]; do case $1 in -o) o=$2; shift 2 ;; *) u=$1; shift ;; esac; done
        case $u in
        *one.example*) echo "curl: (22) The requested URL returned error: 404"; return 22 ;;
        *two.example*) printf 'somebody else' >"$o" ;;
        *) printf 'the right bytes' >"$o" ;;
        esac
    }
    go_fetch go1.24.0.linux-amd64.tar.gz "$_gf/t" 2>&1
    echo "rc=$? from=$GO_FROM kept=$(cat "$_gf/t" 2>/dev/null)"
)
check_contains "a source that fails is named, with why" "$out" "one.example: curl: (22)"
check_contains "one that serves other bytes is refused" "$out" "two.example: what arrived is not go.dev's file"
check_contains "the first with go.dev's bytes is the one kept" "$out" "rc=0 from=three.example kept=the right bytes"
check_missing "and nothing after it is asked" "$out" "four.example"
out=$(
    STATE_DIR=$_gf
    go_sources() { printf '%s\n' https://one.example/dl; }
    go_sum() { printf '%s' "$_right"; }
    spin() { shift; "$@"; }
    curl() { echo "curl: (6) Could not resolve host: one.example"; return 6; }
    go_fetch go1.24.0.linux-amd64.tar.gz "$_gf/t" 2>&1
    echo "rc=$? left=$([ -e "$_gf/t" ] && echo a-file || echo nothing)"
)
check_contains "with nowhere to fetch from, it fails and leaves nothing" "$out" "rc=1 left=nothing"
rm -rf "$_gf"

section "what the core says about a filter reaches the health check"

# On 2026-09-26 six transports to a filtered server said up and the check
# said nothing was wrong while they carried nothing. The core now probes with
# records the size of data and reports data_blocked; the shell has to read
# the same name, or the verdict never reaches anybody.
if [ -f internal/status/status.go ]; then
    check_contains "the core reports data_blocked" "$(cat internal/status/status.go)" 'json:"data_blocked'
else
    skip "the core reports data_blocked" "no engine sources here"
fi
_rep='{
  "up": true,
  "far_seen_sec": 2.1,
  "data_blocked": true,
  "probe_seen_sec": 95.5
}'
check "a report saying so is read as true" "$(json_field "$_rep" data_blocked)" "true"
check "and how long since a probe came back" "$(json_field "$_rep" probe_seen_sec)" "95.5"
# And by tun_stats, which is what every screen and the check go through: it
# reads the report in one pass rather than a json_field per key, so what is
# checked is that the name arrives, not how the source spells the reading.
curl() { printf '%s\n' "$_rep"; }
tun_stats any-tunnel
check "the shell reads that name" "$ST_BLOCKED" "true"
check "and the age of the last probe" "$ST_PROBE_SEEN" "95.5"
check "and the rest of the report beside it" "$ST_UP/$ST_FAR_SEEN" "true/2.1"
unset -f curl
check "and the check turns it into a verdict" "$(grep -c '"$ST_BLOCKED" = true' parts/45-health.sh)" "1"

section "the machine gets its pings back, and not a moment sooner"

# The core mutes echo replies while an ICMP tunnel runs, and has to. Giving
# them back is the manager's job, and doing it while a second ICMP tunnel is
# still running would double that tunnel's traffic on the path.
_sd=$(mktemp -d)
printf '[transport]
type = "icmp"
' >"$_sd/one.toml"
cfg_list() { printf 'one
'; }
cfg_file() { printf '%s' "$_sd/one.toml"; }
# The call is made with its output sent to /dev/null, so what proves it
# happened has to outlive the redirect: the stub writes to a file.
sysctl() { printf 'SYSCTL %s
' "$*" >>"$_sd/calls"; }
icmp_echo_muted() { return 0; }
svc_state() { printf 'active'; }
: >"$_sd/calls"
icmp_echo_restore >/dev/null 2>&1
check_missing "an icmp tunnel still running keeps the kernel quiet" "$(cat "$_sd/calls")" "SYSCTL"
svc_state() { printf 'stopped'; }
: >"$_sd/calls"
icmp_echo_restore >/dev/null 2>&1
check_contains "with the last one stopped, the pings come back" "$(cat "$_sd/calls")" "SYSCTL"
unset -f cfg_list cfg_file sysctl svc_state icmp_echo_muted
rm -rf "$_sd"

section "a running tunnel can be given more ports"

# The core of a forward tunnel binds its own ports, so they are open on the
# machine. Re-setting the list read those sockets as someone else's and
# refused the ports the tunnel already had - found adding three ports to a
# tunnel carrying users, which could not be done without stopping it.
cfg_list() { printf 'mine
other
'; }
forwards_of() {
    case $1 in
    mine) printf '8003
' ;;
    other) printf '9000
' ;;
    esac
}
fwd_listeners() {
    printf 'tcp 8003 pingify-core
'
    printf 'tcp 9000 pingify-core
'
    printf 'tcp 7100 nginx
'
}
out=$(forwards_clash mine "8003,7001,7002,7003" 2>&1)
check "its own port and three new ones are accepted" "$?" "0"
check_missing "and nothing is reported" "$out" "already"
out=$(forwards_clash mine "8003,9000" 2>&1)
check_contains "another tunnel's port is still refused" "$out" "forwarded by the tunnel other"
out=$(forwards_clash mine "8003,7100" 2>&1)
check_contains "and so is a port something else holds" "$out" "held by nginx"
out=$(forwards_clash "" "8003" 2>&1)
check_contains "a new tunnel owns nothing yet, so a bound port is refused" "$out" "held by pingify-core"
unset -f cfg_list forwards_of fwd_listeners

section "a backup says where it goes, on every screen alike"

# The menus, the review and the check all name a backup through this, so a
# tunnel behind a domain shows its backups going to the IP rather than to
# Cloudflare - and the check puts them on one line, not one to a line.
check "a backup that goes where the tunnel goes" "$(backup_label kcp:8443)" "KCP MUX 8443/udp"
check "and one with an address of its own" "$(backup_label utls:2053@198.51.100.15)" "Chrome TLS MUX 2053/tcp to 198.51.100.15"
check "the check names them the same way" "$(grep -c 'backup_label' parts/45-health.sh)" "1"

section "the guard that lets this file be sourced at all"

# build.sh and every test here source the script. Without the guard on the
# last line they would launch the menu instead.
last=$(grep -v '^[[:space:]]*$' parts/90-main.sh | tail -1)
check_contains "the last line only runs main when it was not sourced" \
    "$last" 'PINGIFY_NO_MAIN'

report
