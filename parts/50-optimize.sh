
# ---------------------------------------------------------------------------
# server and network tuning
#
# The defaults on a stock Ubuntu image are sized for a datacentre LAN. An
# Iran <-> Europe path has ~40-120 ms of RTT and real packet loss, so the
# kernel needs far more room in flight and a congestion control that does not
# read loss as congestion.
# ---------------------------------------------------------------------------

apply_tuning() {
    local want_forward="${1:-no}"
    say ""
    if [ -f "$SYSCTL_FILE" ]; then
        dim "replacing the previous Pingify tuning"
    else
        # Keep one copy of whatever the box looked like before we touched it.
        [ -f "$STATE_DIR/sysctl.pre" ] || sysctl -a 2>/dev/null > "$STATE_DIR/sysctl.pre"
    fi

    if ! lsmod 2>/dev/null | grep -q '^tcp_bbr'; then
        modprobe tcp_bbr 2>/dev/null || true
    fi
    if ! grep -q '^tcp_bbr$' /etc/modules-load.d/pingify.conf 2>/dev/null; then
        echo tcp_bbr > /etc/modules-load.d/pingify.conf
    fi

    local cc="cubic"
    if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        cc="bbr"
    else
        warn "this kernel has no BBR; staying on cubic"
    fi

    cat > "$SYSCTL_FILE" <<SYSCTL
# Written by Pingify $PINGIFY_VERSION. Delete this file and run
# "sysctl --system" to go back to the distribution defaults.

# --- congestion control and queueing ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = $cc

# --- room in flight: 64 MB covers a 200 ms / 2.5 Gbit path ---
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 67108864
net.ipv4.tcp_wmem = 4096 1048576 67108864
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# --- behave sensibly on a long, slightly lossy path ---
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1

# --- connection churn ---
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 250000
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.ip_local_port_range = 10240 65535

# --- file descriptors ---
fs.file-max = 2097152
fs.nr_open = 2097152
SYSCTL

    if [ "$want_forward" = "yes" ]; then
        cat >> "$SYSCTL_FILE" <<'SYSCTL'

# --- routing, for full-IP tunnels ---
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
SYSCTL
    fi

    sysctl --system >/dev/null 2>&1
    ok "network tuning applied (congestion control: $cc, qdisc: fq)"

    if ! grep -q 'pingify' /etc/security/limits.d/99-pingify.conf 2>/dev/null; then
        cat > /etc/security/limits.d/99-pingify.conf <<'LIMITS'
# Pingify
*   soft  nofile  1048576
*   hard  nofile  1048576
root soft nofile  1048576
root hard nofile  1048576
LIMITS
        ok "file descriptor limits raised (log out and back in for shells)"
    fi
}

revert_tuning() {
    rm -f "$SYSCTL_FILE" /etc/security/limits.d/99-pingify.conf /etc/modules-load.d/pingify.conf
    sysctl --system >/dev/null 2>&1
    ok "Pingify tuning removed; the distribution defaults are back"
    dim "a reboot makes absolutely sure nothing is left over"
}

show_net_settings() {
    say ""
    printf '  %-34s %s\n' "congestion control" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    printf '  %-34s %s\n' "available" "$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)"
    printf '  %-34s %s\n' "default qdisc" "$(sysctl -n net.core.default_qdisc 2>/dev/null)"
    printf '  %-34s %s\n' "rmem_max" "$(sysctl -n net.core.rmem_max 2>/dev/null)"
    printf '  %-34s %s\n' "wmem_max" "$(sysctl -n net.core.wmem_max 2>/dev/null)"
    printf '  %-34s %s\n' "tcp_rmem" "$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null)"
    printf '  %-34s %s\n' "tcp_wmem" "$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null)"
    printf '  %-34s %s\n' "mtu probing" "$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null)"
    printf '  %-34s %s\n' "ip_forward" "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)"
    printf '  %-34s %s\n' "open file limit" "$(ulimit -n)"
    printf '  %-34s %s\n' "Pingify tuning file" "$([ -f "$SYSCTL_FILE" ] && echo present || echo absent)"
    say ""
}

manage_swap() {
    say ""
    local cur; cur="$(free -m | awk '/^Swap:/{print $2}')"
    dim "current swap: ${cur:-0} MB"
    if [ "${cur:-0}" -gt 0 ] 2>/dev/null; then
        if confirm "remove the existing Pingify swap file?"; then
            swapoff /swapfile 2>/dev/null || true
            sed -i '\#^/swapfile #d' /etc/fstab
            rm -f /swapfile
            ok "swap file removed"
            pause; return
        fi
    fi
    local mb=""
    ask mb "swap size in MB (0 to cancel)" "1024"
    case "$mb" in ''|*[!0-9]*|0) return ;; esac
    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile
    info "creating a ${mb}MB swap file"
    if ! fallocate -l "${mb}M" /swapfile 2>/dev/null; then
        dd if=/dev/zero of=/swapfile bs=1M count="$mb" status=none || { fail "could not create it"; pause; return; }
    fi
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1
    swapon /swapfile || { fail "swapon failed"; pause; return; }
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    sysctl -w vm.swappiness=10 >/dev/null 2>&1
    ok "swap ready"
    pause
}

optimize_menu() {
    while :; do
        banner
        head2 "Optimize Server & Network"
        item 1 "Apply network tuning" "(BBR + fq + high-BDP buffers)"
        item 2 "Apply network tuning" "+ enable IP forwarding (full-IP tunnels)"
        item 3 "Show the current settings"
        item 4 "Swap file"
        item 5 "Sync the clock" "(the handshake rejects a skewed clock)"
        item 6 "Revert every change Pingify made"
        item 0 "Back"
        say ""
        local c=""
        ask c "choose"
        case "$c" in
            1) apply_tuning no; pause ;;
            2) apply_tuning yes; pause ;;
            3) show_net_settings; pause ;;
            4) manage_swap ;;
            5) sync_clock; pause ;;
            6) say ""; confirm "revert the sysctl and limits changes?" && revert_tuning; pause ;;
            0|"") return ;;
        esac
    done
}

sync_clock() {
    say ""
    info "current time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    if have timedatectl; then
        timedatectl set-ntp true 2>/dev/null && ok "NTP synchronisation enabled"
        timedatectl status 2>/dev/null | sed 's/^/  /'
    else
        warn "timedatectl is missing; install systemd-timesyncd or chrony"
    fi
    dim "Pingify rejects a handshake more than 3 minutes out, so both servers"
    dim "must agree on the time."
}
