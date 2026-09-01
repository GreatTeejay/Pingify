#!/usr/bin/env bash
#
# Things done to the machine rather than to a tunnel: kernel tuning, and
# blocking. Both screens obey one rule - everything this file changes, it owns
# outright and can take back.
#
# The kernel settings are one drop-in file. Not three, which is what the old
# manager grew: a profile file, a BBR file and a forwarding file, so "revert"
# was a list somebody had to keep in step and did not. One file means revert is
# deleting one file, and it means the file carries its own state in two comment
# lines instead of needing marker files beside it.
#
# The firewall rules are two chains of our own, hooked into INPUT and OUTPUT at
# position 1 and rebuilt from empty on every apply. The state files in
# $STATE_DIR are the truth and iptables is derived from them, so a flush can
# never reach a rule the operator's panel put there.
#
# One sysctl is deliberately absent. net.ipv4.icmp_echo_ignore_all belongs to
# the ICMP carrier: internal/carrier/icmp.go sets it to 1 while an ICMP tunnel
# runs, because both ends of that tunnel send echo requests and a kernel that
# answers them doubles every packet on the wire. Nothing here reads it, writes
# it, or reports its value as a fault.

HOST_SYSCTL=/etc/sysctl.d/99-pingify.conf
HOST_LIMITS=/etc/security/limits.d/99-pingify.conf

# Benchmark sites, so a customer cannot spend the whole link proving how fast
# it is. The old list carried a CJK entry that no resolver and no string match
# would ever match; it is gone. Read with an unquoted expansion on purpose -
# the whitespace is the separator.
SPEEDTEST_HOSTS="speedtest.net ooklaserver.net speedtestcustom.com fast.com
nperf.com speedof.me openspeedtest.com speedcheck.org librespeed.org
speedtest.cn"

HOSTS_MARK='# --- pingify speedtest block ---'
HOSTS_END='# --- end pingify ---'

# --------------------------------------------------------------------------
# host tuning
# --------------------------------------------------------------------------

# host_profile and host_bbr_state read the drop-in rather than a state file.
# The file is written by exactly one function and always carries both comment
# lines, so it cannot disagree with itself the way a file and a marker beside
# it can.
host_profile() {
    awk '/^# profile: /{ sub(/^# profile: /, ""); print; exit }' "$HOST_SYSCTL" 2>/dev/null
}

host_bbr_state() {
    local s
    s=$(awk '/^# bbr: /{ sub(/^# bbr: /, ""); print; exit }' "$HOST_SYSCTL" 2>/dev/null)
    printf '%s' "${s:-off}"
}

host_summary() {
    local p
    p=$(host_profile)
    [ -n "$p" ] || { printf 'not applied'; return; }
    printf '%s, BBR %s' "$p" "$(host_bbr_state)"
}

host_bbr_available() {
    # Setting the sysctl asks the kernel for the module by name, so this is
    # also how tcp_bbr gets loaded the first time. That is why there is no
    # /etc/modules-load.d entry here: one less file to remember in revert.
    modprobe tcp_bbr 2>/dev/null || true
    local avail
    avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
    # list_has, not `... | grep -qx bbr`: grep would exit at the match, sysctl
    # would take SIGPIPE writing into the closed pipe, and pipefail would hand
    # back 141 for a question that was answered yes. Deliberate word split.
    list_has bbr $avail
}

# host_write_sysctl writes the whole drop-in from scratch. Both the profile and
# the BBR switch come through here, because a switch that appends to a file it
# did not write is a file nobody can predict.
#
# The three profiles differ in one idea: how much the kernel may hold for a
# socket, and how long it may spend draining the card in one go. Measured on
# the real path, a single stream carries 448 Mbit/s at 81 ms idle, which is a
# bandwidth-delay product of about 4.5 MB - so even the smallest ceiling below
# is seven times what one connection can have in flight. The ceiling is not for
# one stream. It is for the sixteen that arrive at once when a household starts
# using the link, and that is what moves between the three.
host_write_sysctl() {
    local profile=$1 bbr=$2
    local sockbuf defbuf udpmin backlog budget budget_us

    case $profile in
    gaming)
        sockbuf=33554432 defbuf=524288 udpmin=131072
        backlog=100000 budget=300 budget_us=2000
        ;;
    download)
        sockbuf=134217728 defbuf=4194304 udpmin=524288
        backlog=300000 budget=1200 budget_us=8000
        ;;
    *)
        profile=balanced
        sockbuf=67108864 defbuf=1048576 udpmin=262144
        backlog=200000 budget=600 budget_us=4000
        ;;
    esac

    # The write is checked. It used to be assumed, so a full disk or a
    # read-only /etc left the old file in place, sysctl --system succeeded on
    # what was already there, and the caller printed "host tuning applied" over
    # settings nobody had changed.
    cat >"$HOST_SYSCTL" <<SYSCTL || { bad "could not write $HOST_SYSCTL"; return 1; }
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

# Behave on a long path. slow_start_after_idle costs a fresh ramp every time a
# connection pauses, which over 81 ms is felt as the first second of every page.
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_notsent_lowat = 131072

# Drain the card's bursts without starving everything else.
net.core.netdev_max_backlog = $backlog
net.core.netdev_budget = $budget
net.core.netdev_budget_usecs = $budget_us

# Connection churn, and the descriptors it needs.
net.core.somaxconn = 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 10240 65535
fs.file-max = 2097152
fs.nr_open = 2097152
vm.swappiness = 10
SYSCTL

    # fq is the queue discipline BBR is designed against, and BBR without it
    # paces in software instead. The tunnel puts fq on its own device whatever
    # this says - tuning.pace in the config does that - so this line is about
    # the host's other interfaces, not about the link.
    if [ "$bbr" = on ]; then
        cat >>"$HOST_SYSCTL" <<'SYSCTL' || { bad "could not add the BBR lines"; return 1; }

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

# host_limits raises the descriptor ceiling for logins. It is a separate switch
# because it is the one change here that a service does not see: systemd units
# get their limit from the unit, and pingify@.service already carries
# LimitNOFILE=1048576. This is for the shell you ssh in with.
host_limits() {
    # Checked, because the success line below said the limit was raised whether
    # or not a single byte reached the file.
    cat >"$HOST_LIMITS" <<'LIMITS' || { bad "could not write $HOST_LIMITS"; return 1; }
# Written by Pingify. Delete this file to undo it.
*    soft  nofile  1048576
*    hard  nofile  1048576
root soft  nofile  1048576
root hard  nofile  1048576
LIMITS
    ok "descriptor limit raised to 1048576"
    dim "PAM reads this at login, so this shell keeps the $(ulimit -n) it started with"
}

# revert_tuning removes what this file wrote, and says plainly what removing it
# does not achieve. The old manager kept a thousand-line dump of sysctl -a and
# called it a restore path; nothing ever read it back, and it would not have
# helped, because most of those values were defaults that were never set.
revert_tuning() {
    rm -f "$HOST_SYSCTL" "$HOST_LIMITS"
    sysctl --system >/dev/null 2>&1 || true
    ok "the Pingify drop-in and the limits file are gone"
    blank
    dim "what that does not undo:"
    dim "  a value we raised stays raised until this machine reboots - sysctl"
    dim "  --system replays the files that are left, and nothing recorded what"
    dim "  the kernel held before, so there is nothing to put back"
    dim "  shells already logged in keep the descriptor limit they started with"
    if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = bbr ]; then
        dim "  congestion control is still bbr for this boot; 'Turn BBR off' sets"
        dim "  it back now, a reboot does it either way"
    fi
    dim "blocking rules are not tuning and are still in place - clear them on"
    dim "the Blocking screen"
}

screen_host() {
    local key p n bbr cc qd
    while :; do
        wipe
        blank
        rule "Host tuning"
        dim "The kernel's own network settings, which apply to everything this"
        dim "server does, not only to the tunnel. Every change is written to one"
        dim "drop-in file and can be taken back from this screen."
        blank
        dim "A tunnel's queue profile is a different thing with the same three"
        dim "names; it lives on that tunnel's screen."
        blank
        p=$(host_profile)
        bbr=$(host_bbr_state)
        # Read back from the kernel, not from the file we wrote. A drop-in that
        # says bbr and a kernel running cubic is exactly the state worth seeing,
        # and the file alone cannot show it.
        cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
        qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
        # Two fields, not one sentence. field cuts its value to UI_W - 20, so
        # at the 60-column floor the single line ran out at 40 columns and the
        # qdisc - half of what the read-back is for - was what fell off.
        field "Profile" "${p:-not applied}"
        field "BBR" "$bbr"
        field "Kernel" "${cc:-unknown} over ${qd:-unknown}"
        field "Open files" "$(ulimit -n) here, $([ -f "$HOST_LIMITS" ] && printf '1048576 at next login' || printf 'unchanged at login')"
        field "Drop-in" "$HOST_SYSCTL"
        blank
        item2 "1" "Profile" "${p:-none applied}"
        item2 "2" "BBR" "$bbr $G_DASH the congestion control the kernel uses"
        item2 "3" "Descriptor limits" \
            "$([ -f "$HOST_LIMITS" ] && printf 'raised to 1048576' || printf 'left at the distribution default')"
        item "4" "Revert" "put every setting on this screen back"
        item "0" "Back"
        blank
        menu_key key || return 0
        case $key in
        1)
            blank
            group "WHAT THIS MACHINE MOSTLY CARRIES"
            item "1" "Gaming" "smaller socket buffers, so a reply waits less"
            item "2" "Balanced" "the one to pick if the answer is everything"
            item "3" "Download" "larger buffers, for long transfers"
            item "0" "Back"
            blank
            dim "This sets the kernel's socket buffer sizes and backlog. It is"
            dim "written to $HOST_SYSCTL and applied at once."
            blank
            # menu_key rather than pick, because this screen was reached from
            # a menu and every one of those has a numeric way back out. pick
            # answers 1 to 3 and nothing else, which is right for a question
            # in the wizard and wrong here: 0 was refused and it asked again.
            menu_key n || continue
            [ -z "$n" ] && n=2
            case $n in
            1) p=gaming ;;
            2) p=balanced ;;
            3) p=download ;;
            0) continue ;;
            *) blank; warn "there is nothing on $n"; pause; continue ;;
            esac
            blank
            host_write_sysctl "$p" "$(host_bbr_state)" && ok "$p host tuning applied"
            ;;
        2)
            blank
            if [ "$(host_bbr_state)" = on ]; then
                # Taking the two lines out of the drop-in does not take BBR off
                # the running kernel: sysctl --system only sets what a file
                # names, and no file names a default. So this branch used to
                # rewrite the file, read the live value back, and print "back
                # to bbr". Set the values here, then report what is true.
                if host_write_sysctl "${p:-balanced}" off; then
                    sysctl -qw net.ipv4.tcp_congestion_control=cubic \
                        net.core.default_qdisc=fq_codel >/dev/null 2>&1
                    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
                    if [ "$cc" = bbr ]; then
                        warn "the drop-in dropped BBR but the kernel is still on bbr"
                        fix "a reboot clears it"
                    else
                        ok "back to ${cc:-the kernel default}"
                    fi
                fi
            elif ! host_bbr_available; then
                bad "this kernel does not offer BBR"
                fix "kernel $(uname -r) - 4.9 or newer with tcp_bbr is what has it"
            else
                host_write_sysctl "${p:-balanced}" on &&
                    ok "BBR is on, with fq underneath it"
            fi
            ;;
        3) blank; host_limits ;;
        4)
            blank
            confirm "remove the drop-in and the limits file?" n && { blank; revert_tuning; }
            ;;
        0 | '') return 0 ;;
        esac
    done
}

# --------------------------------------------------------------------------
# blocking
# --------------------------------------------------------------------------

# block_ipt is prefixed rather than called ipt, because the part that owns
# forwarding hooks its own chains and the two must not end up sharing one
# wrapper by accident and then disagreeing about which errors are quiet.
#
# -w 2, which was missing. Every one of these takes the xtables lock, and
# without a wait iptables gives up the moment the forwarding part is applying
# its own NAT rules. The error goes to /dev/null here, so those rules simply
# were not installed and the screen said they were; the callers below now
# check each one instead.
block_ipt() { iptables -w 2 "$@" 2>/dev/null; }

block_state() { [ -f "$STATE_DIR/block-$1" ] && printf 'on' || printf 'off'; }

host_badge() {
    if [ "$1" = on ]; then printf '%s%s on%s' "$C_OK" "$G_ON" "$C_OFF"
    else printf '%s%s off%s' "$C_MUTE" "$G_OFF" "$C_OFF"; fi
}

block_toggle() {
    local what=$1
    ensure_dirs
    if [ -f "$STATE_DIR/block-$what" ]; then rm -f "$STATE_DIR/block-$what"
    else : >"$STATE_DIR/block-$what"; fi
}

# block_tun_ifaces is every private-link device this server has or will have.
# Both sources are needed: a config names the device before it exists, and a
# device can outlive the config that made it if a delete went half way.
block_tun_ifaces() {
    local n d out= p
    # $out is split on purpose here and below: it is a word list, not a value.
    for n in $(cfg_list); do
        d=$(toml_get "$(cfg_file "$n")" tun name)
        [ -n "$d" ] || continue
        list_has "$d" $out || out="$out $d"
    done
    for p in /sys/class/net/pfy*; do
        [ -e "$p" ] || continue
        d=${p##*/}
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

# block_carrier_443 names a tunnel whose carrier is udp 443, which is the port
# the QUIC switch takes away. The wizard lets the operator pick any port and
# 443 is a common choice precisely because it looks like ordinary web traffic,
# so this is not a corner case.
block_carrier_443() {
    local n f
    while IFS= read -r n; do
        f=$(cfg_file "$n")
        [ "$(toml_get "$f" transport type)" = icmp ] && continue
        [ "$(toml_get "$f" transport port)" = 443 ] || continue
        printf '%s' "$n"
        return 0
    done < <(cfg_list)
    return 1
}

# block_carrier_accept puts this server's own carrier out of reach of the
# string match, and has to run before those rules go in.
#
# Nothing under internal/ encrypts the payload, so a customer's request for
# speedtest.net travels through the tunnel with those bytes in clear and
# -m string matches them inside the carrier's own packet. The rule aimed at a
# browser then rejects the packet carrying it, and the whole link stutters for
# a reason nothing on the screen explains.
#
# Both port directions, because the two ends are not symmetrical: IRAN dials
# out, so its carrier packets carry the port as the destination, and KHAREJ
# listens and answers from it as the source.
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
        p=$(toml_get "$f" transport port)
        case $p in '' | *[!0-9]*) continue ;; esac
        block_ipt -A PINGIFY_OUT -p udp --dport "$p" -j ACCEPT || rc=1
        block_ipt -A PINGIFY_OUT -p udp --sport "$p" -j ACCEPT || rc=1
    done < <(cfg_list)
    return "$rc"
}

# The chains, hooked once at position 1 and rebuilt from empty on every apply.
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
    # -D removes one match. An older script that inserted its hook twice leaves
    # the second behind, still sending every packet through a chain nothing
    # maintains, so take them off in a bounded loop rather than once.
    for i in 1 2 3 4 5; do block_ipt -D INPUT -j PINGIFY_IN || break; done
    for i in 1 2 3 4 5; do block_ipt -D OUTPUT -j PINGIFY_OUT || break; done
    for c in PINGIFY_IN PINGIFY_OUT; do
        block_ipt -F "$c"
        block_ipt -X "$c"
        # -X refuses while anything still jumps to the chain, and that refusal
        # went to /dev/null, so a hook the loops above could not unpick left a
        # live chain behind under a green "every blocking rule is gone". -S
        # fails on a chain that is not there, which is the answer wanted.
        block_ipt -S "$c" >/dev/null 2>&1 && rc=1
    done
    return "$rc"
}

hosts_block_off() {
    grep -qF "$HOSTS_MARK" /etc/hosts 2>/dev/null || return 0
    local tmp
    tmp=$(mktemp)
    # Written back through the same inode. /etc/hosts is a bind mount inside a
    # container and mv over it fails, or worse, succeeds locally and changes
    # nothing the container can see.
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

# apply_blocking is the only thing that writes rules, and it writes all of them
# every time from the state files. Nothing anywhere adds a single rule.
apply_blocking() {
    # rc is the honest answer. This function used to end with an unconditional
    # ok and return 0, so a rule iptables refused - the lock, a missing module,
    # a kernel without the match - was reported as a rule that went in.
    local quiet=${1:-} ifc h any rc=0 carrier
    have iptables || {
        [ "$quiet" = quiet ] || warn "iptables is not installed, so nothing was applied"
        return 1
    }
    ensure_dirs
    block_reset_chains || {
        [ "$quiet" = quiet ] || bad "iptables would not give us our chains"
        return 1
    }

    if [ "$(block_state icmp)" = on ]; then
        # The private link goes first, and the order is the whole rule.
        # `ping -I pfy0 10.99.10.2` is how anybody checks a udp tunnel is
        # carrying, and it is the far end's INPUT chain that has to answer it.
        # Put the global drop above these and blocking pings from the internet
        # quietly takes away the only test the operator has.
        for ifc in $(block_tun_ifaces); do
            block_ipt -A PINGIFY_IN -i "$ifc" -p icmp --icmp-type echo-request -j ACCEPT || rc=1
        done

        # And where a tunnel on this host uses the icmp transport, the global
        # drop is not installed at all.
        #
        # The old manager's comment said our own transport "rides in echo
        # replies, which nothing here matches". True of the old core, false of
        # this one: internal/carrier/icmp.go sends echo requests in both
        # directions. They arrive on the public interface, from an address the
        # KHAREJ side cannot know in advance, and INPUT is traversed before the
        # kernel feeds a raw socket - so the drop would eat the carrier and the
        # tunnel would go deaf with every rule on the screen looking correct.
        #
        # Nothing is lost by leaving it out: the carrier has already set
        # icmp_echo_ignore_all, so this host answers no pings anyway, which is
        # exactly what the switch was for.
        if block_icmp_tunnel; then
            [ "$quiet" = quiet ] ||
                dim "an ICMP tunnel is configured, so the blanket drop is left out - the"
            [ "$quiet" = quiet ] ||
                dim "core has already stopped this host answering pings"
        else
            block_ipt -A PINGIFY_IN -p icmp --icmp-type echo-request -j DROP || rc=1
        fi
    fi

    if [ "$(block_state quic)" = on ]; then
        # A udp carrier on 443 is left alone, the same care the ICMP branch
        # takes. These two rules match on the destination port only, which is
        # the dialling side's carrier on the way out and the listening side's
        # on the way in, so with the tunnel on 443 they made it deaf with every
        # rule on the screen looking correct. Nothing on this host can tell one
        # udp 443 datagram from another, so the choice is to leave them out.
        if carrier=$(block_carrier_443); then
            [ "$quiet" = quiet ] || dim "$carrier carries on udp 443"
            [ "$quiet" = quiet ] ||
                dim "so the QUIC rules are left out - nothing here can tell"
            [ "$quiet" = quiet ] ||
                dim "that carrier from a browser on the same port"
        else
            # Rejected on the way out, not dropped: a browser that gets a port
            # unreachable falls back to TCP now, and one that gets silence waits
            # for a timeout first, which is felt as the page hanging.
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
            # The hostname travels in clear in the TLS ClientHello, so this
            # catches a client that brought its own resolver and never asked
            # this machine for an address.
            block_ipt -A PINGIFY_OUT -m string --string "$h" --algo bm -j REJECT && any=1
        done
        if [ "$any" = 0 ] && [ "$quiet" != quiet ]; then
            warn "this kernel has no string match, so only the hosts file is blocking"
            fix "modprobe xt_string, or accept that a client with its own DNS gets through"
        fi
    else
        hosts_block_off
    fi

    firewall_unit_write || rc=1
    if [ "$rc" != 0 ]; then
        [ "$quiet" = quiet ] || bad "some of those rules would not go in"
        [ "$quiet" = quiet ] || fix "iptables -S PINGIFY_OUT   shows what did"
        return 1
    fi
    [ "$quiet" = quiet ] || ok "blocking rules rebuilt from the state files"
    return 0
}

# iptables forgets everything at reboot, so one oneshot unit replays the state
# files. It calls back into this same script, which means there is one apply
# path and the boot path cannot drift from the interactive one.
firewall_unit_write() {
    local unit=$UNIT_DIR/pingify-firewall.service
    # The unit used to run "$PINGIFY_BIN --apply-firewall", and argv in the
    # main part has no such option: unknown flags print the usage and die, so
    # every boot the unit failed, every rule stayed gone, and the Blocking
    # screen still read "on". Source the script with PINGIFY_NO_MAIN instead
    # and call the function directly, which is what the forwarding part's own
    # boot unit does and what build.sh and the updater already use.
    cat >"$unit" <<UNIT || { bad "could not write the boot unit"; fix "$unit"; return 1; }
[Unit]
Description=Pingify blocking rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'PINGIFY_NO_MAIN=1 . $PINGIFY_BIN && apply_blocking quiet'

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable pingify-firewall.service >/dev/null 2>&1 || true
}

remove_blocking() {
    local rc=0
    rm -f "$STATE_DIR"/block-icmp "$STATE_DIR"/block-quic "$STATE_DIR"/block-speedtest
    hosts_block_off
    have iptables && { block_drop_chains || rc=1; }
    systemctl disable --now pingify-firewall.service >/dev/null 2>&1 || true
    rm -f "$UNIT_DIR/pingify-firewall.service"
    systemctl daemon-reload >/dev/null 2>&1 || true
    # Uninstall calls this and prints its own success after it, so a chain that
    # survived has to come back as a non-zero rather than as the line below.
    if [ "$rc" != 0 ]; then
        bad "the PINGIFY chains are still in the kernel"
        fix "iptables -S PINGIFY_IN   shows what points at it"
        return 1
    fi
    ok "every blocking rule, state file and the boot unit are gone"
    dim "the tunnels themselves are untouched"
}

# The two long explanations live in their own functions. In the old script they
# were inline in the case arms and the dispatch was thirty lines of prose with
# the actual branches hidden in it.
why_block_icmp() {
    blank
    dim "Stops this server answering pings from the internet, which is what a"
    dim "scanner uses to find out it is there at all. Pings inside the private"
    dim "link keep working, because those rules are accepted first."
    if block_icmp_tunnel; then
        blank
        dim "You have an ICMP tunnel here. The core has already stopped the"
        dim "kernel answering echoes - that is how the carrier avoids doubling"
        dim "its own traffic - so this switch has little left to do, and the"
        dim "blanket drop is deliberately not installed while it is running."
    fi
}

why_block_quic() {
    blank
    dim "QUIC is HTTP over UDP 443. It carries its own loss recovery, and over"
    dim "a lossy carrier that recovery and the tunnel's back off from the same"
    dim "loss twice. A browser refused UDP 443 falls back to TCP immediately."
    dim "Nothing else uses the port, so the cost is a browser feature and not"
    dim "a site."
}

screen_firewall() {
    local key
    while :; do
        wipe
        blank
        rule "Blocking"
        dim "state lives in $STATE_DIR. Every apply flushes our two chains and"
        dim "builds them again, so your own rules are never in the way of it."
        blank
        item2 "1" "Ping from outside" "$(host_badge "$(block_state icmp)")"
        item2 "2" "QUIC, udp 443" "$(host_badge "$(block_state quic)")"
        item2 "3" "Speedtest sites" "$(host_badge "$(block_state speedtest)")"
        blank
        item "4" "Show the rules that are in place"
        item "5" "Clear everything, including the boot unit"
        item "0" "Back"
        blank
        menu_key key || return 0
        case $key in
        # The explainer is printed after the flip and only when the answer is
        # now on, so it describes what is true rather than what was clicked.
        1) blank; block_toggle icmp
           [ "$(block_state icmp)" = on ] && why_block_icmp
           blank; apply_blocking ;;
        2) blank; block_toggle quic
           [ "$(block_state quic)" = on ] && why_block_quic
           blank; apply_blocking ;;
        3) blank; block_toggle speedtest; apply_blocking ;;
        4)
            blank
            if ! have iptables; then
                warn "iptables is not installed"
            else
                # Cut to the width like everything else on this screen. A
                # string rule is about 127 columns as iptables prints it, so
                # ten of them wrapped into each other at any width this UI
                # supports and the list stopped being readable at all.
                rule "PINGIFY_IN"
                iptables -S PINGIFY_IN 2>/dev/null | grep -v '^-N ' |
                    sed 's/^/    /' | cut -c "1-$((UI_W - 3))"
                rule "PINGIFY_OUT"
                iptables -S PINGIFY_OUT 2>/dev/null | grep -v '^-N ' |
                    sed 's/^/    /' | cut -c "1-$((UI_W - 3))"
            fi
            blank
            field "hosts file" "$(grep -qF "$HOSTS_MARK" /etc/hosts 2>/dev/null && printf 'our block is in it' || printf 'nothing of ours in it')"
            ;;
        5)
            blank
            confirm "remove every Pingify blocking rule?" n && { blank; remove_blocking; }
            ;;
        0 | '') return 0 ;;
        esac
    done
}
