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
# Windows worktree even though Git stores LF. Canonical content and tar metadata
# keep repeat builds stable on one host. The compressed bytes may still differ
# across gzip implementations, so CI verifies the extracted tree instead of
# pretending cross-platform byte identity is a source-freshness check.
cp core/go.mod core/go.sum "$vendor_stage/"
mkdir -p "$vendor_stage/vendor"
cp -R core/vendor/. "$vendor_stage/vendor/"

# Drop what this bundle can never compile.
#
# The releases are linux/amd64 and linux/arm64, and the fallback build inside
# the script is the same two. Better than half the vendored bytes are Windows,
# macOS, BSD, plan9 and wasm sources that Go excludes by filename before it
# reads a line of them - x/sys/windows alone is bigger than the engine. They
# were riding along in every download of this script for nothing.
#
# Only GOOS-suffixed names are touched, which is exactly the set Go decides by
# filename. Anything with a real build constraint inside it is left alone, and
# section 5 proves the result by compiling both targets out of the extracted
# bundle rather than trusting this list.
rm -rf "$vendor_stage/vendor/golang.org/x/sys/windows"
for goos in windows darwin ios js wasip1 wasm plan9 aix solaris illumos             netbsd openbsd freebsd dragonfly zos hurd; do
    find "$vendor_stage/vendor" -type f         \( -name "*_$goos.go"  -o -name "*_$goos.s"         -o -name "*_${goos}_*.go" -o -name "*_${goos}_*.s" \) -delete
done

# And the same again for architectures. The releases are amd64 and arm64; the
# 386, arm, mips, ppc, riscv, s390x, loong64 and sparc64 sources in x/sys are
# another few megabytes Go would never open. _arm64 is a different suffix from
# _arm and is left alone.
for goarch in 386 arm mips mipsle mips64 mips64le mips64p32 mips64p32le               ppc ppc64 ppc64le riscv riscv64 s390x loong64 sparc sparc64; do
    find "$vendor_stage/vendor" -type f         \( -name "*_$goarch.go" -o -name "*_$goarch.s"         -o -name "*_${goarch}_*.go" -o -name "*_${goarch}_*.s" \) -delete
done
find "$vendor_stage/vendor" -type d -empty -delete
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

# The fallback build is the whole reason the vendor tree ships, so prove it
# rather than assume it: compile both release targets out of the extracted
# bundle. This is the only check that would catch a prune above taking a file
# some Linux build actually needed.
if command -v "$GO_BIN" >/dev/null 2>&1; then
    for arch in amd64 arm64; do
        info "offline build from the bundle: linux/$arch"
        if ! ( cd "$check_dir" && GOFLAGS=-mod=vendor GOOS=linux GOARCH="$arch"                 CGO_ENABLED=0 "$GO_BIN" build -o /dev/null . ); then
            red "the embedded sources cannot build linux/$arch offline"
            rm -rf "$check_dir"
            exit 1
        fi
    done
fi
rm -rf "$check_dir"

grn "Wrote $OUT ($(wc -l < "$OUT") lines, $(wc -c < "$OUT") bytes) - parses, sources verified."
