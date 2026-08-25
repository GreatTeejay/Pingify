
# ---------------------------------------------------------------------------
# the core
#
# Two ways to get it, tried in this order:
#   1. download the prebuilt binary for this CPU from GitHub Releases - the
#      normal path, a couple of seconds and no toolchain
#   2. compile the sources embedded in this script - needs Go but downloads
#      nothing, for a server that cannot reach the release files
# ---------------------------------------------------------------------------

release_base() { printf 'https://github.com/%s/releases/latest/download' "$PINGIFY_REPO"; }
core_asset()   { printf 'pingify-core-linux-%s' "$GOARCH"; }

core_version() {
    [ -x "$CORE_BIN" ] || { printf 'not installed'; return 1; }
    "$CORE_BIN" -version 2>/dev/null | awk '{print $2}' || printf 'unknown'
}

# Accept a candidate binary only once it has proved it runs on this machine.
adopt_core() {
    local tmp="$1" got=""
    chmod +x "$tmp" 2>/dev/null
    if ! "$tmp" -version >/dev/null 2>&1; then
        fail "that binary does not run on this server (wrong architecture?)"
        rm -f "$tmp"
        return 1
    fi
    got="$("$tmp" -version 2>/dev/null | awk '{print $2}')"
    if [ "$got" != "$PINGIFY_VERSION" ]; then
        warn "downloaded core is $got, but this manager is $PINGIFY_VERSION"
        dim "the release is older than this script; using the embedded source instead"
        rm -f "$tmp"
        return 1
    fi
    install -m 0755 "$tmp" "$CORE_BIN" || return 1
    rm -f "$tmp"
    ok "core $("$CORE_BIN" -version | awk '{print $2}') installed"
    return 0
}

download_core() {
    [ -n "$GOARCH" ] || { warn "no prebuilt core for $ARCH"; return 1; }
    have curl || have wget || return 1
    local base tmp="/tmp/pingify-core.dl" sums="/tmp/pingify-core.sums"
    base="$(release_base)"

    if ! spin "downloading the core for $GOARCH" \
         fetch "$base/$(core_asset)" "$tmp" 180; then
        rm -f "$tmp"
        return 1
    fi

    # The checksum file is published alongside the binaries. A missing one is
    # not fatal, a wrong one is.
    if fetch "$base/SHA256SUMS" "$sums" 30 2>/dev/null; then
        local want got
        want="$(awk -v a="$(core_asset)" '$2 == a || $2 == "*" a {print $1; exit}' "$sums")"
        got="$(sha256sum "$tmp" | awk '{print $1}')"
        rm -f "$sums"
        if [ -n "$want" ] && [ "$want" != "$got" ]; then
            fail "checksum mismatch - refusing to install this download"
            rm -f "$tmp"
            return 1
        fi
    fi

    adopt_core "$tmp"
}

build_core() {
    ensure_go || return 1
    rm -rf "$SRC_DIR"
    mkdir -p "$SRC_DIR" || return 1
    write_core_sources "$SRC_DIR" || return 1

    local log="/tmp/pingify-build.log"
    go_build_now() {
        ( cd "$SRC_DIR" && \
          GOTOOLCHAIN=local GO111MODULE=on GOFLAGS=-mod=vendor GOPROXY=off GOSUMDB=off \
          GOPATH="${GOPATH:-/tmp/pingify-gopath}" GOCACHE="${GOCACHE:-/tmp/pingify-gocache}" \
          CGO_ENABLED=0 "$GO_BIN" build -trimpath -ldflags "-s -w" \
          -o "$SRC_DIR/pingify-core" . ) >"$log" 2>&1
    }
    if ! spin "compiling the core (a minute or so on a small VPS)" go_build_now; then
        fail "the core did not compile"
        sed 's/^/      /' "$log" | tail -n 20
        return 1
    fi
    adopt_core "$SRC_DIR/pingify-core"
}

# install_core is the full ladder; ensure_core only runs it when needed.
install_core() {
    if download_core; then return 0; fi
    warn "a matching prebuilt core was unavailable - compiling the embedded core"
    build_core
}

ensure_core() {
    [ -x "$CORE_BIN" ] && return 0
    install_core
}

# The script and the core share the config format, so a core left behind by an
# older install reads a newer config as if half of it were not there. 3.4 moved
# configs into sections; a 3.3 core reads one of those and reports every field
# as empty - which surfaced as "role must be \"server\" or \"client\", got \"\""
# with nothing to point at the real cause. They are kept in step here instead.
core_matches_script() {
    [ -x "$CORE_BIN" ] || return 1
    [ "$(core_version)" = "$PINGIFY_VERSION" ]
}

ensure_core_current() {
    [ -x "$CORE_BIN" ] || return 0
    core_matches_script && return 0
    banner
    head2 "Core update"
    warn "the core is $(core_version), this script is $PINGIFY_VERSION"
    dim "they have to match - the config format is shared between them"
    say ""
    if install_core; then
        restart_all "the core was updated"
    else
        say ""
        fail "the core could not be updated"
        dim "until it matches, new tunnels will be rejected"
        dim "check this server can reach GitHub, then run pingify again"
    fi
    pause
}

# ---------------------------------------------------------------------------
# systemd
# ---------------------------------------------------------------------------

write_units() {
    cat > "$UNIT_DIR/pingify@.service" <<UNIT
[Unit]
Description=Pingify tunnel %i
Documentation=https://github.com/GreatTeejay/Pingify
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=$CORE_BIN -c $CFG_DIR/%i.$CFG_EXT
WorkingDirectory=$BASE_DIR
Restart=always
RestartSec=2
LimitNOFILE=1048576
TasksMax=infinity
NoNewPrivileges=yes
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
# ProtectHome is deliberately off: the core and its config live under /root.
ProtectHome=no
ProtectSystem=full
StandardOutput=journal
StandardError=journal
SyslogIdentifier=pingify-%i

[Install]
WantedBy=multi-user.target
UNIT

    cat > "$UNIT_DIR/pingify-health.service" <<'UNIT'
[Unit]
Description=Pingify health check
ConditionPathExists=/usr/local/bin/pingify

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pingify --health-check
SyslogIdentifier=pingify-health
UNIT

    cat > "$UNIT_DIR/pingify-health.timer" <<'UNIT'
[Unit]
Description=Pingify health check every 30s

[Timer]
OnBootSec=60s
OnUnitActiveSec=30s
AccuracySec=5s
Unit=pingify-health.service

[Install]
WantedBy=timers.target
UNIT

    cat > "$UNIT_DIR/pingify-recycle@.service" <<'UNIT'
[Unit]
Description=Pingify scheduled recycle of tunnel %i

[Service]
Type=oneshot
ExecStart=/bin/systemctl restart pingify@%i.service
SyslogIdentifier=pingify-recycle
UNIT

    systemctl daemon-reload
}

service_enable_start() {
    systemctl enable --now "pingify@$1" >/dev/null 2>&1
}
