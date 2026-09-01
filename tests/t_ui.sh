#!/usr/bin/env bash
#
# The presentation layer, tested by rendering it.
#
# Not by grepping it. A test that counts how many times a phrase appears in the
# source tells you the phrase is there; it does not tell you the line fits on
# the screen, and fitting on the screen is the only thing that matters here.

cd "$(dirname "$0")/.." || exit 1
. tests/lib.sh
load_parts .

section "widths and cutting"

# Every screen must fit. The width is not a constant any more, so this has to
# hold at both ends of the range the script clamps to.
for w in 60 80 100; do
    PINGIFY_WIDTH=$w ui_detect
    out=$(
        banner "core 2.0.0"
        rule "Health"
        field "Link" "10.99.10.1 to 10.99.10.2 on pfy0 with an mtu of 1320"
        item2 1 "Host tuning" "balanced, BBR on"
        UI_COLS=(2 14 8 16 10 18)
        row "*" "a-tunnel-with-a-very-long-name" "IRAN" "10.99.10.2" "88 ms" "412/38 Mbit/s"
        panel_open "review"
        panel_field "Private link" "10.99.10.1 and 10.99.10.2 and a great deal more text than fits"
        panel_close
    )
    longest=$(printf '%s\n' "$out" | awk '{ if (length($0) > m) m = length($0) } END { print m+0 }')
    if [ "$longest" -le "$w" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf '    \033[31mx\033[0m at width %s the longest line was %s\n' "$w" "$longest"
        printf '%s\n' "$out" | awk -v w="$w" 'length($0) > w { print "        " $0 }'
    fi
done

PINGIFY_WIDTH=80 ui_detect

# A box has three lines and they must be the same width, or it is not a box.
# They were not: the rules were one column short of the rows.
out=$(panel_open "t"; panel_row "x"; panel_close)
widths=$(printf '%s\n' "$out" | awk '{ print length($0) }' | sort -u | tr '\n' ' ')
check "a box is one width all the way down" "$widths" "80 "

check "a value that fits is left alone" "$(trunc_to abcdef 10)" "abcdef"
check "a value that does not fit is marked" "$(trunc_to abcdefghijkl 6)" "abcde~"
check "padding fills to the width" "[$(pad_to ab 5)]" "[ab   ]"
check "padding a long value cuts it first" "$(vislen "$(pad_to abcdefghij 5)")" "5"

section "measuring what is on the screen"

check "plain text is its length" "$(vislen abc)" "3"
check "colour does not take space" "$(vislen "$(printf '\033[31mabc\033[0m')")" "3"
check "an escape with several parameters" "$(vislen "$(printf '\033[38;5;37mab\033[0m')")" "2"

# A wide glyph takes two columns and a combining mark takes none. Without
# this, one CJK character in a tunnel name slides every column right of it.
check "a wide glyph counts two" "$(vislen '漢')" "2"
check "a combining mark counts none" "$(vislen "$(printf 'á')")" "1"

section "colour says what it means"

# The whole colour policy in one rule: red means this path is slow, never
# that there is no path. An ICMP tunnel cannot answer a ping by design.
check "a fast path is good" "$(rtt_colour 40)" "$C_OK"
check "a slow path is a warning" "$(rtt_colour 150)" "$C_WARN"
check "a very slow path is bad" "$(rtt_colour 400)" "$C_BAD"
check "no measurement is not a failure" "$(rtt_colour '')" "$C_MUTE"
check "a dash is not a failure either" "$(rtt_colour '-')" "$C_MUTE"

check "running is the only green dot" "$(state_dot running)" "$C_OK$G_ON$C_OFF"
check "up but alone is amber" "$(state_dot idle)" "$C_WARN$G_ON$C_OFF"
check "unknown is grey" "$(state_dot whatever)" "$C_MUTE$G_OFF$C_OFF"

section "a terminal that cannot draw"

# PuTTY without a UTF-8 locale, or a serial console. Every byte must be
# plain ASCII, or the screen fills with question marks.
out=$(
    PINGIFY_ASCII=1 ui_detect
    banner "core"
    rule "Health"
    ok "one"
    bad "two"
    fix "three"
    field "Link" "a $G_BOTH b"
)
if [ -n "$(printf '%s' "$out" | LC_ALL=C tr -d '\11\12\40-\176')" ]; then
    FAIL=$((FAIL + 1))
    printf '    \033[31mx\033[0m the ascii rendering contains bytes above 127\n'
else
    PASS=$((PASS + 1))
fi

section "asking"

# EOF is not an answer to wait for. A piped script that runs out of input must
# stop rather than ask the same question for ever.
check_rc "ask gives up at end of input" 1 bash -c '
    PINGIFY_NO_MAIN=1 NO_COLOR=1; . parts/00-ui.sh; ask v "x" "" v_any </dev/null'
check_rc "pick gives up at end of input" 1 bash -c '
    PINGIFY_NO_MAIN=1 NO_COLOR=1; . parts/00-ui.sh; pick v "x" 1 3 </dev/null'
check_rc "confirm gives up at end of input" 1 bash -c '
    PINGIFY_NO_MAIN=1 NO_COLOR=1; . parts/00-ui.sh; confirm "x" </dev/null'

check "an empty answer takes the default" \
    "$(printf '\n' | { ask v "x" "the-default" v_any >/dev/null 2>&1; printf '%s' "$v"; })" \
    "the-default"
check "an answer is taken as given" \
    "$(printf 'mine\n' | { ask v "x" "d" v_any >/dev/null 2>&1; printf '%s' "$v"; })" \
    "mine"

# The one menu idiom. The old wizard had two, and the lenient one meant a
# fat-fingered 9 silently built a config nobody chose.
check "pick refuses a number outside the range, then takes a good one" \
    "$(printf '9\n2\n' | { pick v "x" 1 3 >/dev/null 2>&1; printf '%s' "$v"; })" \
    "2"
check "pick refuses text" \
    "$(printf 'abc\n1\n' | { pick v "x" 2 3 >/dev/null 2>&1; printf '%s' "$v"; })" \
    "1"

section "validators"

check_rc "an address is an address" 0 v_host 46.247.109.83
check_rc "an octet over 255 is not" 1 v_host 46.247.109.300
check_rc "a hostname is allowed" 0 v_host example.com
check_rc "a bare word is not a hostname" 1 v_host localhost
check_rc "nothing is not an address" 1 v_host ""

check_rc "a port is a port" 0 v_port 8443
check_rc "zero is not a port" 1 v_port 0
check_rc "65536 is not a port" 1 v_port 65536
check_rc "a word is not a port" 1 v_port http

# These mirror what the core will accept. If the manager lets a value past
# that the core refuses, the user gets a Go error instead of a prompt.
check_rc "the smallest mtu the core takes" 0 v_mtu 576
check_rc "one below it is refused here" 1 v_mtu 575
check_rc "the largest the core takes" 0 v_mtu 9000
check_rc "one above it is refused here" 1 v_mtu 9001

check_rc "the shortest token the core takes" 0 v_token 12345678
check_rc "one character shorter is refused here" 1 v_token 1234567

check_rc "an octet in range" 0 v_octet 99
check_rc "zero is not an octet" 1 v_octet 0
check_rc "255 is not an octet" 1 v_octet 255

section "every menu key is a number"

# Not a phrase, a rule: every choice in this script is typed as a number.
#
# They were letters - n for new, p for ports, u for update, a for advanced -
# and the tunnels themselves were keys on the home screen, so the letter for
# Uninstall moved every time somebody added one. The one screen that kept a
# letter after the rest were changed would be the one nobody could find their
# way out of, and nothing else here would notice.
letters=$(grep -hoE '^[[:space:]]*item2? +"?[A-Za-z][A-Za-z0-9]*"?' parts/*.sh |
    sed 's/^[[:space:]]*//' | LC_ALL=C sort -u)
check "no menu key is a letter" "$letters" ""

section "every ask is validated"

# The other grep of the source, and like the one above it enforces a rule
# rather than a phrase: an unvalidated answer is a value the core rejects half
# an hour later with a message the user cannot act on.
bare=$(grep -hn 'ask [A-Za-z_]' parts/*.sh |
    grep -v '^\s*#' |
    awk '{ n = gsub(/"/, "\""); if (NF < 5) print }' | head -5)
check "no ask call omits its validator" "$bare" ""

report
