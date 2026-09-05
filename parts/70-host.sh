#!/usr/bin/env bash
#
# Things done to the machine rather than to a tunnel: kernel tuning, and
# blocking. Everything this file changes, it owns outright and can take back.
#
# The kernel settings are one drop-in file, so revert is deleting one file,
# and the file carries its own state in two comment lines. The firewall rules
# are two chains of our own, hooked into INPUT and OUTPUT at position 1 and
# rebuilt from empty on every apply; the state files are the truth.
#
# One sysctl is deliberately absent. net.ipv4.icmp_echo_ignore_all belongs to
# the ICMP carrier: the core sets it while an ICMP tunnel runs, because both
# ends send echo requests and a kernel that answers them doubles every packet
# on the wire, and the manager gives it back when the last one stops.

HOST_SYSCTL=/etc/sysctl.d/99-pingify.conf
HOST_LIMITS=/etc/security/limits.d/99-pingify.conf
SYSCTL_FILE=$HOST_SYSCTL

SPEEDTEST_HOSTS="speedtest.net ooklaserver.net speedtestcustom.com fast.com
nperf.com speedof.me openspeedtest.com speedcheck.org librespeed.org
speedtest.cn"
HOSTS_MARK='# --- pingify speedtest block ---'
HOSTS_END='# --- end pingify ---'

# ---------------------------------------------------------------------------
# host tuning
# ---------------------------------------------------------------------------

host_profile() {
    awk '/^# profile: /{ sub(/^# profile: /, ""); print; exit }' "$HOST_SYSCTL" 2>/dev/null
}
host_tuning_label() {
    local p
    p=$(host_profile)
    printf '%s' "${p:-default}"
}

host_bbr_state() {
    local s
    s=$(awk '/^# bbr: /{ sub(/^# bbr: /, ""); print; exit }' "$HOST_SYSCTL" 2>/dev/null)
    printf '%s' "${s:-off}"
}

host_bbr_available() {
    modprobe tcp_bbr 2>/dev/null || true
    local avail
    avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
    # shellcheck disable=SC2086
    list_has bbr $avail
}

# host_write_sysctl writes the whole drop-in from scratch. The three profiles
# differ in one idea: how much the kernel may hold for a socket, and how long
# it may spend draining the card in one go. The ceiling is not for one stream
# - it is for the sixteen that arrive at once when a household starts using
# the link.
host_write_sysctl() {
    local profile=$1 bbr=$2 sockbuf defbuf udpmin backlog budget budget_us
    case $profile in
    gaming)
        sockbuf=33554432 defbuf=524288 udpmin=131072
        backlog=100000 budget=300 budget_us=2000 ;;
    download | throughput)
        profile=download
        sockbuf=134217728 defbuf=4194304 udpmin=524288
        backlog=300000 budget=1200 budget_us=8000 ;;
    *)
        profile=balanced
        sockbuf=67108864 defbuf=1048576 udpmin=262144
        backlog=200000 budget=600 budget_us=4000 ;;
    esac
    cat >"$HOST_SYSCTL" <<SYSCTL || { fail "could not write $HOST_SYSCTL"; return 1; }
# Written by Pingify $PINGIFY_VERSION. Delete this file, run "sysctl --system",
# and the distribution's own settings are what is left.
# profile: $profile
# bbr: $bbr

# Room in flight. A long path with real loss needs far more than a datacentre
# LAN, which is what the stock numbers are sized for.
net.core.rmem_max = $sockbuf
net.core.wmem_max = $sockbuf
net.core.rmem_default = $defbuf
net.core.wmem_default = $defbuf
net.core.optmem_max = 4194304
net.ipv4.tcp_rmem = 4096 $defbuf $sockbuf
net.ipv4.tcp_wmem = 4096 $defbuf $sockbuf
net.ipv4.udp_rmem_min = $udpmin
net.ipv4.udp_wmem_min = $udpmin

# Behave on a long path.
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1

# Drain the card's bursts without starving everything else.
net.core.netdev_max_backlog = $backlog
net.core.netdev_budget = $budget
net.core.netdev_budget_usecs = $budget_us

# Connection churn, and the descriptors it needs.
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 32768
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.ip_local_port_range = 10240 65535
fs.file-max = 2097152
fs.nr_open = 2097152
vm.swappiness = 10
SYSCTL
    if [ "$bbr" = on ]; then
        cat >>"$HOST_SYSCTL" <<'SYSCTL' || { fail "could not add the BBR lines"; return 1; }

# fq is the queue discipline BBR is designed against.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
SYSCTL
    fi
    if ! sysctl --system >/dev/null 2>&1; then
        warn "the kernel would not take some of those settings"
        fix "sysctl --system   prints the line it refused"
        return 1
    fi
    return 0
}

apply_tuning() {
    local profile=${1:-balanced}
    host_write_sysctl "$profile" "$(host_bbr_state)" || return 1
    ok "$(host_profile) host tuning applied"
    dim "congestion control is a separate switch - see Enable BBR"
    host_limits quiet
}

choose_tuning_profile() {
    blank
    head2 "Host tuning profile"
    CHOICE_DEF=1
    choice 1 "Balanced" "recommended - video, browsing and games together"
    choice 2 "Gaming" "smaller queues and shorter NIC work cycles"
    choice 3 "Download" "large packet batches and a 128 MB socket ceiling"
    CHOICE_DEF=
    blank
    dim "This sets the kernel's socket buffer sizes and backlog, for everything"
    dim "this server does. A tunnel's own profile is a different thing with the"
    dim "same three names; it lives on that tunnel's Tuning screen."
    blank
    local c
    pick c "select" 1 3 || return 1
    case $c in
    2) apply_tuning gaming ;;
    3) apply_tuning download ;;
    *) apply_tuning balanced ;;
    esac
}

# host_limits raises the descriptor ceiling for logins. systemd units get
# theirs from the unit; this is for the shell you ssh in with.
host_limits() {
    cat >"$HOST_LIMITS" <<'LIMITS' || { fail "could not write $HOST_LIMITS"; return 1; }
# Written by Pingify. Delete this file to undo it.
*    soft  nofile  1048576
*    hard  nofile  1048576
root soft  nofile  1048576
root hard  nofile  1048576
LIMITS
    [ "${1:-}" = quiet ] && return 0
    ok "descriptor limit raised to 1048576"
    dim "PAM reads this at login, so this shell keeps the $(ulimit -n) it started with"
}

enable_bbr() {
    blank
    if ! host_bbr_available; then
        fail "this kernel does not offer BBR"
        dim "kernel $(uname -r); a 4.9 or newer kernel with tcp_bbr is needed"
        return 1
    fi
    host_write_sysctl "$(host_profile)" on || return 1
    ok "BBR enabled with the fq queue discipline"
    dim "now: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) / $(sysctl -n net.core.default_qdisc 2>/dev/null)"
}

disable_bbr() {
    blank
    host_write_sysctl "$(host_profile)" off || return 1
    sysctl -qw net.ipv4.tcp_congestion_control=cubic net.core.default_qdisc=fq_codel >/dev/null 2>&1
    ok "back to $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
}

enable_forwarding() {
    nat_ip_forward && ok "IPv4 forwarding is on, and stays on after a reboot"
}

revert_tuning() {
    rm -f "$HOST_SYSCTL" "$HOST_LIMITS" /etc/sysctl.d/98-pingify-bbr.conf /etc/modules-load.d/pingify.conf \
        /etc/sysctl.d/97-pingify-forward.conf
    sysctl --system >/dev/null 2>&1 || true
    ok "Pingify's tuning and limits files are gone; the distribution defaults are back"
    dim "a value we raised stays raised until this machine reboots, because nothing"
    dim "recorded what the kernel held before; a reboot makes absolutely sure"
}

show_net_settings() {
    blank
    printf '  %-34s %s\n' "Pingify profile" "$(host_tuning_label)"
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
    printf '  %-34s %s\n' "icmp_echo_ignore_all" "$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null)"
    printf '  %-34s %s\n' "open file limit" "$(ulimit -n)"
    printf '  %-34s %s\n' "Pingify tuning file" "$([ -f "$HOST_SYSCTL" ] && echo present || echo absent)"
    blank
}

manage_swap() {
    blank
    local cur mb
    cur=$(free -m 2>/dev/null | awk '/^Swap:/{print $2}')
    dim "current swap: ${cur:-0} MB"
    if [ "${cur:-0}" -gt 0 ] 2>/dev/null && [ -f /swapfile ]; then
        if confirm "remove the existing Pingify swap file?"; then
            swapoff /swapfile 2>/dev/null || true
            sed_i '\#^/swapfile #d' /etc/fstab
            rm -f /swapfile
            ok "swap file removed"
            pause; return
        fi
    fi
    ask mb "swap size in MB (0 to cancel)" "1024" v_number || return
    [ "$mb" = 0 ] && return
    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile
    info "creating a ${mb}MB swap file"
    if ! fallocate -l "${mb}M" /swapfile 2>/dev/null; then
        dd if=/dev/zero of=/swapfile bs=1M count="$mb" status=none 2>/dev/null || { fail "could not create it"; pause; return; }
    fi
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1
    swapon /swapfile || { fail "swapon failed"; pause; return; }
    grep -q '^/swapfile ' /etc/fstab 2>/dev/null || echo '/swapfile none swap sw 0 0' >>/etc/fstab
    sysctl -qw vm.swappiness=10 >/dev/null 2>&1
    ok "swap ready"
    pause
}

sync_clock() {
    blank
    info "current time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    if have timedatectl; then
        timedatectl set-ntp true 2>/dev/null && ok "NTP synchronisation enabled"
        timedatectl status 2>/dev/null | sed 's/^/  /'
    else
        warn "timedatectl is missing; install systemd-timesyncd or chrony"
    fi
}

optimize_menu() {
    local c
    while :; do
        banner
        head2 "Optimize"
        panel "CURRENT"
        panel_field "Congestion" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" \
            "Qdisc" "$(sysctl -n net.core.default_qdisc 2>/dev/null)"
        panel_field "Tuning" "$(host_tuning_label)" "Open files" "$(ulimit -n)"
        panel_field "BBR" "$(state_badge "$(host_bbr_state)")" "Forwarding" "$(sysctl -n net.ipv4.ip_forward 2>/dev/null | sed 's/^1$/on/; s/^0$/off/')"
        panel_end
        blank
        item 1 "Apply host tuning" "Balanced, Gaming or Download"
        item 2 "Enable BBR" "congestion control and fq - measured: 348 Mbit/s where cubic carried 31"
        item 3 "Disable BBR" "back to the kernel default"
        blank
        item 4 "Enable IP forwarding" "a TUN tunnel's ports need it; the manager turns it on itself"
        item 5 "Swap file"
        item 6 "Sync the clock"
        blank
        item 7 "Show all settings"
        item 8 "Revert everything Pingify changed"
        item 0 "Back"
        blank
        menu_key c || return 0
        case $c in
        1) choose_tuning_profile; pause ;;
        2) enable_bbr; pause ;;
        3) disable_bbr; pause ;;
        4) blank; enable_forwarding; pause ;;
        5) manage_swap ;;
        6) sync_clock; pause ;;
        7) show_net_settings; pause ;;
        8) blank; confirm "revert the sysctl and limits changes?" && revert_tuning; pause ;;
        0 | '') return 0 ;;
        esac
    done
}
screen_host() { optimize_menu; }

# ---------------------------------------------------------------------------
# blocking
#
# Three switches people running a tunnel keep reaching for: stop the server
# answering pings, keep clients off benchmark sites, and reject QUIC so
# browsers fall back to TCP. Everything goes in Pingify's own chains, so
# nothing here touches rules you or your panel put in place, and a boot unit
# re-applies the state files, because iptables rules do not survive a reboot.
# ---------------------------------------------------------------------------

block_ipt() { iptables -w 2 "$@" 2>/dev/null; }
block_state() { [ -f "$STATE_DIR/block-$1" ] && printf 'on' || printf 'off'; }

block_summary() {
    local out=
    [ "$(block_state icmp)" = on ] && out="${out}icmp "
    [ "$(block_state speedtest)" = on ] && out="${out}speedtest "
    [ "$(block_state quic)" = on ] && out="${out}quic "
    [ -n "$out" ] && printf '%s' "${out% }" || printf 'none'
}

block_toggle() {
    local what=$1
    ensure_dirs
    if [ -f "$STATE_DIR/block-$what" ]; then rm -f "$STATE_DIR/block-$what"
    else : >"$STATE_DIR/block-$what"; fi
}

# block_tun_ifaces is every private-link device this server has or will have.
block_tun_ifaces() {
    local n d out= p
    for n in $(cfg_list); do
        d=$(toml_get "$(cfg_file "$n")" tun name)
        [ -n "$d" ] || continue
        # shellcheck disable=SC2086
        list_has "$d" $out || out="$out $d"
    done
    for p in /sys/class/net/pfy*; do
        [ -e "$p" ] || continue
        d=${p##*/}
        # shellcheck disable=SC2086
        list_has "$d" $out || out="$out $d"
    done
    printf '%s' "${out# }"
}

block_icmp_tunnel() {
    local n
    for n in $(cfg_list); do
        [ "$(toml_get "$(cfg_file "$n")" transport type)" = icmp ] && return 0
    done
    return 1
}

block_carrier_443() {
    local n f
    while IFS= read -r n; do
        f=$(cfg_file "$n")
        [ "$(toml_get "$f" transport type)" = udp ] || continue
        [ "$(toml_get "$f" transport port)" = 443 ] || continue
        printf '%s' "$n"
        return 0
    done < <(cfg_list)
    return 1
}

# block_carrier_accept puts this server's own carrier out of reach of the
# string match, which would otherwise reject the packet carrying a customer's
# request for speedtest.net through the tunnel.
block_carrier_accept() {
    local n f t p rc=0 icmp_done=0
    while IFS= read -r n; do
        f=$(cfg_file "$n")
        t=$(toml_get "$f" transport type)
        if [ "$t" = icmp ]; then
            [ "$icmp_done" = 1 ] && continue
            icmp_done=1
            block_ipt -A PINGIFY_OUT -p icmp -j ACCEPT || rc=1
            continue
        fi
        [ "$t" = gre ] && { block_ipt -A PINGIFY_OUT -p gre -j ACCEPT || rc=1; continue; }
        p=$(toml_get "$f" transport port)
        [ "$t" = awg ] && p=$(toml_get "$f" awg port)
        case $p in '' | *[!0-9]*) continue ;; esac
        case $(port_family "$t") in
        udp) block_ipt -A PINGIFY_OUT -p udp --dport "$p" -j ACCEPT || rc=1
             block_ipt -A PINGIFY_OUT -p udp --sport "$p" -j ACCEPT || rc=1 ;;
        tcp) block_ipt -A PINGIFY_OUT -p tcp --dport "$p" -j ACCEPT || rc=1
             block_ipt -A PINGIFY_OUT -p tcp --sport "$p" -j ACCEPT || rc=1 ;;
        esac
    done < <(cfg_list)
    return "$rc"
}

block_reset_chains() {
    local c
    for c in PINGIFY_IN PINGIFY_OUT; do
        block_ipt -N "$c" || block_ipt -F "$c" || return 1
    done
    block_ipt -C INPUT -j PINGIFY_IN || block_ipt -I INPUT 1 -j PINGIFY_IN
    block_ipt -C OUTPUT -j PINGIFY_OUT || block_ipt -I OUTPUT 1 -j PINGIFY_OUT
    return 0
}

block_drop_chains() {
    local c i rc=0
    for i in 1 2 3 4 5; do block_ipt -D INPUT -j PINGIFY_IN || break; done
    for i in 1 2 3 4 5; do block_ipt -D OUTPUT -j PINGIFY_OUT || break; done
    for i in 1 2 3; do block_ipt -D FORWARD -j PINGIFY_FWD || break; done
    for c in PINGIFY_IN PINGIFY_OUT PINGIFY_FWD; do
        block_ipt -F "$c"
        block_ipt -X "$c"
    done
    for c in PINGIFY_IN PINGIFY_OUT; do
        block_ipt -S "$c" >/dev/null 2>&1 && rc=1
    done
    return "$rc"
}

hosts_block_off() {
    grep -qF "$HOSTS_MARK" /etc/hosts 2>/dev/null || return 0
    local tmp
    tmp=$(mktemp)
    awk -v a="$HOSTS_MARK" -v b="$HOSTS_END" '
        $0 == a { skip = 1; next }
        $0 == b { skip = 0; next }
        !skip
    ' /etc/hosts >"$tmp" && cat "$tmp" >/etc/hosts
    rm -f "$tmp"
}

hosts_block_on() {
    hosts_block_off
    {
        printf '%s\n' "$HOSTS_MARK"
        local h
        for h in $SPEEDTEST_HOSTS; do
            case $h in *[!a-zA-Z0-9.-]*) continue ;; esac
            printf '127.0.0.1 %s\n127.0.0.1 www.%s\n' "$h" "$h"
        done
        printf '%s\n' "$HOSTS_END"
    } >>/etc/hosts
}

# apply_blocking is the only thing that writes rules, and it writes all of
# them every time from the state files.
apply_blocking() {
    local quiet=${1:-} ifc h any rc=0 carrier
    have iptables || {
        [ "$quiet" = quiet ] || warn "iptables is not installed, so nothing was applied"
        return 1
    }
    ensure_dirs
    block_reset_chains || {
        [ "$quiet" = quiet ] || fail "iptables would not give us our chains"
        return 1
    }

    if [ "$(block_state icmp)" = on ]; then
        # The private link first: a ping across it is the one test the
        # operator has, and it is the far end's INPUT chain that answers it.
        for ifc in $(block_tun_ifaces); do
            block_ipt -A PINGIFY_IN -i "$ifc" -p icmp --icmp-type echo-request -j ACCEPT || rc=1
        done
        # Where a tunnel on this host uses the icmp transport, the blanket
        # drop is left out: the carrier's own echo requests arrive on the
        # public interface, INPUT is traversed before a raw socket is fed,
        # and the core has already stopped the kernel answering pings anyway.
        if block_icmp_tunnel; then
            [ "$quiet" = quiet ] || dim "an ICMP tunnel is configured, so the blanket drop is left out - the core has already stopped this host answering pings"
        else
            block_ipt -A PINGIFY_IN -p icmp --icmp-type echo-request -j DROP || rc=1
        fi
    fi

    if [ "$(block_state quic)" = on ]; then
        if carrier=$(block_carrier_443); then
            [ "$quiet" = quiet ] || dim "$carrier carries on udp 443, so the QUIC rules are left out"
        else
            block_ipt -A PINGIFY_OUT -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable || rc=1
            block_ipt -A PINGIFY_IN -p udp --dport 443 -j DROP || rc=1
        fi
    fi

    if [ "$(block_state speedtest)" = on ]; then
        hosts_block_on
        block_carrier_accept || rc=1
        any=0
        for h in $SPEEDTEST_HOSTS; do
            case $h in *[!a-zA-Z0-9.-]*) continue ;; esac
            block_ipt -A PINGIFY_OUT -m string --string "$h" --algo bm -j REJECT && any=1
        done
        if [ "$any" = 0 ] && [ "$quiet" != quiet ]; then
            warn "this kernel has no string match, so only the hosts file is blocking"
        fi
    else
        hosts_block_off
    fi

    firewall_unit_write || rc=1
    if [ "$rc" != 0 ]; then
        [ "$quiet" = quiet ] || { fail "some of those rules would not go in"; fix "iptables -S PINGIFY_OUT   shows what did"; }
        return 1
    fi
    [ "$quiet" = quiet ] || ok "blocking rules applied"
    return 0
}

# iptables forgets everything at reboot, so one oneshot unit replays the
# state files by calling back into this same script.
firewall_unit_write() {
    local unit=$UNIT_DIR/pingify-firewall.service
    cat >"$unit" <<UNIT || { fail "could not write the boot unit $unit"; return 1; }
[Unit]
Description=Pingify blocking rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$PINGIFY_BIN --apply-firewall

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable pingify-firewall.service >/dev/null 2>&1 || true
}
write_firewall_unit() { firewall_unit_write; }

remove_blocking() {
    local rc=0
    rm -f "$STATE_DIR"/block-icmp "$STATE_DIR"/block-quic "$STATE_DIR"/block-speedtest
    hosts_block_off
    have iptables && { block_drop_chains || rc=1; }
    systemctl disable --now pingify-firewall.service >/dev/null 2>&1 || true
    rm -f "$UNIT_DIR/pingify-firewall.service"
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [ "$rc" != 0 ]; then
        fail "the PINGIFY chains are still in the kernel"
        fix "iptables -S PINGIFY_IN   shows what points at it"
        return 1
    fi
    return 0
}

blocking_menu() {
    local c
    while :; do
        banner
        head2 "Blocking"
        panel "RULES"
        panel_row "$(pad_to "${C_DIM}Ping / ICMP${C_OFF}" 22)$(state_badge "$(block_state icmp)")"
        panel_row "$(pad_to "${C_DIM}Speedtest sites${C_OFF}" 22)$(state_badge "$(block_state speedtest)")"
        panel_row "$(pad_to "${C_DIM}UDP 443${C_OFF}" 22)$(state_badge "$(block_state quic)")"
        panel_end
        blank
        item 1 "Ping / ICMP" "stop this server answering pings from the internet"
        item 2 "Speedtest sites" "block benchmark sites - on the KHAREJ server, where the proxy talks to them"
        item 3 "Block UDP 443" "rejects QUIC, so browsers fall back to TCP through the tunnel"
        blank
        item 4 "Show the live rules"
        item 5 "Clear everything"
        item 0 "Back"
        blank
        menu_key c || return 0
        case $c in
        1) blank
            if [ "$(block_state icmp)" != on ]; then
                dim "Safe with an ICMP tunnel running: the core has already stopped the"
                dim "kernel answering echoes, and pings inside the private link are"
                dim "accepted first. This only stops other people's pings."
                blank
            fi
            block_toggle icmp
            apply_blocking
            if [ "$(block_state icmp)" = on ]; then ok "this server no longer answers pings"
            else ok "this server answers pings again, unless an ICMP tunnel is running"; fi
            pause ;;
        2) blank
            dim "This works on traffic leaving in the clear, so it belongs on the"
            dim "KHAREJ server - that is where the proxy talks to the site."
            blank
            block_toggle speedtest; apply_blocking; pause ;;
        3) blank; block_toggle quic; apply_blocking; pause ;;
        4) show_nat; pause ;;
        5) blank
            confirm "remove every blocking rule?" && { remove_blocking && ok "cleared"; }
            pause ;;
        0 | '') return 0 ;;
        esac
    done
}
screen_firewall() { blocking_menu; }
