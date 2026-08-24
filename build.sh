#!/usr/bin/env bash
# Build Pingify.sh from parts/*.sh and core/*.go.
#
# Run this after touching anything in parts/ or core/. It refuses to write a
# script that does not parse, and it checks that the Go sources it embedded
# come back out byte for byte.
set -euo pipefail
cd "$(dirname "$0")"

OUT="Pingify.sh"
DELIM="PINGIFY_SRC_EOF"
VENDOR_DELIM="PINGIFY_VENDOR_EOF"
GO_BIN="${GO_BIN:-go}"

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }

# --- 1. the core has to be healthy before we bundle it -------------------
if command -v "$GO_BIN" >/dev/null 2>&1; then
    info "gofmt"
    unformatted="$("$GO_BIN" fmt ./core/ 2>/dev/null || true)"
    [ -z "$unformatted" ] || info "reformatted: $unformatted"

    info "vet"
    ( cd core && GOOS=linux "$GO_BIN" vet . )

    info "build linux/amd64"
    ( cd core && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 "$GO_BIN" build -o /dev/null . )
    info "build linux/arm64"
    ( cd core && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 "$GO_BIN" build -o /dev/null . )

    info "test"
    # Kept, not discarded. A build that fails without saying which test failed
    # is a build you have to reproduce somewhere else before you can read it,
    # and the place it failed is usually the place you do not have.
    testlog="$(mktemp)"
    if ! ( cd core && "$GO_BIN" test -count=1 -short -timeout 120s . ) >"$testlog" 2>&1; then
        red "the engine's own tests failed"
        cat "$testlog"
        rm -f "$testlog"
        exit 1
    fi
    rm -f "$testlog"
else
    red "warning: no Go toolchain here, bundling the sources unchecked"
fi

# --- 2. refuse a delimiter collision --------------------------------------
for f in core/*.go; do
    case "$f" in *_test.go) continue ;; esac
    if grep -qx "$DELIM" "$f"; then
        red "$f contains a line equal to the heredoc delimiter"
        exit 1
    fi
done

# --- 3. concatenate the manager parts -------------------------------------
tmp="$(mktemp)"
vendor_stage="$(mktemp -d)"
trap 'rm -f "$tmp" "$tmp.core"; rm -rf "$vendor_stage"' EXIT
cat parts/*.sh > "$tmp"

grep -q '@@CORE_FILES@@' "$tmp" || { red "the @@CORE_FILES@@ marker is missing"; exit 1; }

# --- 4. build the embedded-source block -----------------------------------
{
    for f in core/*.go; do
        case "$f" in *_test.go) continue ;; esac
        printf "    cat > \"\$d/%s\" <<'%s'\n" "$(basename "$f")" "$DELIM"
        cat "$f"
        printf '%s\n' "$DELIM"
    done
} > "$tmp.core"

# KCP/FEC has audited MIT/BSD dependencies. Keep the server-side build fully
# offline by shipping the vendored module tree as one compressed block rather
# than turning hundreds of small source files into hundreds of heredocs.
#
# The staging pass is deliberate. A module zip may leave CRLF files in a
# Windows worktree even though Git stores LF; without canonical content and tar
# metadata, Windows and Ubuntu produce different Pingify.sh files from the same
# commit and the release freshness check can never pass.
cp core/go.mod core/go.sum "$vendor_stage/"
mkdir -p "$vendor_stage/vendor"
cp -R core/vendor/. "$vendor_stage/vendor/"
while IFS= read -r -d '' f; do
    if grep -Iq . "$f"; then
        sed -i 's/\r$//' "$f"
    fi
done < <(find "$vendor_stage" -type f -print0)
find "$vendor_stage" -type d -exec chmod 0755 {} +
find "$vendor_stage" -type f -exec chmod 0644 {} +
{
    printf "    base64 -d <<'%s' | tar -xzf - -C \"\$d\"\n" "$VENDOR_DELIM"
    ( cd "$vendor_stage" && LC_ALL=C tar --sort=name --format=gnu --mtime=@0 \
        --owner=0 --group=0 --numeric-owner -cf - go.mod go.sum vendor ) \
        | gzip -n -9 | base64
    printf '%s\n' "$VENDOR_DELIM"
} >> "$tmp.core"

awk -v corefile="$tmp.core" '
    /@@CORE_FILES@@/ { while ((getline line < corefile) > 0) print line; next }
    { print }
' "$tmp" > "$OUT"
chmod +x "$OUT"

# --- 5. checks ------------------------------------------------------------
if ! bash -n "$OUT"; then
    red "the generated script does not parse - not shipping it"
    rm -f "$OUT"
    exit 1
fi

# The embedded sources must survive the round trip exactly.
check_dir="$(mktemp -d)"
PINGIFY_NO_MAIN=1 bash -c 'set -e; . "$1"; write_core_sources "$2"' _ "./$OUT" "$check_dir" >/dev/null
for f in core/*.go; do
    case "$f" in *_test.go) continue ;; esac
    if ! diff -q "$f" "$check_dir/$(basename "$f")" >/dev/null; then
        red "embedded copy of $f differs from the original"
        rm -rf "$check_dir"
        exit 1
    fi
done
if ! diff -qr "$vendor_stage/vendor" "$check_dir/vendor" >/dev/null ||
   ! diff -q "$vendor_stage/go.mod" "$check_dir/go.mod" >/dev/null ||
   ! diff -q "$vendor_stage/go.sum" "$check_dir/go.sum" >/dev/null; then
    red "embedded vendored modules differ from the originals"
    rm -rf "$check_dir"
    exit 1
fi
rm -rf "$check_dir"

grn "Wrote $OUT ($(wc -l < "$OUT") lines, $(wc -c < "$OUT") bytes) - parses, sources verified."
