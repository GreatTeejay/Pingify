#!/usr/bin/env bash
#
# Build Pingify.sh from parts/*.sh and the Go tree.
#
# The result is one file. A user downloads it, runs it, and it installs a
# tunnel - so everything the tunnel is made of has to be inside it, including
# the source, because a server in Iran cannot always reach a module proxy and
# sometimes cannot reach GitHub either.
#
# The core's own Go files go in as plain heredocs, readable in the middle of
# the script. Its dependencies - uTLS, and kcp-go with what it pulls in - go
# in as one compressed tarball of the vendored tree, trimmed to what a Linux
# server compiles.
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

# The shell suite guards the manager, which is most of what ships in this
# file, and the build used to gate on the Go tests alone. PINGIFY_FAST=1
# skips it while working; nothing that leaves this machine should.
if [ -z "${PINGIFY_FAST:-}" ] && [ -f tests/run.sh ]; then
    bash tests/run.sh >/dev/null 2>&1 ||
        { red "the shell tests do not pass - not shipping that"; exit 1; }
fi

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
    for f in go.mod go.sum "${gofiles[@]}"; do
        [ -f "$f" ] || continue
        printf "    cat > \"\$d/%s\" <<'%s' || return 1\n" "$f" "$DELIM"
        cat "$f"
        printf '%s\n' "$DELIM"
    done

    # The vendored dependencies, as one compressed blob rather than a heredoc
    # each. There are two hundred and eighty two files of them and five
    # megabytes; written out plainly the installer would be a five megabyte
    # shell script that nobody can read a line of. Compressed it is under a
    # megabyte, and the tools to undo it - base64 and tar - are on every
    # server that has a shell.
    #
    # Only what a Linux server on amd64 or arm64 compiles goes in. KCP brought
    # golang.org/x/net and all of golang.org/x/sys with it, and most of both is
    # Windows, the BSDs, and a dozen architectures no server here is: carried
    # whole, the blob was 2.6 MB; without them it is 1.5. Step 4 compiles
    # the extracted copy for both architectures, offline, so a file this
    # leaves out that the build needed stops the release there.
    if [ -d vendor ]; then
        strip="$(mktemp)"
        os='windows|darwin|ios|freebsd|openbsd|netbsd|dragonfly|solaris|illumos|aix|zos|plan9|js|wasip1|android|hurd'
        arch='386|arm|ppc64|ppc64le|s390x|mips|mipsle|mips64|mips64le|mips64p32|mips64p32le|riscv64|loong64|wasm|sparc64|ppc'
        {
            find vendor -type f -regextype posix-extended \
                \( -regex ".*_(${os})(_[a-z0-9]+)?\.(go|s)" -o -regex ".*_(${arch})\.(go|s)" \)
            find vendor -type d \( -path vendor/golang.org/x/sys/windows -o -path vendor/golang.org/x/sys/plan9 \)
        } > "$strip"
        printf "    base64 -d <<'%s' | tar -xzf - -C \"\$d\"\n" "$DELIM"
        tar -cf - --exclude-from="$strip" vendor | gzip -9 | base64 -w 100
        printf '%s\n' "$DELIM"
        rm -f "$strip"
    fi
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
if [ -d vendor ]; then
    [ -f "$check/vendor/modules.txt" ] ||
        { red "the vendored dependencies did not survive the round trip"; rm -f "$OUT"; exit 1; }
fi

# And it must still compile out of the extracted copy, offline, for both
# architectures a server might be. This is the check that matters: everything
# above proves the bytes match, and only this proves they are enough.
for arch in amd64 arm64; do
    ( cd "$check" && GOPROXY=off GOOS=linux GOARCH="$arch" CGO_ENABLED=0 \
        go build -o /dev/null ./cmd/pingify ) ||
        { red "the extracted sources do not build for linux/$arch"; rm -f "$OUT"; exit 1; }
done

green "Wrote $OUT ($(wc -l < "$OUT") lines, $(wc -c < "$OUT") bytes)"
green "  ${#gofiles[@]} Go files embedded$([ -d vendor ] && printf ' and %s vendored' "$(find vendor -name '*.go' | wc -l)"), both architectures build offline from them"
