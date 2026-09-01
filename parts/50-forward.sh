# --------------------------------------------------------------------------
# Ports, from the IRAN server to whatever is listening abroad.
#
# The core does not forward anything any more: it carries a private /24 and
# nothing else. This file is the whole of what stands between a user on the
# internet and a panel running on the other server.
#
# The state file is the truth and iptables is a copy of it. Every change
# writes the list under /var/lib/pingify and then rebuilds the chains from
# every tunnel's list. Nothing edits a live rule in place, so the rules cannot
# end up describing something nobody asked for - which is what happens when a
# tool adds and deletes single rules and one of the deletes quietly fails.
#
# The copy is in memory and nothing survives a reboot, so the premise needs a
# path that makes the copy again at start-up. It has one now: nat_apply_all,
# behind a oneshot unit. Without it the state files and the Ports screen went
# on listing forwarded ports after every reboot and not one of them carried a
# packet, which is the worst shape a fault can take - the machine agreeing
# with you about what it is supposed to be doing.
#
# Two faults of the old script, both named where they are fixed below. A port
# range in iptables is written with a colon, 8000:8010; the old code wrote a
# hyphen and ran it under 2>/dev/null, so every range anyone ever entered was
# accepted, stored, listed back, and never carried a packet. And five places
# parsed the port list, disagreeing about =HOST:PORT. There is one parser
# here, forward_specs, and everything goes through it.
#
# All of this is IRAN-only. KHAREJ is where the panel runs and has no ports to
# take, so the functions check the side rather than trust the caller.
# --------------------------------------------------------------------------

NAT_CHAIN=PINGIFY_NAT
NAT_POST=PINGIFY_SNAT
NAT_SYSCTL=/etc/sysctl.d/99-pingify-forward.conf
NAT_UNIT=pingify-nat.service

# Every iptables call goes through here so the lock wait cannot be forgotten.
# systemd, docker and this script can all want xtables at the same moment, and
# without -w the call fails with "another app is currently holding the xtables
# lock" - in a rebuild loop that is one rule of six missing, and nothing says
# which one.
ipt() { iptables -w 2 "$@"; }

# Rejections are plain, unmarked, and on stderr. Plain because `ask` puts its
# own mark in front of whatever a validator says, and two marks on one line
# read as two problems. On stderr because stdout carries the tuples, and a
# caller capturing those must not capture the complaints with them.
fwd_no() { printf '  %s: %s\n' "$1" "$2" >&2; }

# Where a tunnel's list is kept. This name is the file's own business: another
# part that spells the path out for itself is a second definition, and the
# health check had one - it read "$STATE_DIR/$1.ports", never found a file, and
# reported "no ports are forwarded" about a tunnel forwarding six of them.
# Read the list with forwards_of, or the parsed tuples with forward_specs_for.
fwd_file() { printf '%s/%s.forwards' "$STATE_DIR" "$1"; }

fwd_range() {
    if [ "$1" = "$2" ]; then printf '%s' "$1"; else printf '%s-%s' "$1" "$2"; fi
}

# Do lo1..hi1 and lo2..hi2 share a port.
fwd_overlap() { [ "$1" -le "$4" ] && [ "$3" -le "$2" ]; }

# fwd_tokens splits a list the way somebody writes one: commas, spaces or
# both, in one argument or several. The unquoted expansion here is the only
# one in the file, and the IFS above it is the entire reason for it.
fwd_tokens() {
    local arg tok
    local IFS=$', \t\n'
    for arg in "$@"; do
        for tok in $arg; do printf '%s\n' "$tok"; done
    done
}

fwd_port_ok() {
    case $2 in
    '') fwd_no "$1" "there is no port number in it"; return 1 ;;
    *[!0-9]*) fwd_no "$1" "$2 is not a number, and a port is a number"; return 1 ;;
    esac
    [ "$2" -ge 1 ] && [ "$2" -le 65535 ] && return 0
    fwd_no "$1" "$2 is not a port - they run from 1 to 65535"
    return 1
}

# --------------------------------------------------------------------------
# the one parser
# --------------------------------------------------------------------------
#
#   443                 tcp 443, straight across
#   udp:500             udp instead
#   443=8443            arrives on 443, delivered to 8443
#   8000-8010           a range, delivered on the same ports
#   443=10.99.10.5:443  delivered to a particular machine behind the far end
#
# Prints one tuple per line: "proto lo hi dsthost dstport". dsthost is `-`
# when the token did not name one, meaning the far end of this tunnel: the
# parser is given specs and not a tunnel, so it has nothing to resolve that
# against and does not pretend to. nat_rules_for fills it in.
#
# tcp is the default because udp: exists - if a bare port meant both, nobody
# would ever need to write the prefix.
#
# Nothing is printed unless every token is good. A half applied list is worse
# than none: the ports that did work make the ones that did not look like
# somebody else's fault.
forward_specs() {
    local tok spec dest proto lo hi dsth dstp herr wide dup i refused=0
    local -a out=() sp=() slo=() shi=()

    while read -r tok; do
        [ -n "$tok" ] || continue
        case $tok in
        *=) fwd_no "$tok" "there is nothing after the ="; refused=$((refused + 1)); continue ;;
        esac

        spec=$tok dest= proto=tcp
        case $spec in *=*) dest=${spec#*=}; spec=${spec%%=*} ;; esac
        case $spec in *:*) proto=${spec%%:*}; spec=${spec#*:} ;; esac
        case $proto in
        tcp | TCP) proto=tcp ;;
        udp | UDP) proto=udp ;;
        *) fwd_no "$tok" "iptables forwards tcp and udp; $proto is neither"
           refused=$((refused + 1)); continue ;;
        esac

        case $spec in
        *-*) lo=${spec%%-*}; hi=${spec#*-} ;;
        *) lo=$spec; hi=$spec ;;
        esac
        fwd_port_ok "$tok" "$lo" || { refused=$((refused + 1)); continue; }
        fwd_port_ok "$tok" "$hi" || { refused=$((refused + 1)); continue; }
        if [ "$lo" -gt "$hi" ]; then
            fwd_no "$tok" "the range runs backwards - $lo comes after $hi"
            refused=$((refused + 1)); continue
        fi
        # 512 is not a technical limit. It is the width at which a typo stops
        # looking like a range: 1-9999 is somebody who meant 1999, and opening
        # ten thousand ports on their behalf is not a favour.
        wide=$((hi - lo + 1))
        if [ "$wide" -gt 512 ]; then
            fwd_no "$tok" "that is $wide ports; the most in one range is 512"
            refused=$((refused + 1)); continue
        fi

        dsth=- dstp=$lo
        if [ -n "$dest" ]; then
            case $dest in
            *:*) dsth=${dest%:*}; dstp=${dest##*:} ;;
            *[!0-9]*) dsth=$dest ;;
            *) dstp=$dest ;;
            esac
            # v_host already knows what an address is and already has the
            # wording for what it is not. A second opinion here would in time
            # become a different opinion.
            if [ "$dsth" != - ] && ! herr=$(v_host "$dsth" 2>&1); then
                fwd_no "$tok" "$herr"
                refused=$((refused + 1)); continue
            fi
            fwd_port_ok "$tok" "$dstp" || { refused=$((refused + 1)); continue; }
            if [ "$lo" != "$hi" ] && [ "$dstp" != "$lo" ]; then
                # Kept short on purpose. fwd_no prints with a bare printf and
                # nothing on this path truncates, so a sentence of advice here
                # wrapped past a hundred columns on a sixty column terminal.
                fwd_no "$tok" "a range cannot go to one port"
                refused=$((refused + 1)); continue
            fi
        fi

        # The same port twice is a list somebody is still editing. Better said
        # here than left as two iptables rules, the second of which is dead
        # weight nobody can see.
        dup=0
        for ((i = 0; i < ${#sp[@]}; i++)); do
            [ "${sp[i]}" = "$proto" ] || continue
            fwd_overlap "$lo" "$hi" "${slo[i]}" "${shi[i]}" || continue
            fwd_no "$tok" "this list already has $proto $(fwd_range "${slo[i]}" "${shi[i]}") in it"
            refused=$((refused + 1)) dup=1
            break
        done
        [ "$dup" = 1 ] && continue

        sp+=("$proto") slo+=("$lo") shi+=("$hi")
        out+=("$proto $lo $hi $dsth $dstp")
    done < <(fwd_tokens "$@")

    [ "$refused" -gt 0 ] && return 1
    [ "${#out[@]}" -gt 0 ] && printf '%s\n' "${out[@]}"
    return 0
}

# --------------------------------------------------------------------------
# what a tunnel forwards, and what would collide with it
# --------------------------------------------------------------------------

# The state file holds the tokens as they were typed, one per line, not the
# parsed tuples: that is what the ports screen shows back, and what somebody
# reading /var/lib/pingify by hand expects to find.
forwards_of() {
    local f
    f=$(fwd_file "$1")
    [ -f "$f" ] || return 0
    cat "$f"
}

forwards_set() {
    local name=$1 f
    shift
    forward_specs "$@" >/dev/null || return 1
    ensure_dirs
    f=$(fwd_file "$name")
    fwd_tokens "$@" >"$f" || return 1
    chmod 0600 "$f"
}

peer_tun_addr() {
    local f a
    f=$(cfg_file "$1")
    [ -f "$f" ] || return 0
    a=$(toml_get "$f" tun kharej)
    printf '%s' "${a%%/*}"
}

# tun_dev_of prints nothing once the config has gone rather than guessing
# pfy0. The guess would be used to delete a firewall rule, and deleting one
# that belongs to another tunnel is worse than leaving one behind.
tun_dev_of() {
    local f d
    f=$(cfg_file "$1")
    [ -f "$f" ] || return 0
    d=$(toml_get "$f" tun name)
    printf '%s' "${d:-pfy0}"
}

# forward_specs_for is the parser bound to a tunnel: the same tuples, with the
# `-` in the dsthost column already replaced by that tunnel's far end.
#
# It exists because the placeholder was escaping. forward_specs is handed
# specs and not a tunnel, so it cannot resolve `-` itself and does not pretend
# to; the health check took the tuples straight from it and probed the literal
# host `-`, which cannot answer, so every plain `443` forward was reported as
# a dead backend. Anything outside this file that wants a tunnel's tuples
# wants these, and it should ask for them by tunnel name rather than spell out
# where the state file lives.
forward_specs_for() {
    local name=$1 peer tuples proto lo hi dsth dstp
    tuples=$(forward_specs "$(forwards_of "$name")") || return 1
    [ -n "$tuples" ] || return 0
    peer=$(peer_tun_addr "$name")
    while read -r proto lo hi dsth dstp; do
        [ -n "$proto" ] || continue
        if [ "$dsth" = - ]; then
            # No address for the far end and a token that needs one. Printing
            # the tuple anyway would hand an empty host to whatever consumes
            # it, and an empty host in a DNAT target is a rule iptables takes.
            [ -n "$peer" ] || return 1
            dsth=$peer
        fi
        printf '%s %s %s %s %s\n' "$proto" "$lo" "$hi" "$dsth" "$dstp"
    done <<<"$tuples"
}

# fwd_listeners prints "proto port who" for everything bound on this host.
#
# Loopback-only listeners are left out on purpose: PREROUTING takes the packet
# long before it reaches 127.0.0.1, so such a service never saw the outside
# traffic and calling it a clash is a false alarm - and false alarms are how
# people learn to ignore a collision check.
#
# The whole of 127.0.0.0/8 is loopback, not the one address. Matching only
# 127.0.0.1 meant systemd-resolved on 127.0.0.53:53 was reported as a clash on
# every Ubuntu host, which is precisely the false alarm this filter exists to
# prevent.
fwd_listeners() {
    have ss || return 0
    ss -lntup 2>/dev/null | awk '
        NR > 1 {
            addr = $5
            n = split(addr, p, ":")
            port = p[n]
            host = substr(addr, 1, length(addr) - length(port) - 1)
            if (host ~ /^127\./ || host == "[::1]") next
            who = "something"
            i = index($0, "users:((\"")
            if (i > 0) {
                rest = substr($0, i + 9)
                q = index(rest, "\"")
                if (q > 1) who = substr(rest, 1, q - 1)
            }
            print $1, port, who
        }'
}

# forwards_clash prints every clash it can find, one per line, and returns
# non-zero when there was one. Every clash, not the first: somebody given one
# reason at a time will fix it, be handed a new one, and reasonably decide the
# tool is playing with them.
#
# Two sources. Another tunnel's forwards, this tunnel's own excluded so that
# re-submitting an unchanged list is not a clash with itself. And whatever is
# bound here per ss, because a DNAT in PREROUTING takes the packet before the
# local service sees it, which looks from that service exactly like the port
# going dead for no reason.
forwards_clash() {
    local name=$1
    shift
    local tuples listeners proto lo hi dsth dstp other op olo ohi oport who
    local hits=0

    tuples=$(forward_specs "$@") || return 1
    [ -n "$tuples" ] || return 0
    listeners=$(fwd_listeners)

    # A tunnel whose stored list no longer parses contributes no tuples, and
    # the parse ran under 2>/dev/null inside a process substitution, so both
    # its complaint and its exit status went into the dark. The port it is
    # holding was then handed out as free. Said once per tunnel, here, rather
    # than once per port being checked.
    while read -r other; do
        [ -n "$other" ] || continue
        [ "$other" = "$name" ] && continue
        forward_specs "$(forwards_of "$other")" >/dev/null 2>&1 && continue
        printf '%s: its list cannot be read\n' "$other"
        hits=$((hits + 1))
    done < <(cfg_list)

    while read -r proto lo hi dsth dstp; do
        [ -n "$proto" ] || continue
        while read -r other; do
            [ -n "$other" ] || continue
            [ "$other" = "$name" ] && continue
            while read -r op olo ohi _ _; do
                [ -n "$op" ] || continue
                [ "$op" = "$proto" ] || continue
                fwd_overlap "$lo" "$hi" "$olo" "$ohi" || continue
                printf '%s %s is already forwarded by the tunnel %s\n' \
                    "$op" "$(fwd_range "$olo" "$ohi")" "$other"
                hits=$((hits + 1))
            done < <(forward_specs "$(forwards_of "$other")" 2>/dev/null)
        done < <(cfg_list)
        while read -r op oport who; do
            [ -n "$op" ] || continue
            [ "$op" = "$proto" ] || continue
            fwd_overlap "$lo" "$hi" "$oport" "$oport" || continue
            printf '%s %s is already open here, held by %s\n' "$op" "$oport" "$who"
            hits=$((hits + 1))
        done <<<"$listeners"
    done <<<"$tuples"

    [ "$hits" = 0 ]
}

# The reasons are joined onto one line because `ask` prints a validator's
# answer as one line. The full list, one per line, is what forward_specs
# prints when the screen calls it directly.
v_forwards() {
    local err
    # Empty is a legal answer. It is how somebody says "none of them".
    [ -z "$1" ] && return 0
    if err=$(forward_specs "$1" 2>&1 >/dev/null); then return 0; fi
    printf '%s' "$err" | tr '\n' ';'
    return 1
}

# --------------------------------------------------------------------------
# turning the state into iptables
# --------------------------------------------------------------------------
#
# Two chains, and not for tidiness. DNAT is only valid on the PREROUTING hook
# and MASQUERADE only on POSTROUTING, and the kernel works out which hooks a
# user chain is reachable from when the jump is added - so one chain hooked
# into both is refused outright, and one chain hooked into either cannot hold
# the other's rule.

nat_hook() {
    local chain=$1 target=$2
    ipt -t nat -C "$chain" -j "$target" 2>/dev/null && return 0
    ipt -t nat -I "$chain" 1 -j "$target"
}

# The FORWARD accepts are two plain rules rather than a chain of our own: the
# host part owns Pingify's filter chains, and two owners flushing one chain is
# how each loses the other's work. They matter, because on any machine that
# has run docker the FORWARD policy is DROP, and without them the DNAT
# succeeds and the packet dies one hop later - indistinguishable, from the
# outside, from the far end being down.
nat_forward_hook() {
    local how=$1 dev=$2
    local -a back=(-i "$dev" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT)
    [ -n "$dev" ] || return 0
    case $how in
    add)
        ipt -C FORWARD -o "$dev" -j ACCEPT 2>/dev/null ||
            ipt -I FORWARD 1 -o "$dev" -j ACCEPT || return 1
        # Only replies come back the other way. The far end is not a route to
        # the rest of the internet through this server.
        ipt -C FORWARD "${back[@]}" 2>/dev/null ||
            ipt -I FORWARD 1 "${back[@]}" || return 1
        ;;
    del)
        while ipt -C FORWARD -o "$dev" -j ACCEPT 2>/dev/null; do
            ipt -D FORWARD -o "$dev" -j ACCEPT || break
        done
        while ipt -C FORWARD "${back[@]}" 2>/dev/null; do
            ipt -D FORWARD "${back[@]}" || break
        done
        ;;
    esac
}

# An owned drop-in, so that removing Pingify removes Pingify's change to this
# machine and nobody else's.
nat_ip_forward() {
    local now
    mkdir -p /etc/sysctl.d 2>/dev/null
    if [ ! -s "$NAT_SYSCTL" ]; then
        cat >"$NAT_SYSCTL" <<'SYSCTL'
# Written by Pingify. A forwarded port is a packet that arrives for one
# address and leaves for another, and the kernel drops that unless this is on.
net.ipv4.ip_forward = 1
SYSCTL
    fi
    sysctl -q -w net.ipv4.ip_forward=1 >/dev/null 2>&1 ||
        printf '1\n' >/proc/sys/net/ipv4/ip_forward 2>/dev/null
    now=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)
    [ "$now" = 1 ] && return 0
    bad "the kernel is not forwarding packets, so nothing arrives"
    fix "sysctl -w net.ipv4.ip_forward=1"
    return 1
}

# nat_rules_for appends one tunnel's rules to the already flushed chains. A
# tunnel whose stored list no longer parses is skipped with a complaint rather
# than aborting the rebuild: the rebuild is doing the other tunnels' work too,
# and one bad state file must not take their ports down with it.
nat_rules_for() {
    local name=$1 f side dev tuples proto lo hi dsth dstp dport target
    f=$(cfg_file "$name")
    [ -f "$f" ] || return 0
    side=$(toml_get "$f" tunnel side)
    [ "$side" = iran ] || return 0

    # forward_specs_for resolves the `-` placeholder against this tunnel, so
    # it also fails when a token needs the far end and the config names none.
    tuples=$(forward_specs_for "$name") || return 1
    [ -n "$tuples" ] || return 0
    dev=$(tun_dev_of "$name")
    [ -n "$dev" ] || return 1

    while read -r proto lo hi dsth dstp; do
        [ -n "$proto" ] || continue
        if [ "$lo" = "$hi" ]; then
            dport=$lo target=$dsth:$dstp
        else
            # The colon. iptables writes a range as 8000:8010 and refuses a
            # hyphen; the old script wrote the hyphen and threw the refusal
            # away, so ranges were stored, listed back, and never forwarded.
            # A range keeps its own ports, so the target names none.
            dport=$lo:$hi target=$dsth
        fi
        # Not packets arriving out of the tunnel: without this, a connection
        # made from the far end to this port is sent straight back out again.
        ipt -t nat -A "$NAT_CHAIN" ! -i "$dev" -p "$proto" --dport "$dport" \
            -j DNAT --to-destination "$target" || return 1
    done <<<"$tuples"

    # One MASQUERADE for the device, so the far end sees the traffic coming
    # from this end of the private link and answers back down it. Without it
    # the reply is addressed to the original client and leaves through the far
    # server's own default route, where it is dropped as a stranger.
    ipt -t nat -A "$NAT_POST" -o "$dev" -j MASQUERADE || return 1
    nat_forward_hook add "$dev"
}

# nat_rebuild writes every tunnel's stored list into the freshly flushed
# chains. Everything, because the chains are shared: flushing them to write one
# tunnel's rules and not writing the others back is how a second tunnel
# silently loses its ports.
#
# The argument is the tunnel the caller is about to report on, or empty to mean
# every tunnel matters. It returns non-zero when that tunnel's rules did not go
# in. This used to be inside nat_apply, which threw the result away: a DNAT the
# kernel refused, or a config with no device or no far end, was warned about
# and then reported as a success on the very next line, with a count read from
# the state file rather than from what iptables had accepted.
nat_rebuild() {
    local want=$1 t dev rc=0
    have iptables || {
        warn "iptables is not installed, so nothing can be forwarded"
        fix "apt-get install -y iptables"
        return 1
    }
    ensure_dirs
    nat_ip_forward || return 1

    ipt -t nat -n -L "$NAT_CHAIN" >/dev/null 2>&1 || ipt -t nat -N "$NAT_CHAIN" || return 1
    ipt -t nat -n -L "$NAT_POST" >/dev/null 2>&1 || ipt -t nat -N "$NAT_POST" || return 1
    ipt -t nat -F "$NAT_CHAIN" || return 1
    ipt -t nat -F "$NAT_POST" || return 1
    nat_hook PREROUTING "$NAT_CHAIN" || return 1
    nat_hook POSTROUTING "$NAT_POST" || return 1

    while read -r t; do
        [ -n "$t" ] || continue
        # A tunnel that has stopped forwarding kept its FORWARD accepts:
        # nat_rules_for returns before it adds them and nothing ever took them
        # away again, so `-o pfy0 -j ACCEPT` sat there permitting that device
        # with no DNAT left behind it. The nat chains are flushed above; these
        # two rules live in filter and have to be removed by name.
        if [ -z "$(forwards_of "$t")" ]; then
            dev=$(tun_dev_of "$t")
            nat_forward_hook del "$dev"
            continue
        fi
        nat_rules_for "$t" && continue
        warn "$t: its stored ports could not be applied"
        if [ -z "$want" ] || [ "$t" = "$want" ]; then rc=1; fi
    done < <(cfg_list)
    return "$rc"
}

# nat_apply rebuilds everything, then reports on the one tunnel it was called
# for. The report is the outcome, not a wish: it is only printed when the
# rebuild said that tunnel's rules went in.
nat_apply() {
    local name=$1 n peer word
    nat_rebuild "$name" || {
        bad "$name: its ports are not forwarded"
        fix "read the warnings above, then set the list again"
        return 1
    }
    nat_unit_write || {
        warn "the boot unit is not written, so a reboot loses these"
        fix "check that $UNIT_DIR can be written"
    }

    n=$(forwards_of "$name" | grep -c .) || n=0
    peer=$(peer_tun_addr "$name")
    word=ports
    [ "$n" = 1 ] && word=port
    if [ "$n" = 0 ]; then
        ok "$name forwards nothing now"
    elif [ -n "$peer" ]; then
        ok "$name sends $n $word to $peer"
    else
        # Every token named its own destination, so there is no far end to
        # name here. The old line ended "to " with nothing after it.
        ok "$name sends $n $word across the tunnel"
    fi
    return 0
}

# nat_apply_all is the boot path, and the reason the unit below exists.
#
# iptables keeps its rules in memory alone. Nothing replayed them at start-up,
# so every forwarded port died at the first reboot while the state files and
# the Ports screen went on saying the ports were forwarded - the one failure
# with no symptom anywhere on the machine except that no packet arrives.
nat_apply_all() {
    [ "$(cfg_count)" -gt 0 ] || return 0
    nat_rebuild "" || return 1
    ok "the forwarded ports are back in the kernel"
}

# The unit re-enters this same script rather than repeating the rules, so the
# boot path cannot drift from the interactive one. It sources the manager with
# PINGIFY_NO_MAIN set, which is what stops a sourced copy opening the menu, and
# calls the one function - there is no command line flag for this and adding
# one would put a second entry point on the same work.
nat_unit_write() {
    mkdir -p "$UNIT_DIR" 2>/dev/null
    # The write is checked. A unit that was never written is the reboot fault
    # again, and it would be reported under the same green tick as before.
    cat >"$UNIT_DIR/$NAT_UNIT" <<UNIT || return 1
[Unit]
Description=Pingify forwarded ports
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'PINGIFY_NO_MAIN=1 . $PINGIFY_BIN && nat_apply_all'

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable "$NAT_UNIT" >/dev/null 2>&1 || true
}

# nat_drop removes one tunnel's forwarding. Call it before the config file is
# deleted: the tun device name comes out of the config, and without it the
# FORWARD rules for that device can never be found again.
nat_drop() {
    local name=$1 dev t left=0
    rm -f "$(fwd_file "$name")"
    # The state file has gone either way, so say so. Returning in silence here
    # left the menu item printing nothing at all after the confirmation, which
    # reads as a key that did not work.
    have iptables || { ok "$name forwards nothing now"; return 0; }
    dev=$(tun_dev_of "$name")
    nat_forward_hook del "$dev"

    while read -r t; do
        [ -n "$t" ] || continue
        [ -s "$(fwd_file "$t")" ] && left=1
    done < <(cfg_list)

    if [ "$left" = 1 ]; then
        nat_apply "$name"
        return
    fi
    nat_teardown
    ok "$name forwards nothing, and the chains have gone with it"
}

# nat_teardown is what the last tunnel and the uninstall both call. The loops
# around the unhooking are there because an older version inserted the jump on
# every run: a single -D would leave the duplicates pointing at a chain that
# is about to be deleted.
nat_teardown() {
    # The boot unit goes first and always, iptables or not: a unit left behind
    # would replay chains at the next reboot that nothing on this machine now
    # asks for.
    systemctl disable --now "$NAT_UNIT" >/dev/null 2>&1 || true
    rm -f "$UNIT_DIR/$NAT_UNIT"
    systemctl daemon-reload >/dev/null 2>&1 || true

    have iptables || return 0
    while ipt -t nat -C PREROUTING -j "$NAT_CHAIN" 2>/dev/null; do
        ipt -t nat -D PREROUTING -j "$NAT_CHAIN" || break
    done
    while ipt -t nat -C POSTROUTING -j "$NAT_POST" 2>/dev/null; do
        ipt -t nat -D POSTROUTING -j "$NAT_POST" || break
    done
    ipt -t nat -F "$NAT_CHAIN" 2>/dev/null
    ipt -t nat -X "$NAT_CHAIN" 2>/dev/null
    ipt -t nat -F "$NAT_POST" 2>/dev/null
    ipt -t nat -X "$NAT_POST" 2>/dev/null
    # The drop-in goes, so a reboot comes up without it. The running kernel
    # keeps ip_forward=1 until then, deliberately: something else here may be
    # relying on it and it was not ours to switch off.
    rm -f "$NAT_SYSCTL"
    return 0
}

# --------------------------------------------------------------------------
# the screen
# --------------------------------------------------------------------------

screen_ports() {
    local name=$1 f side peer cur tuples proto lo hi dsth dstp key
    f=$(cfg_file "$name")
    [ -f "$f" ] || { bad "there is no tunnel called $name"; return 1; }
    screen_top

    while :; do
        side=$(toml_get "$f" tunnel side)
        blank
        rule "Ports $G_CUR $name"
        blank
        if [ "$side" != iran ]; then
            warn "this is the KHAREJ side; nothing is forwarded here"
            fix "run this on the IRAN server, where users connect"
            blank
            return 0
        fi

        peer=$(peer_tun_addr "$name")
        # Short because dim prints with a bare printf: the sentence this
        # replaces came to 72 columns against a 60 column floor and wrapped.
        dim "these ports go to $peer across the tunnel"
        blank
        cur=$(forwards_of "$name" | tr '\n' ' ')
        cur=${cur% }
        if [ -z "$cur" ]; then
            dim "nothing is forwarded yet"
        elif ! tuples=$(forward_specs "$cur"); then
            warn "the stored list cannot be read, so nothing is forwarded"
            fix "choose 1 and enter the ports again"
        else
            UI_COLS=(14 7 30)
            row "PORT" "PROTO" "GOES TO"
            while read -r proto lo hi dsth dstp; do
                [ -n "$proto" ] || continue
                [ "$dsth" = - ] && dsth=$peer
                if [ "$lo" = "$hi" ]; then
                    row "$lo" "$proto" "$dsth:$dstp"
                else
                    row "$lo-$hi" "$proto" "$dsth, the same ports"
                fi
            done <<<"$tuples"
        fi

        blank
        item "1" "Set the list"
        item "2" "Forward nothing"
        item "0" "Back"
        blank
        menu_key key || return 0
        case $key in
        1) screen_ports_set "$name" ;;
        2) confirm "stop forwarding every port for $name?" n && nat_drop "$name" ;;
        0 | '') return 0 ;;
        esac
    done
}

screen_ports_set() {
    local name=$1 cur answer clashes
    cur=$(forwards_of "$name" | tr '\n' ' ')
    cur=${cur% }
    blank
    dim "one port  443     a range  8000-8010     udp  udp:500"
    dim "somewhere else  443=8443  or  443=10.99.10.5:443"
    blank
    # The clash report is a re-ask, not a refusal: the answer is still on the
    # screen above and the next one is usually one character different.
    while :; do
        ask answer "ports, comma separated" "$cur" v_forwards || return 0
        clashes=$(forwards_clash "$name" "$answer") && break
        blank
        bad "something else already has one of those:"
        printf '%s\n' "$clashes" | sed 's/^/       /'
        fix "pick other ports, or stop what is holding these"
        blank
    done
    forwards_set "$name" "$answer" || return 1
    nat_apply "$name"
}
