
# ---------------------------------------------------------------------------
# what is already spoken for
#
# Two tunnels on one private network route into each other. Two tunnels
# forwarding one port means whichever bound it first wins. Both fail quietly -
# the traffic goes somewhere, just not where it was meant to - and nothing on
# the server explains it afterwards.
#
# So both are checked before the answer is taken, against the configs on this
# machine and what the kernel already has bound, which together are the only
# places that know.
# ---------------------------------------------------------------------------

# cfg_files - every tunnel config here, one per line
cfg_files() {
    local f
    for f in "$CFG_DIR"/*.toml "$CFG_DIR"/*.json; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done
    return 0
}

# cfg_name FILE - the tunnel's own name, falling back to the filename
cfg_name() {
    local n
    n="$(toml_get "$1" tunnel name)"
    if [ -z "$n" ]; then
        n="$(basename "$1")"
        n="${n%.toml}"; n="${n%.json}"
    fi
    printf '%s' "$n"
}

# ---------------------------------------------------------------------------
# private networks
# ---------------------------------------------------------------------------

# tun_nets [EXCEPT] - "network name" for every private link claimed here,
# skipping one tunnel by name so editing its own settings is not a clash.
tun_nets() {
    local except="${1:-}" f addr name
    cfg_files | while read -r f; do
        addr="$(toml_get "$f" tun local_addr)"
        [ -n "$addr" ] || continue
        name="$(cfg_name "$f")"
        [ -n "$except" ] && [ "$name" = "$except" ] && continue
        printf '%s %s\n' "${addr%.*}" "$name"
    done
    return 0
}

# net_owner NETWORK [EXCEPT] - the tunnel using it, or nothing. NETWORK is the
# first three octets with no mask, e.g. 10.10.10
net_owner() {
    local want="$1" except="${2:-}"
    tun_nets "$except" | while read -r net name; do
        if [ "$net" = "$want" ]; then
            printf '%s' "$name"
            break
        fi
    done
    return 0
}

# host_nets - the /24s this machine already has an address on. Docker, another
# VPN and the provider's own private range all show up here, and a tunnel that
# shadows one of them quietly takes traffic that was not meant for it.
host_nets() {
    have ip || return 0
    ip -4 -o addr show 2>/dev/null | awk '{print $4}' | while read -r cidr; do
        [ -n "$cidr" ] && printf '%s\n' "${cidr%.*}"
    done
    return 0
}

host_has_net() {
    local want="$1"
    host_nets | grep -qxF "$want"
}

# free_link_octet [EXCEPT] - the first x where 10.x.10.0/24 is free, so the
# default offered is one that will be accepted.
free_link_octet() {
    local except="${1:-}" x=10
    while [ "$x" -lt 250 ]; do
        if [ -z "$(net_owner "10.${x}.10" "$except")" ] && ! host_has_net "10.${x}.10"; then
            printf '%s' "$x"
            return 0
        fi
        x=$((x + 1))
    done
    printf '10'
    return 1
}

# ---------------------------------------------------------------------------
# ports
# ---------------------------------------------------------------------------

# ports_of FILE - every single port that config forwards, one per line, with
# ranges expanded and the udp:/tcp: prefixes and =target parts stripped.
ports_of() {
    local f="$1" spec p lo hi pt
    for spec in $(toml_arr "$f" ports | tr -d '"' | tr ',' ' '); do
        p="${spec%%=*}"; p="${p#udp:}"; p="${p#tcp:}"
        case "$p" in
            *-*) lo="${p%%-*}"; hi="${p##*-}" ;;
            *)   lo="$p"; hi="$p" ;;
        esac
        case "$lo" in '' | *[!0-9]*) continue ;; esac
        case "$hi" in '' | *[!0-9]*) continue ;; esac
        [ "$hi" -ge "$lo" ] || continue
        # A range wider than this is a mistake being made, not a range.
        [ "$((hi - lo))" -gt 512 ] && hi="$((lo + 512))"
        pt="$lo"
        while [ "$pt" -le "$hi" ]; do
            printf '%s\n' "$pt"
            pt=$((pt + 1))
        done
    done
    return 0
}

# port_owner PORT [EXCEPT] - the tunnel already forwarding it, or nothing
port_owner() {
    local want="$1" except="${2:-}" f name
    case "$want" in '' | *[!0-9]*) return 0 ;; esac
    cfg_files | while read -r f; do
        name="$(cfg_name "$f")"
        [ -n "$except" ] && [ "$name" = "$except" ] && continue
        if ports_of "$f" | grep -qxF "$want"; then
            printf '%s' "$name"
            break
        fi
    done
    return 0
}

# listening_ports - every port with something bound to it, asked once. Per
# port it would be one ss call each, which on a range is a visible pause.
listening_ports() {
    have ss || return 0
    ss -Hltun 2>/dev/null | awk '{print $5}' | sed 's/.*://' | sort -u
    return 0
}

# forwards_clash SPECS [EXCEPT] - print one line per port that is already
# taken, by another tunnel or by something already listening. Returns 0 when
# there is nothing wrong, so it reads as "these forwards are fine".
forwards_clash() {
    local raw="$1" except="${2:-}" bad=0 bound mine="" spec p lo hi pt who
    bound="$(listening_ports)"
    # A tunnel being edited already has its own ports bound, by its own
    # service. Keeping one of them is not a clash with anything, and calling
    # it one would make the port list impossible to edit without emptying it
    # first.
    if [ -n "$except" ] && [ -f "$(cfg_file "$except")" ]; then
        mine="$(ports_of "$(cfg_file "$except")")"
    fi
    raw="$(printf '%s' "$raw" | tr -d '"' | tr ',' ' ')"
    for spec in $raw; do
        p="${spec%%=*}"; p="${p#udp:}"; p="${p#tcp:}"
        case "$p" in
            *-*) lo="${p%%-*}"; hi="${p##*-}" ;;
            *)   lo="$p"; hi="$p" ;;
        esac
        case "$lo" in '' | *[!0-9]*) continue ;; esac
        case "$hi" in '' | *[!0-9]*) continue ;; esac
        [ "$hi" -ge "$lo" ] || continue
        [ "$((hi - lo))" -gt 512 ] && hi="$((lo + 512))"
        pt="$lo"
        while [ "$pt" -le "$hi" ]; do
            who="$(port_owner "$pt" "$except")"
            if [ -n "$who" ]; then
                printf 'port %s is already forwarded by %s\n' "$pt" "$who"
                bad=1
            elif printf '%s\n' "$mine" | grep -qxF "$pt"; then
                : # its own port, bound by its own service
            elif printf '%s\n' "$bound" | grep -qxF "$pt"; then
                printf 'port %s already has something listening on it\n' "$pt"
                bad=1
            fi
            pt=$((pt + 1))
        done
    done
    [ "$bad" = "0" ]
}

# ---------------------------------------------------------------------------
# saying so
# ---------------------------------------------------------------------------

# show_taken_nets [EXCEPT] - the yellow block above the question, listing what
# is already spoken for. Silent when nothing is.
show_taken_nets() {
    local except="${1:-}" taken
    taken="$(tun_nets "$except")"
    [ -n "$taken" ] || return 0
    warn "private networks already used on this server"
    printf '%s\n' "$taken" | while read -r net name; do
        [ -n "$net" ] && dim "$(pad_to "${net}.0/24" 18)${BX_ARR} $name"
    done
    say ""
    return 0
}

# show_taken_ports [EXCEPT] - the same, for forwarded ports
show_taken_ports() {
    local except="${1:-}" listing
    listing="$(
        cfg_files | while read -r f; do
            name="$(cfg_name "$f")"
            [ -n "$except" ] && [ "$name" = "$except" ] && continue
            list="$(toml_arr "$f" ports | tr -d '"' | tr ',' ' ')"
            [ -n "$list" ] && printf '%s %s\n' "$name" "$list"
        done
    )"
    [ -n "$listing" ] || return 0
    warn "ports already forwarded on this server"
    printf '%s\n' "$listing" | while read -r name list; do
        [ -n "$name" ] && dim "$(pad_to "$name" 18)${BX_ARR} $list"
    done
    say ""
    return 0
}
