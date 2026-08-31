#!/usr/bin/env bash
#
# The wizard, driven rather than grepped.
#
# The old suite could not do this: its questions were inline in one long
# function, so a test could only look at the source and count how many times a
# phrase appeared in it. Those assertions passed on code that could never run
# and broke whenever anybody improved the wording. Here the questions are
# functions and the answers come from stdin, so a test answers them the way a
# person does and then reads what was written.

cd "$(dirname "$0")/.." || exit 1
. tests/lib.sh
load_parts .
sandbox
trap sandbox_clean EXIT

# The wizard writes a file and then asks the core whether it is any good, so
# there has to be a core. Without one, the parts that can be tested without it
# still are.
CORE=
if command -v go >/dev/null 2>&1 && go build -o "$SANDBOX/pingify-core" ./cmd/pingify 2>/dev/null; then
    CORE=$SANDBOX/pingify-core
    CORE_BIN=$CORE
fi

# systemd is not here and must not be reached for. Stub the two things the
# wizard calls, and record what it asked for.
systemctl() { printf '%s\n' "systemctl $*" >>"$SANDBOX/systemctl.log"; return 0; }
svc_do() { printf '%s\n' "svc_do $*" >>"$SANDBOX/systemctl.log"; return 0; }
nat_apply() { return 0; }

# Six answers: iran, the address abroad, udp, the port, the octet, balanced,
# then y to create.
answers() { printf '%s\n' "$@"; }

section "six questions on the first server"

if [ -z "$CORE" ]; then
    skip "the wizard end to end" "no core could be built"
else
    out=$(answers 1 46.247.109.83 1 8443 99 2 y | wizard_new 2>&1)
    rc=$?
    check "the wizard finished" "$rc" "0"

    f=$CFG_DIR/udp-99.toml
    if [ ! -f "$f" ]; then
        FAIL=$((FAIL + 1))
        printf '    \033[31mx\033[0m no config was written\n'
        printf '%s\n' "$out" | tail -20 | sed 's/^/        /'
    else
        check "the side that was chosen" "$(toml_get "$f" tunnel side)" "iran"
        check "the address abroad" "$(toml_get "$f" transport kharej)" "46.247.109.83"
        check "the transport" "$(toml_get "$f" transport type)" "udp"
        check "the port" "$(toml_get "$f" transport port)" "8443"
        check "the profile" "$(toml_get "$f" tuning profile)" "balanced"
        check "iran's address, derived from the octet" \
            "$(toml_get "$f" tun iran)" "10.99.10.1/24"
        check "kharej's, derived from the same octet" \
            "$(toml_get "$f" tun kharej)" "10.99.10.2/24"
        check "the core accepts what the wizard wrote" \
            "$("$CORE" -c "$f" -check >/dev/null 2>&1 && echo yes || echo no)" "yes"

        # The token is generated, not asked for. A question removed is a
        # question nobody gets wrong, and it removes the class of bug where
        # one server has a trailing space on the end of its token.
        tok=$(toml_get "$f" security token)
        if [ "${#tok}" -ge 8 ]; then PASS=$((PASS + 1)); else
            FAIL=$((FAIL + 1))
            printf '    \033[31mx\033[0m the generated token was %s characters\n' "${#tok}"
        fi

        # chmod does nothing at all on some filesystems - NTFS under Git Bash
        # for one - and a test that always fails there is a test people learn
        # to ignore. Find out whether chmod works before believing it.
        probe=$SANDBOX/mode.probe
        : >"$probe"
        chmod 0600 "$probe" 2>/dev/null
        if [ "$(stat -c %a "$probe" 2>/dev/null)" = 600 ]; then
            check "the config is not readable by anyone else" \
                "$(stat -c %a "$f" 2>/dev/null)" "600"
        else
            skip "the config file's mode" "chmod does nothing on this filesystem"
        fi
    fi
fi

section "the name says nothing about which side it is"

# The name lives in the shared file, so a name with iran in it would be wrong
# on the other server the moment it was pasted there. The old naming scheme
# was iran-9443 and walked straight into this.
if [ -f "$CFG_DIR/udp-99.toml" ]; then
    n=$(toml_get "$CFG_DIR/udp-99.toml" tunnel name)
    check_missing "no iran in the name" "$n" "iran"
    check_missing "no kharej in the name" "$n" "kharej"
    d=$(toml_get "$CFG_DIR/udp-99.toml" tun name)
    check_missing "nor in the device name" "$d" "iran"
    if [ "${#d}" -le 15 ]; then PASS=$((PASS + 1)); else
        FAIL=$((FAIL + 1))
        printf '    \033[31mx\033[0m the device name is %s characters; linux allows 15\n' "${#d}"
    fi
fi

section "the token carries the whole file"

if [ -f "$CFG_DIR/udp-99.toml" ]; then
    f=$CFG_DIR/udp-99.toml
    line=$(token_encode "$f")
    check_contains "it is marked as ours" "$line" "PFY2."

    back=$(token_decode "$line")
    check "what comes out is what went in" "$back" "$(cat "$f")"

    # One hash over the body. The old format was thirty-one fields separated
    # by pipes, so every new config key meant editing both halves and keeping
    # them in step, and a truncated paste was caught only by field arithmetic.
    bent=${line%??}zz
    check_rc "a token that was damaged in the paste is refused" 1 token_decode "$bent"

    # A token with awkward characters in it must survive the round trip, since
    # the security token is arbitrary text and people paste it from anywhere.
    g=$SANDBOX/awkward.toml
    cp "$f" "$g"
    toml_set "$g" security token 'a|b"c#d e	f'
    back=$(token_decode "$(token_encode "$g")")
    check "quotes, pipes and hashes come back unharmed" "$back" "$(cat "$g")"
fi

section "one paste finishes the pair"

if [ -n "$CORE" ] && [ -f "$CFG_DIR/udp-99.toml" ]; then
    iran=$SANDBOX/iran.toml
    cp "$CFG_DIR/udp-99.toml" "$iran"
    line=$(token_encode "$iran")

    # The far server, from nothing but that line.
    rm -f "$CFG_DIR"/*.toml
    out=$(printf '%s\ny\n' "$line" | wizard_paste 2>&1)
    kharej=$CFG_DIR/udp-99.toml

    if [ ! -f "$kharej" ]; then
        FAIL=$((FAIL + 1))
        printf '    \033[31mx\033[0m the paste did not produce a config\n'
        printf '%s\n' "$out" | tail -15 | sed 's/^/        /'
    else
        check "the far side knows which side it is" \
            "$(toml_get "$kharej" tunnel side)" "kharej"

        # The property the whole design rests on. Two files, one changed line.
        d=$(diff "$iran" "$kharej" | grep -c '^[<>]')
        check "exactly one line differs between the two servers" "$d" "2"
        check "and it is the side" \
            "$(diff "$iran" "$kharej" | grep '^>' | sed 's/^> //')" 'side = "kharej"'
        check "the core accepts the far side too" \
            "$("$CORE" -c "$kharej" -check >/dev/null 2>&1 && echo yes || echo no)" "yes"
    fi
fi

section "what is already taken"

# Nothing may be handed out twice, and a tunnel being edited may keep what it
# already has - which is the case the old collision check got wrong, so
# changing anything about a tunnel told you its own address was in use.
rm -f "$CFG_DIR"/*.toml
cat >"$CFG_DIR/taken.toml" <<'T'
[tunnel]
name = "taken"
side = "iran"
[transport]
type = "udp"
port = 8443
[tun]
name = "pfy0"
iran = "10.77.10.1/24"
kharej = "10.77.10.2/24"
T

check "an octet another tunnel holds is taken" "$(wiz_link_owner 77)" "the tunnel taken"
check "a free one is free" "$(wiz_link_owner 78)" ""
check "a device another tunnel holds is taken" "$(wiz_device_owner pfy0)" "the tunnel taken"
check "a free device is free" "$(wiz_device_owner pfy1)" ""
check "a port another tunnel holds is taken" "$(wiz_port_owner 8443)" "the tunnel taken"
check "a free port is free" "$(wiz_port_owner 8444)" ""

# The exception that matters: editing a tunnel, its own values are not a clash.
check "a tunnel may keep its own octet" "$(wiz_link_owner 77 taken)" ""
check "and its own device" "$(wiz_device_owner pfy0 taken)" ""
check "and its own port" "$(wiz_port_owner 8443 taken)" ""

check "the next free octet skips what is taken" \
    "$(free_octet | head -1)" "$(free_octet | head -1)"
o=$(free_octet)
check_rc "and what it offers is genuinely free" 0 test -z "$(wiz_link_owner "$o")"

report
