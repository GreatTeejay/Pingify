#!/usr/bin/env bash
#
# What a test in this suite is allowed to do.
#
# The old suite had 631 assertions and about a hundred and thirty of them were
# greps of the manager's own source text - counting how many times a phrase
# appeared in Pingify.sh. They pinned wording rather than behaviour, so
# renaming a menu item broke them, and they passed happily on code that could
# never run. Thirty-eight helper functions existed only to awk a function body
# out of the file so it could be grepped.
#
# They were written that way because the interactive paths were not callable.
# In the new script every question is a function and every screen renders to
# stdout, so a test drives the real thing. There is one grep of the source in
# the whole suite and it enforces an architectural rule rather than a phrase:
# that no ask() call site omits its validator.

set -o pipefail

PASS=0
FAIL=0
SKIP=0
SECTION=

section() {
    SECTION=$1
    printf '\n  \033[1m%s\033[0m\n' "$1"
}

check() {
    local what=$1 got=$2 want=$3
    if [ "$got" = "$want" ]; then
        PASS=$((PASS + 1))
        return 0
    fi
    FAIL=$((FAIL + 1))
    printf '    \033[31mx\033[0m %s\n' "$what"
    printf '        wanted: %s\n' "$want"
    printf '        got:    %s\n' "$got"
    return 1
}

# check_rc is for the things whose answer is an exit status: a validator that
# must refuse, a parser that must reject.
check_rc() {
    local what=$1 want=$2
    shift 2
    "$@" >/dev/null 2>&1
    local got=$?
    if [ "$got" = "$want" ]; then
        PASS=$((PASS + 1))
        return 0
    fi
    FAIL=$((FAIL + 1))
    printf '    \033[31mx\033[0m %s\n' "$what"
    printf '        wanted exit %s, got %s, from: %s\n' "$want" "$got" "$*"
    return 1
}

check_contains() {
    local what=$1 haystack=$2 needle=$3
    case $haystack in
    *"$needle"*)
        PASS=$((PASS + 1))
        return 0
        ;;
    esac
    FAIL=$((FAIL + 1))
    printf '    \033[31mx\033[0m %s\n' "$what"
    printf '        looked for: %s\n' "$needle"
    printf '        in:         %s\n' "$(printf '%s' "$haystack" | head -c 300)"
    return 1
}

check_missing() {
    local what=$1 haystack=$2 needle=$3
    case $haystack in
    *"$needle"*)
        FAIL=$((FAIL + 1))
        printf '    \033[31mx\033[0m %s\n' "$what"
        printf '        should not have contained: %s\n' "$needle"
        return 1
        ;;
    esac
    PASS=$((PASS + 1))
}

# skip counts, and says so. The old runner let about twenty assertions vanish
# without a word when there was no Go toolchain, so a green run on a machine
# missing a dependency looked exactly like a green run on one that had it.
skip() {
    SKIP=$((SKIP + 1))
    printf '    \033[90m- %s (skipped: %s)\033[0m\n' "$1" "$2"
}

have() { command -v "$1" >/dev/null 2>&1; }

# A test file reports through a file rather than through globals, because each
# runs in its own subshell with its own temporary directories - so one section
# leaking a variable cannot change what another one measures.
report() {
    printf '%s %s %s\n' "$PASS" "$FAIL" "$SKIP" >"${TALLY:-/dev/null}"
    [ "$FAIL" = 0 ]
}

# load brings in the manager without letting it run. Every part, in the order
# build.sh concatenates them.
load_parts() {
    local root=${1:-.}
    PINGIFY_NO_MAIN=1
    PINGIFY_ASCII=1
    NO_COLOR=1
    PINGIFY_WIDTH=${PINGIFY_WIDTH:-80}
    export PINGIFY_NO_MAIN PINGIFY_ASCII NO_COLOR PINGIFY_WIDTH
    local f
    for f in "$root"/parts/*.sh; do
        # shellcheck disable=SC1090
        . "$f"
    done
}

# sandbox gives a test its own /etc and /var so nothing it does can reach the
# machine it is running on.
sandbox() {
    SANDBOX=$(mktemp -d)
    PINGIFY_CFG_DIR="$SANDBOX/etc"
    PINGIFY_STATE_DIR="$SANDBOX/var"
    PINGIFY_SRC_DIR="$SANDBOX/src"
    PINGIFY_UNIT_DIR="$SANDBOX/units"
    PINGIFY_CORE_DIR="$SANDBOX/core"
    CFG_DIR=$PINGIFY_CFG_DIR
    STATE_DIR=$PINGIFY_STATE_DIR
    SRC_DIR=$PINGIFY_SRC_DIR
    UNIT_DIR=$PINGIFY_UNIT_DIR
    CORE_DIR=$PINGIFY_CORE_DIR
    mkdir -p "$CFG_DIR" "$STATE_DIR" "$SRC_DIR" "$UNIT_DIR" "$CORE_DIR"
    export PINGIFY_CFG_DIR PINGIFY_STATE_DIR PINGIFY_SRC_DIR PINGIFY_UNIT_DIR PINGIFY_CORE_DIR
}

sandbox_clean() { [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"; }
