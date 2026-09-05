#!/usr/bin/env bash
#
# Health: the watchdog that keeps a tunnel up, the check that says what is
# wrong and what to do about it, the live view, and the two measurements
# worth taking when nothing is wrong.
#
# Every failure carries a fix. A report that lists problems and stops leaves
# you exactly where you started. Grey is a verdict: red means "this is
# broken", never "this could not be measured" - an ICMP tunnel switches off
# echo replies on both servers while it runs, so a ping across it is answered
# by nobody, which is the design working and not the link failing.

# ---------------------------------------------------------------------------
# the watchdog
#
# The core already reconnects on its own and systemd restarts a process that
# dies. This is the outer layer: a process that is alive and carrying nothing
# - the far end gone quiet, a path that took the connection and then dropped
# it - is restarted after three strikes, ninety seconds, and the pass is
# logged so the health log says what happened and when.
# ---------------------------------------------------------------------------

HEALTH_STRIKES=3

run_health_check() {
    mkdir -p "$STATE_DIR" 2>/dev/null
    local n f fails mode seen strike
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        systemctl is-enabled --quiet "pingify@$n" 2>/dev/null || continue
        f=$(cfg_file "$n")

        if ! systemctl is-active --quiet "pingify@$n"; then
            echo "pingify: $n is not running, starting it"
            systemctl restart "pingify@$n"
            echo 0 >"$STATE_DIR/$n.fail"
            continue
        fi

        strike=0
        mode=$(toml_get "$f" tunnel mode)
        [ -n "$mode" ] || mode=tun
        if ! tun_stats "$n"; then
            strike=1
        elif [ "${ST_UPTIME:-0}" -lt 60 ]; then
            # Too young to judge: the far end has a minute to show up.
            strike=0
        elif [ "$mode" = forward ]; then
            [ "$ST_UP" = true ] || strike=1
            seen=${ST_FAR_SEEN%%.*}
            case $seen in '' | *[!0-9]*) ;; *) [ "$seen" -gt 45 ] && strike=1 ;; esac
        else
            # The far end, asked across the link. Its answering proves a packet
            # crossed both ways, which no counter on this machine can.
            far_report "$n" >/dev/null 2>&1 || strike=1
        fi

        if [ "$strike" = 0 ]; then
            echo 0 >"$STATE_DIR/$n.fail"
            continue
        fi
        fails=$(cat "$STATE_DIR/$n.fail" 2>/dev/null || echo 0)
        case $fails in '' | *[!0-9]*) fails=0 ;; esac
        fails=$((fails + 1))
        echo "$fails" >"$STATE_DIR/$n.fail"
        echo "pingify: $n cannot reach the other server (strike $fails of $HEALTH_STRIKES)"
        if [ "$fails" -ge "$HEALTH_STRIKES" ]; then
            echo "pingify: restarting $n"
            systemctl restart "pingify@$n"
            echo 0 >"$STATE_DIR/$n.fail"
        fi
    done < <(cfg_list)
}

enable_watchdog() {
    [ -f "$UNIT_DIR/pingify-health.timer" ] || unit_write
    systemctl enable --now pingify-health.timer >/dev/null 2>&1
    [ "${1:-}" = quiet ] || ok "watchdog enabled (checks every 30s)"
}

disable_watchdog() {
    systemctl disable --now pingify-health.timer >/dev/null 2>&1
    ok "watchdog disabled"
}

watchdog_state() {
    if systemctl is-enabled --quiet pingify-health.timer 2>/dev/null; then printf 'on'
    else printf 'off'; fi
}

# ---------------------------------------------------------------------------
# collecting a verdict
#
# health_check buffers its result rather than printing as it goes, so the
# screen and --json are one pass rendered twice.
# ---------------------------------------------------------------------------

CHK_STATE=() CHK_ID=() CHK_TEXT=() CHK_FIX=()
CHK_NBAD=0 CHK_NWARN=0
HC_BAD=0 HC_WARN=0

chk_reset() {
    CHK_STATE=() CHK_ID=() CHK_TEXT=() CHK_FIX=()
    CHK_NBAD=0 CHK_NWARN=0
}

# chk_add STATE ID TEXT [FIX...] - STATE is ok, warn, bad or note. A note is
# grey: something worth saying that is not a fault, and never counted.
chk_add() {
    local state=$1 id=$2 text=$3 joined= one
    shift 3
    for one in "$@"; do joined=$joined$one$'\n'; done
    CHK_STATE+=("$state")
    CHK_ID+=("$id")
    CHK_TEXT+=("$text")
    CHK_FIX+=("$joined")
    case $state in
    bad) CHK_NBAD=$((CHK_NBAD + 1)) ;;
    warn) CHK_NWARN=$((CHK_NWARN + 1)) ;;
    esac
}

hc_ok() { chk_add ok "${2:-x}" "$1"; }
hc_bad() { chk_add bad "${2:-x}" "$1"; }
hc_warn() { chk_add warn "${2:-x}" "$1"; }

count_word() {
    case $1 in 1) printf 'one' ;; 2) printf 'two' ;; 3) printf 'three' ;; *) printf '%s' "$1" ;; esac
}
plural_s() { [ "$1" = 1 ] || printf 's'; }

chk_tally() {
    local out=
    [ "$CHK_NBAD" = 0 ] && [ "$CHK_NWARN" = 0 ] && { printf 'nothing wrong on this server'; return; }
    [ "$CHK_NBAD" -gt 0 ] && out="$(count_word "$CHK_NBAD") problem$(plural_s "$CHK_NBAD")"
    if [ "$CHK_NWARN" -gt 0 ]; then
        [ -n "$out" ] && out="$out, "
        out="$out$(count_word "$CHK_NWARN") warning$(plural_s "$CHK_NWARN")"
    fi
    printf '%s' "$out"
}

chk_render() {
    local name=$1 i line
    head2 "Health check: $name"
    for ((i = 0; i < ${#CHK_ID[@]}; i++)); do
        case ${CHK_STATE[i]} in
        ok) ok "${CHK_TEXT[i]}" ;;
        warn) warn "${CHK_TEXT[i]}" ;;
        bad) fail "${CHK_TEXT[i]}" ;;
        *) dim "  ${CHK_TEXT[i]}" ;;
        esac
        if [ -n "${CHK_FIX[i]}" ]; then
            while IFS= read -r line; do
                [ -n "$line" ] && fix "$line"
            done <<<"${CHK_FIX[i]}"
        fi
    done
    blank
    rule
    if [ "$CHK_NBAD" = 0 ] && [ "$CHK_NWARN" = 0 ]; then
        ok "nothing wrong on this server"
        dim "if the tunnel still misbehaves, run this on the other one too"
    elif [ "$CHK_NBAD" = 0 ]; then
        warn "$(chk_tally) worth looking at"
    else
        fail "$(chk_tally)"
        dim "each one has a fix under it"
    fi
    blank
}

json_esc() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\t'/ }
    printf '%s' "$s"
}

chk_json() {
    local name=$1 i last first line
    last=$((${#CHK_ID[@]} - 1))
    printf '{\n'
    printf '  "tunnel": "%s",\n' "$(json_esc "$name")"
    printf '  "problems": %s,\n' "$CHK_NBAD"
    printf '  "warnings": %s,\n' "$CHK_NWARN"
    printf '  "checks": [\n'
    for ((i = 0; i <= last; i++)); do
        printf '    {"id": "%s", "state": "%s", "text": "%s", "fixes": [' \
            "$(json_esc "${CHK_ID[i]}")" "${CHK_STATE[i]}" "$(json_esc "${CHK_TEXT[i]}")"
        first=1
        if [ -n "${CHK_FIX[i]}" ]; then
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                [ "$first" = 1 ] || printf ', '
                printf '"%s"' "$(json_esc "$line")"
                first=0
            done <<<"${CHK_FIX[i]}"
        fi
        printf ']}'
        [ "$i" -lt "$last" ] && printf ','
        printf '\n'
    done
    printf '  ]\n}\n'
}

# ---------------------------------------------------------------------------
# reading a tunnel's own idea of itself, once, into CK_*
# ---------------------------------------------------------------------------

chk_load() {
    local name=$1
    CK_FILE=$(cfg_file "$name")
    [ -f "$CK_FILE" ] || return 1
    CK_SIDE=$(toml_get "$CK_FILE" tunnel side)
    CK_TRANSPORT=$(toml_get "$CK_FILE" transport type)
    CK_MODE=$(toml_get "$CK_FILE" tunnel mode)
    [ -n "$CK_MODE" ] || CK_MODE=tun
    CK_PORT=$(toml_get "$CK_FILE" transport port)
    CK_KHAREJ=$(toml_get "$CK_FILE" transport kharej)
    CK_IRAN=$(toml_get "$CK_FILE" transport iran)
    CK_DEV=$(toml_get "$CK_FILE" tun name)
    CK_MTU=$(toml_get "$CK_FILE" tun mtu)
    [ -n "$CK_TRANSPORT" ] || CK_TRANSPORT=udp
    [ -n "$CK_DEV" ] || CK_DEV=pfy0
    [ -n "$CK_MTU" ] || CK_MTU=1320
    if [ "$CK_SIDE" = iran ]; then
        CK_MINE=$(toml_get "$CK_FILE" tun iran)
        CK_THEIRS=$(toml_get "$CK_FILE" tun kharej)
    else
        CK_MINE=$(toml_get "$CK_FILE" tun kharej)
        CK_THEIRS=$(toml_get "$CK_FILE" tun iran)
    fi
    CK_PEER=${CK_THEIRS%%/*}
    CK_DIALS=$(toml_get "$CK_FILE" transport dials)
    [ -n "$CK_DIALS" ] || CK_DIALS=kharej
    if [ "$CK_DIALS" = iran ]; then CK_WAITS=KHAREJ CK_WAIT_ADDR=$CK_KHAREJ
    else CK_WAITS=IRAN CK_WAIT_ADDR=$CK_IRAN; fi
    if [ "$CK_SIDE" = iran ]; then CK_FAR=KHAREJ; else CK_FAR=IRAN; fi
    return 0
}

# link_rtt pings the other end of the private link, bound to the tun device,
# and prints the round trip in milliseconds. Nothing on an ICMP tunnel.
link_rtt() {
    local dev=$1 peer=$2 out
    out=$(ping -n -c1 -W1 -I "$dev" "$peer" 2>/dev/null) || return 1
    case $out in
    *time=*) out=${out#*time=}; printf '%s' "${out%% *}" ;;
    *) return 1 ;;
    esac
}

tcp_reach() {
    local host=$1 port=$2
    if timeout 2 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then return 0; fi
    have nc && nc -z -w2 "$host" "$port" >/dev/null 2>&1
}
tcp_probe() { tcp_reach "$1" "$2"; }

# ---------------------------------------------------------------------------
# health_check NAME [--json] - one pass, in the order things fail. Exit 0
# clean, 1 warnings, 2 problems, so `pingify --check NAME` works from cron.
# ---------------------------------------------------------------------------

health_check() {
    local name=$1 mode=${2:-}
    local core_ver out st since addr fl live_mtu lpm heard cc
    local spec proto lo hi rhost rport total missing unknown

    chk_reset
    if ! chk_load "$name"; then
        chk_add bad config "there is no tunnel called $name" "run pingify with no arguments to see the list"
        chk_finish "$name" "$mode"
        return 2
    fi

    # 1. the core itself
    if [ ! -x "$CORE_BIN" ]; then
        chk_add bad core "the core is not installed at $CORE_BIN" "main menu ${BX_ARR} Update Pingify"
        chk_add note core-rest "nothing below could be checked without it"
        chk_finish "$name" "$mode"
        return 2
    fi
    if core_ver=$(core_version); then
        if [ "$core_ver" = "$PINGIFY_VERSION" ]; then
            chk_add ok core "core and script are both $PINGIFY_VERSION"
        else
            chk_add warn core "core $core_ver against script $PINGIFY_VERSION" \
                "they read the same config file, so a mismatch rejects tunnels" \
                "main menu ${BX_ARR} Update Pingify"
        fi
    else
        chk_add bad core "$CORE_BIN will not run" "it may be built for another architecture" "main menu ${BX_ARR} Update Pingify"
    fi

    # 2. the config, judged by the only judge that counts
    if out=$("$CORE_BIN" -c "$CK_FILE" -check 2>&1); then
        chk_add ok config "the config is valid"
    else
        chk_add bad config "the core rejects it: $(trunc_to "${out%%$'\n'*}" $((UI_W - 26)))" \
            "Manage ${BX_ARR} $name ${BX_ARR} Tuning, or edit $CK_FILE" \
            "the same change is needed on both servers"
    fi

    # 3. the service
    st=$(svc_state "$name")
    case $st in
    active)
        since=$(systemctl show -p ActiveEnterTimestamp --value "pingify@$name" 2>/dev/null)
        chk_add ok service "the service is running since ${since:-a moment ago}"
        ;;
    stopped)
        chk_add bad service "the service is stopped" "systemctl start pingify@$name" "journalctl -u pingify@$name -n 30 --no-pager -o cat"
        ;;
    *)
        chk_add bad service "the service is neither running nor enabled" "systemctl enable --now pingify@$name"
        ;;
    esac

    # 4. the private link, or the port list of a forward tunnel
    if [ "$CK_MODE" = forward ]; then
        local nports
        nports=$(toml_get "$CK_FILE" forward ports | tr ',' '\n' | grep -c '"')
        if [ "$CK_SIDE" = iran ] && [ "${nports:-0}" = 0 ]; then
            chk_add warn ports "no ports are forwarded yet" "Manage ${BX_ARR} $name ${BX_ARR} Ports"
        else
            chk_add ok link "forward tunnel, ${nports:-0} port$(plural_s "${nports:-0}") on IRAN"
        fi
    elif [ ! -d "/sys/class/net/$CK_DEV" ]; then
        if [ "$st" = active ]; then
            chk_add bad link "the private link $CK_DEV does not exist" \
                "the core makes it at start, so it never started" \
                "journalctl -u pingify@$name -n 30 --no-pager -o cat"
        else
            chk_add note link "the private link $CK_DEV is not up, because the service is not running"
        fi
    else
        fl=$(cat "/sys/class/net/$CK_DEV/flags" 2>/dev/null)
        addr=$(ip -4 -o addr show dev "$CK_DEV" 2>/dev/null | awk '{print $4; exit}')
        live_mtu=$(cat "/sys/class/net/$CK_DEV/mtu" 2>/dev/null)
        if [ $((${fl:-0} & 1)) -ne 1 ]; then
            chk_add bad link "$CK_DEV exists but is down" "systemctl restart pingify@$name"
        elif [ -z "$addr" ]; then
            chk_add bad link "$CK_DEV is up but has no address" "systemctl restart pingify@$name"
        elif [ "$addr" != "$CK_MINE" ]; then
            chk_add bad link "$CK_DEV carries $addr, not $CK_MINE" "something else set it; restart the tunnel"
        else
            chk_add ok link "private link $CK_DEV is up, $addr, mtu ${live_mtu:-?}"
        fi
        if [ -n "$live_mtu" ] && [ "$live_mtu" != "$CK_MTU" ]; then
            chk_add warn mtu "device mtu $live_mtu, the config says $CK_MTU" \
                "a hand-set mtu is lost on the next restart" "put the number in the config instead"
        fi
    fi

    # 5. has the far end been heard from
    if [ "$st" = active ] && tun_stats "$name"; then
        heard=$ST_UP
        case $ST_INB in '' | 0) [ "${ST_UPTIME:-0}" -ge 20 ] && heard=false ;; esac
        case $heard in
        true)
            if [ "${ST_INB:-0}" = 0 ]; then
                chk_add note peer "started $(human_secs "$ST_UPTIME") ago; nothing back yet"
            else
                chk_add ok peer "the other server has been heard from - this tunnel has run $(human_secs "$ST_UPTIME")"
            fi
            ;;
        *)
            if [ "$ST_UP" = true ]; then
                chk_add bad dial "the connection was made and then carried nothing" \
                    "some networks take a connection from outside and carry nothing on it" \
                    "switch which end opens it: Manage ${BX_ARR} $name ${BX_ARR} Tuning ${BX_ARR} Link direction, on both servers"
            fi
            case $CK_TRANSPORT in
            icmp)
                chk_add bad peer "the other server has never been seen" \
                    "on $CK_FAR:  systemctl status pingify@$name" \
                    "watch there:  tcpdump -ni any icmp" \
                    "if nothing arrives at all, the route drops ICMP - try TCP UTLS or Raw TCP"
                ;;
            awg)
                chk_add bad peer "the other server has never been seen inside the link" \
                    "the line below says whether the link itself is up" \
                    "if it handshook, the path is dropping udp once it flows" \
                    "on $CK_FAR:  systemctl status pingify@$name"
                ;;
            gre)
                chk_add bad peer "the other server has never been seen" \
                    "on $CK_FAR:  systemctl status pingify@$name" \
                    "watch there:  tcpdump -ni any proto gre" \
                    "some networks drop ip protocol 47 outright; try TCP or ICMP"
                ;;
            tcp | utls | fallback | ws | wss | rawtcp)
                if [ "${CK_SIDE^^}" = "$CK_WAITS" ]; then
                    chk_add bad peer "the other server has never been seen" \
                        "this end is the one that waits, so start with it:  ss -ltn | grep :$CK_PORT" \
                        "open it here:  ufw allow $CK_PORT/tcp" \
                        "on $CK_FAR:  systemctl status pingify@$name"
                elif tcp_reach "$CK_WAIT_ADDR" "$CK_PORT"; then
                    chk_add bad peer "tcp/$CK_PORT is open there, but nothing pingify sent has come back" \
                        "the token differs between the two servers - compare the fingerprints" \
                        "or something else is answering on that port there"
                else
                    chk_add bad peer "the other server has never been seen" \
                        "on $CK_FAR:  systemctl status pingify@$name" \
                        "open it there:  ufw allow $CK_PORT/tcp" \
                        "from here:  nc -zv $CK_WAIT_ADDR $CK_PORT"
                fi
                ;;
            *)
                chk_add bad peer "the other server has never been seen" \
                    "on $CK_FAR:  systemctl status pingify@$name" \
                    "udp/$CK_PORT has to be open on $CK_WAITS:  nc -uzv $CK_WAIT_ADDR $CK_PORT" \
                    "most Iranian lines stop inbound UDP after a few packets; ICMP or Raw TCP is the usual answer"
                ;;
            esac
            ;;
        esac

        if [ "$CK_TRANSPORT" = awg ]; then
            local iface age
            iface=$(awg_iface "$name")
            if [ -z "$iface" ] || ! ip link show "$iface" >/dev/null 2>&1; then
                chk_add bad awg "the AmneziaWG link ${iface:-for this tunnel} is not up" \
                    "systemctl status awg-quick@${iface:-awg0}" "nothing below this can work without it"
            elif age=$(awg_handshake "$iface"); then
                if [ "$age" -lt 180 ]; then
                    chk_add ok awg "AmneziaWG handshook $(human_secs "$age") ago on $iface"
                else
                    chk_add warn awg "the last AmneziaWG handshake was $(human_secs "$age") ago" \
                        "the far end may be down, or the path stopped carrying udp" "awg show $iface"
                fi
            else
                chk_add bad awg "AmneziaWG on $iface has never handshaken" \
                    "the two servers have not agreed on keys" \
                    "open udp/$(toml_get "$CK_FILE" awg port) on both servers" "awg show $iface"
            fi
        fi

        # The far end, asked through the tunnel: the one question whose
        # answer comes from the other server.
        if [ "$heard" = true ] && [ "$CK_MODE" = tun ]; then
            local far fv fp mine_p
            if far=$(far_report "$name") && [ -n "$far" ]; then
                chk_add ok link-end "the other server answers on the private link"
                fv=$(json_field "$far" version)
                if [ -n "$fv" ] && [ -n "$core_ver" ] && [ "$fv" != "$core_ver" ]; then
                    chk_add warn far-version "the other server runs core $fv, this one runs $core_ver" \
                        "presets and wire records move together - update BOTH servers"
                fi
                fp=$(json_field "$far" profile)
                mine_p=$(toml_get "$CK_FILE" tuning profile)
                if [ -n "$fp" ] && [ -n "$mine_p" ] && [ "$fp" != "$mine_p" ]; then
                    chk_add warn far-profile "the other server is on $fp, this one on $mine_p" \
                        "pick one on both: Manage ${BX_ARR} $name ${BX_ARR} Tuning"
                fi
            else
                chk_add warn link-end "the other server does not answer on the private link" \
                    "the carrier is up, so this is the link and not the path" \
                    "on the other server:  pingify --status" \
                    "if packets arrived and then stopped, switch the link direction on both servers"
            fi
        fi
    elif [ "$st" = active ]; then
        if have curl; then
            chk_add bad status "no answer on 127.0.0.1:$(status_port "$name")" \
                "systemctl status pingify@$name" "status.port 0 in the config turns it off"
        else
            chk_add warn status "curl is missing, so nothing could ask it" "apt-get install -y curl"
        fi
    fi

    # 6. loss, as a rate
    if [ "$st" = active ] && [ "${ST_UP:-}" = true ] && [ -n "${ST_UPTIME:-}" ]; then
        lpm=$(awk -v l="${ST_LOST:-0}" -v s="$ST_UPTIME" 'BEGIN { if (s + 0 < 30) print "early"; else printf "%.1f", l * 60 / s }')
        case $lpm in
        early) chk_add note loss "too early to say anything about loss yet" ;;
        *)
            local fec_advice=
            case $CK_TRANSPORT in
            tcp | ws | wss | utls | fallback | gre) ;;
            *) [ "$(toml_get "$CK_FILE" tuning fec)" -gt 0 ] 2>/dev/null ||
                fec_advice="turn on Parity: Manage ${BX_ARR} $name ${BX_ARR} Tuning" ;;
            esac
            if [ "${lpm%%.*}" -ge 60 ]; then
                chk_add bad loss "the path is losing $lpm packets a minute" \
                    "run Find the MTU; a large mtu loses big packets" \
                    ${fec_advice:+"$fec_advice"} "if the mtu is right, the path is congested"
            elif [ "${lpm%%.*}" -ge 5 ]; then
                chk_add warn loss "the path is losing $lpm packets a minute" \
                    "run Find the MTU: a slightly large mtu does this" ${fec_advice:+"$fec_advice"}
            else
                chk_add ok loss "loss is $lpm a minute, ${ST_LATE:-0} arrived late"
            fi
            ;;
        esac
    fi

    # 7. the forwarded ports, and whether anything is behind them. IRAN only.
    if [ "$CK_SIDE" = iran ]; then
        spec=$(ports_of "$name")
        if [ -z "$spec" ]; then
            chk_add warn ports "no ports are forwarded from this server" "Manage ${BX_ARR} $name ${BX_ARR} Ports"
        else
            total=0 missing=0 unknown=0
            if [ "$CK_MODE" = tun ] && have iptables; then
                local rules
                rules=$(iptables -w 2 -t nat -S PINGIFY_NAT 2>/dev/null)
            fi
            while read -r proto lo hi rhost rport; do
                [ -n "$proto" ] || continue
                [ "$rhost" = - ] && rhost=$CK_PEER
                total=$((total + 1))
                if [ "$CK_MODE" = tun ] && have iptables && [ -n "${rules:-}" ] &&
                    ! printf '%s' "$rules" | grep -q -- "--dport $lo"; then
                    chk_add bad "rule-$lo" "no forwarding rule for :$lo in the kernel" \
                        "Manage ${BX_ARR} $name ${BX_ARR} Ports, and set the list again"
                    missing=$((missing + 1))
                    continue
                fi
                if [ "$proto" != tcp ]; then
                    unknown=$((unknown + 1))
                    continue
                fi
                if [ "$CK_MODE" = forward ]; then
                    port_free "$lo" tcp && {
                        chk_add bad "port-$lo" "nothing is listening on :$lo here" "systemctl restart pingify@$name"
                        missing=$((missing + 1))
                    }
                    continue
                fi
                if [ "$st" = active ] && [ "${ST_UP:-}" = true ] && ! tcp_reach "$rhost" "$rport"; then
                    missing=$((missing + 1))
                    chk_add warn "port-$lo" "$lo/tcp goes to $rhost:$rport, nothing there" \
                        "on KHAREJ, listen on $rhost:$rport" "from here:  nc -zv $rhost $rport"
                fi
            done < <(forward_specs "$spec" 2>/dev/null)
            if [ "$total" = 0 ]; then
                chk_add warn ports "the forwarded port list parsed to nothing" "Manage ${BX_ARR} $name ${BX_ARR} Ports, and set them again"
            elif [ "$missing" = 0 ]; then
                if [ "$CK_MODE" = tun ]; then
                    chk_add ok ports "$total forwarded port$(plural_s "$total"), each one has its rule and answers"
                else
                    chk_add ok ports "$total forwarded port$(plural_s "$total"), each one is bound here"
                fi
            fi
            [ "$unknown" -gt 0 ] && chk_add note ports-udp "$unknown are udp and cannot be tested here"
        fi
    fi

    # A stream carrier on a lossy path lives or dies by the congestion
    # control: measured here, bbr carried 348 Mbit/s where cubic carried 31.
    case $CK_TRANSPORT in
    tcp | ws | wss | utls | fallback)
        cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
        if [ -n "$cc" ] && [ "$cc" != bbr ]; then
            chk_add warn bbr "a tcp tunnel, and this kernel is on $cc" \
                "measured here: bbr carried 348 Mbit/s where cubic carried 31" \
                "main menu ${BX_ARR} Optimize ${BX_ARR} Enable BBR - on both servers"
        fi
        ;;
    esac

    if [ "$(watchdog_state)" != on ]; then
        chk_add warn watchdog "the watchdog is off - a tunnel that goes quiet will not be restarted" \
            "main menu ${BX_ARR} Health ${BX_ARR} Enable the watchdog"
    fi

    if [ "$CK_TRANSPORT" = icmp ]; then
        chk_add note icmp "ping gets no answer across this link by design; the round trip is measured on the health port"
    fi

    chk_finish "$name" "$mode"
    HC_BAD=$CHK_NBAD HC_WARN=$CHK_NWARN
    [ "$CHK_NBAD" -gt 0 ] && return 2
    [ "$CHK_NWARN" -gt 0 ] && return 1
    return 0
}

chk_finish() {
    case ${2:-} in
    json | --json) chk_json "$1" ;;
    *) chk_render "$1" ;;
    esac
}

# ---------------------------------------------------------------------------
# the live views
# ---------------------------------------------------------------------------

live_dashboard() {
    local key
    while :; do
        banner
        head2 "Live status"
        list_tunnels
        rule
        say "  ${C_DIM}watchdog: $(watchdog_state)   $(uptime 2>/dev/null | sed 's/^ *//')${C_OFF}"
        blank
        dim "refreshing every 2s - enter or q to go back"
        if read -rsn1 -t 2 key; then
            case $key in q | Q | 0 | "") return ;; esac
        fi
    done
}

LIVE_STOP=0
live_cursor_on() { printf '\033[?25h'; }

# spark_bar is one column of the round-trip history. A reply that never came
# is drawn as the failure glyph, not as a low bar.
spark_bar() {
    local ms=$1 bars i
    case $ms in '' | *[!0-9.]*) printf '%s' "$MK_NO"; return ;; esac
    if [ "$UI_GLYPH" = utf8 ]; then bars='▁▂▃▄▅▆▇█'; else bars='._-=+*#@'; fi
    ms=${ms%%.*}
    if [ "$ms" -lt 60 ]; then i=0
    elif [ "$ms" -lt 80 ]; then i=1
    elif [ "$ms" -lt 100 ]; then i=2
    elif [ "$ms" -lt 130 ]; then i=3
    elif [ "$ms" -lt 170 ]; then i=4
    elif [ "$ms" -lt 220 ]; then i=5
    elif [ "$ms" -lt 300 ]; then i=6
    else i=7; fi
    printf '%s' "${bars:i:1}"
}

# screen_live repaints a fixed block in place about once a second, without
# clearing the screen: the scrollback above is where you look when the
# connection stutters.
screen_live() {
    local name=$1
    local -a lines
    local painted=0 spark= rtt= key rxp txp last_rx= last_tx= din dout w

    chk_load "$name" || { fail "there is no tunnel called $name"; return 1; }
    banner
    head2 "Live status: $name"
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        live_frame "$name" '' ''
        return 0
    fi
    w=$((UI_W - 34))
    [ "$w" -lt 10 ] && w=10
    LIVE_STOP=0
    trap 'LIVE_STOP=1' INT
    trap 'live_cursor_on' EXIT
    printf '\033[?25l'
    while :; do
        rxp=$(cat "/sys/class/net/$CK_DEV/statistics/rx_packets" 2>/dev/null)
        txp=$(cat "/sys/class/net/$CK_DEV/statistics/tx_packets" 2>/dev/null)
        din= dout=
        if [ -n "$last_rx" ] && [ -n "$rxp" ]; then
            din=$((rxp - last_rx))
            dout=$((txp - last_tx))
        fi
        last_rx=$rxp last_tx=$txp
        rtt=
        if [ "$CK_MODE" = tun ] && [ "$CK_TRANSPORT" != icmp ]; then
            rtt=$(link_rtt "$CK_DEV" "$CK_PEER") || rtt=
            spark=$spark$(spark_bar "$rtt")
            [ "${#spark}" -gt "$w" ] && spark=${spark: -w}
        else
            rtt=$(tun_rtt "$name")
        fi
        lines=()
        while IFS= read -r key; do lines+=("$key"); done < <(live_frame "$name" "$spark" "$rtt" "$din" "$dout")
        [ "$painted" -gt 0 ] && printf '\033[%dA' "$painted"
        for key in "${lines[@]}"; do printf '\r\033[K%s\n' "$key"; done
        painted=${#lines[@]}
        [ "$LIVE_STOP" = 1 ] && break
        key=
        read -rsn1 -t 1 key
        [ -n "$key" ] && break
        [ "$LIVE_STOP" = 1 ] && break
    done
    trap - INT
    trap - EXIT
    live_cursor_on
    blank
    return 0
}

live_frame() {
    local name=$1 spark=$2 rtt=$3 din=${4:-} dout=${5:-} state=unknown carrying losses packets
    if tun_stats "$name"; then
        if [ "$ST_UP" = true ] && [ "${ST_INB:-0}" != 0 ]; then state=running; else state=idle; fi
    else
        [ "$(svc_state "$name")" = active ] && state=idle || state=stopped
    fi
    carrying="$(round1 "$ST_IN") Mbit/s in, $(round1 "$ST_OUT") out"
    losses="${ST_LOST:-0} lost, ${ST_LATE:-0} late, ${ST_GAPS:-0} gap$(plural_s "${ST_GAPS:-0}")"
    if [ -n "$din" ]; then packets="$din in, $dout out in the last second"; else packets="counting"; fi
    printf '  %s %s%s%s  %s\n' "$(state_dot "$state")" "$C_B" "$name" "$C_OFF" "$state"
    field "Carrying" "$carrying"
    if [ -n "$rtt" ]; then
        field "Round trip" "$(printf '%s%s ms%s  %s' "$(rtt_colour "$rtt")" "$rtt" "$C_OFF" "$spark")"
    elif [ "$CK_TRANSPORT" = icmp ]; then
        field "Round trip" "${C_DIM}measured on the health port, when the far end answers${C_OFF}"
    else
        field "Round trip" "${C_DIM}no answer${C_OFF}  $spark"
    fi
    field "Losses" "$losses"
    [ "$CK_MODE" = tun ] && field "Packets" "$packets"
    field "Uptime" "$(human_secs "$ST_UPTIME")"
    dim "any key to leave"
}

# ---------------------------------------------------------------------------
# finding the MTU instead of guessing it
#
# A binary search for the largest packet that crosses the private link
# intact. `ping -M do` sets don't-fragment, so a packet too big for the path
# is dropped rather than quietly cut in half. The device's own mtu is the
# ceiling, so this measures whether the configured mtu is honest.
# ---------------------------------------------------------------------------

MTU_WANT=
mtu_editor() { toml_set "$1" tun mtu "$MTU_WANT"; }

mtu_probe() {
    local dev=$1 peer=$2 total=$3
    ping -n -c1 -W2 -M do -s $((total - 28)) -I "$dev" "$peer" >/dev/null 2>&1
}

measure_mtu() {
    local name=$1 lo hi mid best=0 tries=0
    chk_load "$name" || { fail "there is no tunnel called $name"; return 1; }
    banner
    head2 "MTU: $name"
    if [ "$CK_MODE" = forward ]; then
        dim "This tunnel carries ports, not packets - it has no MTU of its own."
        dim "The connections inside it use whatever the two servers negotiate."
        return 0
    fi
    if [ "$CK_TRANSPORT" = icmp ]; then
        dim "This cannot be measured on an ICMP tunnel: the core stops both kernels"
        dim "answering echo while one runs, so a probe is answered by nobody."
        blank
        say "  Use a number instead of a measurement:"
        field "1320" "the default, and right on a 1500 path"
        field "1280" "survives PPPoE, mobile, double tunnels"
        blank
        if [ "$CK_MTU" != 1280 ] && confirm "set the mtu to 1280?" n; then
            MTU_WANT=1280
            cfg_apply "$name" mtu_editor yes && ok "mtu 1280 - set the same number on $CK_FAR"
        fi
        return 0
    fi
    if [ ! -d "/sys/class/net/$CK_DEV" ]; then
        fail "$CK_DEV does not exist, so there is nothing to measure"
        fix "start the tunnel:  systemctl start pingify@$name"
        return 1
    fi
    panel_open "measuring"
    panel_field "Transport" "$(kind_label "$CK_TRANSPORT")" "Set now" "$CK_MTU"
    panel_field "To" "$(addr_tint "$CK_PEER") over $CK_DEV"
    panel_close
    dim "Sends pings that may not be fragmented, one per size. A few seconds."
    blank
    lo=576 hi=$CK_MTU
    while [ "$lo" -le "$hi" ]; do
        mid=$(((lo + hi) / 2))
        tries=$((tries + 1))
        if mtu_probe "$CK_DEV" "$CK_PEER" "$mid"; then
            dim "$(printf '%5s  crosses' "$mid")"
            best=$mid
            lo=$((mid + 1))
        else
            dim "$(printf '%5s  does not' "$mid")"
            hi=$((mid - 1))
        fi
    done
    blank
    if [ "$best" = 0 ]; then
        fail "nothing crossed at any size: not an mtu problem"
        fix "check the tunnel first:  Health check"
        fix "echo may be blocked on the other server; the mtu was left alone"
        return 2
    fi
    if [ "$best" -ge "$CK_MTU" ]; then
        ok "$CK_MTU crosses intact, in $tries probes"
        dim "The device mtu is the ceiling, so more may work."
        return 0
    fi
    warn "the largest that crosses is $best, the config says $CK_MTU"
    dim "the difference is lost as whole packets - what makes a tunnel connect"
    dim "and then stall on anything large"
    blank
    if confirm "set the mtu to $best?" y; then
        MTU_WANT=$best
        cfg_apply "$name" mtu_editor yes && { ok "mtu $best"; dim "set the same on $CK_FAR"; }
    fi
    return 1
}

mtu_menu() {
    pick_tunnel || return 0
    measure_mtu "$PICKED"
    pause
}

# ---------------------------------------------------------------------------
# the speed test
#
# Honest, or nothing. A real test needs a listener at the other end: iperf3
# -s there, sixteen streams from here, six seconds, so the answer compares
# with the table the profiles were measured at.
# ---------------------------------------------------------------------------

IPERF_PORT=5201

iperf_install() {
    have iperf3 && return 0
    blank
    dim "installing iperf3"
    if have apt-get; then
        apt_install iperf3
    elif have dnf; then dnf install -y iperf3 >/dev/null 2>&1
    elif have yum; then yum install -y iperf3 >/dev/null 2>&1
    elif have apk; then apk add --no-cache iperf3 >/dev/null 2>&1
    fi
    have iperf3 && { ok "iperf3 installed"; return 0; }
    fail "iperf3 could not be installed here"
    fix "apt install -y iperf3"
    return 1
}

speed_listen() {
    iperf_install || { pause; return 0; }
    banner
    head2 "Listener"
    dim "iperf3 -s, answering on every address this server has - the tunnel's"
    dim "private address included. Now run the test from the other server."
    dim "ctrl-c when it is finished."
    blank
    trap ':' INT
    iperf3 -s -p "$IPERF_PORT" 2>&1 | sed 's/^/  /'
    trap - INT
    blank
    ok "listener stopped"
    pause
}

speed_test() {
    local name=$1 out rc ref target
    chk_load "$name" || { fail "there is no tunnel called $name"; return 1; }
    banner
    head2 "Speed test: $name"
    if [ "$(svc_state "$name")" != active ]; then
        fail "the tunnel is not running: nothing to push"
        fix "systemctl start pingify@$name"
        return 1
    fi
    if tun_stats "$name" && [ "$ST_UP" != true ]; then
        fail "the other server has not been seen; nothing is there"
        fix "run the Health check first"
        return 1
    fi
    say "  What the link is carrying right now:"
    field "in" "$(round1 "$ST_IN") Mbit/s"
    field "out" "$(round1 "$ST_OUT") Mbit/s"
    blank
    iperf_install || return 1
    if [ "$CK_MODE" = tun ]; then
        target=$CK_PEER
    else
        # A forward tunnel has no private address; the test goes through the
        # first forwarded tcp port, which is what a user gets.
        local spec p
        spec=$(ports_of "$name")
        p=$(forward_specs "$spec" 2>/dev/null | awk '$1 == "tcp" { print $2; exit }')
        if [ "$CK_SIDE" != iran ] || [ -z "$p" ]; then
            fail "a forward tunnel is measured from IRAN, through a forwarded tcp port"
            fix "forward $IPERF_PORT to KHAREJ, run iperf3 -s there, and test from IRAN"
            return 1
        fi
        target=127.0.0.1
        IPERF_PORT=$p
        dim "through forwarded port $p; the listener on KHAREJ must be on what it goes to"
    fi
    dim "This needs a listener there. On $CK_FAR, run:"
    say "       Diagnostics ${BX_ARR} iperf3 ${BX_ARR} Hold the listener     (or: iperf3 -s)"
    blank
    confirm "is it running there?" y || { dim "nothing measured"; return 1; }
    blank
    dim "16 streams for six seconds, matching the numbers the profiles were measured at."
    blank
    out=$(iperf3 -c "$target" -p "$IPERF_PORT" -t 6 -P 16 2>&1)
    rc=$?
    printf '%s\n' "$out" | grep -E 'SUM|error|refused|route' | tail -4 | sed 's/^/       /'
    blank
    if [ "$rc" -ne 0 ]; then
        fail "iperf3 did not finish"
        case $out in
        *"onnection refused"*) fix "nothing on $target:$IPERF_PORT - hold the listener there" ;;
        *"o route to host"* | *"imed out"*) fix "the link is up but nothing crosses it - run the Health check" ;;
        *) fix "read the message above, then run the Health check" ;;
        esac
        return 1
    fi
    case ${ST_PROFILE:-$(toml_get "$CK_FILE" tuning profile)} in
    gaming) ref="gaming measured 397 Mbit/s over 16 streams" ;;
    download) ref="download measured 466 Mbit/s over 16 streams" ;;
    *) ref="balanced measured 448 Mbit/s over 16 streams" ;;
    esac
    ok "done"
    dim "$ref on the reference path, Tehran to Frankfurt."
    dim "A slower path abroad reads lower; that is the path. Take it more than once."
    return 0
}

speed_menu() {
    local c
    while :; do
        banner
        head2 "iperf3"
        dim "Real bandwidth between your two servers. Sixteen parallel streams, six"
        dim "seconds - one stream on a 90 ms path runs out of its own window long"
        dim "before the path runs out of room."
        blank
        item 1 "Hold the listener" "on the other server, first"
        item 2 "Run the test" "on this server, after that"
        item 0 "Back"
        blank
        menu_key c || return 0
        case $c in
        1) speed_listen ;;
        2) pick_tunnel && { speed_test "$PICKED"; pause; } ;;
        0 | '') return 0 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# the menu
# ---------------------------------------------------------------------------

health_menu() {
    local c n
    while :; do
        banner
        head2 "Health"
        list_tunnels
        rule
        item 1 "Health check" "what is wrong, and what to do about it"
        item 2 "Live status dashboard"
        item 3 "Enable the watchdog" "restarts a tunnel that goes quiet"
        item 4 "Disable the watchdog"
        item 5 "Recent health log"
        item 6 "Restart every tunnel"
        item 0 "Back"
        blank
        menu_key c || return 0
        case $c in
        1) pick_tunnel && { banner; health_check "$PICKED"; pause; } ;;
        2) live_dashboard ;;
        3) blank; enable_watchdog; pause ;;
        4) blank; disable_watchdog; pause ;;
        5) blank; journalctl -u pingify-health.service -n 40 --no-pager -o cat 2>/dev/null | sed 's/^/  /'; pause ;;
        6) blank; for n in $(cfg_list); do svc_do restart "$n"; done; pause ;;
        0 | '') return 0 ;;
        esac
    done
}

# screen_health runs the check over every tunnel; the worst answer is kept.
screen_health() {
    local n rc=0 one any=0
    banner
    for n in $(cfg_list); do
        any=1
        health_check "$n" || { one=$?; [ "$one" -gt "$rc" ] && rc=$one; }
    done
    [ "$any" = 1 ] || warn "there are no tunnels to check yet"
    pause
    return "$rc"
}
