#!/usr/bin/env bash
#
# Where things live, and the handful of operations everything else is built
# from: reading and writing a config, asking systemd what it thinks, and asking
# a running tunnel how it is.
#
# The layout is ordinary FHS. The old manager kept everything under /root,
# which meant a second administrator could not find it, backups that skip /root
# skipped the tunnel, and the configs sat beside the operator's ssh keys.

# Every path takes its value from the environment if there is one. Not for
# flexibility - nobody moves these - but so that a test can point the whole
# script at a temporary directory and be certain it cannot touch the machine
# it is running on. Two of the five already did, which meant a test could
# redirect the configs and then have the real core binary invoked on them.
PINGIFY_BIN=${PINGIFY_BIN:-/usr/local/bin/pingify}
CORE_BIN=${PINGIFY_CORE_BIN:-/usr/local/bin/pingify-core}
CFG_DIR=${PINGIFY_CFG_DIR:-/etc/pingify}
STATE_DIR=${PINGIFY_STATE_DIR:-/var/lib/pingify}
SRC_DIR=${PINGIFY_SRC_DIR:-/usr/local/src/pingify}
UNIT_DIR=${PINGIFY_UNIT_DIR:-/etc/systemd/system}

# The status endpoint listens on the loopback address. One port per tunnel,
# from a base, so two tunnels on one server do not collide.
STATUS_BASE=19900

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
    mkdir -p "$CFG_DIR" "$STATE_DIR" "$SRC_DIR"
    chmod 0700 "$CFG_DIR"
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
                    print k " = " v; done = 1; next
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
unit_write() {
    cat >"$UNIT_DIR/pingify@.service" <<'UNIT'
[Unit]
Description=Pingify tunnel %i
Documentation=https://github.com/GreatTeejay/Pingify
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/pingify-core -c /etc/pingify/%i.toml
Restart=always
RestartSec=2
# A limit that means something. The old unit had StartLimitIntervalSec=0, which
# turns the limit off entirely and lets a config the core refuses restart every
# two seconds for ever, filling the journal and hiding the reason.
StartLimitIntervalSec=300
StartLimitBurst=20

# A raw ICMP socket and a tun device need these two, and nothing needs more.
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
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
        stop) ok "$name stopped" ;;
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
    ST_TRANSPORT= ST_PROFILE= ST_SIDE= ST_INB=

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
