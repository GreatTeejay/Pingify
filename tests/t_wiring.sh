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
# packet and four bytes of parity header in front of it is not one. The core
# refuses the setting; these two screens must not go on offering it, and the
# check must never advise turning it on.
check_contains "the Advanced screen leaves gre out of Parity"     "$(grep -A5 'Parity is not offered' parts/40-manage.sh)" "utls | gre"
check_contains "and the check does not advise it on gre"     "$(grep -B4 'turn on Parity' parts/60-check.sh)" "utls | gre"

section "the guard that lets this file be sourced at all"

# build.sh and every test here source the script. Without the guard on the
# last line they would launch the menu instead.
last=$(grep -v '^[[:space:]]*$' parts/90-main.sh | tail -1)
check_contains "the last line only runs main when it was not sourced" \
    "$last" 'PINGIFY_NO_MAIN'

report
