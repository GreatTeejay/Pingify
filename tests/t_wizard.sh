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

# Seven answers: iran, this server's address, the one abroad, udp, the port,
# the octet, balanced, then y to create.
answers() { printf '%s\n' "$@"; }

section "seven questions on the first server"

if [ -z "$CORE" ]; then
    skip "the wizard end to end" "no core could be built"
else
    # 8 is [TUN] UDP: the link kind, with the address pair the octet derives.
    out=$(answers 1 8 185.31.8.129 46.247.109.83 8443 99 2 y | wizard_new 2>&1)
    rc=$?
    check "the wizard finished" "$rc" "0"

    f=$CFG_DIR/iran-udp-8443.toml
    if [ ! -f "$f" ]; then
        FAIL=$((FAIL + 1))
        printf '    \033[31mx\033[0m no config was written\n'
        printf '%s\n' "$out" | tail -20 | sed 's/^/        /'
    else
        check "the side that was chosen" "$(toml_get "$f" tunnel side)" "iran"
        check "the address abroad" "$(toml_get "$f" transport kharej)" "46.247.109.83"
        # Recorded rather than dialled, and the wizard asks for it because a
        # server with several addresses had the first one taken silently.
        check "this server's own address" "$(toml_get "$f" transport iran)" "185.31.8.129"
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

section "the name says which side it is"

# The first thing anybody needs to know about a tunnel is which end of the
# border it is, and `ls /root/pingify` should answer that without opening
# anything. It is why the two files differ in two lines rather than one: the
# paste rewrites the name along with the side.
if [ -f "$CFG_DIR/iran-udp-8443.toml" ]; then
    n=$(toml_get "$CFG_DIR/iran-udp-8443.toml" tunnel name)
    check "the name is side, transport and port" "$n" "iran-udp-8443"
    check "flipping it gives the other server's name" \
        "$(name_for_side "$n" kharej)" "kharej-udp-8443"
    check "a name nobody built from a side is left alone" \
        "$(name_for_side "something-else" kharej)" "something-else"

    # The device name is not the tunnel's name and must not become it: linux
    # takes fifteen characters and kharej-icmp-100 is already fifteen.
    d=$(toml_get "$CFG_DIR/iran-udp-8443.toml" tun name)
    check_missing "the device is not named after a side" "$d" "iran"
    if [ "${#d}" -le 15 ]; then PASS=$((PASS + 1)); else
        FAIL=$((FAIL + 1))
        printf '    \033[31mx\033[0m the device name is %s characters; linux allows 15\n' "${#d}"
    fi
fi

section "the token carries the whole file"

if [ -f "$CFG_DIR/iran-udp-8443.toml" ]; then
    f=$CFG_DIR/iran-udp-8443.toml
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

if [ -n "$CORE" ] && [ -f "$CFG_DIR/iran-udp-8443.toml" ]; then
    iran=$SANDBOX/iran.toml
    cp "$CFG_DIR/iran-udp-8443.toml" "$iran"
    line=$(token_encode "$iran")

    # The far server, from nothing but that line.
    rm -f "$CFG_DIR"/*.toml
    out=$(printf '%s\ny\n' "$line" | wizard_paste 2>&1)
    kharej=$CFG_DIR/kharej-udp-8443.toml

    if [ ! -f "$kharej" ]; then
        FAIL=$((FAIL + 1))
        printf '    \033[31mx\033[0m the paste did not produce a config\n'
        printf '%s\n' "$out" | tail -15 | sed 's/^/        /'
        ls "$CFG_DIR" | sed 's/^/        found: /'
    else
        check "the far side knows which side it is" \
            "$(toml_get "$kharej" tunnel side)" "kharej"
        check "and renamed itself to match" \
            "$(toml_get "$kharej" tunnel name)" "kharej-udp-8443"

        # The property the whole design rests on: one file, two servers. Two
        # lines differ now rather than one, and the second is the name, which
        # is the price of a name that says which end it is.
        d=$(diff "$iran" "$kharej" | grep -c '^[<>]')
        check "two lines differ between the two servers" "$d" "4"
        check "and they are the side and the name" \
            "$(diff "$iran" "$kharej" | grep '^>' | sed 's/^> //' | LC_ALL=C sort | tr '\n' ' ')" \
            'name = "kharej-udp-8443" side = "kharej" '
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


section "a bound port is checked on the end that waits"

# KHAREJ dials IRAN, so the port has to be free on IRAN. The check used to
# run on kharej - from when Iran was the end that dialled - which was the end
# with no socket, and skipped the end with one.
T_DIALS=
check_contains "by default the end that waits is iran" "$(wiz_waits)" "iran"
T_DIALS=iran
check_contains "with transport.dials = iran it is kharej" "$(wiz_waits)" "kharej"
T_DIALS=

wiz_port_owner() { return 1; }
wiz_port_bound() { return 0; } # everything is taken, as far as the kernel says
T_TRANSPORT=tcp
T_SIDE=iran
check_rc "on iran, the end that waits, a bound port is refused" 1 v_wiz_port 8443
T_SIDE=kharej
check_rc "on kharej, the end that dials, the same port is fine" 0 v_wiz_port 8443
unset -f wiz_port_owner wiz_port_bound


section "two kinds of tunnel, and the transport decides which"

# Streams forward ports and packets need a link; the core refuses the other
# pairing, so the wizard has to get it right every time.
for t in tcp ws wss utls fallback; do
    check_contains "$t forwards ports" "$(mode_of $t)" "forward"
done
for t in icmp gre udp rawtcp awg; do
    check_contains "$t is a [TUN] link" "$(mode_of $t)" "tun"
done
check_contains "a [TUN] transport wears the label" "$(kind_label icmp)" "[TUN] ICMP"
check_contains "and Raw TCP keeps its name under it" "$(kind_label rawtcp)" "[TUN] Raw TCP"
check_missing "a TCP tunnel does not" "$(kind_label fallback)" "[TUN]"
check_contains "the port list renders as a TOML array" "$(fwd_toml_list 443 udp:500 8000-8010=9000)" '"443", "udp:500", "8000-8010=9000"'


section "a TCP tunnel: ports instead of a link"

if [ -z "$CORE" ]; then
    skip "the forward wizard end to end" "no core could be built"
else
    out=$(answers 1 1 185.31.8.129 46.247.109.83 8443 "443,udp:500" 2 y | wizard_new 2>&1)
    check "the wizard finished" "$?" "0"
    f=$CFG_DIR/iran-tcp-8443.toml
    if [ ! -f "$f" ]; then
        FAIL=$((FAIL + 1))
        printf '    [31mx[0m no config was written
'
        printf '%s
' "$out" | tail -12 | sed 's/^/        /'
    else
        check "it is a forward tunnel" "$(toml_get "$f" tunnel mode)" "forward"
        check_contains "the ports went into the file, both of them" "$(toml_get "$f" forward ports)" '"443", "udp:500"'
        check_missing "and there is no private link in it" "$(cat "$f")" "[tun]"
        check "the core accepts it"             "$("$CORE" -c "$f" -check >/dev/null 2>&1 && echo yes || echo no)" "yes"
    fi
fi

report
