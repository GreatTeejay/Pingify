
# ---------------------------------------------------------------------------
# server and network tuning
#
# The defaults on a stock Ubuntu image are sized for a datacentre LAN. An
# Iran <-> Europe path has ~40-120 ms of RTT and real packet loss, so the
# kernel needs far more room in flight and a congestion control that does not
# read loss as congestion.
# ---------------------------------------------------------------------------

FORWARD_SYSCTL_FILE="/etc/sysctl.d/97-pingify-forward.conf"

apply_tuning() {
    local profile="${1:-balanced}" want_forward="${2:-no}"
    local sockbuf default_buf udp_min backlog budget budget_us syn_backlog
    case "$profile" in
        gaming)
            sockbuf=33554432; default_buf=524288; udp_min=131072
            backlog=100000; budget=300; budget_us=2000; syn_backlog=16384 ;;
        throughput)
            sockbuf=134217728; default_buf=4194304; udp_min=524288
            backlog=300000; budget=1200; budget_us=8000; syn_backlog=65535 ;;
        *)
            profile="balanced"
            sockbuf=67108864; default_buf=1048576; udp_min=262144
            backlog=200000; budget=600; budget_us=4000; syn_backlog=32768 ;;
    esac
    say ""
    if [ -f "$SYSCTL_FILE" ]; then
        dim "replacing the previous Pingify tuning"
    else
        # Keep one copy of whatever the box looked like before we touched it.
        [ -f "$STATE_DIR/sysctl.pre" ] || sysctl -a 2>/dev/null > "$STATE_DIR/sysctl.pre"
    fi

    cat > "$SYSCTL_FILE" <<SYSCTL
# Written by Pingify $PINGIFY_VERSION. Delete this file and run
# "sysctl --system" to go back to the distribution defaults.
# profile: ${profile}

# --- room in flight and packet bursts ---
net.core.rmem_max = ${sockbuf}
net.core.wmem_max = ${sockbuf}
net.core.rmem_default = ${default_buf}
net.core.wmem_default = ${default_buf}
net.core.optmem_max = 4194304
net.ipv4.tcp_rmem = 4096 ${default_buf} ${sockbuf}
net.ipv4.tcp_wmem = 4096 ${default_buf} ${sockbuf}
net.ipv4.udp_rmem_min = ${udp_min}
net.ipv4.udp_wmem_min = ${udp_min}

# --- behave sensibly on a long, slightly lossy path ---
net.core.default_qdisc = fq
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1

# --- drain NIC bursts without starving interactive work ---
net.core.netdev_max_backlog = ${backlog}
net.core.netdev_budget = ${budget}
net.core.netdev_budget_usecs = ${budget_us}

# --- connection churn ---
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = ${syn_backlog}
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_max_tw_buckets = 1000000
net.ipv4.ip_local_port_range = 10240 65535

# --- file descriptors ---
fs.file-max = 2097152
fs.nr_open = 2097152
vm.swappiness = 10
SYSCTL

    if [ "$want_forward" = "yes" ]; then
        cat >> "$SYSCTL_FILE" <<'SYSCTL'

# --- routing, for full-IP tunnels ---
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
SYSCTL
    fi

    sysctl --system >/dev/null 2>&1 || true
    ok "${profile} host tuning applied"
    dim "congestion control is a separate switch - see Enable BBR"

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

choose_tuning_profile() {
    say ""
    head2 "Host tuning profile"
    choice 1 "Balanced" "recommended - video, browsing and games together"
    choice 2 "Gaming" "smaller queues and shorter NIC work cycles"
    choice 3 "Throughput" "large packet batches and a 128 MB socket ceiling"
    say ""
    local c=""
    ask c "select" "1"
    case "$c" in
        2) apply_tuning gaming no ;;
        3) apply_tuning throughput no ;;
        *) apply_tuning balanced no ;;
    esac
}

enable_forwarding() {
    cat > "$FORWARD_SYSCTL_FILE" <<'SYSCTL'
# Written by Pingify for Full IP / kernel-forwarded tunnels.
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
SYSCTL
    sysctl --system >/dev/null 2>&1 || true
    ok "IPv4 and IPv6 forwarding enabled"
}

# BBR is its own switch: it is the one change with a visible effect on a slow
# path, and people want to turn it on or off without touching everything else.
enable_bbr() {
    say ""
    if ! lsmod 2>/dev/null | grep -q '^tcp_bbr'; then
        modprobe tcp_bbr 2>/dev/null || true
    fi
    if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        fail "this kernel does not offer BBR"
        dim "kernel $(uname -r); a 4.9 or newer kernel with tcp_bbr is needed"
        return 1
    fi
    echo tcp_bbr > /etc/modules-load.d/pingify.conf
    cat > /etc/sysctl.d/98-pingify-bbr.conf <<'SYSCTL'
# Written by Pingify. Delete this file and run "sysctl --system" to undo it.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
SYSCTL
    sysctl --system >/dev/null 2>&1
    ok "BBR enabled with the fq queue discipline"
    dim "now: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) / $(sysctl -n net.core.default_qdisc 2>/dev/null)"
}

disable_bbr() {
    say ""
    rm -f /etc/sysctl.d/98-pingify-bbr.conf /etc/modules-load.d/pingify.conf
    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
    sysctl --system >/dev/null 2>&1
    ok "back to $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
}

revert_tuning() {
    rm -f "$SYSCTL_FILE" /etc/security/limits.d/99-pingify.conf \
          /etc/modules-load.d/pingify.conf /etc/sysctl.d/98-pingify-bbr.conf \
          "$FORWARD_SYSCTL_FILE"
    sysctl --system >/dev/null 2>&1
    ok "Pingify tuning removed; the distribution defaults are back"
    dim "a reboot makes absolutely sure nothing is left over"
}

show_net_settings() {
    say ""
    printf '  %-34s %s\n' "Pingify profile" "$(sed -n 's/^# profile: //p' "$SYSCTL_FILE" 2>/dev/null | head -n1)"
    printf '  %-34s %s\n' "congestion control" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    printf '  %-34s %s\n' "available" "$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)"
    printf '  %-34s %s\n' "default qdisc" "$(sysctl -n net.core.default_qdisc 2>/dev/null)"
    printf '  %-34s %s\n' "rmem_max" "$(sysctl -n net.core.rmem_max 2>/dev/null)"
    printf '  %-34s %s\n' "wmem_max" "$(sysctl -n net.core.wmem_max 2>/dev/null)"
    printf '  %-34s %s\n' "tcp_rmem" "$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null)"
    printf '  %-34s %s\n' "tcp_wmem" "$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null)"
    printf '  %-34s %s\n' "mtu probing" "$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null)"
    printf '  %-34s %s\n' "packet backlog" "$(sysctl -n net.core.netdev_max_backlog 2>/dev/null)"
    printf '  %-34s %s / %s us\n' "packet budget" "$(sysctl -n net.core.netdev_budget 2>/dev/null)" "$(sysctl -n net.core.netdev_budget_usecs 2>/dev/null)"
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

host_tuning_label() {
    [ -f "$SYSCTL_FILE" ] || { printf 'default'; return; }
    local p
    p="$(sed -n 's/^# profile: //p' "$SYSCTL_FILE" 2>/dev/null | head -n1)"
    printf '%s' "${p:-legacy}"
}

optimize_menu() {
    while :; do
        banner
        head2 "Optimize"
        panel "CURRENT"
        field "Congestion" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" \
              "Qdisc" "$(sysctl -n net.core.default_qdisc 2>/dev/null)"
        field "Tuning" "$(host_tuning_label)" "Open files" "$(ulimit -n)"
        panel_end
        say ""
        item 1 "Apply host tuning" "Balanced, Gaming or Throughput"
        item 2 "Enable BBR" "congestion control and fq"
        item 3 "Disable BBR" "back to the kernel default"
        say ""
        item 4 "Enable IP forwarding" "needed for Full IP tunnels"
        item 5 "Swap file"
        item 6 "Sync the clock" "the handshake rejects a skewed clock"
        say ""
        item 7 "Show all settings"
        item 8 "Revert everything Pingify changed"
        item 0 "Back"
        say ""
        local c=""
        ask c "select"
        case "$c" in
            1) choose_tuning_profile; pause ;;
            2) enable_bbr; pause ;;
            3) disable_bbr; pause ;;
            4) enable_forwarding; pause ;;
            5) manage_swap ;;
            6) sync_clock; pause ;;
            7) show_net_settings; pause ;;
            8) say ""; confirm "revert the sysctl and limits changes?" && revert_tuning; pause ;;
            0 | "") return ;;
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
