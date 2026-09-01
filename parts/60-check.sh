#!/usr/bin/env bash
#
# Diagnostics: the screens you open when something is wrong, and the two
# measurements worth taking when nothing is.
#
# Four decisions shape this whole part.
#
#   Every failure carries a fix. A health check that lists problems and stops
#   is a list of reasons to be worried with no way to stop being worried. That
#   was the old check's one good idea, and it is kept without its 320 lines.
#
#   Grey is a verdict. Red means "this is broken", never "this could not be
#   measured". An ICMP tunnel switches off echo replies on both servers while
#   it runs, so a ping across it is answered by nobody - the design working,
#   not the link failing. The old manager drew that in red and told a healthy
#   tunnel it was dead. Here it is one grey line.
#
#   Status comes from the core, never from its prose. `tun_stats` reads the
#   JSON the core serves on loopback. The old manager took the eighth field of
#   an English sentence out of the journal with awk, and broke the day somebody
#   reworded the sentence.
#
#   Every message fits in sixty columns, which is UI_W's floor. None of
#   ok/warn/bad/fix/dim truncates - they carry prose, and prose that overruns
#   wraps and destroys the indentation that carries the meaning. The budgets
#   are 54 characters for a verdict, 46 for a fix, 56 for a grey note.

# --------------------------------------------------------------------------
# collecting a verdict
# --------------------------------------------------------------------------
#
# health_check buffers its result rather than printing as it goes, so the text
# screen and --json are one pass rendered twice. Two passes would eventually
# disagree, and the one a script reads is the one nobody looks at.

CHK_STATE=() CHK_ID=() CHK_TEXT=() CHK_FIX=()
CHK_NBAD=0 CHK_NWARN=0

chk_reset() {
    CHK_STATE=() CHK_ID=() CHK_TEXT=() CHK_FIX=()
    CHK_NBAD=0 CHK_NWARN=0
}

# chk_add STATE ID TEXT [FIX...]
#
# STATE is ok, warn, bad or note. note is the grey one: something worth saying
# that is not a fault, and it is never counted as one. Every warn and every bad
# passes at least one fix; nothing else passes any.
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

# count_word turns a small number into the word for it. "one problem" reads;
# "1 problem(s)" is a form to be filled in.
count_word() {
    case $1 in
    1) printf 'one' ;; 2) printf 'two' ;; 3) printf 'three' ;;
    *) printf '%s' "$1" ;;
    esac
}

# plural_s prints the s, or nothing, inline, so a count and its noun cannot
# drift apart in an edit.
plural_s() { [ "$1" = 1 ] || printf 's'; }

chk_tally() {
    local out=
    [ "$CHK_NBAD" = 0 ] && [ "$CHK_NWARN" = 0 ] &&
        { printf 'nothing wrong here'; return; }
    [ "$CHK_NBAD" -gt 0 ] &&
        out="$(count_word "$CHK_NBAD") problem$(plural_s "$CHK_NBAD")"
    if [ "$CHK_NWARN" -gt 0 ]; then
        [ -n "$out" ] && out="$out, "
        out="$out$(count_word "$CHK_NWARN") warning$(plural_s "$CHK_NWARN")"
    fi
    printf '%s' "$out"
}

chk_render() {
    local name=$1 i line
    blank
    rule "Health of $name"
    blank
    for ((i = 0; i < ${#CHK_ID[@]}; i++)); do
        case ${CHK_STATE[i]} in
        ok) ok "${CHK_TEXT[i]}" ;;
        warn) warn "${CHK_TEXT[i]}" ;;
        bad) bad "${CHK_TEXT[i]}" ;;
        # ok/warn/bad each spend two columns on a glyph before their text. A
        # grey note has no glyph, so it is padded into the same column; without
        # that it sits two to the left and reads as a different list.
        *) dim "  ${CHK_TEXT[i]}" ;;
        esac
        if [ -n "${CHK_FIX[i]}" ]; then
            while IFS= read -r line; do
                [ -n "$line" ] && fix "$line"
            done <<<"${CHK_FIX[i]}"
        fi
    done
    blank
    dim "$(chk_tally)"
    blank
}

# json_esc covers what can actually appear in these strings: backslashes,
# quotes and tabs. Nothing here builds a check line out of text with a newline
# in it - the one place that could, the core's own refusal, is cut to its first
# line before it gets here.
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
            "$(json_esc "${CHK_ID[i]}")" "${CHK_STATE[i]}" \
            "$(json_esc "${CHK_TEXT[i]}")"
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

# --------------------------------------------------------------------------
# reading a tunnel's own idea of itself
# --------------------------------------------------------------------------
#
# Eight values every screen here needs, read once into CK_* globals. Reading
# them per screen meant eight awk passes over one file and, in the old script,
# two of the readers disagreed about which side we were on.

chk_load() {
    local name=$1
    CK_FILE=$(cfg_file "$name")
    [ -f "$CK_FILE" ] || return 1
    CK_SIDE=$(toml_get "$CK_FILE" tunnel side)
    CK_TRANSPORT=$(toml_get "$CK_FILE" transport type)
    CK_PORT=$(toml_get "$CK_FILE" transport port)
    CK_KHAREJ=$(toml_get "$CK_FILE" transport kharej)
    CK_DEV=$(toml_get "$CK_FILE" tun name)
    CK_MTU=$(toml_get "$CK_FILE" tun mtu)
    # The core fills these in when the file leaves them out, so the manager has
    # to agree with it or it reports a mismatch that is not one.
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
    return 0
}

# link_rtt pings the other end of the private link and prints the round trip in
# milliseconds. It is bound to the tun device, so the answer is the tunnel's
# latency and not the carrier's. Prints nothing and returns 1 when no reply
# comes, which on an ICMP tunnel is always - see the note in health_check.
link_rtt() {
    local dev=$1 peer=$2 out
    out=$(ping -n -c1 -W1 -I "$dev" "$peer" 2>/dev/null) || return 1
    case $out in
    *time=*) out=${out#*time=}; printf '%s' "${out%% *}" ;;
    *) return 1 ;;
    esac
}

# tcp_reach says whether something accepts a connection at HOST:PORT. bash's
# own /dev/tcp is tried first because it is always there and needs no package;
# nc is the fallback for the builds that compile it out.
tcp_reach() {
    local host=$1 port=$2
    if timeout 2 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
        return 0
    fi
    have nc && nc -z -w2 "$host" "$port" >/dev/null 2>&1
}

# The forwarding part owns the port spec and where it is kept; this only reads
# it. When forwarding was never set up the check says nothing about ports
# rather than inventing a failure out of an absent file.
#
# The path comes from fwd_file rather than being spelled out a second time
# here. It used to read $STATE_DIR/$1.ports, a name nothing has ever written -
# the forwarding part writes $1.forwards - so the file was never found, section
# 7 always took the absent-file branch, and a server forwarding six ports was
# told in grey that it forwards none, with any dead backend behind them never
# reported at all.
chk_forward_spec() {
    local f
    declare -F fwd_file >/dev/null 2>&1 || return 1
    f=$(fwd_file "$1")
    [ -f "$f" ] || return 1
    # The tokens are stored one per line. Deleting the newlines glued 443 and
    # 8080 into 4438080, forward_specs refused that as one impossible port, and
    # the check told the user to set the list again about a list that was fine.
    # fwd_tokens splits on newlines as readily as on commas, so the file is
    # passed on as it stands.
    cat "$f"
}

# --------------------------------------------------------------------------
# health_check
# --------------------------------------------------------------------------
#
# One pass, in the order things fail. A check whose evidence is missing says so
# in grey and does not guess: with no core installed there is no verdict to
# give about whether it accepts the config, and giving one anyway is how a
# health report comes to be ignored. Exit 0 clean, 1 warnings, 2 problems, so
# `pingify --check NAME` is usable from cron; the old one ended in `pause`.

health_check() {
    local name=$1 mode=${2:-}
    local core_ver out st since addr fl live_mtu lpm heard cc
    local spec proto lo hi rhost rport total missing unknown

    chk_reset
    if ! chk_load "$name"; then
        chk_add bad config "there is no tunnel called $name" \
            "run pingify with no arguments to see the list"
        chk_finish "$name" "$mode"
        return 2
    fi

    # 1. the core itself. Everything below is a question about what the core is
    # doing, so a missing core makes the rest unanswerable rather than failed.
    if [ ! -x "$CORE_BIN" ]; then
        chk_add bad core "the core is not installed at $CORE_BIN" \
            "run pingify and choose 6, Update Pingify"
        chk_add note core-rest "nothing below could be checked without it"
        chk_finish "$name" "$mode"
        return 2
    fi
    if core_ver=$("$CORE_BIN" -version 2>&1); then
        core_ver=${core_ver%%$'\n'*}
        core_ver=${core_ver##* }
        if [ "$core_ver" = "$PINGIFY_VERSION" ]; then
            chk_add ok core "core $core_ver, matching this script"
        else
            chk_add warn core "core $core_ver, this script is $PINGIFY_VERSION" \
                "an older core can lack a setting this writes" \
                "update both:  pingify --update"
        fi
    else
        chk_add bad core "$CORE_BIN will not run" \
            "it may be built for another architecture" \
            "reinstall it:  pingify --update"
    fi

    # 2. the config, judged by the only judge that counts. The core's refusal
    # is one long sentence, so it goes through the UI's own cut rather than
    # over the right-hand edge of a phone terminal.
    if out=$("$CORE_BIN" -c "$CK_FILE" -check 2>&1); then
        chk_add ok config "the core accepts $CK_FILE"
    else
        chk_add bad config \
            "the core refuses it: $(trunc_to "${out%%$'\n'*}" $((UI_W - 26)))" \
            "edit $CK_FILE" \
            "the same change is needed on both servers"
    fi

    # 3. systemd. svc_state tells stopped (enabled, not running) from disabled
    # (not even wanted), and the two need different advice.
    st=$(svc_state "$name")
    case $st in
    active)
        since=$(systemctl show -p ActiveEnterTimestamp --value \
            "pingify@$name" 2>/dev/null)
        chk_add ok service "running since ${since:-a moment ago}"
        ;;
    stopped)
        # The command goes on the fix line bare. The old "read why:  " prefix
        # spent ten columns of a 46-column budget, so any tunnel name over ten
        # characters wrapped, and fix() pads rather than cuts, so the wrapped
        # half landed hard against the left margin and read as a line of its
        # own.
        chk_add bad service "the service is enabled but not running" \
            "systemctl start pingify@$name" \
            "journalctl -u pingify@$name -n 30"
        ;;
    *)
        chk_add bad service "the service is neither running nor enabled" \
            "systemctl enable --now pingify@$name"
        ;;
    esac

    # 4. the private link. operstate on a tun device reads "unknown" even when
    # it is carrying perfectly - the driver has no carrier to report - so the
    # flags word is the thing to look at. Bit 0 of it is IFF_UP.
    if [ ! -d "/sys/class/net/$CK_DEV" ]; then
        chk_add bad link "the private link $CK_DEV does not exist" \
            "the core makes it at start, so it never started" \
            "journalctl -u pingify@$name -n 30"
    else
        fl=$(cat "/sys/class/net/$CK_DEV/flags" 2>/dev/null)
        addr=$(ip -4 -o addr show dev "$CK_DEV" 2>/dev/null | awk '{print $4; exit}')
        live_mtu=$(cat "/sys/class/net/$CK_DEV/mtu" 2>/dev/null)
        if [ $((${fl:-0} & 1)) -ne 1 ]; then
            chk_add bad link "$CK_DEV exists but is down" \
                "restart it:  systemctl restart pingify@$name"
        elif [ -z "$addr" ]; then
            chk_add bad link "$CK_DEV is up but has no address" \
                "restart it:  systemctl restart pingify@$name"
        elif [ "$addr" != "$CK_MINE" ]; then
            chk_add bad link "$CK_DEV carries $addr, not $CK_MINE" \
                "something else set it; restart the tunnel"
        else
            chk_add ok link "link $CK_DEV is up, $addr, mtu ${live_mtu:-?}"
        fi
        if [ -n "$live_mtu" ] && [ "$live_mtu" != "$CK_MTU" ]; then
            chk_add warn mtu "device mtu $live_mtu, the config says $CK_MTU" \
                "a hand-set mtu is lost on the next restart" \
                "put the number in the config instead"
        fi
    fi

    # 5. has the far end ever been heard from. Nothing else stands in for it:
    # the link can be up, the config right and the service running with no
    # packet from over there having ever arrived.
    if tun_stats "$name"; then
        # Only the word true. up is a Go bool in the core's report, so the
        # value is true or false and never 1 or yes, and accepting those two
        # here made this section disagree with the loss check and the speed
        # test below, which both test for true alone. Had the core ever
        # answered 1, this line would have said the far end was there while
        # the loss check vanished and the speed test called the same tunnel
        # unseen.
        # up alone is not the question. On the side that dials, the core's up
        # is true from the first second because it knows the address it was
        # given; only bytes arriving prove there is anybody at it. Twenty
        # seconds of grace so that a check run right after a start does not
        # call a healthy tunnel dead.
        heard=$ST_UP
        case $ST_INB in '' | 0) [ "${ST_UPTIME:-0}" -ge 20 ] && heard=false ;; esac
        case $heard in
        true)
            if [ "${ST_INB:-0}" = 0 ]; then
                chk_add note peer "started $(human_secs "$ST_UPTIME") ago; nothing back yet"
            else
                # "has been heard from", not "is there": this counts bytes
                # that have arrived since the tunnel started, so it is a fact
                # about the past. Whether anybody is at the far end *now* is
                # the next check, and the two disagree exactly when something
                # has just broken. The time is this tunnel's own, not the far
                # end's - it used to read "the far end is there, up for 3m",
                # which is our uptime wearing their name.
                chk_add ok peer \
                    "the far end has been heard from - this tunnel has run $(human_secs "$ST_UPTIME")"
            fi
            ;;
        *)
            case $CK_TRANSPORT in
            icmp)
                chk_add bad peer "the far end has never been seen" \
                    "on KHAREJ:  systemctl status pingify@$name" \
                    "watch there:  tcpdump -ni any icmp" \
                    "if nothing arrives at all, try tcp or udp"
                ;;
            awg)
                # The port worth naming here is AmneziaWG's, not the carrier's:
                # the carrier's is inside the link and nothing outside can
                # reach it or block it.
                chk_add bad peer "the far end has never been seen inside the link" \
                    "the line below says whether the link itself is up" \
                    "if it handshook, the path is dropping udp once it flows" \
                    "on KHAREJ:  systemctl status pingify@$name"
                ;;
            gre)
                chk_add bad peer "the far end has never been seen" \
                    "on KHAREJ:  systemctl status pingify@$name" \
                    "watch there:  tcpdump -ni any proto gre" \
                    "some networks drop ip protocol 47 outright; try tcp or ws"
                ;;
            tcp)
                # TCP is the one transport whose far end can be tested from
                # here without the tunnel: a connection either opens or it
                # does not, and which of the two it is decides where to look.
                if [ "$CK_SIDE" = iran ] && tcp_reach "$CK_KHAREJ" "$CK_PORT"; then
                    chk_add bad peer \
                        "tcp/$CK_PORT is open there, but nothing pingify sent has come back" \
                        "the token differs between the two servers" \
                        "compare:  grep token $CK_FILE   on both" \
                        "or something else is answering on that port there"
                else
                    chk_add bad peer "the far end has never been seen" \
                        "on KHAREJ:  systemctl status pingify@$name" \
                        "open it there:  ufw allow $CK_PORT/tcp" \
                        "from here:  nc -zv $CK_KHAREJ $CK_PORT"
                fi
                ;;
            *)
                # Bare again: the address on this line is a hostname somebody
                # else chose, so the prefix is the only part of it there is
                # room to give up.
                chk_add bad peer "the far end has never been seen" \
                    "on KHAREJ:  systemctl status pingify@$name" \
                    "open it there:  ufw allow $CK_PORT/udp" \
                    "nc -uzv $CK_KHAREJ $CK_PORT" \
                    "a token edited on one side only does this"
                ;;
            esac
            ;;
        esac

        # The link underneath, when there is one. An AmneziaWG tunnel has two
        # things that can be down and they fail differently: the handshake is
        # theirs and says whether the two servers have agreed on keys at all,
        # and everything below this is ours and runs inside it.
        if [ "$CK_TRANSPORT" = awg ]; then
            local iface age
            iface=$(awg_iface "$name")
            if [ -z "$iface" ] || ! ip link show "$iface" >/dev/null 2>&1; then
                chk_add bad awg "the AmneziaWG link ${iface:-for this tunnel} is not up" \
                    "systemctl status awg-quick@${iface:-awg0}" \
                    "nothing below this can work without it"
            elif age=$(awg_handshake "$iface"); then
                if [ "$age" -lt 180 ]; then
                    chk_add ok awg "AmneziaWG handshook $(human_secs "$age") ago on $iface"
                else
                    chk_add warn awg "the last AmneziaWG handshake was $(human_secs "$age") ago" \
                        "the far end may be down, or the path stopped carrying udp" \
                        "awg show $iface"
                fi
            else
                chk_add bad awg "AmneziaWG on $iface has never handshaken" \
                    "the two servers have not agreed on keys" \
                    "open udp/$(toml_get "$CK_FILE" awg port) on KHAREJ" \
                    "awg show $iface"
            fi
        fi

        # The far end, asked through the tunnel.
        #
        # Everything above is this server's own opinion of the tunnel. This is
        # the one question in the check whose answer comes from the other
        # server, and the asking is the test: if it answers, a packet put into
        # the tun device here came out of the one over there and the reply
        # found its way back. The carrier being up does not say that.
        if [ "$heard" = true ]; then
            local far fv fp mine_p
            if far=$(far_report "$name") && [ -n "$far" ]; then
                chk_add ok link-end "the far end answers on the private link"

                # Two servers on two versions is the commonest way a pair that
                # worked stops working, and until now finding it meant logging
                # into both of them.
                fv=$(json_field "$far" version)
                if [ -n "$fv" ] && [ -n "$core_ver" ] && [ "$fv" != "$core_ver" ]; then
                    chk_add warn far-version \
                        "the far end runs core $fv, this one runs $core_ver" \
                        "update both servers:  pingify --update"
                fi
                fp=$(json_field "$far" profile)
                mine_p=$(toml_get "$CK_FILE" tuning profile)
                if [ -n "$fp" ] && [ -n "$mine_p" ] && [ "$fp" != "$mine_p" ]; then
                    chk_add warn far-profile \
                        "the far end is on $fp, this one on $mine_p" \
                        "pick one on both, from the tunnel screen"
                fi
            else
                chk_add warn link-end "the far end does not answer on the private link" \
                    "the carrier is up, so this is the link and not the path" \
                    "on the other server:  pingify --status" \
                    "a core older than $PINGIFY_VERSION has no health port"
            fi
        fi
    else
        if have curl; then
            chk_add bad status \
                "no answer on 127.0.0.1:$(status_port "$name")" \
                "systemctl status pingify@$name" \
                "status.port 0 in the config turns it off"
        else
            # Not knowing is a warning, not a note: a note is something that is
            # fine, and a tunnel nobody can question is not fine.
            chk_add warn status "curl is missing, so nothing could ask it" \
                "install curl:  apt-get install -y curl"
        fi
    fi

    # 6. loss, as a rate. There is no denominator in the report - the core
    # counts what it missed, not what it should have had - so this is losses
    # per minute since it started, and it is not called a percentage.
    if [ "$ST_UP" = true ] && [ -n "$ST_UPTIME" ]; then
        lpm=$(awk -v l="${ST_LOST:-0}" -v s="$ST_UPTIME" \
            'BEGIN { if (s + 0 < 30) print "early"; else printf "%.1f", l * 60 / s }')
        case $lpm in
        early)
            chk_add note loss "too early to say anything about loss yet"
            ;;
        *)
            if [ "${lpm%%.*}" -ge 60 ]; then
                chk_add bad loss "the path is losing $lpm packets a minute" \
                    "run Measure MTU; a large mtu loses big packets" \
                    "if the mtu is right, the path is congested"
            elif [ "${lpm%%.*}" -ge 5 ]; then
                chk_add warn loss "the path is losing $lpm packets a minute" \
                    "run Measure MTU: a slightly large mtu does this"
            else
                chk_add ok loss "loss is $lpm a minute, ${ST_LATE:-0} arrived late"
            fi
            ;;
        esac
    fi

    # 7. the forwarded ports, and whether anything is behind them. IRAN only:
    # KHAREJ forwards nothing, because nobody connects to it.
    if [ "$CK_SIDE" = iran ]; then
        spec=$(chk_forward_spec "$name") || spec=
        if [ -z "$spec" ]; then
            chk_add note ports "no ports are forwarded from this server"
        elif ! declare -F forward_specs >/dev/null 2>&1; then
            chk_add note ports "ports unchecked: forwarding is not loaded"
        else
            total=0 missing=0 unknown=0
            while read -r proto lo hi rhost rport; do
                [ -n "$proto" ] || continue
                # forward_specs writes - in the destination column when the
                # token named no host, and it means "the far end of this
                # tunnel"; nat_rules_for substitutes the peer address before it
                # builds a rule. This did not, so a plain 443 forward probed
                # the host called - , always failed, and every ordinary forward
                # drew a warning telling the operator to listen on -:443.
                [ "$rhost" = - ] && rhost=$CK_PEER
                total=$((total + 1))
                if [ "$proto" != tcp ]; then
                    # There is no way to ask a udp port whether anybody is
                    # behind it. "Closed" would be a guess dressed up as a
                    # measurement, and this screen does not do that.
                    unknown=$((unknown + 1))
                    continue
                fi
                if ! tcp_reach "$rhost" "$rport"; then
                    missing=$((missing + 1))
                    chk_add warn "port-$lo" \
                        "$lo/tcp goes to $rhost:$rport, nothing there" \
                        "on KHAREJ, listen on $rhost:$rport" \
                        "from here:  nc -zv $rhost $rport"
                fi
            done < <(forward_specs "$spec" 2>/dev/null)
            if [ "$total" = 0 ]; then
                chk_add warn ports "the forwarded port list parsed to nothing" \
                    "open Ports on the tunnel screen and set them again"
            elif [ "$missing" = 0 ]; then
                chk_add ok ports \
                    "$total forwarded port$(plural_s "$total"), each one answers"
            fi
            [ "$unknown" -gt 0 ] &&
                chk_add note ports-udp "$unknown are udp and cannot be tested here"
        fi
    fi

    # A stream carrier on a path that drops packets lives or dies by the
    # kernel's congestion control, and this is not a preference. Measured on
    # the Tehran to Frankfurt pair, the same tunnel, minutes apart:
    #
    #	cubic    31 Mbit/s over sixteen streams
    #	bbr     348
    #
    # Cubic reads a dropped packet as congestion and halves the window. On a
    # path that drops packets for reasons of its own, that is a window that
    # never opens again. It is worth a warning rather than a note because the
    # tunnel is carrying a tenth of what it could.
    if [ "$CK_TRANSPORT" = tcp ]; then
        cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
        if [ -n "$cc" ] && [ "$cc" != bbr ]; then
            chk_add warn bbr "a tcp tunnel, and this kernel is on $cc" \
                "measured here: bbr carried 348 Mbit/s where cubic carried 31" \
                "pingify, 4 Host tuning, 2 BBR - on both servers"
        fi
    fi

    # The ICMP note, last, because it explains something rather than reporting
    # it. Grey, uncounted, one line.
    #
    # An ordinary ping across this link gets nothing back and that is correct:
    # the carrier stops both kernels answering echo. The round trip on the
    # screens above is not a ping - it is the handshake with the far end's
    # health port, which is a real crossing of the link and back.
    if [ "$CK_TRANSPORT" = icmp ]; then
        chk_add note icmp "ping gets no answer here by design; the round trip is measured on the health port"
    fi

    chk_finish "$name" "$mode"
    [ "$CHK_NBAD" -gt 0 ] && return 2
    [ "$CHK_NWARN" -gt 0 ] && return 1
    return 0
}

# chk_finish picks the renderer. One place, so an early return in health_check
# cannot forget the --json case and print a screen at a caller that wanted
# something a machine could read.
#
# Both spellings of the mode word are matched, and that is not tidiness. main
# calls health_check with the bare word json, while this tested only for
# --json, so `pingify --check NAME --json` rendered the escape-coded human
# screen into whatever script was parsing it and exited 0, 1 or 2 as though it
# had answered. Taking either word means neither side can break it again by
# settling on the other one.
chk_finish() {
    case ${2:-} in
    json | --json) chk_json "$1" ;;
    *) chk_render "$1" ;;
    esac
}

# --------------------------------------------------------------------------
# the live view
# --------------------------------------------------------------------------
#
# A fixed block repainted in place about once a second. It moves the cursor up
# with \033[<n>A and erases each line as it rewrites it, and never clears the
# screen: over a link with 100 ms of delay and real loss, the scrollback above
# is where you look when the connection stutters.
#
# The cursor is hidden on entry and put back by a trap on EXIT and INT. The old
# spinner hid it and had no trap, so one Ctrl-C left the cursor invisible for
# the rest of the ssh session. This is the only EXIT trap in the script; if
# another is ever added, this one has to save and restore it.

LIVE_STOP=0

live_cursor_on() { printf '\033[?25h'; }

# spark_bar is one column of the round-trip history. A reply that never came is
# drawn as the failure glyph, not as a low bar: a low bar is the same shape as
# a fast reply and would read as good news.
spark_bar() {
    local ms=$1 bars i
    case $ms in
    '' | *[!0-9.]*) printf '%s' "$G_BAD"; return ;;
    esac
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

screen_live() {
    local name=$1
    local -a lines
    local painted=0 spark= rtt= key rxp txp last_rx= last_tx= din dout w

    chk_load "$name" || { bad "there is no tunnel called $name"; return 1; }

    blank
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        # Nothing to repaint into and nobody to press a key. One frame, plain,
        # so a script or a test gets an answer instead of a spin.
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

        # One ping per frame, bound to the tun. On an ICMP tunnel there is
        # nothing to ping, so that row becomes the grey explanation and the
        # block keeps its height. The ping and the status read add about a
        # tenth of a second, so a frame is about a second, not exactly.
        rtt=
        if [ "$CK_TRANSPORT" != icmp ]; then
            rtt=$(link_rtt "$CK_DEV" "$CK_PEER") || rtt=
            spark=$spark$(spark_bar "$rtt")
            # Trim only once it is over the width. ${spark: -w} on a string
            # shorter than w returns nothing at all, so trimming on every frame
            # left the sparkline empty until it had run for w seconds.
            [ "${#spark}" -gt "$w" ] && spark=${spark: -w}
        fi

        lines=()
        while IFS= read -r key; do lines+=("$key"); done < <(
            live_frame "$name" "$spark" "$rtt" "$din" "$dout"
        )

        [ "$painted" -gt 0 ] && printf '\033[%dA' "$painted"
        for key in "${lines[@]}"; do printf '\r\033[K%s\n' "$key"; done
        painted=${#lines[@]}

        [ "$LIVE_STOP" = 1 ] && break
        # read returns non-zero for both a timeout and a keystroke, so the
        # variable is what tells them apart: only a keystroke sets it.
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

# live_frame prints the block once, from the CK_* screen_live loaded. Separate,
# so the non-interactive path and the loop draw the same thing and the height
# of the block is a property of one function rather than of the loop.
live_frame() {
    local name=$1 spark=$2 rtt=$3 din=${4:-} dout=${5:-} state=unknown
    local carrying losses packets

    if tun_stats "$name"; then
        [ "$ST_UP" = true ] && state=running || state=idle
    else
        [ "$(svc_state "$name")" = active ] && state=idle || state=stopped
    fi

    carrying="$(round1 "$ST_IN") Mbit/s in, $(round1 "$ST_OUT") out"
    losses="${ST_LOST:-0} lost, ${ST_LATE:-0} late, ${ST_GAPS:-0}"
    losses="$losses gap$(plural_s "${ST_GAPS:-0}")"
    if [ -n "$din" ]; then
        packets="$din in, $dout out in the last second"
    else
        packets="counting"
    fi

    rule "$name  $(state_dot "$state")"
    field "Carrying" "$carrying"
    if [ "$CK_TRANSPORT" = icmp ]; then
        field "Round trip" "$(printf '%snot measurable while ICMP runs%s' \
            "$C_MUTE" "$C_OFF")"
    else
        field "Round trip" "$(printf '%s%s ms%s  %s' "$(rtt_colour "$rtt")" \
            "${rtt:-?}" "$C_OFF" "$spark")"
    fi
    field "Losses" "$losses"
    field "Packets" "$packets"
    field "Uptime" "$(human_secs "$ST_UPTIME")"
    dim "any key to leave"
}

# --------------------------------------------------------------------------
# measuring the mtu
# --------------------------------------------------------------------------
#
# A binary search for the largest packet that crosses the private link intact.
# `ping -M do` sets don't-fragment, so a packet too big for the carrier path is
# dropped rather than quietly cut in half and the search finds the boundary.
# The device's own mtu is the ceiling - the kernel will not send a bigger
# don't-fragment packet - so this measures whether the configured mtu is
# honest, and when it is not, what is.

MTU_WANT=

mtu_editor() { toml_set "$1" tun mtu "$MTU_WANT"; }

# One probe. -s is the payload, so the packet on the wire is 28 bytes larger:
# 20 of IP and 8 of ICMP. Getting that 28 wrong is the classic way to set an
# mtu a little too big and then lose exactly the full-size packets.
mtu_probe() {
    local dev=$1 peer=$2 total=$3
    ping -n -c1 -W2 -M do -s $((total - 28)) -I "$dev" "$peer" >/dev/null 2>&1
}

measure_mtu() {
    local name=$1 lo hi mid best=0 tries=0

    chk_load "$name" || { bad "there is no tunnel called $name"; return 1; }
    blank
    rule "Measure MTU for $name"
    blank

    if [ "$CK_TRANSPORT" = icmp ]; then
        dim "This cannot be measured on an ICMP tunnel. The core"
        dim "stops both kernels answering echo while one runs, so"
        dim "a probe is answered by nobody, every size looks too"
        dim "big, and the search sets the floor on no evidence."
        blank
        say "  Use a number instead of a measurement:"
        # Short enough to survive field's cut at UI_W-20 on a 60-column
        # terminal: a truncated explanation explains nothing.
        field "1320" "the default, and right on a 1500 path"
        field "1280" "survives PPPoE, mobile, double tunnels"
        blank
        if [ "$CK_MTU" != 1280 ] && confirm "set the mtu to 1280?" n; then
            MTU_WANT=1280
            # yes, not restart. cfg_apply compares its third argument against
            # the word yes, so the literal restart passed here read as "do not
            # restart" - and cfg_apply still returned 0, so this printed a
            # green line over a tunnel still running the old mtu until somebody
            # happened to restart it by hand.
            cfg_apply "$name" mtu_editor yes &&
                ok "mtu 1280 - set the same number on KHAREJ"
        fi
        return 0
    fi

    if [ ! -d "/sys/class/net/$CK_DEV" ]; then
        bad "$CK_DEV does not exist, so there is nothing to measure"
        fix "start the tunnel:  systemctl start pingify@$name"
        return 1
    fi

    dim "Probing $CK_PEER over $CK_DEV, don't-fragment set."
    dim "One ping per size, so this takes a few seconds."
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
        # Nothing crossed, not even the smallest legal packet. That is a dead
        # link or a firewall eating echo, and lowering the mtu on this evidence
        # would be exactly the wrong move: it would hide a real fault behind a
        # setting nobody would think to put back.
        bad "nothing crossed at any size: not an mtu problem"
        fix "check the tunnel first:  pingify --check $name"
        fix "echo may be blocked; the mtu was left alone"
        return 2
    fi

    if [ "$best" -ge "$CK_MTU" ]; then
        ok "$CK_MTU crosses intact, in $tries probes"
        dim "The device mtu is the ceiling, so more may work."
        return 0
    fi

    warn "the largest that crosses is $best, config says $CK_MTU"
    fix "the difference is lost as whole packets"
    blank
    if confirm "set the mtu to $best?" y; then
        MTU_WANT=$best
        # yes is the word cfg_apply tests for; restart quietly meant no, and
        # the measured mtu sat in the file unused.
        if cfg_apply "$name" mtu_editor yes; then
            ok "mtu $best"
            dim "Set the same on KHAREJ: the file is shared."
        fi
    fi
    return 1
}

# --------------------------------------------------------------------------
# the speed test
# --------------------------------------------------------------------------
#
# Honest, or nothing. Only one thing is reachable across a private /24 without
# cooperation from the far server - the far kernel's echo reply - and that is
# rate limited to about a thousand a second, so a figure built from it would be
# net.ipv4.icmp_msgs_per_sec reported as the link's throughput. The old
# bench_menu had the same shape of fault: it curl'd a third-party script that
# measured the machine's own path to the internet and printed the answer as if
# it were the tunnel.
#
# A real test needs a listener at the other end. Ask for one, use it, and when
# there is not one say so, and show what the link is actually carrying instead
# of inventing a number.

speed_test() {
    local name=$1 out rc ref

    chk_load "$name" || { bad "there is no tunnel called $name"; return 1; }
    blank
    rule "Speed test for $name"
    blank

    if [ "$(svc_state "$name")" != active ]; then
        bad "the tunnel is not running: nothing to push"
        fix "systemctl start pingify@$name"
        return 1
    fi
    if tun_stats "$name" && [ "$ST_UP" != true ]; then
        bad "the far end has not been seen; nothing is there"
        fix "check it first:  pingify --check $name"
        return 1
    fi

    say "  What the link is carrying right now:"
    field "in" "$(round1 "$ST_IN") Mbit/s"
    field "out" "$(round1 "$ST_OUT") Mbit/s"
    blank

    if ! have iperf3; then
        warn "iperf3 is missing, and it is the honest way"
        fix "apt-get install -y iperf3"
        fix "dnf install -y iperf3 on Rocky or Alma"
        blank
        dim "Nothing else on the far server can be pushed into,"
        dim "and a figure built from pings would measure the far"
        dim "kernel's echo rate limit, not this link."
        return 1
    fi

    dim "This needs a listener there. On KHAREJ, run:"
    say "       iperf3 -s"
    blank
    confirm "is it running there?" y || {
        dim "Nothing measured."
        return 1
    }

    # Sixteen streams and six seconds, so the answer is directly comparable
    # with the table the profiles come from: gaming 397 Mbit/s over 16 streams,
    # balanced 448, download 466. A four-stream figure would be smaller for
    # reasons that have nothing to do with this link.
    blank
    dim "16 streams for six seconds, matching the numbers"
    dim "the profiles were measured at."
    blank
    out=$(iperf3 -c "$CK_PEER" -t 6 -P 16 2>&1)
    rc=$?
    printf '%s\n' "$out" | sed 's/^/       /'
    blank

    if [ "$rc" -ne 0 ]; then
        bad "iperf3 did not finish"
        case $out in
        *"onnection refused"*)
            fix "nothing on $CK_PEER:5201 - run iperf3 -s there"
            ;;
        *"o route to host"* | *"imed out"*)
            fix "the link is up but nothing crosses it"
            fix "pingify --check $name"
            ;;
        *)
            fix "read the message above, then:"
            fix "pingify --check $name"
            ;;
        esac
        return 1
    fi

    case ${ST_PROFILE:-$(toml_get "$CK_FILE" tuning profile)} in
    gaming) ref="gaming measured 397 Mbit/s over 16 streams" ;;
    download) ref="download measured 466 Mbit/s over 16 streams" ;;
    *) ref="balanced measured 448 Mbit/s over 16 streams" ;;
    esac
    ok "done"
    dim "$ref on the reference path."
    dim "A slower path abroad reads lower; that is the path."
    return 0
}
