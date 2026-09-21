#!/usr/bin/env bash
#
# Where things live, and the handful of operations everything else is built
# from: reading and writing a config, asking systemd what it thinks, and
# asking a running tunnel how it is.
#
# Everything Pingify has lives in one directory, so it is obvious what is
# installed and trivial to back up or delete:
#
#   /root/pingify/                 the tunnels, one .toml each
#   /root/pingify/core/            the core binary
#   /root/pingify/core/src/        its sources, so it can be built with no network
#   /root/pingify/state/           what the manager remembers between runs
#
# Two things stay where they are because nothing else would find them: the
# pingify command on PATH, and the systemd units.
#
# Every path takes its value from the environment if there is one - not for
# flexibility, but so that a test can point the whole script at a temporary
# directory and be certain it cannot touch the machine it is running on.

BASE_DIR=${PINGIFY_BASE_DIR:-/root/pingify}
PINGIFY_BIN=${PINGIFY_BIN:-/usr/local/bin/pingify}
SELF_BIN=$PINGIFY_BIN
CFG_DIR=${PINGIFY_CFG_DIR:-$BASE_DIR}
CORE_DIR=${PINGIFY_CORE_DIR:-$BASE_DIR/core}
CORE_BIN=${PINGIFY_CORE_BIN:-$CORE_DIR/pingify-core}
SRC_DIR=${PINGIFY_SRC_DIR:-$CORE_DIR/src}
STATE_DIR=${PINGIFY_STATE_DIR:-$BASE_DIR/state}
UNIT_DIR=${PINGIFY_UNIT_DIR:-/etc/systemd/system}
CFG_EXT=toml

# The status endpoint listens on the loopback address. One port per tunnel,
# from a base, so two tunnels on one server do not collide.
STATUS_BASE=19900

# And the health port, which the core binds on the tunnel's own private
# address so that the server at the other end can ask it questions. One
# number for every tunnel on every server, and it can be: the address it is
# bound to belongs to one tunnel. It has to be the number the core uses -
# config.DefaultHealthPort is the other half, and a test compares the two.
HEALTH_PORT=19999

# --------------------------------------------------------------------------
# the small things everything uses
# --------------------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

# list_has WANT ITEM... - membership without a pipeline. `generator | grep -q`
# is wrong here: grep exits at the first match, the generator takes SIGPIPE,
# and with pipefail the whole thing reports 141 for a question answered yes.
list_has() {
    local want=$1 item
    shift
    for item in "$@"; do [ "$item" = "$want" ] && return 0; done
    return 1
}

require_root() {
    [ "$(id -u)" = 0 ] || die "Pingify has to run as root - it installs services and changes the network. Try: sudo pingify"
}

# 0700 on the config directory because the files in it contain the token.
ensure_dirs() {
    mkdir -p "$CFG_DIR" "$CORE_DIR" "$SRC_DIR" "$STATE_DIR" || return 1
    chmod 0700 "$CFG_DIR" 2>/dev/null
    return 0
}

arch_go() {
    case "$(uname -m)" in
    x86_64 | amd64) printf 'amd64' ;;
    aarch64 | arm64) printf 'arm64' ;;
    *) printf '' ;;
    esac
}

# sed_i writes through a temporary file rather than sed -i, which takes an
# argument on BSD that it refuses on GNU.
sed_i() {
    local script=$1 file=$2 tmp
    tmp=$(mktemp)
    sed "$script" "$file" >"$tmp" && cat "$tmp" >"$file"
    rm -f "$tmp"
}

# fetch <url> <dest> [timeout] - download one file with whatever this machine
# has. The install line is written with curl, but wget is what a bare image
# is most likely to carry.
fetch() {
    local url=$1 dest=$2 t=${3:-120}
    if have curl; then
        curl -fsSL --retry 2 --max-time "$t" -o "$dest" "$url" && return 0
    fi
    if have wget; then
        wget -q --tries=2 --timeout="$t" -O "$dest" "$url" && return 0
    fi
    return 1
}

# --------------------------------------------------------------------------
# the config file
# --------------------------------------------------------------------------
#
# The core reads a small, fixed subset of TOML that this script writes: a
# table header, then key = value lines with a note after a #. Both halves of
# that agreement live in one place each - internal/config for reading, the
# wizard for writing - and these are the only functions in the manager that
# touch the text.

toml_get() {
    local file=$1 table=$2 key=$3
    [ -f "$file" ] || return 0
    awk -v t="$table" -v k="$key" '
        /^[[:space:]]*\[/ { cur = $0; gsub(/[][[:space:]]/, "", cur); next }
        cur == t {
            line = $0
            if (line ~ "^[[:space:]]*" k "[[:space:]]*=") {
                sub(/^[^=]*=[[:space:]]*/, "", line)
                # A quoted value runs to its closing quote, # and all; a
                # bare one runs to the comment, if there is one.
                if (substr(line, 1, 1) == "\"") {
                    line = substr(line, 2)
                    sub(/".*$/, "", line)
                } else {
                    sub(/#.*/, "", line)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
                }
                print line
                exit
            }
        }
    ' "$file" 2>/dev/null
}

# toml_arr <file> <table> <key> - a one-line list, as its items separated by
# spaces: ["443", "udp:500"] becomes 443 udp:500.
toml_arr() {
    toml_get "$1" "$2" "$3" | tr -d '[]"' | tr ',' ' ' | tr -s ' ' | sed 's/^ //; s/ $//'
}

# toml_set replaces a value in place, keeping the file's order and the note
# beside the value. A key that is not there yet is appended to its table, and
# a table nobody has written yet is created.
toml_set() {
    local file=$1 table=$2 key=$3 val=$4 quoted=${5:-auto}
    case $quoted in
    auto) case $val in '' | *[!0-9]*) quoted=yes ;; *) quoted=no ;; esac ;;
    esac
    [ "$val" = true ] || [ "$val" = false ] && quoted=no
    case $val in -[0-9]*) quoted=no ;; esac

    local rendered=$val
    [ "$quoted" = yes ] && rendered="\"$val\""

    # The value travels in the environment: awk -v reads backslash escapes,
    # and a value with one in it was written out changed.
    PINGIFY_TOML_V=$rendered awk -v t="$table" -v k="$key" '
        BEGIN { done = 0; seen = 0; v = ENVIRON["PINGIFY_TOML_V"] }
        /^[[:space:]]*\[/ {
            if (cur == t && !done) { print k " = " v; done = 1 }
            cur = $0; gsub(/[][[:space:]]/, "", cur)
            if (cur == t) seen = 1
            print; next
        }
        {
            if (cur == t && !done) {
                line = $0; sub(/#.*/, "", line)
                if (line ~ "^[[:space:]]*" k "[[:space:]]*=") {
                    # The note is what follows the old value, and a quoted
                    # value may hold a # of its own.
                    rest = $0; sub(/^[^=]*=[[:space:]]*/, "", rest)
                    if (substr(rest, 1, 1) == "\"") { rest = substr(rest, 2); sub(/^[^"]*"/, "", rest) }
                    note = ""
                    if (match(rest, /[[:space:]]*#.*$/)) note = substr(rest, RSTART)
                    print k " = " v note; done = 1; next
                }
                # A key left at its default is a commented line; setting it
                # takes the comment off rather than adding a second copy.
                if (line == "" && $0 ~ "^# *" k "[[:space:]]*=") {
                    note = ""
                    rest = $0; sub(/^# *[^#]*/, "", rest)
                    if (rest != "") note = " " rest
                    print k " = " v note; done = 1; next
                }
            }
            print
        }
        END {
            if (cur == t && !done) { print k " = " v; done = 1 }
            if (!seen) { print ""; print "[" t "]"; print k " = " v }
        }
    ' "$file" >"$file.tmp" && cat "$file.tmp" >"$file"
    rm -f "$file.tmp"
}

cfg_file() { printf '%s/%s.%s' "$CFG_DIR" "$1" "$CFG_EXT"; }

# cfg_list is every tunnel this server knows about, in a stable order.
cfg_list() {
    local f n
    for f in "$CFG_DIR"/*."$CFG_EXT"; do
        [ -e "$f" ] || continue
        n=${f##*/}
        printf '%s\n' "${n%.$CFG_EXT}"
    done
}

# cfg_apply is the only way a config is changed: copy, edit, ask the core
# whether it will accept the result, and put the old one back if it will not.
cfg_apply() {
    local name=$1 editor=$2 restart=${3:-yes} f out
    f=$(cfg_file "$name")
    [ -f "$f" ] || { fail "there is no tunnel called $name"; return 1; }

    cp -f "$f" "$f.bak"
    if ! "$editor" "$f"; then
        mv -f "$f.bak" "$f"
        return 1
    fi
    if ! out=$("$CORE_BIN" -c "$f" -check 2>&1); then
        mv -f "$f.bak" "$f"
        fail "the core would not accept that change, so nothing was changed:"
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
    case $p in '' | *[!0-9]* | 0) p= ;; esac
    if [ -z "$p" ]; then
        local i=0 n
        for n in $(cfg_list); do
            [ "$n" = "$name" ] && { p=$((STATUS_BASE + i)); break; }
            i=$((i + 1))
        done
    fi
    printf '%s' "${p:-$STATUS_BASE}"
}

health_port_of() {
    local p
    p=$(toml_get "$(cfg_file "$1")" status health_port)
    case $p in '' | *[!0-9]*) p=$HEALTH_PORT ;; esac
    printf '%s' "$p"
}

# port_free PORT [PROTO] - nothing is listening there. A UDP socket and a TCP
# socket on the same number are two different things.
# host_listening FAM [MAX] - the ports something on this server already
# listens on, for one family, each with the program's name where root can see
# it: "22 (sshd)", "80 (nginx)". The loopback-only ones are left out; they
# are nobody's business from outside. So are this tool's own: those are the
# tunnel and forwarded ports, and they are listed as such beside this.
host_listening() {
    local fam=${1:-tcp} max=${2:-14} flag=t
    have ss || return 0
    [ "$fam" = udp ] && flag=u
    ss -Hl${flag}np 2>/dev/null | awk -v max="$max" '
        {
            addr = $4; port = addr; sub(/.*:/, "", port)
            if (addr ~ /^127\./ || addr ~ /^\[::1\]/) next
            if (port !~ /^[0-9]+$/) next
            name = ""
            if (match($0, /users:\(\("[^"]+"/)) { name = substr($0, RSTART + 9, RLENGTH - 10) }
            if (name == "pingify-core") next
            if (!(port in seen)) { seen[port] = name; order[++n] = port }
        }
        END {
            for (i = 1; i <= n && i <= max; i++) {
                p = order[i]
                if (seen[p] != "") printf "%s (%s)\n", p, seen[p]; else print p
            }
        }'
}

# host_port_holder PORT FAM - the program on a port, or nothing.
host_port_holder() {
    host_listening "$2" 1000 | awk -v p="$1" '$1 == p { sub(/^[0-9]+ ?/, ""); gsub(/[()]/, ""); print; exit }'
}

show_host_listening() {
    local fam=$1 list
    list=$(host_listening "$fam")
    [ -n "$list" ] || return 0
    printf '%s\n' "$list" | dim_wrap "already listening here on $fam: " "  "
    return 0
}

port_free() {
    local p=$1 proto=${2:-tcp}
    have ss || return 0
    case $proto in
    # No pipeline into grep -q: under pipefail a generator that dies of
    # SIGPIPE reports the port free. See list_has.
    udp) [ -n "$(ss -Hlun "sport = :$p" 2>/dev/null)" ] && return 1 ;;
    *) [ -n "$(ss -Hltn "sport = :$p" 2>/dev/null)" ] && return 1 ;;
    esac
    return 0
}

# --------------------------------------------------------------------------
# systemd
# --------------------------------------------------------------------------

# unit_write writes the units: the template every tunnel runs under, the
# watchdog pass and its timer, and the recycle service the scheduled restart
# uses. Once, at install and on a version change - not on every tunnel.
#
# The template names the core and the config by path, and takes both from
# the constants above rather than writing them out again, so moving either
# cannot leave every tunnel pointing at a file that is not there any more.
unit_write() {
    mkdir -p "$UNIT_DIR" 2>/dev/null
    cat >"$UNIT_DIR/pingify@.service" <<UNIT || return 1
[Unit]
Description=Pingify tunnel %i
Documentation=https://github.com/GreatTeejay/Pingify
After=network-online.target
Wants=network-online.target
# A limit that means something: with it off entirely, a config the core
# refuses restarts every two seconds for ever and fills the journal.
StartLimitIntervalSec=300
StartLimitBurst=20

[Service]
Type=simple
# What a reboot took away is put back before the core starts: the kernel
# link of a GRE FOU tunnel, the AmneziaWG link, the raw TCP firewall rule.
# For every other transport this is a no-op that exits 0.
ExecStartPre=/bin/bash -c 'PINGIFY_NO_MAIN=1 . $PINGIFY_BIN && tunnel_boot %i'
ExecStart=$CORE_BIN -c $CFG_DIR/%i.$CFG_EXT
Restart=always
RestartSec=2

# A raw ICMP socket and a tun device need the first two. The third is for a
# transport that waits on a port below 1024, which behind a CDN is 80 or 443.
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
LimitNOFILE=1048576
TasksMax=infinity

[Install]
WantedBy=multi-user.target
UNIT
    cat >"$UNIT_DIR/pingify-health.service" <<UNIT || return 1
[Unit]
Description=Pingify health check
ConditionPathExists=$PINGIFY_BIN

[Service]
Type=oneshot
ExecStart=$PINGIFY_BIN --health-check
SyslogIdentifier=pingify-health
UNIT
    cat >"$UNIT_DIR/pingify-health.timer" <<'UNIT' || return 1
[Unit]
Description=Pingify health check every 30s

[Timer]
# Twenty seconds, not sixty: the pass right after a boot is the one that
# catches a tunnel whose link was built before the network was ready.
OnBootSec=20s
OnUnitActiveSec=30s
AccuracySec=5s
Unit=pingify-health.service

[Install]
WantedBy=timers.target
UNIT
    cat >"$UNIT_DIR/pingify-recycle@.service" <<'UNIT' || return 1
[Unit]
Description=Pingify scheduled recycle of tunnel %i

[Service]
Type=oneshot
ExecStart=/bin/systemctl restart pingify@%i.service
SyslogIdentifier=pingify-recycle
UNIT
    systemctl daemon-reload 2>/dev/null || true
    return 0
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

# The machine gets its pings back when the last ICMP tunnel stops.
#
# The core sets net.ipv4.icmp_echo_ignore_all while it runs, and has to: both
# ends of an ICMP tunnel send echo requests, so without it every packet is
# answered twice. What it does not do is give it back. This counts the
# remaining ICMP tunnels first: two of them, one stopped, must not unmute the
# one still running.
# Whether the kernel is muted right now. Its own function so that what the
# machine happens to be doing is not baked into the one below - a test can
# say yes here and get the same answer on any machine.
icmp_echo_muted() { [ "$(cat /proc/sys/net/ipv4/icmp_echo_ignore_all 2>/dev/null)" = 1 ]; }

icmp_echo_restore() {
    local n t
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        t=$(toml_get "$(cfg_file "$n")" transport type)
        [ "$t" = icmp ] || continue
        [ "$(svc_state "$n")" = active ] && return 0
    done < <(cfg_list)
    icmp_echo_muted || return 0
    sysctl -qw net.ipv4.icmp_echo_ignore_all=0 >/dev/null 2>&1 &&
        ok "this server answers pings again"
}

# svc_do never swallows the result: a unit that failed to start is reported
# with the last lines of its journal, not with a green "is running".
svc_do() {
    local what=$1 name=$2
    case $what in
    start | restart)
        rm -f "$STATE_DIR/$name.stopped"
        # A unit that failed often enough to spend its start limit refuses
        # to start again until the count is cleared.
        systemctl reset-failed "pingify@$name" >/dev/null 2>&1
        systemctl "$what" "pingify@$name" 2>&1 | sed 's/^/       /'
        sleep 1
        if systemctl is-active --quiet "pingify@$name"; then
            ok "$name is running"
            return 0
        fi
        fail "$name did not start"
        journalctl -u "pingify@$name" -n 15 --no-pager -o cat 2>/dev/null | sed 's/^/       /'
        return 1
        ;;
    stop | disable)
        systemctl "$what" "pingify@$name" >/dev/null 2>&1
        case $what in
        stop)
            # Written down so the watchdog leaves it stopped: a stop the
            # user asked for is not a tunnel that fell over.
            mkdir -p "$STATE_DIR" 2>/dev/null && : >"$STATE_DIR/$name.stopped"
            ok "$name stopped - the watchdog leaves it until you start it"
            icmp_echo_restore ;;
        *) ok "$name will not start at boot" ;;
        esac
        ;;
    enable)
        rm -f "$STATE_DIR/$name.stopped"
        systemctl enable --now "pingify@$name" 2>&1 | sed 's/^/       /'
        sleep 1
        if systemctl is-active --quiet "pingify@$name"; then
            ok "$name is running"
            return 0
        fi
        fail "$name did not start"
        journalctl -u "pingify@$name" -n 15 --no-pager -o cat 2>/dev/null | sed 's/^/       /'
        return 1
        ;;
    esac
}

# --------------------------------------------------------------------------
# asking a tunnel how it is
# --------------------------------------------------------------------------
#
# One function, because there is one source: the core answers on a loopback
# port with JSON. Nothing here parses English prose out of a log. Sets ST_*
# in the caller; returns non-zero when the tunnel does not answer, and then
# the ST_* are empty rather than stale.

tun_stats() {
    local name=$1 json
    ST_UP= ST_IN= ST_OUT= ST_LOST= ST_GAPS= ST_LATE= ST_UPTIME= ST_DROPPED=
    ST_TRANSPORT= ST_PROFILE= ST_SIDE= ST_INB= ST_OUTB= ST_MODE= ST_FAR_RTT= ST_FAR_SEEN=
    ST_VERSION= ST_TOWIRE= ST_TODEV= ST_NOTOURS= ST_SENDERR= ST_ACTIVE=

    have curl || return 1
    json=$(curl -s --max-time 3 "http://127.0.0.1:$(status_port "$name")/" 2>/dev/null) || return 1
    [ -n "$json" ] || return 1

    ST_VERSION=$(json_field "$json" version)
    ST_UP=$(json_field "$json" up)
    # Bytes in is the only thing on this report that says somebody is at the
    # other end: the core's up means the carrier knows where to send.
    ST_INB=$(json_field "$json" in_bytes)
    ST_OUTB=$(json_field "$json" out_bytes)
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
    ST_MODE=$(json_field "$json" mode)
    ST_FAR_RTT=$(json_field "$json" far_rtt_ms)
    ST_FAR_SEEN=$(json_field "$json" far_seen_sec)
    ST_TOWIRE=$(json_field "$json" to_wire)
    ST_TODEV=$(json_field "$json" to_device)
    ST_NOTOURS=$(json_field "$json" not_ours)
    ST_SENDERR=$(json_field "$json" send_errors)
    # With failover backups, the transport carrying now. Empty without them.
    ST_ACTIVE=$(json_field "$json" transport_active)
    return 0
}

# json_field reads one value out of the core's report, which encoding/json
# writes one field to a line.
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

# far_report is the other server's own status, fetched across the tunnel. It
# is the one thing on this machine that can see the far end.
far_report() {
    local name=$1 peer hp
    hp=$(health_port_of "$name")
    [ "$hp" -gt 0 ] 2>/dev/null || return 1
    peer=$(peer_addr "$name")
    [ -n "$peer" ] || return 1
    have curl || return 1
    curl -s --max-time 3 "http://$peer:$hp/" 2>/dev/null
}

# tunnel_is_up - one answer for every kind of tunnel: the service runs and
# the far end has been heard from.
tunnel_is_up() {
    local name=$1
    [ "$(svc_state "$name")" = active ] || return 1
    tun_stats "$name" || return 1
    [ "$ST_UP" = true ] && [ "${ST_INB:-0}" != 0 ]
}

round1() {
    case $1 in '' | *[!0-9.]*) printf '%s' "$G_DASH"; return ;; esac
    LC_ALL=C printf '%.1f' "$1" 2>/dev/null || printf '%s' "$G_DASH"
}

human_secs() {
    local s=$1
    case $s in '' | *[!0-9]*) printf '%s' "$G_DASH"; return ;; esac
    if [ "$s" -lt 60 ]; then printf '%ds' "$s"
    elif [ "$s" -lt 3600 ]; then printf '%dm' $((s / 60))
    elif [ "$s" -lt 86400 ]; then printf '%dh %dm' $((s / 3600)) $((s % 3600 / 60))
    else printf '%dd %dh' $((s / 86400)) $((s % 86400 / 3600)); fi
}

# --------------------------------------------------------------------------
# this machine
# --------------------------------------------------------------------------

detect_os() {
    OS_ID=unknown OS_VER=0 OS_PRETTY=unknown
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID=${ID:-unknown}
        OS_VER=${VERSION_ID:-0}
        OS_PRETTY=${PRETTY_NAME:-$OS_ID $OS_VER}
    fi
    ARCH=$(uname -m)
    GOARCH=$(arch_go)
}

apt_install() {
    export DEBIAN_FRONTEND=noninteractive
    # A file, not a variable: this runs under spin, in a child, and a
    # variable set there is gone when it returns. One update a day.
    local stamp=$STATE_DIR/apt.updated
    if [ -z "$(find "$stamp" -mmin -1440 2>/dev/null)" ]; then
        apt-get update -qq >/dev/null 2>&1 || warn "apt-get update reported a problem, continuing"
        mkdir -p "$STATE_DIR" 2>/dev/null && : >"$stamp"
    fi
    apt-get install -y -qq "$@" >/dev/null 2>&1
}

ensure_deps() {
    local missing=()
    have curl || missing+=(curl)
    have tar || missing+=(tar)
    have ip && have ss || missing+=(iproute2)
    have iptables || missing+=(iptables)
    have ethtool || missing+=(ethtool)
    if [ ${#missing[@]} -gt 0 ]; then
        if have apt-get; then
            spin "installing ${missing[*]}" apt_install "${missing[@]}" ||
                warn "some packages could not be installed: ${missing[*]}"
        else
            warn "please install by hand: ${missing[*]}"
        fi
    fi
    ensure_dirs
}

public_ip() {
    local ip=
    have ip && ip=$(ip -4 route get 1.1.1.1 2>/dev/null |
        awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')
    printf '%s' "$ip"
}

# srv_info fills the three lines at the top of the home screen: the address
# the outside world sees this server at, and where that address is. Cached
# for a week, because the home screen is drawn on every return and a lookup
# inside that loop is six seconds of nothing each time.
SRV_TTL_DAYS=7
srv_info() {
    [ -n "${SRV_IP:-}" ] && return 0
    local cache=$STATE_DIR/server.info j
    if [ -f "$cache" ] && [ -z "$(find "$cache" -mtime "+$SRV_TTL_DAYS" 2>/dev/null)" ]; then
        IFS='|' read -r SRV_IP SRV_LOC SRV_ORG <"$cache"
    fi
    # The country and the datacentre on the front page come from asking a
    # third party what this server looks like from outside, which tells
    # that third party this server's address. Over TLS, once a week, and
    # PINGIFY_NO_LOOKUP=1 turns it off - the address is then read from the
    # machine itself and the two lines say "not looked up".
    if [ -z "${SRV_IP:-}" ] && [ -z "${PINGIFY_NO_LOOKUP:-}" ] && have curl; then
        j=$(curl -fsS --max-time 6 'https://ip-api.com/json/?fields=query,country,isp' 2>/dev/null)
        SRV_IP=$(printf '%s' "$j" | sed -n 's/.*"query":"\([^"]*\)".*/\1/p')
        SRV_LOC=$(printf '%s' "$j" | sed -n 's/.*"country":"\([^"]*\)".*/\1/p')
        SRV_ORG=$(printf '%s' "$j" | sed -n 's/.*"isp":"\([^"]*\)".*/\1/p')
        [ -n "$SRV_IP" ] && [ -d "$STATE_DIR" ] &&
            printf '%s|%s|%s\n' "$SRV_IP" "$SRV_LOC" "$SRV_ORG" >"$cache"
    fi
    [ -n "${SRV_IP:-}" ] || SRV_IP=$(public_ip)
    [ -n "${SRV_IP:-}" ] || SRV_IP=unknown
    if [ -n "${PINGIFY_NO_LOOKUP:-}" ]; then
        [ -n "${SRV_LOC:-}" ] || SRV_LOC="not looked up"
        [ -n "${SRV_ORG:-}" ] || SRV_ORG="not looked up"
    fi
    [ -n "${SRV_LOC:-}" ] || SRV_LOC=unknown
    [ -n "${SRV_ORG:-}" ] || SRV_ORG=unknown
    return 0
}

# migrate_layout moves a server from the layout before this one, once.
migrate_layout() {
    local moved=0 f n
    for f in /etc/pingify/*.toml /root/Pingify/*.toml; do
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
    for f in /var/lib/pingify/*; do
        [ -e "$f" ] || continue
        n=${f##*/}
        if [ -e "$STATE_DIR/$n" ]; then rm -f "$f"; else mv -f "$f" "$STATE_DIR/$n" && moved=1; fi
    done
    rmdir /var/lib/pingify 2>/dev/null
    rm -rf /usr/local/src/pingify
    [ "$moved" = 1 ] || return 0
    chmod 0700 "$CFG_DIR"
    unit_write
    while IFS= read -r n; do
        systemctl is-enabled --quiet "pingify@$n" 2>/dev/null && svc_do restart "$n"
    done < <(cfg_list)
    info "moved the existing setup into $BASE_DIR"
}
