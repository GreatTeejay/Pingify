
# ---------------------------------------------------------------------------
# blocking
#
# Three switches people running a tunnel keep reaching for:
#
#   ICMP       stop the server answering pings
#   speedtest  keep clients from burning the link on benchmark sites
#   UDP 443    reject QUIC, so browsers fall back to TCP where the tunnel
#
# Everything goes in Pingify's own iptables chains, so nothing here touches
# rules you or your panel put in place. State lives in $STATE_DIR and a boot
# unit re-applies it, because iptables rules do not survive a reboot.
# ---------------------------------------------------------------------------

SPEEDTEST_HOSTS="speedtest.net ooklaserver.net speedtestcustom.com fast.com \
nperf.com speedof.me openspeedtest.com speedcheck.org librespeed.org \
测速 speedtest.cn"

# The hosts file gets a marked block so it can be removed cleanly.
HOSTS_MARK="# --- pingify speedtest block ---"

block_state() { [ -f "$STATE_DIR/block-$1" ] && printf 'on' || printf 'off'; }

block_summary() {
    local out=""
    [ "$(block_state icmp)" = "on" ]      && out="${out}icmp "
    [ "$(block_state speedtest)" = "on" ] && out="${out}speedtest "
    [ "$(block_state quic)" = "on" ]      && out="${out}quic "
    [ -n "$out" ] && printf '%s' "${out% }" || printf 'none'
}

block_toggle() {
    local what="$1"
    if [ -f "$STATE_DIR/block-$what" ]; then
        rm -f "$STATE_DIR/block-$what"
    else
        mkdir -p "$STATE_DIR"
        : > "$STATE_DIR/block-$what"
    fi
    apply_blocking
}

# ---------------------------------------------------------------------------
# applying
# ---------------------------------------------------------------------------

ipt() { iptables "$@" 2>/dev/null; }

# Our chains, hooked once into the built-in ones and rebuilt from scratch each
# time so the state file is always the single source of truth.
block_reset_chains() {
    local c
    for c in PINGIFY_IN PINGIFY_OUT PINGIFY_FWD; do
        ipt -N "$c" || ipt -F "$c"
    done
    ipt -C INPUT   -j PINGIFY_IN  || ipt -I INPUT 1   -j PINGIFY_IN
    ipt -C OUTPUT  -j PINGIFY_OUT || ipt -I OUTPUT 1  -j PINGIFY_OUT
    ipt -C FORWARD -j PINGIFY_FWD || ipt -I FORWARD 1 -j PINGIFY_FWD
}

block_drop_chains() {
    ipt -D INPUT   -j PINGIFY_IN
    ipt -D OUTPUT  -j PINGIFY_OUT
    ipt -D FORWARD -j PINGIFY_FWD
    local c
    for c in PINGIFY_IN PINGIFY_OUT PINGIFY_FWD; do
        ipt -F "$c"
        ipt -X "$c"
    done
}

hosts_block_off() {
    if grep -qF "$HOSTS_MARK" /etc/hosts 2>/dev/null; then
        sed -i "/$(printf '%s' "$HOSTS_MARK" | sed 's/[]\/$*.^[]/\\&/g')/,/# --- end pingify ---/d" /etc/hosts
    fi
}

hosts_block_on() {
    hosts_block_off
    {
        printf '%s\n' "$HOSTS_MARK"
        local h
        for h in $SPEEDTEST_HOSTS; do
            case "$h" in *[!a-zA-Z0-9.-]*) continue ;; esac
            printf '127.0.0.1 %s\n127.0.0.1 www.%s\n' "$h" "$h"
        done
        printf '%s\n' "# --- end pingify ---"
    } >> /etc/hosts
}

apply_blocking() {
    local quiet="${1:-}"
    have iptables || { [ "$quiet" = quiet ] || warn "iptables is not installed; nothing applied"; return 1; }
    mkdir -p "$STATE_DIR"
    block_reset_chains

    # --- ICMP -------------------------------------------------------------
    #
    # Dropped in the firewall rather than switched off in the kernel, because
    # icmp_echo_ignore_all is global and a private link is not public.
    #
    # A server told to ignore every echo also ignores the one its own tunnel's
    # health check sends across the private link - so building an ICMP tunnel,
    # which turns this on, made every GRE tunnel on the same pair of servers
    # read as down while it was carrying traffic perfectly well.
    #
    # A rule can tell the two apart. Echo requests arriving on a tunnel
    # interface are answered; everything else is dropped, which is the whole
    # point of the switch. Our own ICMP transport is untouched either way:
    # it rides in echo *replies*, which nothing here matches.
    if [ "$(block_state icmp)" = "on" ]; then
        if have iptables; then
            rm -f /etc/sysctl.d/99-pingify-block.conf
            sysctl -w net.ipv4.icmp_echo_ignore_all=0 >/dev/null 2>&1
            local ifc
            for ifc in $(tun_ifaces | awk '{print $1}'); do
                [ -n "$ifc" ] || continue
                ipt -A PINGIFY_IN -i "$ifc" -p icmp --icmp-type echo-request -j ACCEPT
            done
            ipt -A PINGIFY_IN -p icmp --icmp-type echo-request -j DROP
        else
            # No firewall to be selective with: the blunt switch, and the
            # health check knows to expect it.
            printf 'net.ipv4.icmp_echo_ignore_all = 1\n' > /etc/sysctl.d/99-pingify-block.conf
        fi
    else
        rm -f /etc/sysctl.d/99-pingify-block.conf
        sysctl -w net.ipv4.icmp_echo_ignore_all=0 >/dev/null 2>&1
    fi
    sysctl --system >/dev/null 2>&1
    # --- speedtest --------------------------------------------------------
    if [ "$(block_state speedtest)" = "on" ]; then
        hosts_block_on
        local h ok_any=0
        for h in $SPEEDTEST_HOSTS; do
            case "$h" in *[!a-zA-Z0-9.-]*) continue ;; esac
            # Matches the hostname in a plaintext TLS ClientHello, so it also
            # catches traffic that only passes through this server.
            if ipt -A PINGIFY_OUT -m string --string "$h" --algo bm -j REJECT; then ok_any=1; fi
            ipt -A PINGIFY_FWD -m string --string "$h" --algo bm -j REJECT
        done
        if [ "$ok_any" = "0" ] && [ "$quiet" != quiet ]; then
            warn "the kernel string match is unavailable; only the hosts file block is active"
        fi
    else
        hosts_block_off
    fi

    # --- QUIC -------------------------------------------------------------
    if [ "$(block_state quic)" = "on" ]; then
        ipt -A PINGIFY_OUT -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable
        ipt -A PINGIFY_FWD -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable
        ipt -A PINGIFY_IN  -p udp --dport 443 -j DROP
    fi

    write_firewall_unit
    [ "$quiet" = quiet ] || ok "blocking rules applied"
    return 0
}

# iptables forgets everything on reboot, so re-apply from the state files.
write_firewall_unit() {
    cat > "$UNIT_DIR/pingify-firewall.service" <<UNIT
[Unit]
Description=Pingify blocking rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SELF_BIN --apply-firewall

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable pingify-firewall.service >/dev/null 2>&1
}

remove_blocking() {
    rm -f "$STATE_DIR"/block-icmp "$STATE_DIR"/block-speedtest "$STATE_DIR"/block-quic
    rm -f /etc/sysctl.d/99-pingify-block.conf
    sysctl -w net.ipv4.icmp_echo_ignore_all=0 >/dev/null 2>&1
    hosts_block_off
    have iptables && block_drop_chains
    systemctl disable --now pingify-firewall.service >/dev/null 2>&1
    rm -f "$UNIT_DIR/pingify-firewall.service"
    systemctl daemon-reload
}

# ---------------------------------------------------------------------------
# menu
# ---------------------------------------------------------------------------

blocking_menu() {
    while :; do
        banner
        head2 "Blocking"
        panel "RULES"
        row "$(pad_to "${C_DIM}Ping / ICMP${C_OFF}" 22)$(state_badge "$(block_state icmp)")"
        row "$(pad_to "${C_DIM}Speedtest sites${C_OFF}" 22)$(state_badge "$(block_state speedtest)")"
        row "$(pad_to "${C_DIM}UDP 443${C_OFF}" 22)$(state_badge "$(block_state quic)")"
        panel_end
        say ""
        item 1 "Ping / ICMP" "stop this server answering pings - wanted on an ICMP tunnel"
        item 2 "Speedtest sites" "block benchmark sites and their CDNs"
        item 3 "Block UDP 443" "rejects QUIC, so browsers fall back to TCP"
        say ""
        item 4 "Show the live rules"
        item 5 "Clear everything"
        item 0 "Back"
        say ""
        local c=""
        ask c "select"
        case "$c" in
            1) say ""
               # The question people arrive with is whether this breaks an
               # ICMP tunnel. It does not, and the reason is worth stating
               # once here rather than being rediscovered on a live server.
               if [ "$(block_state icmp)" != "on" ]; then
                   dim "Safe with an ICMP tunnel running. The tunnel reads from a raw"
                   dim "socket, which the kernel copies to us whatever this is set to,"
                   dim "and both ends send echo replies, which the kernel never answers"
                   dim "by itself. This only stops it answering other people's pings."
                   say ""
               fi
               block_toggle icmp
               if [ "$(block_state icmp)" = "on" ]; then
                   ok "this server no longer answers pings"
               else
                   ok "this server answers pings again"
               fi
               pause ;;
            2) say ""
               dim "This works on traffic leaving in the clear, so it belongs on"
               dim "the KHAREJ server - that is where the proxy talks to the site."
               say ""
               block_toggle speedtest; pause ;;
            3) say ""; block_toggle quic; pause ;;
            4) say ""
               if have iptables; then
                   iptables -S PINGIFY_IN PINGIFY_OUT PINGIFY_FWD 2>/dev/null | sed 's/^/    /' | head -n 40
                   printf '    %sicmp_echo_ignore_all = %s%s\n' \
                       "$C_DIM" "$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null)" "$C_OFF"
               else
                   warn "iptables is not installed"
               fi
               pause ;;
            5) say ""
               confirm "remove every blocking rule?" && { remove_blocking; ok "cleared"; }
               pause ;;
            0 | "") return ;;
        esac
    done
}
