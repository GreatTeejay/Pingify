#!/usr/bin/env bash
#
# Where things live, and the handful of operations everything else is built
# from: reading and writing a config, asking systemd what it thinks, and asking
# a running tunnel how it is.
#
# Everything Pingify has lives in one directory: the tunnels, the core, and
# the little state the manager keeps. It was spread over /etc, /var/lib and
# /usr/local/src, which is the ordinary place for each of those things and
# means four directories to look in when something is wrong, four to copy when
# a server is rebuilt, and four to be sure of when one is taken apart.
#
#   /root/pingify/                 the tunnels, one .toml each
#   /root/pingify/core/            the core binary
#   /root/pingify/core/src/        its sources, so it can be built with no network
#   /root/pingify/state/           what the manager remembers between runs
#
# Two things stay where they are because nothing else would find them: the
# pingify command on PATH, and the systemd units.

# Every path takes its value from the environment if there is one. Not for
# flexibility - nobody moves these - but so that a test can point the whole
# script at a temporary directory and be certain it cannot touch the machine
# it is running on. Two of the five already did, which meant a test could
# redirect the configs and then have the real core binary invoked on them.
BASE_DIR=${PINGIFY_BASE_DIR:-/root/pingify}
PINGIFY_BIN=${PINGIFY_BIN:-/usr/local/bin/pingify}
CFG_DIR=${PINGIFY_CFG_DIR:-$BASE_DIR}
CORE_DIR=${PINGIFY_CORE_DIR:-$BASE_DIR/core}
CORE_BIN=${PINGIFY_CORE_BIN:-$CORE_DIR/pingify-core}
SRC_DIR=${PINGIFY_SRC_DIR:-$CORE_DIR/src}
STATE_DIR=${PINGIFY_STATE_DIR:-$BASE_DIR/state}
UNIT_DIR=${PINGIFY_UNIT_DIR:-/etc/systemd/system}

# The status endpoint listens on the loopback address. One port per tunnel,
# from a base, so two tunnels on one server do not collide.
STATUS_BASE=19900

# And the health port, which the core binds on the tunnel's own private
# address so that the server at the other end can ask it questions.
#
# One number for every tunnel on every server, and it can be: the address it
# is bound to belongs to one tunnel, so two of them hold the same port without
# ever meeting. It has to be the same number the core uses - config's
# DefaultHealthPort is the other half of it, and a test compares the two.
HEALTH_PORT=19999

health_port_of() {
    local p
    p=$(toml_get "$(cfg_file "$1")" status health_port)
    case $p in '' | *[!0-9]*) p=$HEALTH_PORT ;; esac
    printf '%s' "$p"
}

# far_report is the other server's own status, fetched across the tunnel.
#
# Nothing else in this script can see the far end. The carrier being up says
# the two carriers have found each other over the wire; it does not say that a
# packet put into the tun device here comes out of the one over there, and it
# says nothing at all about what version or profile the other server is on -
# which is the commonest reason a pair that was working stops working.
far_report() {
    local name=$1 peer hp
    hp=$(health_port_of "$name")
    [ "$hp" -gt 0 ] 2>/dev/null || return 1
    peer=$(peer_addr "$name")
    [ -n "$peer" ] || return 1
    have curl || return 1
    curl -s --max-time 3 "http://$peer:$hp/" 2>/dev/null
}

# --------------------------------------------------------------------------
# the small things everything uses
# --------------------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

# list_has is membership without a pipeline.
#
# The obvious form - `generator | grep -q x` - is wrong here and the reason is
# worth keeping: grep exits at the first match, the generator writing into the
# closed pipe takes SIGPIPE, and with pipefail the whole thing reports 141.
# A loop cannot do that.
list_has() {
    local want=$1 item
    shift
    for item in "$@"; do [ "$item" = "$want" ] && return 0; done
    return 1
}

require_root() {
    [ "$(id -u)" = 0 ] || die "run this as root - it installs services and changes the network"
}

# ensure_dirs is called before anything writes. 0700 on the config directory
# because the files in it contain the security token.
ensure_dirs() {
    mkdir -p "$CFG_DIR" "$CORE_DIR" "$SRC_DIR" "$STATE_DIR"
    chmod 0700 "$CFG_DIR"
}

# migrate_layout moves a server from the layout before this one.
#
# It runs on the interactive path only, and it does nothing at all after the
# first time, because what it looks for is not there any more. It is not on
# the --status path on purpose: that one is called from cron, and a monitoring
# call is no place to be restarting tunnels.
#
# The order matters. The units name the core by its path, so they are written
# again after the binary has moved, and every tunnel that was running is
# restarted onto the new one - otherwise the running core is a deleted file
# and the next restart finds nothing where the unit says it is.
migrate_layout() {
    local moved=0 f n
    # A tunnel of the same name in both places is the one thing here that
    # cannot be decided without asking. The new one wins - it is the one the
    # units point at - and the old one is left where it is and named, so
    # whoever has to look at it can.
    for f in /etc/pingify/*.toml; do
        [ -e "$f" ] || continue
        n=${f##*/}
        if [ -e "$CFG_DIR/$n" ]; then
            warn "$f was left behind - $CFG_DIR/$n already exists"
        else
            mv -f "$f" "$CFG_DIR/$n" && moved=1
        fi
    done
    rmdir /etc/pingify 2>/dev/null

    if [ -x /usr/local/bin/pingify-core ] && [ ! -x "$CORE_BIN" ]; then
        mkdir -p "$CORE_DIR"
        mv -f /usr/local/bin/pingify-core "$CORE_BIN" && moved=1
    fi
    rm -f /usr/local/bin/pingify-core

    # State is ours and the newer copy is the true one, so a name that exists
    # in both places is not a conflict: the old file goes.
    for f in /var/lib/pingify/*; do
        [ -e "$f" ] || continue
        n=${f##*/}
        if [ -e "$STATE_DIR/$n" ]; then
            rm -f "$f"
        else
            mv -f "$f" "$STATE_DIR/$n" && moved=1
        fi
    done
    rmdir /var/lib/pingify 2>/dev/null
    rm -rf /usr/local/src/pingify

    [ "$moved" = 1 ] || return 0

    chmod 0700 "$CFG_DIR"
    unit_write
    while IFS= read -r n; do
        systemctl is-enabled --quiet "pingify@$n" 2>/dev/null && svc_do restart "$n"
    done < <(cfg_list)
    ok "moved into $BASE_DIR"
}

arch_go() {
    case "$(uname -m)" in
    x86_64 | amd64) printf 'amd64' ;;
    aarch64 | arm64) printf 'arm64' ;;
    *) printf '' ;;
    esac
}

# sed_i writes through a temporary file rather than using sed -i, which is a
# GNU extension and takes an argument on BSD that it refuses on GNU.
sed_i() {
    local script=$1 file=$2 tmp
    tmp=$(mktemp)
    sed "$script" "$file" >"$tmp" && cat "$tmp" >"$file"
    rm -f "$tmp"
}

# --------------------------------------------------------------------------
# the config file
# --------------------------------------------------------------------------
#
# The core reads a small, fixed subset of TOML that this script writes: a table
# header, then bare key = value lines. Both halves of that agreement live in
# one place each - core/internal/config for reading, here for writing - and
# these three functions are the only things in the manager that touch the text.
# The old script had five hand-rolled parsers of the same file and they had
# already drifted apart.

toml_get() {
    local file=$1 table=$2 key=$3
    awk -v t="$table" -v k="$key" '
        /^[[:space:]]*\[/ { cur = $0; gsub(/[][[:space:]]/, "", cur); next }
        cur == t {
            line = $0
            sub(/#.*/, "", line)
            if (line ~ "^[[:space:]]*" k "[[:space:]]*=") {
                sub(/^[^=]*=[[:space:]]*/, "", line)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
                gsub(/^"|"$/, "", line)
                print line
                exit
            }
        }
    ' "$file" 2>/dev/null
}

# toml_set replaces a value in place, keeping the file's order and comments. A
# key that is not there yet is appended to its table.
toml_set() {
    local file=$1 table=$2 key=$3 val=$4 quoted=${5:-auto}
    case $quoted in
    auto) case $val in '' | *[!0-9]*) quoted=yes ;; *) quoted=no ;; esac ;;
    esac
    [ "$val" = true ] || [ "$val" = false ] && quoted=no

    local rendered=$val
    [ "$quoted" = yes ] && rendered="\"$val\""

    awk -v t="$table" -v k="$key" -v v="$rendered" '
        BEGIN { done = 0; seen = 0 }
        /^[[:space:]]*\[/ {
            # Leaving the table we wanted without having written the key means
            # it belongs at the end of that table, not at the end of the file.
            if (cur == t && !done) { print k " = " v; done = 1 }
            cur = $0; gsub(/[][[:space:]]/, "", cur)
            if (cur == t) seen = 1
            print; next
        }
        {
            if (cur == t && !done) {
                line = $0; sub(/#.*/, "", line)
                if (line ~ "^[[:space:]]*" k "[[:space:]]*=") {
                    # The note beside the value stays. The file is written
                    # with one on every line, and a value changed from the
                    # manager should not lose the sentence that explains it.
                    note = ""
                    if (match($0, /[[:space:]]*#.*$/)) note = substr($0, RSTART)
                    print k " = " v note; done = 1; next
                }
            }
            print
        }
        END {
            if (cur == t && !done) { print k " = " v; done = 1 }
            # A table nobody has written yet. The old manager silently did
            # nothing here, so status.port was set, read back empty, and the
            # feature simply did not work.
            if (!seen) { print ""; print "[" t "]"; print k " = " v }
        }
    ' "$file" >"$file.tmp" && cat "$file.tmp" >"$file"
    rm -f "$file.tmp"
}

cfg_file() { printf '%s/%s.toml' "$CFG_DIR" "$1"; }

# cfg_list is every tunnel this server knows about, in a stable order.
cfg_list() {
    local f n
    for f in "$CFG_DIR"/*.toml; do
        [ -e "$f" ] || continue
        n=${f##*/}
        printf '%s\n' "${n%.toml}"
    done
}

cfg_count() { cfg_list | grep -c . || true; }

# cfg_apply is the only way a config is changed.
#
# Copy, edit, ask the core whether it will accept the result, and put the old
# one back if it will not. The old manager wrote this out five times with five
# different messages, and one of the five forgot to restore.
cfg_apply() {
    local name=$1 editor=$2 restart=${3:-yes} f
    f=$(cfg_file "$name")
    [ -f "$f" ] || { bad "there is no tunnel called $name"; return 1; }

    cp -f "$f" "$f.bak"
    if ! "$editor" "$f"; then
        mv -f "$f.bak" "$f"
        return 1
    fi

    local out
    if ! out=$("$CORE_BIN" -c "$f" -check 2>&1); then
        mv -f "$f.bak" "$f"
        bad "the core would not accept that change, so nothing was changed:"
        printf '%s\n' "$out" | sed 's/^/       /'
        return 1
    fi
    rm -f "$f.bak"
    [ "$restart" = yes ] && svc_do restart "$name"
    return 0
}

# status_port is derived, not stored: the config carries it, and a tunnel
# created before this existed gets one the first time it is asked.
status_port() {
    local name=$1 p
    p=$(toml_get "$(cfg_file "$name")" status port)
    case $p in '' | *[!0-9]* | 0) p='' ;; esac
    if [ -z "$p" ]; then
        local i=0 n
        for n in $(cfg_list); do
            [ "$n" = "$name" ] && { p=$((STATUS_BASE + i)); break; }
            i=$((i + 1))
        done
    fi
    printf '%s' "${p:-$STATUS_BASE}"
}

# --------------------------------------------------------------------------
# systemd
# --------------------------------------------------------------------------

# unit_write writes the template unit. Once, at install and on a version
# change - not on every tunnel creation, which is a global side effect from a
# per-tunnel action and how the old script came to rewrite four units whenever
# anybody added one.
# The unit names the core and the config by path, and it takes both from the
# constants at the top of this file rather than writing them out again.
#
# It used to write them out again, inside a quoted heredoc, so the two paths in
# the unit were the two paths this script used *when the unit was written* -
# and moving either of them left every tunnel on the machine pointing at a
# file that was not there any more. systemd's answer to that is 203/EXEC, and
# nothing else on the screen says what happened.
unit_write() {
    cat >"$UNIT_DIR/pingify@.service" <<UNIT
[Unit]
Description=Pingify tunnel %i
Documentation=https://github.com/GreatTeejay/Pingify
After=network-online.target
Wants=network-online.target
# In [Unit], which is where systemd reads them. They were in [Service], and
# systemd said so on every start - "Unknown key name 'StartLimitIntervalSec'"
# - and then applied its own default instead of the limit written here.
#
# A limit that means something: the old unit had StartLimitIntervalSec=0, which
# turns the limit off entirely and lets a config the core refuses restart every
# two seconds for ever, filling the journal and hiding the reason.
StartLimitIntervalSec=300
StartLimitBurst=20

[Service]
Type=simple
ExecStart=$CORE_BIN -c $CFG_DIR/%i.toml
Restart=always
RestartSec=2

# A raw ICMP socket and a tun device need the first two. The third is for a
# transport that waits on a port below 1024, which is not a luxury: behind a
# CDN the edge comes to the origin on the port the client asked for, and a
# WebSocket carrier fronted by one is listening on 80 or 443 or it is not
# listening at all. Found by a tunnel that died with "bind: permission denied"
# while the far end read back Cloudflare's 521.
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
NoNewPrivileges=yes

# The tunnel is a long-lived process that holds a lot of sockets open.
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload 2>/dev/null || true
}

svc_state() {
    local name=$1
    if ! systemctl is-active --quiet "pingify@$name" 2>/dev/null; then
        systemctl is-enabled --quiet "pingify@$name" 2>/dev/null &&
            printf 'stopped' || printf 'disabled'
        return
    fi
    printf 'active'
}

# svc_do never swallows the result. The old service_enable_start returned the
# exit status of a `systemctl daemon-reload` that always succeeds, so the caller
# printed a green "is running" over a unit that had failed to start.
# The machine gets its pings back when the last ICMP tunnel stops.
#
# The core sets net.ipv4.icmp_echo_ignore_all while it runs, and it has to:
# both ends of an ICMP tunnel send echo requests, so without it every packet
# is answered twice - once by the far tunnel and once by the far kernel, which
# has no idea it is in the middle of anything - and the traffic on the path
# doubles. It is the same setting flagtun asks you to put in a sysctl.d file
# by hand, set at start instead, so a reboot needs nothing.
#
# What it did not do was give it back. A server whose ICMP tunnel had been
# stopped went on answering no pings at all, which looks exactly like a dead
# server, and every other tunnel on it lost its round trip measurement as
# well. This is the other half, and it counts the remaining ICMP tunnels
# first: two of them, one stopped, must not unmute the one still running.
icmp_echo_restore() {
    local n t
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        t=$(toml_get "$(cfg_file "$n")" transport type)
        [ "$t" = icmp ] || continue
        [ "$(svc_state "$n")" = active ] && return 0
    done < <(cfg_list)
    [ "$(cat /proc/sys/net/ipv4/icmp_echo_ignore_all 2>/dev/null)" = 1 ] || return 0
    sysctl -qw net.ipv4.icmp_echo_ignore_all=0 >/dev/null 2>&1 &&
        ok "this server answers pings again"
}

svc_do() {
    local what=$1 name=$2
    case $what in
    start | restart)
        systemctl "$what" "pingify@$name" 2>&1 | sed 's/^/       /'
        sleep 1
        if systemctl is-active --quiet "pingify@$name"; then
            ok "$name is running"
            return 0
        fi
        bad "$name did not start"
        journalctl -u "pingify@$name" -n 15 --no-pager -o cat 2>/dev/null |
            sed 's/^/       /'
        return 1
        ;;
    stop | disable)
        systemctl "$what" "pingify@$name" >/dev/null 2>&1
        # Two verbs, two sentences. One line built the past tense by adding
        # "ped" to whichever word came in, which is right for stop and made
        # "disableped" out of disable - on the uninstall screen, where every
        # other line is plain English.
        case $what in
        stop) ok "$name stopped"; icmp_echo_restore ;;
        *) ok "$name will not start at boot" ;;
        esac
        ;;
    enable)
        systemctl enable --now "pingify@$name" 2>&1 | sed 's/^/       /'
        sleep 1
        if systemctl is-active --quiet "pingify@$name"; then
            ok "$name is running"
            return 0
        fi
        bad "$name did not start"
        journalctl -u "pingify@$name" -n 15 --no-pager -o cat 2>/dev/null |
            sed 's/^/       /'
        return 1
        ;;
    esac
}

# --------------------------------------------------------------------------
# asking a tunnel how it is
# --------------------------------------------------------------------------
#
# One function, because there is one source. The core answers on a loopback
# port with JSON, so nothing here parses English prose out of a log - which is
# what the old manager did, with an awk that took the eighth field of a
# sentence and broke the day the sentence was reworded.
#
# Sets ST_* in the caller. Returns non-zero when the tunnel does not answer,
# and in that case the ST_* are empty rather than stale.

tun_stats() {
    local name=$1 json
    ST_UP= ST_IN= ST_OUT= ST_LOST= ST_GAPS= ST_LATE= ST_UPTIME= ST_DROPPED=
    ST_TRANSPORT= ST_PROFILE= ST_SIDE= ST_INB= ST_MODE= ST_FAR_RTT= ST_FAR_SEEN=

    json=$(curl -s --max-time 3 "http://127.0.0.1:$(status_port "$name")/" 2>/dev/null) || return 1
    [ -n "$json" ] || return 1

    ST_UP=$(json_field "$json" up)
    # Bytes in, and it is not a statistic: it is the only thing on this report
    # that says somebody is at the other end. The core's `up` means the
    # carrier knows where to send, and on the side that dials that is true the
    # moment it starts, answer or no answer - so a tunnel pointed at a dead
    # address reported itself up, with a green dot, for ever.
    ST_INB=$(json_field "$json" in_bytes)
    ST_IN=$(json_field "$json" in_mbit)
    ST_OUT=$(json_field "$json" out_mbit)
    ST_LOST=$(json_field "$json" path_lost)
    ST_LATE=$(json_field "$json" path_reordered)
    ST_GAPS=$(json_field "$json" path_gaps)
    ST_UPTIME=$(json_field "$json" uptime_sec)
    ST_DROPPED=$(json_field "$json" dropped)
    ST_TRANSPORT=$(json_field "$json" transport)
    ST_PROFILE=$(json_field "$json" profile)
    ST_SIDE=$(json_field "$json" side)
    # A forward tunnel measures its own far end; a private link is measured
    # from outside. These are empty on a link.
    ST_MODE=$(json_field "$json" mode)
    ST_FAR_RTT=$(json_field "$json" far_rtt_ms)
    ST_FAR_SEEN=$(json_field "$json" far_seen_sec)
    return 0
}

# json_field reads one value out of the core's report. The report is generated
# by encoding/json with indentation, one field per line, so this is enough and
# a JSON parser would be a dependency bought for nothing.
json_field() {
    printf '%s' "$1" | awk -v k="\"$2\":" '
        index($0, k) {
            sub(/^[^:]*:[[:space:]]*/, "")
            sub(/,$/, "")
            gsub(/^"|"$/, "")
            print
            exit
        }'
}

# round1 is for rates: 412.336 Mbit/s is not more informative than 412.3.
round1() {
    case $1 in
    '' | *[!0-9.]*) printf '%s' "$G_DASH"; return ;;
    esac
    printf '%.1f' "$1" 2>/dev/null || printf '%s' "$G_DASH"
}

# human_secs is an uptime a person reads rather than counts.
human_secs() {
    local s=$1
    case $s in '' | *[!0-9]*) printf '%s' "$G_DASH"; return ;; esac
    if [ "$s" -lt 60 ]; then printf '%ds' "$s"
    elif [ "$s" -lt 3600 ]; then printf '%dm' $((s / 60))
    elif [ "$s" -lt 86400 ]; then printf '%dh %dm' $((s / 3600)) $((s % 3600 / 60))
    else printf '%dd %dh' $((s / 86400)) $((s % 86400 / 3600)); fi
}
