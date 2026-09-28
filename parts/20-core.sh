#!/usr/bin/env bash
#
# The core: the Go program this script exists to install, and the two things
# needed to get one - its source, and a compiler for it.
#
# Everything in here is shaped by one fact. The server this runs on is in
# Iran and may be able to reach neither a module proxy nor GitHub, so the Go
# sources travel inside this script as plain heredocs and are compiled on the
# machine, offline, with GOPROXY=off. Its two dependencies, uTLS and kcp-go,
# travel the same way, vendored, which is what makes that possible.
#
# There is deliberately no "download a prebuilt binary instead" path. A
# fallback that needs the network is not a fallback for the only machine that
# ever needs one, and carrying it would mean the offline path was never
# exercised and rotted quietly until the day it mattered.
#
# The single step that can want the network is a Go toolchain, and only when
# this machine has none or has one older than the module asks for. That
# download is described in plain words, confirmed before it happens, and
# checked against go.dev's own sha256 before anything is unpacked.

# The compiler ensure_go settled on. Empty until it has run.
GO_BIN=

# Where the Go tarball comes from, in the order tried. go.dev first, which is
# Google's - and to a server in Iran dl.google.com answers every request with
# a 404, measured on 2026-09-28. Then the copy of the very same file that this
# project's release carries, and two mirrors that did answer from Iran that
# day. PINGIFY_GO_URL, when it is set, is tried before all of them: a mirror
# of your own, or a copy on your other server.
go_sources() {
    [ -n "${PINGIFY_GO_URL:-}" ] && printf '%s\n' "${PINGIFY_GO_URL%/}"
    printf '%s\n' \
        https://go.dev/dl \
        "https://github.com/$PINGIFY_REPO/releases/download/v$PINGIFY_VERSION" \
        https://mirrors.nju.edu.cn/golang \
        https://mirrors.aliyun.com/golang
}

# go_sum NAME - go.dev's own sha256 of a tarball ensure_go can ask for, so that
# whichever of those places a server could reach, what it unpacks is the file
# Google published: a mirror is a stranger, and with the sum here it does not
# have to be trusted. The tests check there is one for every tarball the
# embedded go.mod can ask for, so a new go directive cannot ship without them.
go_sum() {
    case $1 in
    go1.24.0.linux-amd64.tar.gz) printf 'dea9ca38a0b852a74e81c26134671af7c0fbe65d81b0dc1c5bfe22cf7d4c8858' ;;
    go1.24.0.linux-arm64.tar.gz) printf 'c3fa6d16ffa261091a5617145553c71d21435ce547e44cc6dfb7470865527cc7' ;;
    *) return 1 ;;
    esac
}

# go_tarball ARCH - the file ensure_go fetches. A released minor always has a
# .0, so the name comes from the go directive rather than from a version
# typed here that could drift from it.
go_tarball() {
    local want tar_ver
    want=$(go_version_needed) || return 1
    tar_ver=$want
    case $want in *.*.*) ;; *) tar_ver=$want.0 ;; esac
    printf 'go%s.linux-%s.tar.gz' "$tar_ver" "$1"
}

# go_fetch NAME DEST - the tarball into DEST from the first source that has it
# and serves go.dev's own bytes. A source that fails, or serves anything else,
# is named and passed over, and so is one that trickles: a throttled source
# used to hold the install for as long as it pleased. GO_FROM is the one used.
go_fetch() {
    local name=$1 dest=$2 want src host got
    GO_FROM=
    want=$(go_sum "$name") || want=
    while IFS= read -r src; do
        [ -n "$src" ] || continue
        host=${src#*://}
        host=${host%%/*}
        rm -f "$dest"
        if ! spin "fetching $name from $host" go_fetch_one "$src/$name" "$dest"; then
            warn "$host: $(go_fetch_why)"
            continue
        fi
        got=$(wiz_sha256 <"$dest" 2>/dev/null) || got=
        if [ -z "$want" ] || [ -z "$got" ]; then
            # Nothing to check it against, or nothing here to check with: the
            # one case left unverified, and it says so.
            warn "$name from $host could not be checked against go.dev's sha256"
            [ -n "$got" ] && dim "sha256 $got - compare it with https://go.dev/dl/"
            GO_FROM=$host
            return 0
        fi
        if [ "$got" = "$want" ]; then
            ok "$name from $host, sha256 matches go.dev"
            GO_FROM=$host
            return 0
        fi
        warn "$host: what arrived is not go.dev's file (sha256 ${got:0:16}) - not used"
    done < <(go_sources)
    rm -f "$dest"
    return 1
}
go_fetch_one() {
    if have curl; then
        curl -fSL --retry 1 --connect-timeout 15 --speed-limit 20000 --speed-time 45 \
            -o "$2" "$1" >"$STATE_DIR/fetch.log" 2>&1
    else
        wget -T 45 -O "$2" "$1" >"$STATE_DIR/fetch.log" 2>&1
    fi
}
# go_fetch_why is the line of the fetch log that says why it failed.
go_fetch_why() {
    local l
    l=$(grep -v '^[[:space:]]*$' "$STATE_DIR/fetch.log" 2>/dev/null | tail -n 1)
    printf '%s' "${l:-no answer}"
}

# --------------------------------------------------------------------------
# the sources
# --------------------------------------------------------------------------

# write_core_sources lays the module out under DIR with its paths intact -
# cmd/pingify and internal/*, not a heap of basenames in one directory. The
# old bundle did flatten them, which was harmless while the core was a single
# package and stopped compiling the hour it became a module.
#
# The body below is generated. build.sh replaces the marker line with one
# mkdir -p covering every directory, then one quoted heredoc per source file and a base64 tarball of the vendored modules, each
# writing into "$d" - so that variable name is part of the agreement with
# build.sh and cannot be renamed here. build.sh then sources the built script,
# calls this function into a temporary tree, diffs it against the repository
# and compiles the result, so the round trip is checked rather than hoped for.
write_core_sources() {
    local d=$1
    mkdir -p "$d"
@@CORE_FILES@@
}

# go_version_needed reads the go directive out of the go.mod that is baked
# into the function above, so there is one statement of the minimum and the
# build cannot disagree with the module. The old script kept its own
# GO_MIN_MINOR=19 beside a module that said 1.24, accepted a toolchain four
# years too old, and then died inside go build with a message about toolchain
# downloads that named none of that.
#
# declare -f prints a function's heredocs verbatim, so the whole embedded
# tree is readable without touching the disk. It is fed to awk with a here
# string rather than a pipe on purpose: awk exits at the first match, and a
# printf pouring a hundred kilobytes into a pipe that just closed takes
# SIGPIPE and reports 141 under pipefail.
go_version_needed() {
    local body v=
    body=$(declare -f write_core_sources 2>/dev/null) || body=
    if [ -n "$body" ]; then
        v=$(awk '/^go [0-9]/ { print $2; exit }' <<<"$body")
    fi
    # If bash ever stops reproducing heredocs, fall back to reading the file
    # this writes. Slower, and correct for the same reason.
    if [ -z "$v" ]; then
        local tmp
        tmp=$(mktemp -d) || return 1
        write_core_sources "$tmp" >/dev/null 2>&1 &&
            v=$(awk '/^go [0-9]/ { print $2; exit }' "$tmp/go.mod")
        rm -rf "$tmp"
    fi
    [ -n "$v" ] || return 1
    printf '%s' "$v"
}

# ver_ge compares two dotted versions, missing parts counting as zero, so
# 1.24 and 1.24.0 are the same version. String comparison gets 1.9 and 1.24
# the wrong way round, which is exactly the pair that matters here.
ver_ge() {
    local i av bv
    local -a A B
    IFS=. read -r -a A <<<"$1"
    IFS=. read -r -a B <<<"$2"
    for i in 0 1 2; do
        av=${A[i]:-0}
        bv=${B[i]:-0}
        case $av in '' | *[!0-9]*) av=0 ;; esac
        case $bv in '' | *[!0-9]*) bv=0 ;; esac
        [ "$av" -gt "$bv" ] && return 0
        [ "$av" -lt "$bv" ] && return 1
    done
    return 0
}

# --------------------------------------------------------------------------
# a compiler
# --------------------------------------------------------------------------

# ensure_go finds a Go new enough for the module or offers to fetch one, and
# sets GO_BIN. It never installs anything without being asked.
ensure_go() {
    local want cand out v found= arch tar_ver tmp

    if ! want=$(go_version_needed); then
        bad "the embedded go.mod could not be read, so I cannot tell what Go this needs"
        fix "rebuild the script from the repository:  ./build.sh"
        return 1
    fi

    # /usr/local/go before PATH: if an earlier run put one there it is the one
    # known to be new enough, and a distro package earlier on PATH usually is
    # not. command -v may print nothing; the quotes keep that an empty word
    # rather than dropping the loop item.
    for cand in /usr/local/go/bin/go "$(command -v go 2>/dev/null)"; do
        [ -x "$cand" ] || continue
        out=$("$cand" version 2>/dev/null) || continue
        v=${out#go version go}
        v=${v%% *}
        case $v in '' | *[!0-9.]*) continue ;; esac
        if ver_ge "$v" "$want"; then
            GO_BIN=$cand
            return 0
        fi
        found=$v
    done

    arch=$(arch_go)
    if [ -z "$arch" ]; then
        bad "$(uname -m) is not a machine this can build for"
        fix "amd64 and arm64 are what the core is built and tested on"
        return 1
    fi

    GO_TARBALL=$(go_tarball "$arch") || return 1
    tar_ver=${GO_TARBALL#go}
    tar_ver=${tar_ver%.linux-*}

    blank
    if [ -n "$found" ]; then
        warn "the Go here is $found and the core needs $want or newer"
    else
        warn "there is no Go on this machine, and the core is built here"
    fi
    blank
    dim "This is the one step that wants the network: Go $tar_ver for $arch, about 80 MB, unpacked into /usr/local/go in place of whatever is there."
    dim "It comes from go.dev, or where go.dev is out of reach - as it is from Iran - from this project's GitHub release or a mirror, and is checked against go.dev's own sha256 before it is used."
    [ -n "${PINGIFY_GO_URL:-}" ] && dim "PINGIFY_GO_URL is set, so $PINGIFY_GO_URL is tried first."
    dim "Or skip the compiler: build the core on the other server and carry it here with  pingify core export  and  pingify core import FILE."
    blank

    if ! confirm "fetch it?" y; then
        bad "no compiler, so no core"
        fix "install Go $want or newer, then run this again"
        return 1
    fi
    if ! have curl && ! have wget; then
        bad "neither curl nor wget is installed, so nothing here can fetch it"
        fix "apt install curl"
        return 1
    fi

    tmp=$(mktemp) || return 1
    # Eighty megabytes, and /tmp is a tmpfs on a small server. Ctrl-C in the
    # middle of the fetch, or of the unpack, used to leave both behind.
    trap 'rm -f "$tmp"; rm -rf /usr/local/go.new' INT TERM
    if ! go_fetch "$GO_TARBALL" "$tmp"; then
        rm -f "$tmp"
        bad "no place this server can reach had go.dev's $GO_TARBALL"
        fix "carry the core from the other server:  pingify core export  there, then  pingify core import FILE  here"
        fix "or name a mirror that has it:  PINGIFY_GO_URL=https://<mirror>/golang bash Pingify.sh"
        return 1
    fi

    # Unpack beside whatever is there and swap only when it worked. Deleting
    # first is how a truncated download leaves a server with no compiler at
    # all - including the too-old one it had a minute ago - and the advice
    # printed after that failure needs the network that just failed.
    rm -rf /usr/local/go.new
    if ! tar -C /usr/local --one-top-level=go.new --strip-components=1 -xzf "$tmp"; then
        rm -rf /usr/local/go.new
        rm -f "$tmp"
        bad "the tarball would not unpack - it is probably a truncated download"
        fix "run this again, or unpack it by hand into /usr/local"
        return 1
    fi
    rm -f "$tmp"
    if [ ! -x /usr/local/go.new/bin/go ]; then
        rm -rf /usr/local/go.new
        bad "the tarball unpacked but there is no bin/go in it"
        return 1
    fi
    rm -rf /usr/local/go.old
    [ -d /usr/local/go ] && mv /usr/local/go /usr/local/go.old
    mv /usr/local/go.new /usr/local/go
    rm -rf /usr/local/go.old

    if [ ! -x /usr/local/go/bin/go ]; then
        bad "the tarball unpacked but there is no /usr/local/go/bin/go in it"
        return 1
    fi
    GO_BIN=/usr/local/go/bin/go
    ok "go $tar_ver is installed in /usr/local/go"
    return 0
}

# --------------------------------------------------------------------------
# building
# --------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# a core carried over
#
# The server in Iran is usually the one that cannot build: too small, or
# cut off from go.dev, or both. The other server can. So a core built there
# is exported with its hash and version beside it, carried over by whatever
# means the operator has (scp, a USB key, a pasted base64), and imported
# here - checked against the hash, asked its version, and refused unless it
# is this script's. This is the only way a binary enters a server without
# being compiled on it, and it enters through the operator's hands.
# ---------------------------------------------------------------------------

core_export() {
    require_root
    [ -x "$CORE_BIN" ] || { fail "there is no core here to export - build one first"; return 1; }
    core_matches_script || { fail "the core here is $(core_version), not this script's $PINGIFY_VERSION"; return 1; }
    local arch out
    arch=$(arch_go) || arch=unknown
    out=${CORE_EXPORT_DIR:-/root}/pingify-core-$PINGIFY_VERSION-linux-$arch
    cp -f "$CORE_BIN" "$out" || { fail "could not write $out"; return 1; }
    chmod 0755 "$out"
    sha256sum "$out" | cut -c1-64 > "$out.sha256"
    ok "exported $out"
    dim "sha256 $(cat "$out.sha256")"
    blank
    dim "carry both files to the other server, then there:"
    dim "  pingify core import $out"
    return 0
}

core_import() {
    require_root
    ensure_dirs
    local f=$1 want got arch v
    [ -f "$f" ] || { fail "$f is not there"; return 1; }
    [ -f "$f.sha256" ] || { fail "$f.sha256 is not beside it - export writes both, carry both"; return 1; }
    want=$(cut -c1-64 < "$f.sha256")
    got=$(sha256sum "$f" | cut -c1-64)
    if [ "$want" != "$got" ]; then
        fail "the hash does not match: the file changed on the way"
        dim "expected $want"
        dim "got      $got"
        return 1
    fi
    arch=$(arch_go)
    case $f in
    *-linux-$arch) ;;
    *) fail "this is a $(printf '%s' "$f" | sed 's/.*-linux-//') core and this machine is $arch"; return 1 ;;
    esac
    chmod 0755 "$f"
    v=$("$f" -version 2>/dev/null | awk '{print $2}')
    if [ "$v" != "$PINGIFY_VERSION" ]; then
        fail "that core says it is ${v:-nothing}, and this script is $PINGIFY_VERSION - they have to match"
        return 1
    fi
    # Beside, then renamed over: a running core keeps its old file until the
    # rename, and a copy that fails half way leaves the old one in place.
    if ! { cp -f "$f" "$CORE_BIN.new" && mv -f "$CORE_BIN.new" "$CORE_BIN"; }; then
        rm -f "$CORE_BIN.new"
        fail "could not install to $CORE_BIN"
        return 1
    fi
    ok "core $v installed at $CORE_BIN, hash checked"
    unit_write
    # The same tail as a core built here: every file in the current shape,
    # every tunnel restarted onto the new core. Without this the tunnels
    # would keep running the old core in memory, matching nothing on disk.
    cfg_modernise
    restart_all "the core was updated"
    return 0
}

build_core() {
    require_root
    ensure_dirs
    ensure_go || return 1

    local log out rc
    log=$STATE_DIR/build.log
    out=$SRC_DIR/pingify-core

    # Clear the tree first. A file dropped between versions would otherwise
    # sit there and be compiled alongside the new ones, and a stale
    # internal/carrier/*.go is a build error nobody can explain by reading
    # this script. The build cache under gocache/ is kept, so an unchanged
    # rebuild is a couple of seconds rather than forty.
    rm -rf "$SRC_DIR/cmd" "$SRC_DIR/internal" "$SRC_DIR/go.mod"
    if ! write_core_sources "$SRC_DIR"; then
        bad "the core sources could not be written into $SRC_DIR"
        fix "check there is space and that $SRC_DIR is writable:  df -h $SRC_DIR"
        return 1
    fi

    # GOPROXY=off and GOFLAGS=-mod=vendor because everything is already here:
    # saying so turns a confusing "cannot reach proxy.golang.org" into a build
    # that simply works. GOTOOLCHAIN=local because from 1.21 go will otherwise
    # try to download the toolchain the go directive names, over the network
    # this machine may not have - ensure_go has already checked the local one
    # is new enough, so there is nothing to gain and a hang to lose.
    go_build_now() {
        (
            cd "$SRC_DIR" &&
                GOTOOLCHAIN=local GO111MODULE=on GOPROXY=off GOSUMDB=off \
                    GOFLAGS=-mod=vendor GOPATH="$SRC_DIR/gopath" \
                    GOCACHE="$SRC_DIR/gocache" CGO_ENABLED=0 \
                    "$GO_BIN" build -trimpath -ldflags "-s -w" -o "$out" ./cmd/pingify
        ) >"$log" 2>&1
    }
    spin "compiling the core (a minute or so on a small VPS)" go_build_now
    rc=$?

    if [ "$rc" != 0 ]; then
        bad "the core did not build, go exited $rc"
        tail -n 20 "$log" | sed 's/^/       /'
        fix "the whole log is in $log"
        return 1
    fi

    # Only now. An install that overwrites the binary before the build is
    # known to have worked leaves a machine with no core and a running tunnel
    # that cannot be restarted.
    if ! install -m 0755 "$out" "$CORE_BIN"; then
        bad "the core built but would not install to $CORE_BIN"
        return 1
    fi
    # Ask the binary that just landed. `ok "core $(core_version) ..."` reads as
    # a check and is not one: the substitution runs inside an argument, so a
    # core that will not exec - wrong architecture, most likely - prints
    # "core  is installed" in green and returns success, and every later run
    # rebuilds it from scratch and says the same thing again.
    local here
    here=$(core_version)
    if [ -z "$here" ]; then
        bad "the core installed but will not run - is $(arch_go) really this machine?"
        return 1
    fi
    if [ "$here" != "$PINGIFY_VERSION" ]; then
        bad "the core says it is $here and this script is $PINGIFY_VERSION"
        fix "they are built from the same file, so this means a stale copy somewhere"
        return 1
    fi
    ok "core $here is installed at $CORE_BIN"
    return 0
}

# core_version prints what is installed, and nothing at all when there is no
# core to ask. The binary answers "pingify-core 2.0.0"; only the number is of
# use to a caller comparing it with this script's own.
core_version() {
    local out
    [ -x "$CORE_BIN" ] || return 1
    out=$("$CORE_BIN" -version 2>/dev/null) || return 1
    printf '%s' "${out#pingify-core }"
}

# ensure_core is what every path that needs a working core calls first.
#
# The version has to match this script exactly, not merely be present. The two
# halves ship together and a config key the manager writes may be one the
# older core refuses, which surfaces as the core rejecting a file the manager
# just built - a confusing failure a long way from its cause.
#
# Replacing the binary does not disturb a running tunnel: systemd keeps the
# old inode open until the unit is restarted, so nothing is felt until the
# caller restarts it, which is the caller's decision to make and to announce.
ensure_core() {
    local here
    here=$(core_version) || here=

    [ "$here" = "$PINGIFY_VERSION" ] && return 0

    if [ -n "$here" ]; then
        blank
        dim "the core here is $here and this manager is $PINGIFY_VERSION - rebuilding"
    fi
    build_core
}

# core_matches_script is the one comparison every screen makes: the two ship
# together, and a config key the manager writes may be one an older core
# refuses.
core_matches_script() {
    [ -x "$CORE_BIN" ] || return 1
    [ "$(core_version)" = "$PINGIFY_VERSION" ]
}
