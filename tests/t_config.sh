#!/usr/bin/env bash
#
# The config file, and the property the whole design rests on: the same file is
# correct on both servers except for one line.
#
# If that stops being true, the wizard's second half - paste this on the other
# machine and you are done - stops being possible, and nothing else in the tool
# matters as much.

cd "$(dirname "$0")/.." || exit 1
. tests/lib.sh
load_parts .
sandbox
trap sandbox_clean EXIT

write_sample() {
    cat >"$1" <<'TOML'
[tunnel]
name = "udp-99"
side = "iran"
mode = "tun"

[transport]
type          = "udp"
kharej        = "46.247.109.83"
port          = 8443
keepalive_sec = 10

[security]
token = "a token typed on both servers"

[tun]
name   = "pfy0"
iran   = "10.99.10.1/24"
kharej = "10.99.10.2/24"
mtu    = 1320

[tuning]
profile = "balanced"

[logging]
level = "info"
TOML
}

f=$CFG_DIR/udp-99.toml
write_sample "$f"

section "reading"

check "a string" "$(toml_get "$f" tunnel side)" "iran"
check "a number" "$(toml_get "$f" transport port)" "8443"
check "a value with padding around the equals" "$(toml_get "$f" transport type)" "udp"
check "an address with a prefix" "$(toml_get "$f" tun iran)" "10.99.10.1/24"
check "a token with spaces in it" "$(toml_get "$f" security token)" "a token typed on both servers"

# The same key name lives in three tables. Reading one must not find another.
check "name in [tunnel]" "$(toml_get "$f" tunnel name)" "udp-99"
check "name in [tun] is a different key" "$(toml_get "$f" tun name)" "pfy0"

check "a key that is not there is empty" "$(toml_get "$f" tuning nonesuch)" ""
check "a table that is not there is empty" "$(toml_get "$f" nosuchtable key)" ""

section "writing"

toml_set "$f" tuning profile gaming
check "a value is replaced" "$(toml_get "$f" tuning profile)" "gaming"

toml_set "$f" tun mtu 1400
check "a number is replaced" "$(toml_get "$f" tun mtu)" "1400"
check "and its neighbours are left alone" "$(toml_get "$f" tun name)" "pfy0"

# A table the file does not have yet. The first version of toml_set silently
# did nothing here, so status.port was written, read back empty, and the
# status endpoint simply never came up.
toml_set "$f" status port 19900
check "a table that did not exist is created" "$(toml_get "$f" status port)" "19900"
check "and everything else survived it" "$(toml_get "$f" tunnel side)" "iran"

toml_set "$f" tuning queue_packets 900
check "a key added to an existing table" "$(toml_get "$f" tuning queue_packets)" "900"
check "beside the one already there" "$(toml_get "$f" tuning profile)" "gaming"

# A number goes in bare and a word goes in quoted, because the core's parser
# takes the quotes off strings and would read a bare word as one anyway - but
# a quoted number would come back with quotes on it.
check "numbers are written bare" \
    "$(grep -c '^queue_packets = 900$' "$f")" "1"
check "words are written quoted" \
    "$(grep -c '^profile = "gaming"$' "$f")" "1"

section "the file is the same on both servers"

# The property everything else depends on. Build the far side the way the
# wizard does - flip one line - and check that is all that differs.
write_sample "$f"
kh=$SANDBOX/kharej.toml
cp "$f" "$kh"
toml_set "$kh" tunnel side kharej

d=$(diff "$f" "$kh" | grep -c '^[<>]')
check "exactly two lines differ, which is one line changed" "$d" "2"
check "and the line that changed is side" \
    "$(diff "$f" "$kh" | grep '^>' | sed 's/^> //')" 'side = "kharej"'

# The addresses are named by side, not by near and far, so both files carry
# both addresses and neither has to be rewritten.
check "iran's address is the same in both" \
    "$(toml_get "$f" tun iran)" "$(toml_get "$kh" tun iran)"
check "and so is kharej's" \
    "$(toml_get "$f" tun kharej)" "$(toml_get "$kh" tun kharej)"
check "and the abroad address, which both name" \
    "$(toml_get "$f" transport kharej)" "$(toml_get "$kh" transport kharej)"

section "what the core will accept"

# The manager's validators exist to catch a bad value while the user is still
# looking at the prompt. If one lets something through that the core refuses,
# the user gets a Go error half an hour later instead. These are the same
# limits, asserted on both sides of each boundary.
if [ -x "$(command -v go)" ] && [ -f go.mod ]; then
    core=$SANDBOX/pingify-core
    if go build -o "$core" ./cmd/pingify 2>/dev/null; then
        write_sample "$f"
        check_rc "the core accepts what the manager writes" 0 "$core" -c "$f" -check

        for bad_case in "tun mtu 100" "tun mtu 20000" "tuning profile extreme" \
            "tuning queue_packets 50" "transport type gre"; do
            set -- $bad_case
            write_sample "$f"
            toml_set "$f" "$1" "$2" "$3"
            check_rc "the core refuses $1.$2 = $3" 1 "$core" -c "$f" -check
        done

        # And the manager must refuse the same things first.
        check_rc "so does the manager, for the mtu" 1 v_mtu 100
        check_rc "so does the manager, for the queue" 1 v_queue 50
    else
        skip "config against the real core" "the core did not build"
    fi
else
    skip "config against the real core" "no go toolchain"
fi

report
