
# ---------------------------------------------------------------------------
# tunnel configuration
# ---------------------------------------------------------------------------

# The T_* variables below describe one tunnel while the wizard runs.
cfg_reset() {
    T_NAME=""; T_ROLE=""; T_MODE="forward"; T_TRANSPORT="direct"
    T_LISTEN=""; T_CONNECT=""; T_PSK=""; T_PUBLIC_IP=""
    T_CARRIERS=4; T_WINDOW=512; T_KEEPALIVE=10
    T_FORWARDS=""; T_STATUS=""
    T_TUNIF="pfy0"; T_TUNLOCAL=""; T_TUNPEER=""; T_TUNMTU=1380
}

# cfg_render <role> <mode> <listen> <connect> <forwards-json> <status-addr>
# Prints one config document. Every key sits on its own line, which is what
# lets the manager read these files back with sed instead of a JSON parser.
# A config should read like a description of the tunnel, not a bag of keys.
# Each section is one question about how this end is set up, and the sections
# come in the order you would explain it to somebody: what it is, how it
# travels, what protects it, what it carries, and how it behaves.
#
# Only what applies is written. A forward tunnel has no [tun] section at all
# rather than an empty one, so nothing on the page is there to be ignored.
cfg_render() {
    local role="$1" mode="$2" listen="$3" connect="$4" fwd="$5" status="$6"
    printf '# Pingify tunnel - written by the manager, safe to edit by hand.
'
    printf '# Both servers need the same psk; everything else is local to this one.
'

    printf '
[tunnel]
'
    printf '%-16s = "%s"
' name "$T_NAME"
    printf '%-16s = "%s"   # server = IRAN, client = KHAREJ
' role "$role"
    printf '%-16s = "%s"   # forward = ports, tun = a private layer-3 link
' mode "$mode"

    printf '
[transport]
'
    printf '%-16s = "%s"
' type "$T_TRANSPORT"
    [ -n "$listen" ]  && printf '%-16s = "%s"   # this end accepts the carriers
' listen "$listen"
    [ -n "$connect" ] && printf '%-16s = "%s"   # this end dials them
' connect "$connect"
    printf '%-16s = %s   # connections the tunnel is spread over
' carriers "$T_CARRIERS"
    printf '%-16s = %s   # how often this end speaks when idle
' keepalive_sec "$T_KEEPALIVE"

    printf '
[security]
'
    printf '%-16s = "%s"
' psk "$T_PSK"

    if [ -n "$fwd" ]; then
        printf '
[forward]
'
        printf '# 443            the same port on both servers
'
        printf '# 443=8443       clients hit 443 here, it lands on 8443 there
'
        printf '# udp:500        a UDP port
'
        printf '%-16s = [%s]
' ports "$fwd"
    fi

    if [ "$mode" = "tun" ]; then
        local lo="$T_TUNLOCAL" pe="$T_TUNPEER"
        if [ "$role" != "$T_ROLE" ]; then
            local pfx="${T_TUNLOCAL##*/}"
            [ "$pfx" = "$T_TUNLOCAL" ] && pfx=30
            lo="$T_TUNPEER/$pfx"
            pe="${T_TUNLOCAL%%/*}"
        fi
        printf '
[tun]
'
        printf '%-16s = "%s"
' name "$T_TUNIF"
        printf '%-16s = "%s"   # this server, on the private link
' local_addr "$lo"
        printf '%-16s = "%s"   # the other one
' remote_addr "$pe"
        printf '%-16s = %s
' mtu "$T_TUNMTU"
    fi

    printf '
[tuning]
'
    printf '%-16s = %s   # in flight per forwarded connection
' window_kb "$T_WINDOW"

    printf '
[status]
'
    printf '%-16s = "%s"
' addr "$status"

    printf '
[logging]
'
    printf '%-16s = "info"   # error, warn, info, debug
' level
}

cfg_save() {
    local file="$(cfg_file "$T_NAME")"
    cfg_render "$T_ROLE" "$T_MODE" "$T_LISTEN" "$T_CONNECT" "$T_FORWARDS" "$T_STATUS" > "$file"
    chmod 600 "$file"
    printf '%s' "$file"
}

# The peer document is this one mirrored: the sides swap, and whichever end
# dials becomes the end that listens.
# The token is the other server's half of the tunnel.
#
# It used to be the whole config document, base64'd - long, and tied to
# whatever format that document happened to be in, so changing the format
# quietly broke every token. It is a short list of values now, and the far end
# builds its own config from them with the same renderer this end used. A token
# from any version therefore produces a file in the current format.
#
#   p1|mode|transport|endpoint|psk|carriers|window|keepalive|tunlocal|tunpeer|mtu
#
# endpoint is c=host:port when the far end should dial, or l=0.0.0.0:port when
# it should accept. Everything else the far end can work out for itself.
cfg_peer_token() {
    local ep tl="" tp="" mtu=""
    if [ -n "$T_CONNECT" ]; then
        # We dial them, so they accept - on the port we were dialling.
        ep="l=0.0.0.0:${T_CONNECT##*:}"
    else
        # We accept, so they dial us, and they need our address to do it.
        ep="c=${T_PUBLIC_IP}:${T_LISTEN##*:}"
    fi
    if [ "$T_MODE" = "tun" ]; then
        # Their end of the /30 is our peer address, and ours becomes theirs.
        local pfx="${T_TUNLOCAL##*/}"
        [ "$pfx" = "$T_TUNLOCAL" ] && pfx=30
        tl="${T_TUNPEER}/${pfx}"
        tp="${T_TUNLOCAL%%/*}"
        mtu="$T_TUNMTU"
    fi
    printf 'p1|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' \
        "$T_MODE" "$T_TRANSPORT" "$ep" "$T_PSK" \
        "$T_CARRIERS" "$T_WINDOW" "$T_KEEPALIVE" "$tl" "$tp" "$mtu" \
        | base64 | tr -d '\n'
}


parse_forwards() {
    local raw="$1" out="" item
    raw="${raw//,/ }"
    for item in $raw; do
        [ -n "$item" ] || continue
        [ -n "$out" ] && out="$out,"
        out="$out\"$item\""
    done
    printf '%s' "$out"
}

# Friendly names for the values stored in the config.
side_label()      { [ "$1" = "server" ] && printf 'IRAN' || printf 'KHAREJ'; }
mode_label()      { [ "$1" = "tun" ] && printf 'Full IP' || printf 'Ports'; }
transport_label() { case "$1" in direct) printf 'Direct' ;; *) printf '%s' "$1" ;; esac; }

# ---------------------------------------------------------------------------
# new tunnel
# ---------------------------------------------------------------------------

new_tunnel() {
    banner
    head2 "New Tunnel"
    ensure_core || { pause; return 1; }

    item 1 "Configure this server" "you will get a token for the other one"
    item 2 "Apply a token" "paste what the other server gave you"
    say ""
    local choice=""
    ask choice "select" "1"
    [ "$choice" = "2" ] && { import_tunnel; return; }

    cfg_reset

    # -- 1. which end is this ----------------------------------------------
    head2 "1/6   This server"
    item 1 "Iran" "clients connect to this server"
    item 2 "Kharej" "the panel and inbounds run on this server"
    say ""
    local side=""
    ask side "select" "1"
    [ "$side" = "2" ] && T_ROLE="client" || T_ROLE="server"

    # -- 2. link direction and endpoint ------------------------------------
    head2 "2/6   Link direction"
    dim "the tunnel is one link; only one end has to accept connections"
    say ""
    item 1 "Outbound" "this server connects to the other one"
    item 2 "Inbound" "the other one connects in; needs an open port"
    say ""
    local dir=""
    ask dir "select" "1"

    local tport=""
    say ""
    if [ "$dir" = "2" ]; then
        ask tport "listen port" "9443"
        T_LISTEN="0.0.0.0:$tport"
        port_free "$tport" || warn "port $tport is already in use on this server"
        T_PUBLIC_IP="$(public_ip)"
        ask T_PUBLIC_IP "public address of this server" "${T_PUBLIC_IP:-}"
    else
        local peer=""
        ask peer "address of the other server"
        [ -n "$peer" ] || { fail "an address is required"; pause; return 1; }
        ask tport "port on the other server" "9443"
        T_CONNECT="$peer:$tport"
    fi

    # -- the name, derived --------------------------------------------------
    # iran-9443 here, kharej-9443 on the other server. Two machines side by
    # side then say what they are without either config being opened.
    T_NAME="$(printf '%s' "$(side_label "$T_ROLE")" | tr 'A-Z' 'a-z')-${tport}"
    if [ -f "$(cfg_file "$T_NAME")" ]; then
        local n=2
        while [ -f "$(cfg_file "${T_NAME}-${n}")" ]; do n=$((n + 1)); done
        T_NAME="${T_NAME}-${n}"
    fi
    say ""
    ok "this tunnel is called ${C_B}${T_NAME}${C_OFF}"

    # -- 3. key ------------------------------------------------------------
    head2 "3/6   Shared key"
    dim "both servers authenticate with the same key; the token carries it"
    say ""
    item 1 "Generate" "recommended"
    item 2 "Enter an existing key" "if you already have one"
    say ""
    local kmode=""
    ask kmode "select" "1"
    say ""
    if [ "$kmode" = "2" ]; then
        ask T_PSK "key"
    else
        T_PSK="$("$CORE_BIN" -genpsk)"
        ok "generated"
    fi
    case "$T_PSK" in
        "" | *[!0-9a-fA-F]*) fail "a key is 64 hex characters"; pause; return 1 ;;
    esac

    # -- 5. transport ------------------------------------------------------
    head2 "4/6   Protocol"
    dim "how the link itself travels between the two servers"
    say ""
    item 1 "Direct" "encrypted stream, no wrapper - fastest"
    say ""
    dim "TLS and WebSocket are planned; Direct is the only one in this build"
    say ""
    local tr=""
    ask tr "select" "1"
    T_TRANSPORT="direct"

    # -- 6. payload --------------------------------------------------------
    head2 "5/6   What the tunnel carries"
    item 1 "Ports" "forward TCP and UDP ports - panels, inbounds"
    item 2 "Full IP" "a private layer-3 link between the two servers"
    say ""
    local m=""
    ask m "select" "1"
    say ""

    if [ "$m" = "2" ]; then
        T_MODE="tun"
        local sub=""
        ask sub "subnet index (0-63)" "1"
        case "$sub" in "" | *[!0-9]*) sub=1 ;; esac
        T_TUNIF="pfy${sub}"
        if [ "$T_ROLE" = "server" ]; then
            T_TUNLOCAL="10.71.${sub}.1/30"; T_TUNPEER="10.71.${sub}.2"
        else
            T_TUNLOCAL="10.71.${sub}.2/30"; T_TUNPEER="10.71.${sub}.1"
        fi
        ask T_TUNMTU "MTU" "1380"
        dim "this server takes ${T_TUNLOCAL}, the other one takes ${T_TUNPEER}"
    else
        T_MODE="forward"
        dim "port           same port on both servers"
        dim "443=8443       arrives on 443 here, reaches 8443 there"
        dim "udp:500        a UDP port"
        dim "8000-8010      a range"
        say ""
        local raw=""
        ask raw "ports on the Iran server, comma separated" "443"
        T_FORWARDS="$(parse_forwards "$raw")"
        [ -n "$T_FORWARDS" ] || { fail "at least one port is required"; pause; return 1; }
    fi

    # -- 7. performance ----------------------------------------------------
    head2 "6/6   Performance"
    dim "carriers are the parallel connections the link runs over; more of"
    dim "them absorb packet loss better, 4 to 8 suits most paths"
    say ""
    if confirm "change the defaults? (carriers ${T_CARRIERS}, window ${T_WINDOW} KB)"; then
        say ""
        ask T_CARRIERS "carriers" "$T_CARRIERS"
        ask T_WINDOW "window per stream in KB" "$T_WINDOW"
        ask T_KEEPALIVE "keepalive seconds" "$T_KEEPALIVE"
    fi
    case "$T_CARRIERS" in "" | *[!0-9]*) T_CARRIERS=4 ;; esac
    case "$T_WINDOW" in "" | *[!0-9]*) T_WINDOW=512 ;; esac
    case "$T_KEEPALIVE" in "" | *[!0-9]*) T_KEEPALIVE=10 ;; esac
    [ "$T_CARRIERS" -lt 1 ] && T_CARRIERS=1
    [ "$T_CARRIERS" -gt 64 ] && T_CARRIERS=64

    T_STATUS="127.0.0.1:$(pick_free_port 9700)"

    # -- review ------------------------------------------------------------
    banner
    head2 "Review"
    box_top
    box_row "$(pad_to "tunnel" 14)${C_B}${T_NAME}${C_OFF}"
    box_row "$(pad_to "this server" 14)$(side_label "$T_ROLE")"
    box_row "$(pad_to "link" 14)$([ -n "$T_CONNECT" ] && echo "outbound to $T_CONNECT" || echo "inbound on $T_LISTEN")"
    box_row "$(pad_to "protocol" 14)$(transport_label "$T_TRANSPORT")"
    box_row "$(pad_to "carries" 14)$(mode_label "$T_MODE")"
    if [ "$T_MODE" = "forward" ]; then
        box_row "$(pad_to "ports" 14)$(printf '%s' "$T_FORWARDS" | tr -d '"' | tr ',' ' ')"
    else
        box_row "$(pad_to "addresses" 14)${T_TUNLOCAL} ${BX_ARR} ${T_TUNPEER}"
    fi
    box_row "$(pad_to "carriers" 14)${T_CARRIERS}"
    box_bot
    say ""
    if ! confirm "create it?"; then
        warn "cancelled, nothing was written"
        pause
        return 1
    fi

    # -- write and start ---------------------------------------------------
    say ""
    local file; file="$(cfg_save)"
    if ! "$CORE_BIN" -c "$file" -check >/dev/null 2>&1; then
        fail "the core rejected this configuration"
        "$CORE_BIN" -c "$file" -check 2>&1 | sed 's/^/      /'
        rm -f "$file"
        pause; return 1
    fi

    write_units
    service_enable_start "$T_NAME"
    enable_watchdog quiet
    ok "$T_NAME is configured and running"

    # -- token -------------------------------------------------------------
    head2 "Token for the other server"
    dim "on the ${C_OFF}$( [ "$T_ROLE" = "server" ] && echo KHAREJ || echo IRAN )${C_DIM} server: New Tunnel ${BX_ARR} Apply a token"
    say ""
    rule
    printf '%s\n' "${C_YEL}$(cfg_peer_token)${C_OFF}"
    rule
    say ""
    warn "treat it like a password - it contains the shared key"
    say ""
    tunnel_status_block "$T_NAME"
    pause
}

# ---------------------------------------------------------------------------
# apply a token
# ---------------------------------------------------------------------------

# apply_token turns one of those back into a running tunnel on this server.
import_tunnel() {
    banner
    head2 "Apply a token"
    dim "paste what the other server printed when you made the tunnel there"
    say ""
    local token=""
    ask token "token"
    [ -n "$token" ] || return 1

    local raw
    raw="$(printf '%s' "$token" | tr -d ' \t\r\n' | base64 -d 2>/dev/null)"
    case "$raw" in
        p1\|*) ;;
        *) fail "that is not a Pingify token"; pause; return 1 ;;
    esac

    local ver mode transport ep psk carriers window keepalive tl tp mtu
    IFS='|' read -r ver mode transport ep psk carriers window keepalive tl tp mtu <<TOKEN
$raw
TOKEN
    if [ -z "$psk" ] || [ -z "$ep" ]; then
        fail "the token is incomplete"
        pause; return 1
    fi

    cfg_reset
    T_MODE="$mode"; T_TRANSPORT="$transport"; T_PSK="$psk"
    T_CARRIERS="$carriers"; T_WINDOW="$window"; T_KEEPALIVE="$keepalive"
    case "$ep" in
        c=*)  T_CONNECT="${ep#c=}"; T_ROLE="client" ;;
        l=*)  T_LISTEN="${ep#l=}";  T_ROLE="client" ;;
        *) fail "the token is malformed"; pause; return 1 ;;
    esac
    if [ "$T_MODE" = "tun" ]; then
        T_TUNLOCAL="$tl"; T_TUNPEER="$tp"; T_TUNMTU="${mtu:-1380}"; T_TUNIF="pfy0"
    fi

    # The ports live on the IRAN server, so this end carries none. The name
    # follows the same rule as everywhere else: which end, and which port.
    local port="${ep##*:}"
    T_NAME="$(printf '%s' "$(side_label "$T_ROLE")" | tr 'A-Z' 'a-z')-${port}"
    if [ -f "$(cfg_file "$T_NAME")" ]; then
        say ""
        warn "a tunnel named $T_NAME already exists on this server"
        confirm "replace it?" || return 1
        systemctl stop "pingify@$T_NAME" >/dev/null 2>&1
    fi
    T_STATUS="127.0.0.1:$(pick_free_port 9700)"

    local file
    file="$(cfg_save)"
    if ! "$CORE_BIN" -c "$file" -check >/dev/null 2>&1; then
        say ""
        fail "the core rejected this configuration"
        core_matches_script || dim "the core is $(core_version) and this script is $PINGIFY_VERSION"
        "$CORE_BIN" -c "$file" -check 2>&1 | sed 's/^/      /'
        rm -f "$file"
        pause; return 1
    fi

    write_units
    service_enable_start "$T_NAME"
    enable_watchdog quiet
    say ""
    ok "$T_NAME is configured and running"
    say ""
    tunnel_status_block "$T_NAME"
    pause
}
