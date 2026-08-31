#!/usr/bin/env bash
# Every suite, in the order that fails fastest.
#
# The engine first, because a broken core makes the manager suites fail in
# ways that point at the wrong file. Then the manager, then the forwarding
# matrix. This is what CI runs before it publishes anything.
set -uo pipefail
cd "$(dirname "$0")/.."

GO_BIN="${GO_BIN:-go}"
fail=0

run() {
    printf '\n\033[1m== %s ==\033[0m\n' "$1"
    shift
    if "$@"; then
        return 0
    fi
    fail=1
    return 1
}

if command -v "$GO_BIN" >/dev/null 2>&1; then
    run "engine" bash -c "cd core && '$GO_BIN' test -count=1 -timeout 600s ./..."
else
    printf '\n\033[33m== engine: skipped, no Go toolchain ==\033[0m\n'
fi

run "manager"          bash tests/manager_test.sh
run "forwarding matrix" bash tests/matrix_test.sh

printf '\n'
if [ "$fail" = "0" ]; then
    printf '\033[32mall suites passed\033[0m\n\n'
else
    printf '\033[31mone or more suites failed\033[0m\n\n'
fi
exit "$fail"
