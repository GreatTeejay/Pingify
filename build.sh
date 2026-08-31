#!/usr/bin/env bash
#
# Build Pingify.sh from parts/*.sh and the Go tree.
#
# The result is one file. A user downloads it, runs it, and it installs a
# tunnel - so everything the tunnel is made of has to be inside it, including
# the source, because a server in Iran cannot always reach a module proxy and
# sometimes cannot reach GitHub either.
#
# The old bundle carried a compressed tarball of a vendored module tree for
# this: kcp, reed-solomon, uTLS and their dependencies, most of it Windows and
# BSD sources that Go would never open. The new core has no dependencies at
# all, so this is now what it looks like when there is nothing to vendor: the
# Go files go in as plain heredocs, readable in the middle of the script, and
# the whole embedding is thirty lines instead of a hundred.
set -euo pipefail

cd "$(dirname "$0")"

OUT=Pingify.sh
DELIM='PINGIFY_GO_SOURCE_EOF'

red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

# --- 1. what goes in -------------------------------------------------------

command -v go >/dev/null || { red "go is not on PATH"; exit 1; }

[ -d parts ] || { red "there is no parts/ directory to build from"; exit 1; }
shopt -s nullglob
parts=(parts/*.sh)
(( ${#parts[@]} )) || { red "parts/ is empty"; exit 1; }

# Every Go file except the tests. The tests stay in the repository: they are
# run before a release, not on the server that is installing.
mapfile -t gofiles < <(
    find cmd internal -name '*.go' ! -name '*_test.go' | LC_ALL=C sort
)
(( ${#gofiles[@]} )) || { red "no Go sources found under cmd/ and internal/"; exit 1; }

# --- 2. check the source is sound before wrapping it -----------------------

gofmt -l cmd internal | grep . && { red "gofmt has changes to make - not shipping that"; exit 1; }
go vet ./... || { red "go vet is unhappy - not shipping that"; exit 1; }
go test ./... >/dev/null || { red "the tests do not pass - not shipping that"; exit 1; }

for arch in amd64 arm64; do
    GOOS=linux GOARCH="$arch" CGO_ENABLED=0 go build -o /dev/null ./cmd/pingify ||
        { red "linux/$arch does not build"; exit 1; }
done

# --- 3. build the embedded-source block ------------------------------------

tmp="$(mktemp)"; core="$(mktemp)"
trap 'rm -f "$tmp" "$core"' EXIT

cat parts/*.sh > "$tmp"
grep -q '@@CORE_FILES@@' "$tmp" || { red "the @@CORE_FILES@@ marker is missing from parts/"; exit 1; }

{
    # The paths matter now. The old core was one flat package, so the bundle
    # wrote basenames into one directory; this one is a module with cmd/ and
    # internal/, and Go will not compile it laid out any other way.
    printf '    mkdir -p'
    printf ' "$d/%s"' $(printf '%s\n' "${gofiles[@]}" | xargs -n1 dirname | LC_ALL=C sort -u)
    printf '\n'
    for f in go.mod "${gofiles[@]}"; do
        printf "    cat > \"\$d/%s\" <<'%s'\n" "$f" "$DELIM"
        cat "$f"
        printf '%s\n' "$DELIM"
    done
} > "$core"

awk -v corefile="$core" '
    /@@CORE_FILES@@/ { while ((getline line < corefile) > 0) print line; next }
    { print }
' "$tmp" > "$OUT"
chmod +x "$OUT"

# --- 4. prove the thing that came out is the thing that went in ------------

bash -n "$OUT" || { red "the generated script does not parse"; rm -f "$OUT"; exit 1; }

check="$(mktemp -d)"
trap 'rm -f "$tmp" "$core"; rm -rf "$check"' EXIT

PINGIFY_NO_MAIN=1 bash -c 'set -e; . "$1"; write_core_sources "$2"' _ "./$OUT" "$check" >/dev/null

for f in go.mod "${gofiles[@]}"; do
    cmp -s "$f" "$check/$f" || { red "$f did not survive the round trip"; rm -f "$OUT"; exit 1; }
done

# And it must still compile out of the extracted copy, offline, for both
# architectures a server might be. This is the check that matters: everything
# above proves the bytes match, and only this proves they are enough.
for arch in amd64 arm64; do
    ( cd "$check" && GOFLAGS=-mod=mod GOPROXY=off GOOS=linux GOARCH="$arch" CGO_ENABLED=0 \
        go build -o /dev/null ./cmd/pingify ) ||
        { red "the extracted sources do not build for linux/$arch"; rm -f "$OUT"; exit 1; }
done

green "Wrote $OUT ($(wc -l < "$OUT") lines, $(wc -c < "$OUT") bytes)"
green "  ${#gofiles[@]} Go files embedded, both architectures build offline from them"
