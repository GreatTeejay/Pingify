
# ---------------------------------------------------------------------------
# health
#
# The core already reconnects a carrier on its own. This watchdog is the
# outer layer: it catches a wedged process, a tunnel that lost every carrier,
# and a service that failed to come back after a reboot.
# ---------------------------------------------------------------------------

HEALTH_STRIKES=3

run_health_check() {
    mkdir -p "$STATE_DIR"
    local n f addr fails
    for n in $(tunnel_names); do
        systemctl is-enabled --quiet "pingify@$n" 2>/dev/null || continue
        f="$(cfg_file "$n")"

        if ! systemctl is-active --quiet "pingify@$n"; then
            echo "pingify: $n is not running, starting it"
            systemctl restart "pingify@$n"
            echo 0 > "$STATE_DIR/$n.fail"
            continue
        fi

        addr="$(toml_get "$f" status addr)"
        if [ -z "$addr" ] || [ ! -x "$CORE_BIN" ]; then
            continue
        fi
        if "$CORE_BIN" -healthz "$addr" >/dev/null 2>&1; then
            echo 0 > "$STATE_DIR/$n.fail"
            continue
        fi

        fails="$(cat "$STATE_DIR/$n.fail" 2>/dev/null || echo 0)"
        case "$fails" in ''|*[!0-9]*) fails=0 ;; esac
        fails=$((fails + 1))
        echo "$fails" > "$STATE_DIR/$n.fail"
        echo "pingify: $n has no live carrier (strike $fails of $HEALTH_STRIKES)"
        if [ "$fails" -ge "$HEALTH_STRIKES" ]; then
            echo "pingify: restarting $n"
            systemctl restart "pingify@$n"
            echo 0 > "$STATE_DIR/$n.fail"
        fi
    done
}


# ---------------------------------------------------------------------------
# health check
#
# Every check that fails prints what to do about it. A report that says a
# thing is wrong and stops there leaves you exactly where you started, and the
# faults this tool actually hits are the same handful over and over - a stale
# core, a port nothing is listening on, a leftover NAT rule, a tunnel built one
# way on one server and the other way on the other.
#
# It only reports on what it can see from this machine, and says so where the
# answer is on the other one.
# ---------------------------------------------------------------------------

HC_BAD=0
HC_WARN=0

hc_ok()   { printf '  %s%s%s %s\n' "$C_GRN" "$MK_OK" "$C_OFF" "$1"; }
hc_bad()  { printf '  %s%s%s %s\n' "$C_RED" "$MK_NO" "$C_OFF" "$1"; HC_BAD=$((HC_BAD + 1)); }
hc_warn() { printf '  %s%s%s %s\n' "$C_YEL" "$MK_WARN" "$C_OFF" "$1"; HC_WARN=$((HC_WARN + 1)); }
hc_fix()  { printf '      %s%s fix:%s %s\n' "$C_CYN" "$BX_ARR" "$C_OFF" "$1"; }
hc_note() { printf '      %s%s%s\n' "$C_DIM" "$1" "$C_OFF"; }

health_check() {
    local name="$1" f
    f="$(cfg_file "$name")"
    [ -f "$f" ] || { fail "no such tunnel: $name"; return 1; }
    cfg_load "$name" || return 1
    cfg_endpoints

    HC_BAD=0; HC_WARN=0
    banner
    head2 "Health check: $name"
    say ""

    # --- the core and the script have to agree -----------------------------
    if [ ! -x "$CORE_BIN" ]; then
        hc_bad "the core is not installed"
        hc_fix "main menu ${BX_ARR} Core ${BX_ARR} install"
    elif ! core_matches_script; then
        hc_bad "core $(core_version) against script $PINGIFY_VERSION"
        hc_note "they read the same config file, so a mismatch rejects tunnels"
        hc_fix "main menu ${BX_ARR} Update Pingify"
    else
        hc_ok "core and script are both $PINGIFY_VERSION"
    fi

    # --- the service -------------------------------------------------------
    local state; state="$(svc_state "$name")"
    case "$state" in
        active) hc_ok "the service is running" ;;
        stopped)
            hc_bad "the service is stopped"
            hc_fix "systemctl start pingify@$name" ;;
        *)
            hc_bad "the service is $state"
            hc_fix "journalctl -u pingify@$name -n 40 --no-pager -o cat" ;;
    esac

    # --- the config itself -------------------------------------------------
    # A kernel tunnel has no core in the path, so the core has no opinion on
    # it. What can be checked instead is whether the kernel can still do what
    # the config asks for.
    if kernel_transport; then
        kernel_ready_check
    elif [ -x "$CORE_BIN" ]; then
        if "$CORE_BIN" -c "$f" -check >/dev/null 2>&1; then
            hc_ok "the config is valid"
        else
            hc_bad "the core rejects this config"
            "$CORE_BIN" -c "$f" -check 2>&1 | sed 's/^/      /'
            hc_fix "Manage ${BX_ARR} $name ${BX_ARR} Tuning, or edit $f"
        fi
    fi

    # --- carriers, or the one link a kernel tunnel has ---------------------
    local up=0 total="$T_CARRIERS" rtt="-" brief=""
    if [ "$state" = "active" ]; then
        if kernel_transport; then
            total=1
            brief="$(kernel_brief "$name")"
        elif [ -n "$T_STATUS" ] && [ -x "$CORE_BIN" ]; then
            brief="$("$CORE_BIN" -status "$T_STATUS" -brief 2>/dev/null)"
        fi
    fi
    if [ -n "$brief" ]; then
        set -- $brief
        up="$2"; [ "$3" != "0" ] && total="$3"; rtt="$4"
    fi

    if [ "$state" != "active" ]; then
        :
    elif kernel_transport && [ "$up" = "0" ]; then
        kernel_link_check "$name"
    elif [ -z "$brief" ]; then
        hc_bad "the status endpoint is not answering on $T_STATUS"
        hc_note "the core is running but has not opened it, or has just started"
        hc_fix "journalctl -u pingify@$name -n 20 --no-pager -o cat"
    elif [ "$up" = "0" ]; then
        hc_bad "no carrier is up (0 of $total)"
        if this_side_accepts; then
            hc_note "this end waits for the other one to connect"
            case "$T_TRANSPORT" in
                tcp)
                    hc_fix "check the other server is running, then open ${T_PORT}/tcp here:"
                    hc_note "ufw allow ${T_PORT}/tcp    (or the provider's firewall)"
                    hc_note "if it still will not hold, rebuild with Direct instead" ;;
                kcp)
                    hc_fix "open ${T_PORT}/udp here and in the provider firewall"
                    hc_note "ufw allow ${T_PORT}/udp" ;;
                pck)
                    hc_fix "open ${T_PORT}/tcp in the provider firewall and inspect the live log"
                    hc_note "PCK has no TCP listener; do not test it with ss or /dev/tcp"
                    hc_note "both servers need Linux, CAP_NET_RAW/root and iptables" ;;
                *)
                    hc_fix "check the other server is running and can ping this one" ;;
            esac
        else
            hc_note "this end dials ${CFG_CONNECT}"
            case "$T_TRANSPORT" in
                tcp)
                    hc_fix "check that port is open on the other server"
                    hc_note "from here:  timeout 5 bash -c '</dev/tcp/${CFG_CONNECT%:*}/${CFG_CONNECT##*:}' && echo open" ;;
                kcp)
                    hc_fix "open ${T_PORT}/udp on the other server and its provider firewall" ;;
                pck)
                    hc_fix "inspect both live logs for packet-socket or firewall-rule errors"
                    hc_note "PCK deliberately has no TCP handshake for /dev/tcp to test" ;;
                *)
                    hc_fix "check the other server answers a ping:  ping -c3 ${CFG_CONNECT}" ;;
            esac
        fi
        hc_note "and that both ends have the same security token"
    elif [ "$up" != "$total" ]; then
        hc_warn "$up of $total carriers are up"
        hc_note "some are being dropped - the path is lossy or something is trimming them"
        hc_fix "Manage ${BX_ARR} $name ${BX_ARR} Live log, and look for 'carrier .* down'"
    else
        hc_ok "$up of $total carriers up, $(rtt_tint "${rtt}ms") to the other server"
        # A long round trip is usually geography rather than a fault, so it
        # explains itself and is not counted as a problem.
        if rtt_slow "$rtt"; then
            hc_note "that is a long way round - anything interactive will feel it"
            hc_note "the other server being closer is the only thing that fixes it"
        fi
    fi

    # --- the forwarded ports, on the end that has them ---------------------
    #
    # What "bound" means depends on who forwards. Our core binds the port and
    # accepts on it. The kernel does not bind anything at all - a DNAT rule
    # rewrites the destination in PREROUTING, before any socket is consulted -
    # so asking whether something is listening reports a fault on every
    # working iptables tunnel, and offers a restart that cannot help.
    if [ "$T_ROLE" = "server" ] && [ -n "$T_FORWARDS" ]; then
        local p spec bad=0 rules=""
        [ "$T_FORWARDER" = "iptables" ] && have iptables \
            && rules="$(iptables -t nat -S PINGIFY_NAT 2>/dev/null)"
        for spec in $(printf '%s' "$T_FORWARDS" | tr -d '"' | tr ',' ' '); do
            p="${spec%%=*}"; p="${p#udp:}"; p="${p#tcp:}"; p="${p%%-*}"
            case "$p" in '' | *[!0-9]*) continue ;; esac
            if [ "$T_FORWARDER" = "iptables" ]; then
                if ! printf '%s' "$rules" | grep -q -- "--dport $p "; then
                    hc_bad "no forwarding rule for :$p"
                    hc_note "the kernel forwards this tunnel, so the port is not"
                    hc_note "bound here - it is rewritten on the way past"
                    hc_fix "pingify --apply-firewall"
                    bad=1
                fi
            elif port_free "$p"; then
                hc_bad "nothing is listening on :$p"
                hc_fix "systemctl restart pingify@$name"
                bad=1
            fi
        done
        if [ "$bad" = "0" ]; then
            if [ "$T_FORWARDER" = "iptables" ]; then
                hc_ok "every forwarded port has a rule here"
            else
                hc_ok "every forwarded port is bound here"
            fi
        fi
    fi

    # --- a leftover NAT rule eats a port silently --------------------------
    if have iptables && iptables -t nat -S PINGIFY_NAT >/dev/null 2>&1; then
        local rules; rules="$(iptables -t nat -S PINGIFY_NAT 2>/dev/null | grep -c ' -j DNAT')"
        if [ "${rules:-0}" != "0" ] && [ "$T_FORWARDER" != "iptables" ]; then
            hc_warn "$rules forwarding rules are installed but this tunnel does not use them"
            hc_note "a rule pointing at an address that has gone swallows every packet"
            hc_note "for that port, which looks exactly like a broken tunnel"
            hc_fix "pingify --apply-firewall     (rebuilds them from the configs)"
        fi
    fi

    # --- ICMP echo, on a tunnel that rides in it ---------------------------
    # The kernel answering an ordinary ping costs nothing, but it answers
    # every scanner on the internet, and this server is meant to look quiet.
    # It never touches our own traffic: the transport is a raw socket, which
    # the kernel copies to us regardless, and both ends send echo *replies*,
    # which the kernel never answers by itself. So the block is wanted here.
    if [ "$T_TRANSPORT" = "icmp" ]; then
        if [ "$(block_state icmp)" = "on" ]; then
            hc_ok "this server is not answering pings, which is what we want"
        else
            hc_warn "this server still answers ordinary pings"
            hc_note "the tunnel keeps working either way, but the server is"
            hc_note "louder than it needs to be and answers every scanner"
            hc_fix "main menu ${BX_ARR} Blocking ${BX_ARR} turn the ICMP block on"
        fi
    fi

    # PCK receives before conntrack but Linux still tries to answer the fake
    # established segments with RST. The core installs these narrow guards;
    # show a precise repair when a stripped-down VPS lacks iptables support.
    if [ "$T_TRANSPORT" = "pck" ]; then
        local pck_local_port="$T_PORT"
        this_side_accepts || pck_local_port="$(pck_source_port "$T_TOKEN" "$T_PORT")"
        if ! have iptables; then
            hc_bad "iptables is missing, so PCK cannot suppress kernel RST packets"
            hc_fix "install iptables, then restart pingify@$name"
        elif iptables -t filter -C OUTPUT -p tcp --sport "$pck_local_port" --tcp-flags RST RST -m comment --comment "pingify-pck-$pck_local_port" -j DROP >/dev/null 2>&1 &&
           iptables -t raw -C PREROUTING -p tcp --dport "$pck_local_port" -m comment --comment "pingify-pck-$pck_local_port" -j NOTRACK >/dev/null 2>&1 &&
           iptables -t raw -C OUTPUT -p tcp --sport "$pck_local_port" -m comment --comment "pingify-pck-$pck_local_port" -j NOTRACK >/dev/null 2>&1; then
            hc_ok "PCK RST and conntrack guards are installed"
        else
            hc_bad "PCK firewall guards are missing"
            hc_fix "systemctl restart pingify@$name, then inspect its first 30 log lines"
        fi
    fi

    # --- the far side ------------------------------------------------------
    # The probe is the only check here that reaches past this machine, and
    # its verdict has to reach the summary: a report that lists a port the
    # other server could not reach and then says nothing is wrong is worse
    # than no report at all.
    # Not for a kernel tunnel: the probe is part of the core, and the core
    # cannot even read a config for a transport it does not run. Asking it
    # anyway produced a rejection and then blamed the far server for it.
    if [ "$T_ROLE" = "server" ] && [ "$up" != "0" ] && [ -n "$T_FORWARDS" ]        && ! kernel_transport; then
        say ""
        head2 "Through the tunnel"
        local out rc
        out="$("$CORE_BIN" -c "$f" -probe 2>&1)"; rc=$?
        # the carrier line is already above, in this report's own words
        printf '%s\n' "$out" | sed '/carriers up,/d' | sed 's/^/  /'
        # 3 means nothing came back at all, which is a different machine's
        # problem from a port that could not be reached - and used to be
        # reported as the same one, sending the reader to check a listening
        # socket that was listening perfectly well.
        if [ "$rc" = "3" ]; then
            say ""
            hc_bad "nothing is coming back from the other server at all"
            hc_note "the carriers are up, so the handshake crossed both ways -"
            hc_note "then the return direction stopped. A silent service would"
            hc_note "still leave the keepalives flowing, and they are not"
            hc_fix "try the same two servers on a TCP tunnel, same port"
            hc_note "if TCP carries both ways and this does not, the difference"
            hc_note "is something on the path reading what this transport sends"
        elif [ "$rc" != "0" ]; then
            say ""
            hc_bad "a forwarded port did not reach the service on the other server"
            hc_note "this end is fine - the tunnel carried the test across"
            hc_note "and the far end is where it stopped"
            hc_fix "on the KHAREJ server:  ss -ltnp | grep <the port after the arrow>"
            hc_note "whatever should answer there is not listening on that address"
        fi
    fi

    # A kernel tunnel gets the same question asked a different way: not
    # through the core, which is not in this path, but across the private link
    # the kernel built - which is the route real traffic takes.
    if [ "$T_ROLE" = "server" ] && [ "$up" != "0" ] && kernel_transport; then
        say ""
        head2 "Through the tunnel"
        kernel_probe "$name" || {
            say ""
            hc_note "everything on this server is doing its part"
        }
    fi

    # --- what it comes to --------------------------------------------------
    say ""
    rule
    if [ "$HC_BAD" = "0" ] && [ "$HC_WARN" = "0" ]; then
        ok "nothing wrong on this server"
        dim "if the tunnel still misbehaves, run this on the other one too"
    elif [ "$HC_BAD" = "0" ]; then
        warn "$HC_WARN thing$([ "$HC_WARN" = "1" ] || echo s) worth looking at"
    else
        fail "$HC_BAD problem$([ "$HC_BAD" = "1" ] || echo s), $HC_WARN warning$([ "$HC_WARN" = "1" ] || echo s)"
        dim "each one has a fix under it"
    fi
    pause
}

enable_watchdog() {
    write_units
    systemctl enable --now pingify-health.timer >/dev/null 2>&1
    [ "${1:-}" = "quiet" ] || ok "watchdog enabled (checks every 30s)"
}

disable_watchdog() {
    systemctl disable --now pingify-health.timer >/dev/null 2>&1
    ok "watchdog disabled"
}

watchdog_state() {
    if systemctl is-enabled --quiet pingify-health.timer 2>/dev/null; then
        printf 'on'
    else
        printf 'off'
    fi
}

live_dashboard() {
    local key=""
    while :; do
        banner
        head2 "Live status"
        list_tunnels
        rule
        say "  ${C_DIM}watchdog: $(watchdog_state)   $(uptime | sed 's/^ *//')${C_OFF}"
        say ""
        dim "  refreshing every 2s - enter or q to go back"
        # read returns 0 only when a key actually arrived, and non-zero when
        # the two seconds ran out. Without that test an empty key means both
        # "the user pressed enter" and "nothing happened", so enter did
        # nothing and the only way out of here was to kill the script.
        if read -rsn1 -t 2 key; then
            case "$key" in q|Q|0|"") return ;; esac
        fi
    done
}

health_menu() {
    while :; do
        banner
        head2 "Health"
        list_tunnels
        rule
        item 1 "Health check" "what is wrong, and what to do about it"
        item 2 "Live status dashboard"
        item 3 "Enable the watchdog"
        item 4 "Disable the watchdog"
        item 5 "Recent health log"
        item 6 "Restart every tunnel"
        item 0 "Back"
        say ""
        local c=""
        ask c "select"
        case "$c" in
            1) if pick_tunnel; then health_check "$PICKED"; fi ;;
            2) live_dashboard ;;
            3) enable_watchdog; pause ;;
            4) disable_watchdog; pause ;;
            5) say ""; journalctl -u pingify-health.service -n 40 --no-pager -o cat | sed 's/^/  /'; pause ;;
            6) local n
               for n in $(tunnel_names); do systemctl restart "pingify@$n"; ok "restarted $n"; done
               pause ;;
            0|"") return ;;
        esac
    done
}
