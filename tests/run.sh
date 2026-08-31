#!/usr/bin/env bash
#
# Everything, in order, with a total that is honest about what did not run.
#
# The old runner let about twenty assertions disappear without a word when
# there was no Go toolchain on the machine, so a green run somewhere missing a
# dependency looked exactly like a green run somewhere that had it. Skips are
# counted here and printed at the end whether there are none or forty.

cd "$(dirname "$0")/.." || exit 1

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0

hdr() { printf '\n\033[1m%s\033[0m\n' "$1"; }

hdr "the core"
if command -v go >/dev/null 2>&1; then
    # The status of the pipeline is grep's, and grep says 1 when it filtered
    # everything out - which is what a clean run looks like. Take the status
    # from go itself.
    out=$(go test ./... 2>&1)
    rc=$?
    printf '%s\n' "$out" | grep -v "no test files" | sed 's/^/  /'
    if [ "$rc" != 0 ]; then
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
else
    printf '  \033[90m- the Go tests did not run (no go on PATH)\033[0m\n'
    TOTAL_SKIP=$((TOTAL_SKIP + 1))
fi

for t in tests/t_*.sh; do
    [ -e "$t" ] || continue
    hdr "${t##*/}"
    tally=$(mktemp)
    TALLY=$tally bash "$t"
    read -r p f s <"$tally" 2>/dev/null || { p=0; f=1; s=0; }
    rm -f "$tally"
    TOTAL_PASS=$((TOTAL_PASS + p))
    TOTAL_FAIL=$((TOTAL_FAIL + f))
    TOTAL_SKIP=$((TOTAL_SKIP + s))
    printf '    \033[90m%s passed, %s failed, %s skipped\033[0m\n' "$p" "$f" "$s"
done

printf '\n'
if [ "$TOTAL_FAIL" = 0 ]; then
    printf '\033[32m  %s passed\033[0m' "$TOTAL_PASS"
else
    printf '\033[31m  %s failed\033[0m, %s passed' "$TOTAL_FAIL" "$TOTAL_PASS"
fi
[ "$TOTAL_SKIP" != 0 ] && printf ', \033[33m%s skipped\033[0m' "$TOTAL_SKIP"
printf '\n\n'

[ "$TOTAL_FAIL" = 0 ]
