
# ---------------------------------------------------------------------------
# health
#
# The engine already reconnects a carrier on its own. This watchdog is the
# outer layer: it catches a wedged process, a tunnel that lost every carrier,
# and a service that failed to come back after a reboot.
# ---------------------------------------------------------------------------

HEALTH_STRIKES=3

run_health_check() {
    mkdir -p "$STATE_DIR"
    local n f addr fails
    for n in $(tunnel_names); do
        systemctl is-enabled --quiet "pingify@$n" 2>/dev/null || continue
        f="$CFG_DIR/$n.json"

        if ! systemctl is-active --quiet "pingify@$n"; then
            echo "pingify: $n is not running, starting it"
            systemctl restart "pingify@$n"
            echo 0 > "$STATE_DIR/$n.fail"
            continue
        fi

        addr="$(json_str "$f" status_addr)"
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
        read -rsn1 -t 2 key
        case "$key" in q|Q) return ;; esac
    done
}

health_menu() {
    while :; do
        banner
        head2 "Health & Monitoring"
        list_tunnels
        rule
        item 1 "Live status dashboard"
        item 2 "Run a health check right now"
        item 3 "Enable the watchdog timer"
        item 4 "Disable the watchdog timer"
        item 5 "Recent health log"
        item 6 "Restart every tunnel"
        item 0 "Back"
        say ""
        local c=""
        ask c "choose"
        case "$c" in
            1) live_dashboard ;;
            2) say ""; run_health_check | sed 's/^/  /'; ok "done"; pause ;;
            3) enable_watchdog; pause ;;
            4) disable_watchdog; pause ;;
            5) say ""; journalctl -u pingify-health.service -n 40 --no-pager | sed 's/^/  /'; pause ;;
            6) local n
               for n in $(tunnel_names); do systemctl restart "pingify@$n"; ok "restarted $n"; done
               pause ;;
            0|"") return ;;
        esac
    done
}
