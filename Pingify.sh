#!/usr/bin/env bash
#
# Pingify - a tunnel between a server in Iran and a server abroad.
#
# This file is everything the person at the other end of an ssh session sees.
# It is first because everything else draws through it.
#
# The rules it follows, and why:
#
#   The width comes from the terminal, not from a constant. The old manager
#   drew everything 64 columns wide, which wasted half of a laptop window and
#   overflowed a phone. Here it is `tput cols`, clamped to 60 and 100, and it
#   is re-read when the window changes.
#
#   Colour is by role, not by name. Seven roles, five colours: accent, good,
#   warning, bad, muted. There is no blue and no magenta, and grey is
#   load-bearing - unknown is not a failure, so a thing that cannot be measured
#   is grey and never red. An ICMP tunnel cannot answer a ping, by design; the
#   old manager would have drawn that in red and called a healthy tunnel dead.
#
#   Anything with data in it is drawn with rules and columns, not boxes. A box
#   has a right-hand edge, so every value has to be cut to fit or the frame
#   breaks - and the old row() padded without cutting, so one long address
#   pushed the closing bar off the end and shredded the panel. A rule with a
#   title in it has no right edge and cannot break. Boxes are kept for the two
#   places where this script generates the contents and knows the width.
#
#   Nothing clears the screen. Over a link with a hundred milliseconds of delay
#   and real loss, scrollback is where you look when the connection stutters,
#   and the old banner threw it away on every keystroke.

set -o pipefail

PINGIFY_VERSION="2.0.0"

# --------------------------------------------------------------------------
# what this terminal can do
# --------------------------------------------------------------------------

# ui_detect runs once at startup and again on SIGWINCH.
#
# Two gates, not one. Output colour depends on stdout being a terminal, but
# read -p writes its prompt to *stderr*, so a script whose stdout is piped
# still shows prompts - and colouring them by stdout leaves them bare while
# everything around them is painted.
ui_detect() {
    UI_COLOR=8
    UI_GLYPH=ascii

    case "${TERM:-dumb}" in dumb | "") UI_COLOR=none ;; esac
    [ -n "${NO_COLOR:-}" ] && UI_COLOR=none
    [ -t 1 ] || UI_COLOR=none
    if [ "$UI_COLOR" != none ] && [ "$(tput colors 2>/dev/null || echo 0)" -ge 256 ]; then
        UI_COLOR=256
    fi
    UI_PROMPT_COLOR=$UI_COLOR
    [ -t 2 ] || UI_PROMPT_COLOR=none

    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]*) UI_GLYPH=utf8 ;;
    esac
    [ -n "${PINGIFY_ASCII:-}" ] && UI_GLYPH=ascii

    UI_W=${PINGIFY_WIDTH:-$(tput cols 2>/dev/null || echo 80)}
    case "$UI_W" in '' | *[!0-9]*) UI_W=80 ;; esac
    [ "$UI_W" -gt 100 ] && UI_W=100
    [ "$UI_W" -lt 60 ] && UI_W=60

    ui_palette
    ui_glyphs
}

ui_palette() {
    if [ "$UI_COLOR" = none ]; then
        C_OFF= C_B= C_ACCENT= C_OK= C_WARN= C_BAD= C_MUTE= C_KEY= C_RULE=
        return
    fi
    C_OFF=$'\033[0m'
    C_B=$'\033[1m'
    C_OK=$'\033[32m'
    C_WARN=$'\033[33m'
    C_BAD=$'\033[31m'
    C_MUTE=$'\033[90m'
    C_KEY=$'\033[2m'
    C_RULE=$'\033[90m'
    # Raw cyan is unreadable on the white-background terminals a lot of people
    # actually run. Where there are 256 colours, use a desaturated teal.
    if [ "$UI_COLOR" = 256 ]; then
        C_ACCENT=$'\033[38;5;37m'
    else
        C_ACCENT=$'\033[36m'
    fi
}

ui_glyphs() {
    if [ "$UI_GLYPH" = utf8 ]; then
        G_H='─' G_V='│' G_TL='╭' G_TR='╮' G_BL='╰' G_BR='╯'
        G_CUR='▸' G_ON='●' G_OFF='○' G_OK='✓' G_BAD='✗' G_WARN='!'
        G_ARROW='→' G_BOTH='⇄' G_CUT='…' G_DASH='—'
    else
        G_H='-' G_V='|' G_TL='+' G_TR='+' G_BL='+' G_BR='+'
        G_CUR='>' G_ON='*' G_OFF='o' G_OK='+' G_BAD='x' G_WARN='!'
        G_ARROW='->' G_BOTH='<->' G_CUT='~' G_DASH='-'
    fi
}

# --------------------------------------------------------------------------
# measuring and cutting text
# --------------------------------------------------------------------------

# vislen is how many columns a string occupies once the escape codes are gone.
#
# Columns, not characters. A CJK glyph or an emoji is two columns wide and a
# combining mark is none, and a name containing one slides every column to the
# right of it. The escape stripping is parameter expansion rather than a call
# to sed, because this runs once per cell and a subprocess per cell is how a
# menu comes to take a second to draw over ssh.
vislen() {
    local s=$1 out= n=0 c
    while [ -n "$s" ]; do
        case $s in
        $'\033['*)
            s=${s#$'\033['}
            s=${s#*m}
            continue
            ;;
        esac
        out=$out${s:0:1}
        s=${s:1}
    done
    # Bash counts characters; correct for the ones that are not one column.
    local i ch
    n=${#out}
    for ((i = 0; i < ${#out}; i++)); do
        ch=${out:i:1}
        case $ch in
        # Combining marks take no space of their own.
        [$'̀'-$'ͯ'] | [$'ً'-$'ٟ'] | [$'‌'-$'‏']) n=$((n - 1)) ;;
        # The wide ranges: CJK, Hangul, and the emoji planes.
        [$'ᄀ'-$'ᅟ'] | [$'⺀'-$'꓏'] | [$'가'-$'힣'] | \
            [$'豈'-$'﫿'] | [$'︰'-$'﹯'] | [$'＀'-$'｠'] | \
            [$'￠'-$'￦']) n=$((n + 1)) ;;
        esac
    done
    printf '%s' "$n"
}

# trunc_to cuts a string to a width, marking that it did.
#
# Every column goes through this. A value that does not fit is cut and given a
# mark, because a value that does not fit and is printed anyway takes the next
# column's place and the reader has no way to know it happened.
trunc_to() {
    local s=$1 w=$2
    [ "$(vislen "$s")" -le "$w" ] && { printf '%s' "$s"; return; }
    local cut=$((w - 1))
    [ "$cut" -lt 1 ] && cut=1
    printf '%s%s' "${s:0:cut}" "$G_CUT"
}

pad_to() {
    local s cut=$2
    s=$(trunc_to "$1" "$cut")
    local n
    n=$(vislen "$s")
    printf '%s%*s' "$s" "$((cut - n))" ''
}

rep() {
    local out
    printf -v out '%*s' "$2" ''
    printf '%s' "${out// /$1}"
}

# --------------------------------------------------------------------------
# the pieces a screen is made of
# --------------------------------------------------------------------------

say() { printf '%s\n' "$*"; }
blank() { printf '\n'; }
dim() { printf '  %s%s%s\n' "$C_MUTE" "$*" "$C_OFF"; }
ok() { printf '  %s%s%s %s\n' "$C_OK" "$G_OK" "$C_OFF" "$*"; }
warn() { printf '  %s%s%s %s\n' "$C_WARN" "$G_WARN" "$C_OFF" "$*"; }
bad() { printf '  %s%s%s %s\n' "$C_BAD" "$G_BAD" "$C_OFF" "$*"; }

# fix is the line under a failure that says what to do about it. Every failure
# gets one. A health check that lists problems without them is a list of
# reasons to be worried and no way to stop being worried.
fix() { printf '     %sfix:%s  %s\n' "$C_MUTE" "$C_OFF" "$*"; }

die() {
    printf '\n  %s%s%s %s\n\n' "$C_BAD" "$G_BAD" "$C_OFF" "$*" >&2
    exit 1
}

# fill_to writes a line and fills the rest of the width with a glyph.
#
# Everything that draws a horizontal line goes through it, because every one of
# them used to work out how many glyphs to draw and every one was off by one in
# its own direction - a box came out 59 columns on its rules and 60 on its
# rows. Build the line, measure what is on it, fill what is left. There is no
# count left to get wrong.
fill_to() {
    local text=$1 glyph=$2 tail=${3:-} n
    n=$((UI_W - $(vislen "$text") - $(vislen "$tail")))
    [ "$n" -lt 0 ] && n=0
    printf '%s%s%s%s%s' "$text" "$C_RULE" "$(rep "$glyph" "$n")" "$tail" "$C_OFF"
}

# rule draws a horizontal line with an optional title inside it. No right-hand
# end, so no value can break it.
rule() {
    local title=${1:-}
    if [ -z "$title" ]; then
        printf '%s\n' "$(fill_to "  $C_RULE" "$G_H")"
        return
    fi
    printf '%s\n' "$(fill_to "  $C_RULE$G_H$G_H$C_OFF $C_B$title$C_OFF " "$G_H")"
}

# field is one key and one value, aligned. The key column is fixed so that
# every screen lines up with every other screen.
UI_KEYW=12
field() {
    printf '    %s%s%s  %s\n' \
        "$C_KEY" "$(pad_to "$1" "$UI_KEYW")" "$C_OFF" \
        "$(trunc_to "$2" $((UI_W - UI_KEYW - 8)))"
}

# item is a menu line. The key is what you type.
item() {
    printf '   %s%2s%s  %s\n' "$C_ACCENT" "$1" "$C_OFF" "$2"
}

# item2 is a menu line with a note to its right, for settings that show their
# current value.
item2() {
    local left
    left=$(pad_to "$2" $((UI_W - 30)))
    printf '   %s%2s%s  %s%s%s%s\n' \
        "$C_ACCENT" "$1" "$C_OFF" "$left" "$C_MUTE" "$3" "$C_OFF"
}

group() { printf '  %s%s%s\n' "$C_B" "$1" "$C_OFF"; }

# panel is the one full box, used where this script generates the contents and
# knows how wide they are.
# row prints cells padded to the widths in UI_COLS, which the caller sets once.
# Nothing hand-aligns a column: the header and the rows read the same array, so
# they cannot drift apart.
row() {
    local i=0 out= cell
    for cell in "$@"; do
        out=$out$(pad_to "$cell" "${UI_COLS[i]:-12}")'  '
        i=$((i + 1))
    done
    out=${out%  }
    # Whatever widths the caller chose, the line still has to fit. A table that
    # overflows is worse than one with a cut value in it: the overflow wraps and
    # takes the row below it with it.
    printf '   %s\n' "$(trunc_to "$out" $((UI_W - 3)))"
}

# The three lines of a box must come to the same width or it is not a box.
panel_open() {
    printf '%s\n' "$(fill_to "  $C_RULE$G_TL$G_H$C_OFF $C_B$1$C_OFF " "$G_H" "$G_TR")"
}
panel_row() {
    local inner=$((UI_W - 6))
    printf '  %s%s%s %s %s%s%s\n' \
        "$C_RULE" "$G_V" "$C_OFF" "$(pad_to "$1" "$inner")" \
        "$C_RULE" "$G_V" "$C_OFF"
}
panel_field() {
    panel_row "$(printf '%s%s%s  %s' "$C_KEY" "$(pad_to "$1" 14)" "$C_OFF" "$2")"
}
panel_close() {
    printf '%s\n' "$(fill_to "  $C_RULE$G_BL" "$G_H" "$G_BR")"
}

# state_dot is the one glyph that says whether a thing is doing its job.
# Four states, and the fourth is grey: not known is not broken.
state_dot() {
    case $1 in
    running) printf '%s%s%s' "$C_OK" "$G_ON" "$C_OFF" ;;
    idle) printf '%s%s%s' "$C_WARN" "$G_ON" "$C_OFF" ;;
    stopped) printf '%s%s%s' "$C_WARN" "$G_OFF" "$C_OFF" ;;
    *) printf '%s%s%s' "$C_MUTE" "$G_OFF" "$C_OFF" ;;
    esac
}

# rtt_colour is the reason the palette has four states rather than three.
# Under a hundred milliseconds is good, under two hundred is worth a look,
# above that is bad - and anything that is not a number is grey, because red
# should mean "this path is slow", never "there is no path".
rtt_colour() {
    case $1 in
    '' | *[!0-9.]*) printf '%s' "$C_MUTE" ;;
    *) if [ "${1%%.*}" -lt 100 ]; then printf '%s' "$C_OK"
       elif [ "${1%%.*}" -lt 200 ]; then printf '%s' "$C_WARN"
       else printf '%s' "$C_BAD"; fi ;;
    esac
}

banner() {
    blank
    panel_open "P I N G I F Y   $PINGIFY_VERSION"
    panel_row "$1"
    panel_close
}

# --------------------------------------------------------------------------
# asking
# --------------------------------------------------------------------------

# ask reads one answer into the caller's variable.
#
# The locals are prefixed because bash scopes locals dynamically: a caller that
# names its own variable `def` and passes it here would have had it overwritten
# by this function's `def`. The prefix is not decoration.
#
# Every call site passes a validator. There is no unvalidated ask in this
# script and a test enforces that, because an unvalidated answer is a value the
# core rejects half an hour later with a Go error the user cannot read.
ask() {
    local _pk_var=$1 _pk_prompt=$2 _pk_def=${3:-} _pk_check=${4:-v_any} _pk_in _pk_err
    while :; do
        if [ -n "$_pk_def" ]; then
            printf '  %s%s%s %s [%s%s%s]: ' "$C_ACCENT" "$G_CUR" "$C_OFF" \
                "$_pk_prompt" "$C_ACCENT" "$_pk_def" "$C_OFF" >&2
        else
            printf '  %s%s%s %s: ' "$C_ACCENT" "$G_CUR" "$C_OFF" "$_pk_prompt" >&2
        fi
        # An answer that never comes is not a loop to spin in. A piped script
        # that runs out of input stops here rather than asking for ever.
        IFS= read -r _pk_in || return 1
        [ -z "$_pk_in" ] && _pk_in=$_pk_def
        case $_pk_in in
        q | Q) WIZ_QUIT=1; return 1 ;;
        esac
        if _pk_err=$("$_pk_check" "$_pk_in" 2>&1); then
            printf -v "$_pk_var" '%s' "$_pk_in"
            return 0
        fi
        printf '    %s%s %s%s\n' "$C_BAD" "$G_BAD" "$_pk_err" "$C_OFF" >&2
    done
}

# pick is the one menu idiom in this script.
#
# One idiom, because the old wizard had two: a strict picker for some questions
# and a lenient ask-with-a-default for others, so a fat-fingered 9 at the wrong
# question silently built a config nobody chose.
pick() {
    local _pk_var=$1 _pk_prompt=$2 _pk_def=$3 _pk_n=$4 _pk_in
    while :; do
        printf '  %s%s%s %s [%s%s%s]: ' "$C_ACCENT" "$G_CUR" "$C_OFF" \
            "$_pk_prompt" "$C_ACCENT" "$_pk_def" "$C_OFF" >&2
        IFS= read -r _pk_in || return 1
        [ -z "$_pk_in" ] && _pk_in=$_pk_def
        case $_pk_in in
        q | Q) WIZ_QUIT=1; return 1 ;;
        esac
        case $_pk_in in
        '' | *[!0-9]*) ;;
        *) if [ "$_pk_in" -ge 1 ] && [ "$_pk_in" -le "$_pk_n" ]; then
               printf -v "$_pk_var" '%s' "$_pk_in"
               return 0
           fi ;;
        esac
        printf '    %s%s pick a number from 1 to %s%s\n' \
            "$C_BAD" "$G_BAD" "$_pk_n" "$C_OFF" >&2
    done
}

confirm() {
    local _pk_prompt=$1 _pk_def=${2:-y} _pk_in _pk_hint='[Y/n]'
    [ "$_pk_def" = n ] && _pk_hint='[y/N]'
    while :; do
        printf '  %s%s%s %s %s: ' "$C_ACCENT" "$G_CUR" "$C_OFF" "$_pk_prompt" "$_pk_hint" >&2
        IFS= read -r _pk_in || return 1
        [ -z "$_pk_in" ] && _pk_in=$_pk_def
        case $_pk_in in
        y | Y | yes | YES) return 0 ;;
        n | N | no | NO) return 1 ;;
        esac
    done
}

# menu_key reads a single keystroke for a screen whose choices are not all
# numbers. It falls back to a line when there is no terminal to read a key
# from, so the tests can drive it.
menu_key() {
    local _pk_var=$1 _pk_in
    printf '  %s%s%s select: ' "$C_ACCENT" "$G_CUR" "$C_OFF" >&2
    if [ -t 0 ]; then
        IFS= read -rn1 _pk_in || return 1
        printf '\n' >&2
    else
        IFS= read -r _pk_in || return 1
    fi
    printf -v "$_pk_var" '%s' "$_pk_in"
}

# --------------------------------------------------------------------------
# validators
# --------------------------------------------------------------------------
#
# A validator prints why it refused and returns non-zero. The message is shown
# under the prompt and the question is asked again; nothing in this script
# throws a session away because one answer was wrong.

v_any() { [ -n "$1" ] || { echo "say something"; return 1; }; }

v_host() {
    local h=$1
    case $h in
    '') echo "an address is needed - both servers name the one abroad"; return 1 ;;
    esac
    # A dotted quad, each part in range.
    if [[ $h =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local o
        for o in ${h//./ }; do
            [ "$o" -le 255 ] || { echo "$h: $o is not part of an address"; return 1; }
        done
        return 0
    fi
    # Otherwise a hostname: letters, digits, dots and dashes, with a dot in it.
    case $h in
    *[!a-zA-Z0-9.-]* | .* | *. | *..*) echo "$h is not an address or a hostname"; return 1 ;;
    *.*) return 0 ;;
    esac
    echo "$h is not an address or a hostname"
    return 1
}

v_port() {
    case $1 in
    '' | *[!0-9]*) echo "a port is a number"; return 1 ;;
    esac
    { [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; } || { echo "a port is between 1 and 65535"; return 1; }
}

v_octet() {
    case $1 in
    '' | *[!0-9]*) echo "pick a number"; return 1 ;;
    esac
    { [ "$1" -ge 1 ] && [ "$1" -le 254 ]; } || { echo "between 1 and 254"; return 1; }
}

v_mtu() {
    case $1 in
    '' | *[!0-9]*) echo "an mtu is a number"; return 1 ;;
    esac
    { [ "$1" -ge 576 ] && [ "$1" -le 9000 ]; } ||
        { echo "the core takes 576 to 9000; 1320 is what works on most paths"; return 1; }
}

v_token() {
    [ "${#1}" -ge 8 ] || { echo "the core wants at least eight characters"; return 1; }
}

v_name() {
    case $1 in
    '' | *[!a-zA-Z0-9_-]*) echo "letters, digits, dash and underscore"; return 1 ;;
    esac
    [ "${#1}" -le 24 ] || { echo "keep it under twenty-five characters"; return 1; }
}

# --------------------------------------------------------------------------
# waiting
# --------------------------------------------------------------------------

# spin shows that something is happening, and shows nothing at all when there
# is nobody watching or when colour has been turned off. It starts late: a
# spinner for something that takes a fifth of a second is a flash of noise.
spin() {
    local msg=$1 pid=$2 i=0 frames='|/-\'
    if [ ! -t 2 ] || [ "$UI_COLOR" = none ]; then
        wait "$pid"
        return $?
    fi
    sleep 0.3
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r  %s%s%s %s' "$C_ACCENT" "${frames:i++%4:1}" "$C_OFF" "$msg" >&2
        sleep 0.12
    done
    printf '\r%*s\r' $((UI_W - 1)) '' >&2
    wait "$pid"
}

ui_detect
trap 'ui_detect' WINCH
#!/usr/bin/env bash
#
# Where things live, and the handful of operations everything else is built
# from: reading and writing a config, asking systemd what it thinks, and asking
# a running tunnel how it is.
#
# The layout is ordinary FHS. The old manager kept everything under /root,
# which meant a second administrator could not find it, backups that skip /root
# skipped the tunnel, and the configs sat beside the operator's ssh keys.

# Every path takes its value from the environment if there is one. Not for
# flexibility - nobody moves these - but so that a test can point the whole
# script at a temporary directory and be certain it cannot touch the machine
# it is running on. Two of the five already did, which meant a test could
# redirect the configs and then have the real core binary invoked on them.
PINGIFY_BIN=${PINGIFY_BIN:-/usr/local/bin/pingify}
CORE_BIN=${PINGIFY_CORE_BIN:-/usr/local/bin/pingify-core}
CFG_DIR=${PINGIFY_CFG_DIR:-/etc/pingify}
STATE_DIR=${PINGIFY_STATE_DIR:-/var/lib/pingify}
SRC_DIR=${PINGIFY_SRC_DIR:-/usr/local/src/pingify}
UNIT_DIR=${PINGIFY_UNIT_DIR:-/etc/systemd/system}

# The status endpoint listens on the loopback address. One port per tunnel,
# from a base, so two tunnels on one server do not collide.
STATUS_BASE=19900

# --------------------------------------------------------------------------
# the small things everything uses
# --------------------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

# list_has is membership without a pipeline.
#
# The obvious form - `generator | grep -q x` - is wrong here and the reason is
# worth keeping: grep exits at the first match, the generator writing into the
# closed pipe takes SIGPIPE, and with pipefail the whole thing reports 141.
# A loop cannot do that.
list_has() {
    local want=$1 item
    shift
    for item in "$@"; do [ "$item" = "$want" ] && return 0; done
    return 1
}

require_root() {
    [ "$(id -u)" = 0 ] || die "run this as root - it installs services and changes the network"
}

# ensure_dirs is called before anything writes. 0700 on the config directory
# because the files in it contain the security token.
ensure_dirs() {
    mkdir -p "$CFG_DIR" "$STATE_DIR" "$SRC_DIR"
    chmod 0700 "$CFG_DIR"
}

arch_go() {
    case "$(uname -m)" in
    x86_64 | amd64) printf 'amd64' ;;
    aarch64 | arm64) printf 'arm64' ;;
    *) printf '' ;;
    esac
}

# sed_i writes through a temporary file rather than using sed -i, which is a
# GNU extension and takes an argument on BSD that it refuses on GNU.
sed_i() {
    local script=$1 file=$2 tmp
    tmp=$(mktemp)
    sed "$script" "$file" >"$tmp" && cat "$tmp" >"$file"
    rm -f "$tmp"
}

# --------------------------------------------------------------------------
# the config file
# --------------------------------------------------------------------------
#
# The core reads a small, fixed subset of TOML that this script writes: a table
# header, then bare key = value lines. Both halves of that agreement live in
# one place each - core/internal/config for reading, here for writing - and
# these three functions are the only things in the manager that touch the text.
# The old script had five hand-rolled parsers of the same file and they had
# already drifted apart.

toml_get() {
    local file=$1 table=$2 key=$3
    awk -v t="$table" -v k="$key" '
        /^[[:space:]]*\[/ { cur = $0; gsub(/[][[:space:]]/, "", cur); next }
        cur == t {
            line = $0
            sub(/#.*/, "", line)
            if (line ~ "^[[:space:]]*" k "[[:space:]]*=") {
                sub(/^[^=]*=[[:space:]]*/, "", line)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
                gsub(/^"|"$/, "", line)
                print line
                exit
            }
        }
    ' "$file" 2>/dev/null
}

# toml_set replaces a value in place, keeping the file's order and comments. A
# key that is not there yet is appended to its table.
toml_set() {
    local file=$1 table=$2 key=$3 val=$4 quoted=${5:-auto}
    case $quoted in
    auto) case $val in '' | *[!0-9]*) quoted=yes ;; *) quoted=no ;; esac ;;
    esac
    [ "$val" = true ] || [ "$val" = false ] && quoted=no

    local rendered=$val
    [ "$quoted" = yes ] && rendered="\"$val\""

    awk -v t="$table" -v k="$key" -v v="$rendered" '
        BEGIN { done = 0; seen = 0 }
        /^[[:space:]]*\[/ {
            # Leaving the table we wanted without having written the key means
            # it belongs at the end of that table, not at the end of the file.
            if (cur == t && !done) { print k " = " v; done = 1 }
            cur = $0; gsub(/[][[:space:]]/, "", cur)
            if (cur == t) seen = 1
            print; next
        }
        {
            if (cur == t && !done) {
                line = $0; sub(/#.*/, "", line)
                if (line ~ "^[[:space:]]*" k "[[:space:]]*=") {
                    print k " = " v; done = 1; next
                }
            }
            print
        }
        END {
            if (cur == t && !done) { print k " = " v; done = 1 }
            # A table nobody has written yet. The old manager silently did
            # nothing here, so status.port was set, read back empty, and the
            # feature simply did not work.
            if (!seen) { print ""; print "[" t "]"; print k " = " v }
        }
    ' "$file" >"$file.tmp" && cat "$file.tmp" >"$file"
    rm -f "$file.tmp"
}

cfg_file() { printf '%s/%s.toml' "$CFG_DIR" "$1"; }

# cfg_list is every tunnel this server knows about, in a stable order.
cfg_list() {
    local f n
    for f in "$CFG_DIR"/*.toml; do
        [ -e "$f" ] || continue
        n=${f##*/}
        printf '%s\n' "${n%.toml}"
    done
}

cfg_count() { cfg_list | grep -c . || true; }

# cfg_apply is the only way a config is changed.
#
# Copy, edit, ask the core whether it will accept the result, and put the old
# one back if it will not. The old manager wrote this out five times with five
# different messages, and one of the five forgot to restore.
cfg_apply() {
    local name=$1 editor=$2 restart=${3:-yes} f
    f=$(cfg_file "$name")
    [ -f "$f" ] || { bad "there is no tunnel called $name"; return 1; }

    cp -f "$f" "$f.bak"
    if ! "$editor" "$f"; then
        mv -f "$f.bak" "$f"
        return 1
    fi

    local out
    if ! out=$("$CORE_BIN" -c "$f" -check 2>&1); then
        mv -f "$f.bak" "$f"
        bad "the core would not accept that change, so nothing was changed:"
        printf '%s\n' "$out" | sed 's/^/       /'
        return 1
    fi
    rm -f "$f.bak"
    [ "$restart" = yes ] && svc_do restart "$name"
    return 0
}

# status_port is derived, not stored: the config carries it, and a tunnel
# created before this existed gets one the first time it is asked.
status_port() {
    local name=$1 p
    p=$(toml_get "$(cfg_file "$name")" status port)
    case $p in '' | *[!0-9]* | 0) p='' ;; esac
    if [ -z "$p" ]; then
        local i=0 n
        for n in $(cfg_list); do
            [ "$n" = "$name" ] && { p=$((STATUS_BASE + i)); break; }
            i=$((i + 1))
        done
    fi
    printf '%s' "${p:-$STATUS_BASE}"
}

# --------------------------------------------------------------------------
# systemd
# --------------------------------------------------------------------------

# unit_write writes the template unit. Once, at install and on a version
# change - not on every tunnel creation, which is a global side effect from a
# per-tunnel action and how the old script came to rewrite four units whenever
# anybody added one.
unit_write() {
    cat >"$UNIT_DIR/pingify@.service" <<'UNIT'
[Unit]
Description=Pingify tunnel %i
Documentation=https://github.com/GreatTeejay/Pingify
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/pingify-core -c /etc/pingify/%i.toml
Restart=always
RestartSec=2
# A limit that means something. The old unit had StartLimitIntervalSec=0, which
# turns the limit off entirely and lets a config the core refuses restart every
# two seconds for ever, filling the journal and hiding the reason.
StartLimitIntervalSec=300
StartLimitBurst=20

# A raw ICMP socket and a tun device need these two, and nothing needs more.
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
NoNewPrivileges=yes

# The tunnel is a long-lived process that holds a lot of sockets open.
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload 2>/dev/null || true
}

svc_state() {
    local name=$1
    if ! systemctl is-active --quiet "pingify@$name" 2>/dev/null; then
        systemctl is-enabled --quiet "pingify@$name" 2>/dev/null &&
            printf 'stopped' || printf 'disabled'
        return
    fi
    printf 'active'
}

# svc_do never swallows the result. The old service_enable_start returned the
# exit status of a `systemctl daemon-reload` that always succeeds, so the caller
# printed a green "is running" over a unit that had failed to start.
svc_do() {
    local what=$1 name=$2
    case $what in
    start | restart)
        systemctl "$what" "pingify@$name" 2>&1 | sed 's/^/       /'
        sleep 1
        if systemctl is-active --quiet "pingify@$name"; then
            ok "$name is running"
            return 0
        fi
        bad "$name did not start"
        journalctl -u "pingify@$name" -n 15 --no-pager -o cat 2>/dev/null |
            sed 's/^/       /'
        return 1
        ;;
    stop | disable)
        systemctl "$what" "pingify@$name" >/dev/null 2>&1
        ok "$name $what""ped"
        ;;
    enable)
        systemctl enable --now "pingify@$name" 2>&1 | sed 's/^/       /'
        sleep 1
        if systemctl is-active --quiet "pingify@$name"; then
            ok "$name is running"
            return 0
        fi
        bad "$name did not start"
        journalctl -u "pingify@$name" -n 15 --no-pager -o cat 2>/dev/null |
            sed 's/^/       /'
        return 1
        ;;
    esac
}

# --------------------------------------------------------------------------
# asking a tunnel how it is
# --------------------------------------------------------------------------
#
# One function, because there is one source. The core answers on a loopback
# port with JSON, so nothing here parses English prose out of a log - which is
# what the old manager did, with an awk that took the eighth field of a
# sentence and broke the day the sentence was reworded.
#
# Sets ST_* in the caller. Returns non-zero when the tunnel does not answer,
# and in that case the ST_* are empty rather than stale.

tun_stats() {
    local name=$1 json
    ST_UP= ST_IN= ST_OUT= ST_LOST= ST_GAPS= ST_LATE= ST_UPTIME= ST_DROPPED=
    ST_TRANSPORT= ST_PROFILE= ST_SIDE=

    json=$(curl -s --max-time 3 "http://127.0.0.1:$(status_port "$name")/" 2>/dev/null) || return 1
    [ -n "$json" ] || return 1

    ST_UP=$(json_field "$json" up)
    ST_IN=$(json_field "$json" in_mbit)
    ST_OUT=$(json_field "$json" out_mbit)
    ST_LOST=$(json_field "$json" path_lost)
    ST_LATE=$(json_field "$json" path_reordered)
    ST_GAPS=$(json_field "$json" path_gaps)
    ST_UPTIME=$(json_field "$json" uptime_sec)
    ST_DROPPED=$(json_field "$json" dropped)
    ST_TRANSPORT=$(json_field "$json" transport)
    ST_PROFILE=$(json_field "$json" profile)
    ST_SIDE=$(json_field "$json" side)
    return 0
}

# json_field reads one value out of the core's report. The report is generated
# by encoding/json with indentation, one field per line, so this is enough and
# a JSON parser would be a dependency bought for nothing.
json_field() {
    printf '%s' "$1" | awk -v k="\"$2\":" '
        index($0, k) {
            sub(/^[^:]*:[[:space:]]*/, "")
            sub(/,$/, "")
            gsub(/^"|"$/, "")
            print
            exit
        }'
}

# round1 is for rates: 412.336 Mbit/s is not more informative than 412.3.
round1() {
    case $1 in
    '' | *[!0-9.]*) printf '%s' "$G_DASH"; return ;;
    esac
    printf '%.1f' "$1" 2>/dev/null || printf '%s' "$G_DASH"
}

# human_secs is an uptime a person reads rather than counts.
human_secs() {
    local s=$1
    case $s in '' | *[!0-9]*) printf '%s' "$G_DASH"; return ;; esac
    if [ "$s" -lt 60 ]; then printf '%ds' "$s"
    elif [ "$s" -lt 3600 ]; then printf '%dm' $((s / 60))
    elif [ "$s" -lt 86400 ]; then printf '%dh %dm' $((s / 3600)) $((s % 3600 / 60))
    else printf '%dd %dh' $((s / 86400)) $((s % 86400 / 3600)); fi
}
#!/usr/bin/env bash
#
# The core: the Go program this script exists to install, and the two things
# needed to get one - its source, and a compiler for it.
#
# Everything in here is shaped by one fact. The server this runs on is in
# Iran and may be able to reach neither a module proxy nor GitHub, so the Go
# sources travel inside this script as plain heredocs and are compiled on the
# machine, offline, with GOPROXY=off. The core has no dependencies at all,
# which is what makes that possible.
#
# There is deliberately no "download a prebuilt binary instead" path. A
# fallback that needs the network is not a fallback for the only machine that
# ever needs one, and carrying it would mean the offline path was never
# exercised and rotted quietly until the day it mattered.
#
# The single step that can want the network is a Go toolchain, and only when
# this machine has none or has one older than the module asks for. That
# download is described in plain words and confirmed before it happens.

# The compiler ensure_go settled on. Empty until it has run.
GO_BIN=

GO_DL_BASE=https://go.dev/dl

# --------------------------------------------------------------------------
# the sources
# --------------------------------------------------------------------------

# write_core_sources lays the module out under DIR with its paths intact -
# cmd/pingify and internal/*, not a heap of basenames in one directory. The
# old bundle did flatten them, which was harmless while the core was a single
# package and stopped compiling the hour it became a module.
#
# The body below is generated. build.sh replaces the marker line with one
# mkdir -p covering every directory, then one quoted heredoc per file, each
# writing into "$d" - so that variable name is part of the agreement with
# build.sh and cannot be renamed here. build.sh then sources the built script,
# calls this function into a temporary tree, diffs it against the repository
# and compiles the result, so the round trip is checked rather than hoped for.
write_core_sources() {
    local d=$1
    mkdir -p "$d"
    mkdir -p "$d/cmd/pingify" "$d/internal/buf" "$d/internal/carrier" "$d/internal/config" "$d/internal/link" "$d/internal/logging" "$d/internal/status"
    cat > "$d/go.mod" <<'PINGIFY_GO_SOURCE_EOF'
module pingify

go 1.24
PINGIFY_GO_SOURCE_EOF
    cat > "$d/cmd/pingify/main.go" <<'PINGIFY_GO_SOURCE_EOF'
package main

import (
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"pingify/internal/carrier"
	"pingify/internal/config"
	"pingify/internal/link"
	"pingify/internal/logging"
	"pingify/internal/status"
)

// Pingify, the core.
//
// A tunnel between a server in Iran and a server abroad. The Iran server is
// the one users reach; the abroad server is the one with the internet on the
// other side of it. What matters about it, in the order it matters: latency,
// then throughput, then staying up. Nothing else is worth a millisecond.
//
// This is the second core. The first one worked, and worked well - by the end
// it was level with the tunnel it was being compared against on ping and ahead
// of it under load. What it did not have was a shape: it was written outward
// from a first working version over two days, so its structure was the order
// in which things were discovered rather than the way the problem is actually
// laid out.
//
// The way the problem is actually laid out:
//
//	a carrier moves messages between the two servers        carrier.go
//	over UDP, or ICMP, or something dressed as TLS          udp.go, ...
//	and one thing rides on it, chosen by the mode:
//	    the private link - one IP packet per message        link.go
//	    forwarded ports  - many connections per carrier     (not yet)
//
// Transports are added one at a time and each is measured on the real path
// between Tehran and Frankfurt before the next one starts. What was learned
// from the first core is in docs/measured.md, and none of it is re-learned
// here by accident: every finding in that file is either satisfied by this
// code or has not been reached yet.
const version = "2.0.0"

func main() {
	// Before anything else, because everything else is downstream of having
	// somewhere to run. See sched.go.
	widenScheduler()

	var (
		cfgPath = flag.String("c", "", "path to the config file")
		check   = flag.Bool("check", false, "read the config, say whether it is good, and stop")
		showVer = flag.Bool("version", false, "print the version and stop")
		ask     = flag.String("status", "", "ask a running tunnel how it is (host:port or just a port) and stop")
		healthz = flag.String("healthz", "", "exit 0 only if the tunnel at this address is up")
	)
	flag.Parse()

	if *showVer {
		fmt.Println("pingify-core " + version)
		return
	}
	if *healthz != "" {
		r, err := status.Fetch(*healthz)
		if err != nil || !r.Up {
			os.Exit(1)
		}
		return
	}
	if *ask != "" {
		r, err := status.Fetch(*ask)
		if err != nil {
			logging.Die("could not ask the tunnel at %s: %v", *ask, err)
		}
		status.Print(r)
		return
	}
	if *cfgPath == "" {
		logging.Die("no config: pass -c /path/to/config.toml")
	}

	cfg, err := config.Load(*cfgPath)
	if err != nil {
		logging.Die("%s: %v", *cfgPath, err)
	}
	if *check {
		fmt.Printf("%s: good - %s side, %s mode, %s transport\n",
			*cfgPath, cfg.Side, cfg.Mode, cfg.Transport.Type)
		return
	}
	logging.SetLevel(cfg.Level)

	logging.Info("pingify-core %s starting: %s, %s side, %s over %s",
		version, cfg.Name, cfg.Side, cfg.Mode, cfg.Transport.Type)

	car, err := carrier.Open(cfg)
	if err != nil {
		logging.Die("carrier: %v", err)
	}

	l, err := link.New(cfg, car)
	if err != nil {
		car.Close()
		logging.Die("private link: %v", err)
	}

	l.Start()
	go car.Run()
	if cfg.Dials() {
		go car.Keepalive(time.Duration(cfg.Transport.Keepalive) * time.Second)
	}
	go reportEvery(30*time.Second, car, l)
	go status.New(cfg, version, car, l).Serve(cfg.StatusPort)

	logging.Info("running")

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop

	logging.Info("stopping")
	l.Close()
	car.Close()
	logging.Info("%s", l)
}

// reportEvery says what the tunnel has been doing, but only when it has been
// doing something. A line every thirty seconds saying nothing happened fills
// a log with the absence of news, and the one line that matters is then in the
// middle of a thousand that do not.
func max64(a, b uint64) uint64 {
	if a > b {
		return a
	}
	return b
}

func reportEvery(every time.Duration, c carrier.Full, l *link.Link) {
	tk := time.NewTicker(every)
	defer tk.Stop()
	var lastRx, lastTx uint64
	var lastMissing, lastLate, lastGaps uint64
	for range tk.C {
		rx, tx, bad, replay, errs := c.Counters()
		if rx == lastRx && tx == lastTx {
			continue
		}
		secs := every.Seconds()
		logging.Info("carrier: %.1f Mbit/s in, %.1f Mbit/s out",
			float64(rx-lastRx)*8/secs/1e6, float64(tx-lastTx)*8/secs/1e6)
		if bad > 0 || replay > 0 {
			logging.Debug("carrier: %d not ours, %d already seen", bad, replay)
		}
		// How much was lost matters less than how it was lost. Losses spread
		// one at a time are noise a congestion window shrugs off; the same
		// number arriving in runs is a window halved once per run.
		if missing, late, gaps := c.Lost(); missing != lastMissing || late != lastLate {
			run := float64(missing-lastMissing) / float64(max64(gaps-lastGaps, 1))
			logging.Info("the path lost %d and reordered %d in the last %s (%d gaps, %.0f packets each)",
				missing-lastMissing, late-lastLate, every, gaps-lastGaps, run)
			lastMissing, lastLate, lastGaps = missing, late, gaps
		}
		if errs > 0 {
			logging.Debug("carrier: %d sends failed", errs)
		}
		if d := l.Dropped(); d > 0 {
			logging.Warn("private link: %d packets could not be put on the wire", d)
		}
		lastRx, lastTx = rx, tx
	}
}
PINGIFY_GO_SOURCE_EOF
    cat > "$d/cmd/pingify/sched.go" <<'PINGIFY_GO_SOURCE_EOF'
package main

import "runtime"

// widenScheduler gives the runtime two processors on a machine that has one.
//
// A tunnel is not short of work, it is short of turns. With one processor Go
// has one P, and a goroutine that becomes runnable waits for the running one
// to reach a point where it can be taken off - which sysmon forces only after
// ten milliseconds. Two of those is twenty, and twenty is what was measured
// on a single-core server in Iran: a packet already read off the device and
// already built sat waiting for a turn to be handed to the wire.
//
//	                   device to wire     round trip
//	one processor       18.63 ms           99.9 ms
//	two                  0.05 ms           81.2 ms
//	four                 0.08 ms           81.3 ms
//
// The wire underneath was 81, so all of the gap was this. Throughput did not
// pay for the fix: sixteen streams carried 391.9 Mbit/s on one processor and
// 391.5 on two.
//
// Two Ps on one core is not two cores. It is permission for a goroutine that
// is ready to run to be picked up while another is still running, which is
// all that was missing - this work waits on sockets, it does not compute.
// Most servers people run this on in Iran have one core.
func widenScheduler() {
	if runtime.GOMAXPROCS(0) < 2 {
		runtime.GOMAXPROCS(2)
	}
}
PINGIFY_GO_SOURCE_EOF
    cat > "$d/internal/buf/buf.go" <<'PINGIFY_GO_SOURCE_EOF'
package buf

import "sync"

// One buffer size, big enough for any datagram this tunnel sends, handed out
// and given back rather than allocated. At four hundred megabits the link
// moves something like forty thousand packets a second, and forty thousand
// allocations a second is work the collector then has to undo.
//
// A buffer always carries its carrier's headroom at the front. The layer above
// builds its packet after it, so a packet is written once and never shifted
// along to make room for a header that was known about all along.
const bufSize = 2048

// Put hands a buffer back. It is a function rather than the pool itself so
// that nothing outside can reach past it.
func Put(bp *[]byte) { pool.Put(bp) }

var pool = sync.Pool{
	New: func() any {
		b := make([]byte, bufSize)
		return &b
	},
}

// Take returns a buffer with room for a packet of n bytes behind head bytes
// of headroom, already sliced to the full length.
func Take(head, n int) *[]byte {
	bp := pool.Get().(*[]byte)
	b := (*bp)[:cap(*bp)]
	if len(b) < head+n {
		b = make([]byte, head+n)
	}
	*bp = b[:head+n]
	return bp
}

// The replay window.
//
// A sliding bitmap, not a map swept once per packet. The counter of the
// newest packet seen sits at the top of the window, and each older one is a
// bit below it; a packet that arrives in order - which is nearly all of them -
// costs one shift and one bit set, and no allocation at all.
//
// The old core swept a map of counters on every packet to expire the ones
// that had fallen out of the window, which is O(window) per packet to learn
// something a shift already knows.
const (
	ReplayDepth = 4096
	replayWords = ReplayDepth / 64
)

type ReplayWindow struct {
	top   uint32 // the highest counter seen
	bits  [replayWords]uint64
	empty bool

	// What the far end sent that we did not get, and what arrived behind
	// something newer. The counter is consecutive at the sender, so a number
	// that is skipped is a packet the path lost - and that is not visible
	// anywhere else: not in a device counter, not in a qdisc, not in the
	// socket. It was found once by capturing at the far end and counting by
	// hand, and once was enough.
	skipped, late, gaps uint64
}

func NewReplayWindow() *ReplayWindow { return &ReplayWindow{empty: true} }

// Lost is what the far end sent that never arrived, what arrived behind
// something newer, and how many separate runs the missing packets came in.
//
// The last of those is the one that matters. Losses spread one at a time are
// noise a congestion window shrugs off; the same number arriving in runs is a
// window halved once per run.
func (w *ReplayWindow) Lost() (missing, late, gaps uint64) {
	return w.skipped, w.late, w.gaps
}

// Fresh reports whether this counter is one we have not already delivered,
// and records it. It is called from one goroutine only.
func (w *ReplayWindow) Fresh(seq uint32) bool {
	if w.empty {
		w.empty = false
		w.top = seq
		w.set(0)
		return true
	}
	switch {
	case seq == w.top:
		return false
	case int32(seq-w.top) > 0:
		// Newer than anything seen. Drag the window forward, clearing the
		// bits that just fell off the bottom.
		if d := seq - w.top; d > 1 {
			w.skipped += uint64(d - 1)
			w.gaps++
		}
		w.shift(seq - w.top)
		w.top = seq
		w.set(0)
		return true
	default:
		w.late++
		back := w.top - seq
		if back >= ReplayDepth {
			return false // older than the window remembers; treat as replay
		}
		if w.get(back) {
			return false
		}
		w.set(back)
		return true
	}
}

func (w *ReplayWindow) get(back uint32) bool {
	return w.bits[back/64]&(1<<(back%64)) != 0
}

func (w *ReplayWindow) set(back uint32) {
	w.bits[back/64] |= 1 << (back % 64)
}

// shift moves every bit up by n places, which is what "the newest packet is
// now this one" means when the newest is the top of the window.
func (w *ReplayWindow) shift(n uint32) {
	if n >= ReplayDepth {
		w.bits = [replayWords]uint64{}
		return
	}
	words, bits := n/64, n%64
	if bits == 0 {
		for i := replayWords - 1; i >= 0; i-- {
			if uint32(i) >= words {
				w.bits[i] = w.bits[uint32(i)-words]
			} else {
				w.bits[i] = 0
			}
		}
		return
	}
	for i := replayWords - 1; i >= 0; i-- {
		var v uint64
		if uint32(i) >= words {
			v = w.bits[uint32(i)-words] << bits
			if uint32(i) > words {
				v |= w.bits[uint32(i)-words-1] >> (64 - bits)
			}
		}
		w.bits[i] = v
	}
}
PINGIFY_GO_SOURCE_EOF
    cat > "$d/internal/carrier/batch_linux.go" <<'PINGIFY_GO_SOURCE_EOF'
//go:build linux && (amd64 || arm64)

package carrier

import (
	"syscall"
	"unsafe"
)

// One crossing into the kernel per batch, instead of one per packet.
//
// At four hundred megabits this link moves something like forty thousand
// packets a second in each direction. One recvfrom and one sendto each is
// eighty thousand system calls a second, on a server with one core, and it is
// the whole difference between what the plain path measured and what the wire
// can carry:
//
//	                    idle ping   16 streams
//	one call per packet   81.0 ms    351 Mbit/s
//	recvmmsg/sendmmsg     81.0 ms    (see below)
//
// The ping was never the problem - a single packet with nothing behind it
// costs one call either way. It is throughput that pays, and it pays in the
// place that is hardest to see from inside the process, because the packets
// are not dropped by us and not delayed by us: they simply arrive at the wire
// later than they could have.
//
// recvmmsg and sendmmsg are not in Go's syscall package as functions, only as
// numbers, so the structures are laid out here. Both are stable kernel ABI and
// have been since 2.6.33; the layout below is for 64-bit, which is what the
// build tag says.
const (
	recvBatch = 128 // what a busy link can have waiting when we look
	sendBatch = 64  // the most a sender will ever be asked for

	// How many packets go on the wire in one crossing unless the config says
	// otherwise. One - which is to say, none.
	//
	// This is not a throughput knob. It is a burst knob, and the path cares
	// about bursts far more than it cares about syscalls. Measured at Germany
	// by counting gaps in our own sequence numbers, one stream pushing:
	//
	//	  send_batch    packets the path lost    one stream
	//	      64             2.870%               129.8 Mbit/s
	//	      16             0.728%               144.1
	//	       4             1.145%               157.0
	//	       1             0.000%               170.6
	//
	// flagtun on the same path in the same minute lost nothing at all, which
	// is what said the loss was ours and not the route's. Draining the device
	// and firing sixty-four packets into the wire at line rate undoes the
	// pacing the TCP inside had carefully applied, and something on the way
	// polices the burst by dropping a run of it - a hundred and seventy-three
	// packets in a row, twice in fifteen seconds.
	//
	// Batching cost nothing to give up. Sixteen streams carried 442.7 Mbit/s
	// at a batch of one against 443.2 at sixty-four, because with sixteen
	// streams the packets are already there when we look; it is the single
	// stream, the one that arrives paced, that a batch can only damage.
	defaultSendBatch = 1
)

// mmsghdr is the kernel's struct mmsghdr: a msghdr and the length that call
// filled in. syscall.Msghdr is already the right shape for the first half.
type mmsghdr struct {
	hdr syscall.Msghdr
	len uint32
	_   [4]byte
}

// batchReader takes up to recvBatch datagrams off a socket in one call.
type batchReader struct {
	msgs []mmsghdr
	iovs []syscall.Iovec
	sas  []syscall.RawSockaddrInet4
	bufs [][]byte
}

func newBatchReader(size int) *batchReader {
	r := &batchReader{
		msgs: make([]mmsghdr, recvBatch),
		iovs: make([]syscall.Iovec, recvBatch),
		sas:  make([]syscall.RawSockaddrInet4, recvBatch),
		bufs: make([][]byte, recvBatch),
	}
	for i := range r.bufs {
		r.bufs[i] = make([]byte, size)
		r.iovs[i].Base = &r.bufs[i][0]
		r.iovs[i].Len = uint64(size)
		r.msgs[i].hdr.Name = (*byte)(unsafe.Pointer(&r.sas[i]))
		r.msgs[i].hdr.Namelen = uint32(unsafe.Sizeof(r.sas[i]))
		r.msgs[i].hdr.Iov = &r.iovs[i]
		r.msgs[i].hdr.Iovlen = 1
	}
	return r
}

// read waits for the socket to have something and takes everything that is
// there, up to the batch size. It returns how many datagrams arrived.
//
// rc.Read parks the goroutine on the network poller until the socket is
// readable, then calls this; returning false means "not ready after all, wait
// again", which is what EAGAIN means when a poller wakes on a packet another
// goroutine got to first.
func (r *batchReader) read(rc syscall.RawConn) (int, error) {
	var n int
	var errno syscall.Errno
	err := rc.Read(func(fd uintptr) bool {
		ret, _, e := syscall.Syscall6(sysRecvmmsg, fd,
			uintptr(unsafe.Pointer(&r.msgs[0])), uintptr(len(r.msgs)), 0, 0, 0)
		if e == syscall.EAGAIN || e == syscall.EINTR {
			return false
		}
		n, errno = int(ret), e
		return true
	})
	if err != nil {
		return 0, err
	}
	if errno != 0 {
		return 0, errno
	}
	// The kernel writes each datagram's length into msg_len and leaves the
	// iovecs alone, so the buffers are ready for the next call as they are.
	return n, nil
}

// packet returns the i'th datagram of the batch and the address it came from.
func (r *batchReader) packet(i int) ([]byte, [4]byte) {
	return r.bufs[i][:r.msgs[i].len], r.sas[i].Addr
}

// batchWriter puts up to sendBatch datagrams on a socket in one call.
type batchWriter struct {
	msgs []mmsghdr
	iovs []syscall.Iovec
	sas  []syscall.RawSockaddrInet4
}

func newBatchWriter() *batchWriter {
	w := &batchWriter{
		msgs: make([]mmsghdr, sendBatch),
		iovs: make([]syscall.Iovec, sendBatch),
		sas:  make([]syscall.RawSockaddrInet4, sendBatch),
	}
	for i := range w.msgs {
		w.sas[i].Family = syscall.AF_INET
		w.msgs[i].hdr.Name = (*byte)(unsafe.Pointer(&w.sas[i]))
		w.msgs[i].hdr.Namelen = uint32(unsafe.Sizeof(w.sas[i]))
		w.msgs[i].hdr.Iov = &w.iovs[i]
		w.msgs[i].hdr.Iovlen = 1
	}
	return w
}

// write sends the given packets to one address, and reports how many the
// kernel took. A short count is not an error: the caller keeps the rest for
// the next crossing rather than throwing them away.
func (w *batchWriter) write(rc syscall.RawConn, pkts [][]byte, to [4]byte) (int, error) {
	n := len(pkts)
	if n > len(w.msgs) {
		n = len(w.msgs)
	}
	for i := 0; i < n; i++ {
		w.sas[i].Addr = to
		w.iovs[i].Base = &pkts[i][0]
		w.iovs[i].Len = uint64(len(pkts[i]))
	}

	var sent int
	var errno syscall.Errno
	err := rc.Write(func(fd uintptr) bool {
		ret, _, e := syscall.Syscall6(sysSendmmsg, fd,
			uintptr(unsafe.Pointer(&w.msgs[0])), uintptr(n), 0, 0, 0)
		if e == syscall.EAGAIN || e == syscall.EINTR {
			return false
		}
		sent, errno = int(ret), e
		return true
	})
	if err != nil {
		return 0, err
	}
	if errno != 0 {
		return sent, errno
	}
	return sent, nil
}

const canBatch = true
PINGIFY_GO_SOURCE_EOF
    cat > "$d/internal/carrier/batch_linux_amd64.go" <<'PINGIFY_GO_SOURCE_EOF'
//go:build linux && amd64

package carrier

// The two calls this core makes by number, because Go's syscall package
// exports SYS_RECVMMSG on some architectures and SYS_SENDMMSG on none of them.
// Both have been fixed kernel ABI since 2.6.33 and 3.0.
const (
	sysRecvmmsg = 299
	sysSendmmsg = 307
)
PINGIFY_GO_SOURCE_EOF
    cat > "$d/internal/carrier/batch_linux_arm64.go" <<'PINGIFY_GO_SOURCE_EOF'
//go:build linux && arm64

package carrier

// arm64 uses the generic syscall table, where these two sit at different
// numbers from x86-64. See batch_linux_amd64.go.
const (
	sysRecvmmsg = 243
	sysSendmmsg = 269
)
PINGIFY_GO_SOURCE_EOF
    cat > "$d/internal/carrier/batch_other.go" <<'PINGIFY_GO_SOURCE_EOF'
//go:build !(linux && (amd64 || arm64))

package carrier

import (
	"errors"
	"syscall"
)

// Everywhere the batched calls are not available: a laptop, or a 32-bit
// server. The carrier falls back to one call per packet, which is correct and
// slower, and says so in the log rather than pretending.

const (
	canBatch         = false
	recvBatch        = 1
	sendBatch        = 1
	defaultSendBatch = 1
)

var errNoBatch = errors.New("recvmmsg and sendmmsg are not available here")

type batchReader struct{ n int }

func newBatchReader(size int) *batchReader { return &batchReader{} }

func (r *batchReader) read(rc syscall.RawConn) (int, error) { return 0, errNoBatch }

func (r *batchReader) packet(i int) ([]byte, [4]byte) { return nil, [4]byte{} }

type batchWriter struct{}

func newBatchWriter() *batchWriter { return &batchWriter{} }

func (w *batchWriter) write(rc syscall.RawConn, pkts [][]byte, to [4]byte) (int, error) {
	return 0, errNoBatch
}
PINGIFY_GO_SOURCE_EOF
    cat > "$d/internal/carrier/carrier.go" <<'PINGIFY_GO_SOURCE_EOF'
package carrier

// A carrier moves whole messages between the two servers.
//
// There are two kinds and the difference is not a detail. A packet carrier -
// UDP, and ICMP after it - can lose a message and can deliver two out of
// order. A stream carrier - TCP, and the things dressed up as TCP - can do
// neither, and pays for that in head-of-line blocking.
//
// Which one is underneath decides what has to ride on top, so the choice is
// made here, once, and is not rediscovered in every layer above. That was the
// structural mistake in the old core: the private link was built on a stream
// multiplexer it never needed, and the path that skips the multiplexer had to
// be bolted on beside it afterwards.
//
// The private link wants a packet carrier and nothing else. One IP packet is
// one datagram; if it is lost, the TCP inside it will notice long before we
// could, and if it arrives out of order, that is what IP has always been
// allowed to do.
type Carrier interface {
	// Headroom is how many bytes at the front of a buffer belong to the
	//  The layer above builds its packet after them, so that a packet
	// is written once and never shifted along to make room for a header.
	Headroom() int

	// MaxPayload is the largest packet this carrier will take, after the
	// headroom has been subtracted.
	MaxPayload() int

	// Burst is how many packets this carrier wants handed to it at once.
	// One means the reader sends each packet as it reads it, which is what
	// keeps the pacing the TCP inside applied - see the note in the link.
	Burst() int

	// Send puts one datagram on the wire, on its own. It takes ownership of
	// the buffer: after Send returns the caller must not look at it again,
	// whatever the error says. This is for keepalives and nothing else - the
	// data path uses a sender.
	Send(bp *[]byte) error

	// NewSender returns somewhere to send batches from. One per goroutine
	// that sends, because a sender holds the arrays the kernel is handed and
	// two goroutines sharing them would hand it each other's packets.
	//
	// Batching used to live behind a channel here, with one goroutine draining
	// it. That is the obvious design and it is wrong: one flow is read by one
	// device queue, so every packet of it crossed the channel and waited to be
	// scheduled on the other side. Sixteen streams did not care - there was
	// always something to batch - but a single stream fell from 245 Mbit/s to
	// 164, because a single stream is exactly the case where the queue is
	// always empty and the handoff is pure cost.
	//
	// So the goroutine that read the packets sends them. Nothing is handed
	// over and nothing is woken.
	NewSender() Sender

	// OnPacket registers what to do with each datagram that arrives. It is
	// called on the goroutine that read the datagram off the socket, and the
	// slice it is given stops being valid when it returns.
	OnPacket(func(b []byte))

	// Up reports whether the carrier knows where to send. On the side that
	// dials this is true from the start; on the side that waits it becomes
	// true when the first datagram carrying the right tag arrives.
	Up() bool

	Close() error
}

// A Sender puts a batch of packets on the wire in one crossing into the
// kernel. It belongs to one goroutine and is not safe for two.
type Sender interface {
	// send takes ownership of every buffer in the batch, and returns them to
	// the pool however it goes.
	Send(bps []*[]byte)
}
PINGIFY_GO_SOURCE_EOF
    cat > "$d/internal/carrier/frame.go" <<'PINGIFY_GO_SOURCE_EOF'
package carrier

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"hash"
	"sync"
	"sync/atomic"

	"pingify/internal/buf"
)

// What every packet carrier puts in front of a packet, and the only thing they
// share.
//
// Twelve bytes: eight of tag, four of counter.
//
//	0                 8                12
//	+-----------------+----------------+-----------------------------+
//	|  tag            |  counter       |  the IP packet              |
//	+-----------------+----------------+-----------------------------+
//
// The tag says a datagram is ours. Anyone can send to an open UDP port and
// anyone at all can send an echo request, so without it the first thing a
// scanner sends would be handed to the kernel as an IP packet.
//
// It is one hash over the counter and the first bytes of the packet - not the
// whole packet, which at four hundred megabits would mean hashing fifty
// megabytes a second to learn what the first thirty-two bytes already say. One
// hash per packet, not two: the old core built a second tag it then checked in
// a different order, and that was pure cost.
//
// There is no encryption and none is wanted. What travels through this tunnel
// is already TLS, and what is asked of the tunnel is speed, ping and stability.
const (
	tagLen   = 8
	seqLen   = 4
	frameLen = tagLen + seqLen
	tagOver  = 32 // how many bytes of the payload the tag covers
)

type framer struct {
	key  []byte
	hp   sync.Pool // hash.Hash, kept rather than made per packet
	seq  uint32
	seen *buf.ReplayWindow

	badTag, replayed uint64
}

// lost reports what the far end sent that never arrived, and what arrived out
// of order. Both are counted from the sequence number, which is consecutive at
// the sender - so a gap in it is the one measure of the path that no counter
// on either machine will show.
func (f *framer) lost() (missing, late, gaps uint64) {
	return f.seen.Lost()
}

// newFramer derives this carrier's key from the token the user typed.
//
// Each carrier passes its own label, so a datagram built for one can never be
// mistaken for a datagram built for another - which matters the moment two
// tunnels between the same pair of servers are given the same token.
func newFramer(token, label string) *framer {
	m := hmac.New(sha256.New, []byte(label))
	m.Write([]byte(token))
	f := &framer{key: m.Sum(nil), seen: buf.NewReplayWindow()}
	f.hp.New = func() any { return hmac.New(sha256.New, f.key) }
	return f
}

func (f *framer) headroom() int { return frameLen }

// covered is the part of a frame the tag is computed over: the counter, and as
// much of the packet as tagOver allows.
func covered(b []byte) []byte {
	if len(b) > frameLen+tagOver {
		return b[tagLen : frameLen+tagOver]
	}
	return b[tagLen:]
}

func (f *framer) tag(dst, over []byte) {
	m := f.hp.Get().(hash.Hash)
	m.Reset()
	m.Write(over)
	var sum [sha256.Size]byte
	copy(dst, m.Sum(sum[:0])[:tagLen])
	f.hp.Put(m)
}

// seal stamps a frame with the next counter and its tag. b starts at the tag,
// so a carrier with a header of its own passes the slice after that header.
func (f *framer) seal(b []byte) {
	binary.BigEndian.PutUint32(b[tagLen:frameLen], atomic.AddUint32(&f.seq, 1))
	f.tag(b[:tagLen], covered(b))
}

// open checks a frame and returns what was inside it. The second result is
// false for anything that is not ours or that has already been delivered.
//
// It is called from one goroutine, which is what lets the replay window be a
// plain sliding bitmap with no lock on it.
func (f *framer) open(b []byte) ([]byte, bool) {
	if len(b) < frameLen {
		return nil, false
	}
	var want [tagLen]byte
	f.tag(want[:], covered(b))
	if !hmac.Equal(want[:], b[:tagLen]) {
		f.badTag++
		return nil, false
	}
	if !f.seen.Fresh(binary.BigEndian.Uint32(b[tagLen:frameLen])) {
		f.replayed++
		return nil, false
	}
	return b[frameLen:], true
}
PINGIFY_GO_SOURCE_EOF
    cat > "$d/internal/carrier/icmp.go" <<'PINGIFY_GO_SOURCE_EOF'
package carrier

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"pingify/internal/buf"
	"pingify/internal/config"
	"pingify/internal/logging"
)

// ICMP: the transport that works on the path this tunnel was built for.
//
// Not the fallback. On the route between the Iran server and Frankfurt, UDP
// gets six packets back and then nothing - on every port, from every source
// port, for ever. ICMP gets all of them. That is the whole reason this exists
// and the reason it is worth being careful with.
//
// Both ends send echo *requests*, type 8, and both accept either type. This is
// the single fact that took longest to find, and it is worth writing down
// plainly because every textbook says the opposite: client asks, server
// answers. Counted on the real path, out of 300:
//
//	                    echo reply (0)    echo request (8)
//	  Iran -> Germany    nothing           300 of 300
//	  Germany -> Iran    nothing           most
//	  Iran -> Turkey     300 of 300        300 of 300
//
// An unsolicited echo reply is not part of any conversation, and the route
// drops it in both directions. A request is the start of one, and passes. So a
// tunnel built the textbook way does not come up on this path at all, which is
// exactly what "ICMP does not work" looked like for weeks.
//
// Because both ends send requests, both kernels would answer them by
// themselves and double every packet on the wire. net.ipv4.icmp_echo_ignore_all
// stops that, and this carrier sets it rather than leaving it to a document
// nobody reads.
//
// On the wire:
//
//	 0     1     2           4         6         8              20
//	 +-----+-----+-----------+---------+---------+--------------+-------------+
//	 |type |code | checksum  |   id    |  seq    | tag + count  | the packet  |
//	 +-----+-----+-----------+---------+---------+--------------+-------------+
//	 |<---------- ICMP's own header ------------>|<--- ours --->|

// errNoFilter means the kernel would not sort our echoes for us, so Go has to.
// Not an error anybody needs to act on - see attachICMPFilter.
var errNoFilter = errors.New("icmp: no socket filter on this platform")

const (
	icmpHdrLen     = 8
	icmpEchoReply  = 0
	icmpEchoReq    = 8
	icmpMaxPayload = 1460 // 1500 on the path, less 20 of IP and 8 of ICMP
	icmpReadBuf    = 1600
)

type icmpCarrier struct {
	pc *net.IPConn
	rc syscall.RawConn
	fr *framer
	id uint16

	seq   uint32 // the ICMP header's own sequence, which nothing reads
	peer  atomic.Pointer[net.IPAddr]
	peer4 atomic.Uint32 // the same address as a number, to compare per packet

	onPacket atomic.Pointer[func([]byte)]

	batched bool
	burst   int

	// Whether the kernel handed us the IP header. It does on a raw socket, and
	// Go takes it off again in ReadFromIP but not in recvmmsg - so it is looked
	// for rather than assumed, and said once.
	sawIPHeader sync.Once

	done chan struct{}
	once sync.Once

	rxBytes, txBytes  uint64
	sendErrs, wrongID uint64
	notEcho, dropped  uint64
}

func newICMPCarrier(cfg *config.Config) (*icmpCarrier, error) {
	c := &icmpCarrier{
		fr:    newFramer(cfg.Token, "pingify icmp v1"),
		id:    icmpIDFrom(cfg.Token),
		done:  make(chan struct{}),
		burst: cfg.Tuning.SendBatch,
	}
	if c.burst <= 0 {
		c.burst = defaultSendBatch
	}

	pc, err := net.ListenIP("ip4:icmp", &net.IPAddr{IP: net.IPv4zero})
	if err != nil {
		return nil, fmt.Errorf("open raw icmp socket: %v (this needs root)", err)
	}
	c.pc = pc

	if cfg.Dials() {
		addr, err := net.ResolveIPAddr("ip4", cfg.Transport.Kharej)
		if err != nil {
			pc.Close()
			return nil, fmt.Errorf("resolve %s: %v", cfg.Transport.Kharej, err)
		}
		c.setPeer(addr.IP)
		logging.Info("carrier: echoing to %s, id %d", addr.IP, c.id)
	} else {
		logging.Info("carrier: listening for echoes, id %d", c.id)
	}

	silenceKernelPings()
	tuneSocket(pc, cfg)
	smoothTheWire(cfg)
	pace(pc, cfg, c.done, func() uint64 { return atomic.LoadUint64(&c.txBytes) })

	// The kernel can sort our echoes from everybody else's for nothing, before
	// a packet is queued or a goroutine woken. Without it, every monitoring
	// ping and every scanner on a public address arrives here and is thrown
	// out in Go, one hash at a time - which on a busy address is most of the
	// work the transport does.
	if err := attachICMPFilter(pc, c.id); err != nil {
		logging.Debug("no socket filter (%v); every echo the host sees is sorted here instead", err)
	} else {
		logging.Info("the kernel is filtering echoes for us: only id %d arrives", c.id)
	}

	if canBatch {
		if rc, err := pc.SyscallConn(); err == nil {
			c.rc, c.batched = rc, true
			logging.Info("packet i/o: up to %d in and %d out per crossing into the kernel",
				recvBatch, sendBatch)
		} else {
			logging.Warn("no raw access to the socket (%v): one call per packet", err)
		}
	} else {
		logging.Info("packet i/o: one call per packet on this platform")
	}
	return c, nil
}

func (c *icmpCarrier) setPeer(ip net.IP) {
	v4 := ip.To4()
	if v4 == nil {
		return
	}
	c.peer.Store(&net.IPAddr{IP: append(net.IP(nil), v4...)})
	c.peer4.Store(uint32(v4[0])<<24 | uint32(v4[1])<<16 | uint32(v4[2])<<8 | uint32(v4[3]))
}

func (c *icmpCarrier) Burst() int      { return c.burst }
func (c *icmpCarrier) Headroom() int   { return icmpHdrLen + c.fr.headroom() }
func (c *icmpCarrier) MaxPayload() int { return icmpMaxPayload - c.fr.headroom() }
func (c *icmpCarrier) Up() bool        { return c.peer.Load() != nil }

func (c *icmpCarrier) OnPacket(f func([]byte)) { c.onPacket.Store(&f) }

// stamp fills in the ICMP header, the tag and the checksum. After it, the
// buffer is a whole packet and nothing else needs to touch it.
func (c *icmpCarrier) stamp(b []byte) {
	b[0] = icmpEchoReq
	b[1] = 0
	b[2], b[3] = 0, 0
	binary.BigEndian.PutUint16(b[4:6], c.id)
	binary.BigEndian.PutUint16(b[6:8], uint16(atomic.AddUint32(&c.seq, 1)))
	c.fr.seal(b[icmpHdrLen:])
	binary.BigEndian.PutUint16(b[2:4], icmpChecksum(b))
}

// Send puts one packet on the wire on its own. Only keepalives come this way,
// once every ten seconds, so it does not batch and does not need to.
func (c *icmpCarrier) Send(bp *[]byte) error {
	peer := c.peer.Load()
	b := *bp
	if peer == nil || len(b) < c.Headroom() {
		buf.Put(bp)
		if peer == nil {
			return ErrNoPeer
		}
		return nil
	}
	c.stamp(b)
	n, err := c.pc.WriteToIP(b, peer)
	buf.Put(bp)
	if err != nil {
		atomic.AddUint64(&c.sendErrs, 1)
		return err
	}
	atomic.AddUint64(&c.txBytes, uint64(n))
	return nil
}

// icmpSender belongs to one goroutine reading one device queue, and puts that
// queue's packets on the wire in as few crossings into the kernel as it can.
type icmpSender struct {
	c    *icmpCarrier
	w    *batchWriter
	bufs [][]byte
}

func (c *icmpCarrier) NewSender() Sender {
	if !c.batched {
		return &plainSender{c: c}
	}
	return &icmpSender{c: c, w: newBatchWriter(), bufs: make([][]byte, 0, sendBatch)}
}

func (s *icmpSender) Send(bps []*[]byte) {
	c := s.c
	peer := c.peer.Load()
	if peer == nil {
		for _, bp := range bps {
			buf.Put(bp)
		}
		return
	}
	var to [4]byte
	copy(to[:], peer.IP.To4())

	s.bufs = s.bufs[:0]
	for _, bp := range bps {
		c.stamp(*bp)
		s.bufs = append(s.bufs, *bp)
	}

	// sendmmsg may take fewer than it was offered. What it did not take has
	// not been sent, so it goes round again rather than being let go quietly.
	out := s.bufs
	for len(out) > 0 {
		n, err := s.w.write(c.rc, out, to)
		if err != nil {
			atomic.AddUint64(&c.sendErrs, 1)
			logging.Debug("icmp send batch: %v", err)
			break
		}
		if n <= 0 {
			break
		}
		for i := 0; i < n; i++ {
			atomic.AddUint64(&c.txBytes, uint64(len(out[i])))
		}
		out = out[n:]
	}
	for _, bp := range bps {
		buf.Put(bp)
	}
}

// plainSender is what a platform without the batched calls gets: one packet,
// one call, which is what every carrier did before.
type plainSender struct{ c *icmpCarrier }

func (s *plainSender) Send(bps []*[]byte) {
	for _, bp := range bps {
		_ = s.c.Send(bp)
	}
}

func (c *icmpCarrier) Run() {
	if c.batched {
		c.runBatched()
		return
	}
	c.runPlain()
}

func (c *icmpCarrier) runBatched() {
	r := newBatchReader(icmpReadBuf)
	for {
		n, err := r.read(c.rc)
		for i := 0; i < n; i++ {
			b, from := r.packet(i)
			c.handle(b, from)
		}
		if err != nil {
			select {
			case <-c.done:
			default:
				logging.Warn("icmp read: %v", err)
			}
			return
		}
	}
}

func (c *icmpCarrier) runPlain() {
	buf := make([]byte, icmpReadBuf)
	for {
		n, from, err := c.pc.ReadFromIP(buf)
		if n > 0 {
			var a [4]byte
			if v4 := from.IP.To4(); v4 != nil {
				copy(a[:], v4)
			}
			c.handle(buf[:n], a)
		}
		if err != nil {
			select {
			case <-c.done:
			default:
				logging.Warn("icmp read: %v", err)
			}
			return
		}
	}
}

// handle sorts one arrival. It runs on the goroutine that took the packet off
// the socket and hands it to the private link from there - see link.fromWire
// for why there is nothing in between.
func (c *icmpCarrier) handle(b []byte, from [4]byte) {
	// A raw socket is given the IP header by the kernel. Whether the net
	// package has already taken it off depends on which call read the packet,
	// so it is looked for rather than assumed.
	if len(b) >= 20 && b[0]>>4 == 4 {
		ihl := int(b[0]&0x0f) * 4
		if ihl < 20 || len(b) <= ihl {
			return
		}
		b = b[ihl:]
		c.sawIPHeader.Do(func() {
			logging.Debug("the ip header arrives with each echo; stepping over it")
		})
	}
	if len(b) < icmpHdrLen+frameLen {
		return
	}
	if b[0] != icmpEchoReq && b[0] != icmpEchoReply {
		atomic.AddUint64(&c.notEcho, 1)
		return
	}
	if binary.BigEndian.Uint16(b[4:6]) != c.id {
		atomic.AddUint64(&c.wrongID, 1)
		return
	}

	body, ok := c.fr.open(b[icmpHdrLen:])
	if !ok {
		return
	}

	// The tag was right, so this is the far end, wherever it is speaking from.
	// The side that waits learns the address here and nowhere else.
	v := uint32(from[0])<<24 | uint32(from[1])<<16 | uint32(from[2])<<8 | uint32(from[3])
	if v != 0 && c.peer4.Load() != v {
		c.setPeer(net.IPv4(from[0], from[1], from[2], from[3]))
		logging.Info("carrier: the far end is at %d.%d.%d.%d", from[0], from[1], from[2], from[3])
	}

	atomic.AddUint64(&c.rxBytes, uint64(len(b)))
	if len(body) == 0 {
		return // a keepalive, which has done its whole job by arriving
	}
	if f := c.onPacket.Load(); f != nil {
		(*f)(body)
	}
}

func (c *icmpCarrier) Keepalive(every time.Duration) {
	keepaliveLoop(c, c.done, every)
}

func (c *icmpCarrier) Close() error {
	c.once.Do(func() { close(c.done) })
	return c.pc.Close()
}

func (c *icmpCarrier) Lost() (missing, late, gaps uint64) { return c.fr.lost() }

func (c *icmpCarrier) Counters() (rx, tx, bad, replay, errs uint64) {
	return atomic.LoadUint64(&c.rxBytes), atomic.LoadUint64(&c.txBytes),
		c.fr.badTag, c.fr.replayed,
		atomic.LoadUint64(&c.sendErrs) + atomic.LoadUint64(&c.dropped)
}

// icmpIDFrom is the identifier both ends put in every echo they send.
//
// Derived from the token, so it is the same on both servers and different on
// every tunnel: the kernel can then be told exactly what to keep, and two
// tunnels between the same pair of servers do not collect each other's
// packets. Zero is stepped over, because plenty of tools ping with an
// identifier of zero and matching all of them would defeat the point.
func icmpIDFrom(token string) uint16 {
	m := hmac.New(sha256.New, []byte("pingify icmp id v1"))
	m.Write([]byte(token))
	id := binary.BigEndian.Uint16(m.Sum(nil))
	if id == 0 {
		id = 1
	}
	return id
}

// icmpChecksum is the ones-complement sum the header carries, over the whole
// message with the checksum field held at zero.
func icmpChecksum(b []byte) uint16 {
	var sum uint32
	for i := 0; i+1 < len(b); i += 2 {
		sum += uint32(b[i])<<8 | uint32(b[i+1])
	}
	if len(b)%2 == 1 {
		sum += uint32(b[len(b)-1]) << 8
	}
	for sum>>16 != 0 {
		sum = sum&0xffff + sum>>16
	}
	return ^uint16(sum)
}

// silenceKernelPings stops this host answering echo requests on its own.
//
// Both ends of this tunnel send requests, so without it every packet we send
// is answered twice: once by the tunnel at the far end, and once by the far
// end's kernel, which has no idea it is in the middle of anything. That
// doubles the traffic on the path and hands the sender a reply nobody asked
// for.
//
// It is a system-wide setting, which is worth being honest about in the log:
// ordinary pings to this server stop being answered for as long as this runs.
func silenceKernelPings() {
	const path = "/proc/sys/net/ipv4/icmp_echo_ignore_all"
	was, err := os.ReadFile(path)
	if err != nil {
		return // not Linux, or not permitted; the tunnel still works
	}
	if len(was) > 0 && was[0] == '1' {
		return
	}
	if err := os.WriteFile(path, []byte("1\n"), 0o644); err != nil {
		logging.Warn("could not stop the kernel answering pings (%v) - it will answer"+
			" every echo this tunnel sends, and double the traffic", err)
		return
	}
	logging.Info("the kernel will stop answering pings while this runs" +
		" (icmp_echo_ignore_all), because both ends of this tunnel send requests")
}
PINGIFY_GO_SOURCE_EOF
    cat > "$d/internal/carrier/icmpfilter_linux.go" <<'PINGIFY_GO_SOURCE_EOF'
//go:build linux

package carrier

import (
	"net"
	"runtime"
	"syscall"
	"unsafe"
)

// Keeping other people's pings out of our socket.
//
// A raw ICMP socket receives every echo the host sees. Ours, everybody else's,
// every monitoring ping, every scanner - all of it arrives here and is sorted
// out in Go, one hash at a time. On a public address that is most of the work
// the transport does.
//
// The kernel will do the sorting for nothing. A socket filter runs before the
// packet is queued, so what does not match is never copied, never scheduled
// and never seen. This is the one thing flagtun did that the old core did not,
// and it is why its ICMP tunnel does not drown in the noise of its own
// address.
//
// Hand-assembled with the syscall package rather than written against a BPF
// library, because this core has no dependencies and is built from source on
// servers with no module proxy.
const (
	soAttachFilter = 26

	bpfLD   = 0x00
	bpfLDX  = 0x01
	bpfJMP  = 0x05
	bpfRET  = 0x06
	bpfB    = 0x10
	bpfH    = 0x08
	bpfIND  = 0x40
	bpfMSH  = 0xa0
	bpfJEQ  = 0x10
	bpfK    = 0x00
	bpfPass = 0xffffffff
)

type sockFilter struct {
	code uint16
	jt   uint8
	jf   uint8
	k    uint32
}

// Laid out to match the kernel's struct sock_fprog. The padding between the
// two fields is left to the compiler on purpose: Go aligns a struct the way C
// does, so this is right on every architecture, where writing the gap out by
// hand would be right on exactly the one it was written for.
type sockFprog struct {
	length uint16
	filter *sockFilter
}

// attachICMPFilter tells the kernel to deliver only echoes carrying our
// identifier, and to drop the rest before they arrive.
//
// Failing is not fatal: every check this replaces is still there in Go, and
// the filter only means they are reached far less often.
func attachICMPFilter(pc net.PacketConn, id uint16) error {
	sc, ok := pc.(syscall.Conn)
	if !ok {
		return errNoFilter
	}
	rc, err := sc.SyscallConn()
	if err != nil {
		return err
	}

	// The packet starts at the IP header, so the ICMP header's offset is the
	// header length the packet itself declares - not a guess at 20, which is
	// wrong the moment anything on the path adds an option.
	prog := []sockFilter{
		{code: bpfLDX | bpfB | bpfMSH, k: 0},        // X = IP header length
		{code: bpfLD | bpfB | bpfIND, k: 0},         // A = ICMP type
		{code: bpfJMP | bpfJEQ | bpfK, jt: 1, k: 0}, // echo reply? then check id
		{code: bpfJMP | bpfJEQ | bpfK, jf: 3, k: 8}, // echo request? else drop
		{code: bpfLD | bpfH | bpfIND, k: 4},         // A = ICMP identifier
		{code: bpfJMP | bpfJEQ | bpfK, jt: 1, k: uint32(id)},
		{code: bpfRET | bpfK, k: 0},       // not ours: drop
		{code: bpfRET | bpfK, k: bpfPass}, // ours: keep
	}
	fprog := sockFprog{length: uint16(len(prog)), filter: &prog[0]}

	var serr error
	if err := rc.Control(func(fd uintptr) {
		_, _, e := syscall.Syscall6(syscall.SYS_SETSOCKOPT, fd,
			uintptr(syscall.SOL_SOCKET), uintptr(soAttachFilter),
			uintptr(unsafe.Pointer(&fprog)), unsafe.Sizeof(fprog), 0)
		if e != 0 {
			serr = e
		}
	}); err != nil {
		return err
	}
	// prog must outlive the setsockopt call, and nothing after it refers to
	// the slice.
	runtime.KeepAlive(prog)
	return serr
}
PINGIFY_GO_SOURCE_EOF
    cat > "$d/internal/carrier/pace_linux.go" <<'PINGIFY_GO_SOURCE_EOF'
//go:build linux

package carrier

import (
	"bufio"
	"net"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"

	"pingify/internal/config"
	"pingify/internal/logging"
)

// Smoothing what we put on the wire.
//
// A tunnel does not generate traffic, it repeats it - and the TCP inside has
// already decided when each packet should go. Then something stalls the reader
// for a few milliseconds, a hundred packets pile up behind it, and we hand all
// hundred to the wire as fast as the system calls will go. The path treats
// that the way paths treat bursts: it drops a run of it.
//
// Counted at the far end, one stream pushing, the same fifteen seconds:
//
//	the path lost 895 in the last 30s (9 gaps, 99 packets each)
//
// Ninety-nine at a time. A window survives losses spread one at a time; it
// does not survive nine cliffs a minute.
//
// The kernel already knows how to fix this, and it is the fq queue discipline.
// fq spaces a socket's packets out instead of letting them leave in a clump,
// and that alone - with no rate given, nothing tuned to this path - was most
// of the difference. Three runs each, interleaved:
//
//	eth0 qdisc      one stream    retransmissions
//	fq_codel        187.2 Mbit/s  247, 847, 201
//	fq              229.7         86
//	fq, paced       243.7         none
//
// A rate cap on top helps further but has to suit the path - 400 Mbit/s gave
// 253.8 here where 200 throttled us to 181 - so it is offered and not assumed.
// fq on its own needs no number and cannot be set too low.
const soMaxPacingRate = 47

// egressInterface is the one the default route leaves by, read from the
// kernel rather than guessed at from a name.
func egressInterface() string {
	f, err := os.Open("/proc/net/route")
	if err != nil {
		return ""
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Scan() // the header
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) > 1 && fields[1] == "00000000" {
			return fields[0]
		}
	}
	return ""
}

// rootQdisc is the whole line describing what currently spaces this
// interface's packets - the kind and everything it was set with.
//
// The whole line, not just the kind. Checking only for "fq" and stopping
// there left an interface someone had set to fq with a flow_limit of two
// hundred exactly as it was, and two hundred packets is not enough queue to
// carry anything: sixteen streams fell from 450 Mbit/s to 183 and one stream
// to 75, while the tunnel logged that the queue was already what it wanted.
func rootQdisc(dev string) string {
	out, err := exec.Command("tc", "qdisc", "show", "dev", dev, "root").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// smoothTheWire puts fq on the way out, unless it is already there or the
// config asked us not to.
//
// This is a change to the whole interface and is said out loud for that
// reason. fq is a reasonable queue for anything - it is the default on a lot
// of systems already - and it does not cap anything by itself, so the rest of
// what the server does is unaffected.
func smoothTheWire(cfg *config.Config) {
	if !cfg.Tuning.Pace {
		return
	}
	dev := egressInterface()
	if dev == "" {
		logging.Debug("could not tell which interface leaves this machine; not touching the queue")
		return
	}
	was := rootQdisc(dev)
	if was == "" {
		logging.Debug("could not read the queue on %s", dev)
		return
	}
	limit := strconv.Itoa(cfg.Tuning.QueuePkts)
	if strings.Contains(was, "qdisc fq ") && strings.Contains(was, "flow_limit "+limit+"p") {
		logging.Info("%s already spaces packets the way this wants", dev)
		return
	}

	// flow_limit is how many packets one flow may have waiting, and both ends
	// of the range are wrong. The default of a hundred is the size of the
	// burst this exists to smooth, so it would drop exactly what we came to
	// space out. Twenty thousand - which is what this asked for first - is a
	// quarter of a second of queue at four hundred megabits, and it behaves
	// like one: when the rate cap sits briefly under what is being offered,
	// the queue fills and every packet behind it waits.
	//
	//	  flow_limit   ping under load   16 streams    one stream
	//	     20000       102.8 ms         456.4         246.9 Mbit/s
	//	      2000       104.5            449.9         240.7
	//	       600        88.9            337.4         247.7
	//	       200        82.1            232.1          75.8
	//
	// Measured once at twenty thousand, with the cap still catching up: p50
	// 302 ms and a tail at 1174.
	//
	// Between the floor and that, it is one straight trade and there is no
	// setting on it that is free. Restarted fresh at each depth:
	//
	//	  queue    16 streams   one stream   under load
	//	   600      327.1        193.1        84.6 / 91.5 ms
	//	   900      476.5        245.6        99.8 / 116.3
	//	  1200      461.6        251.0       104.2 / 127.7
	//	  1500      451.5        254.3       111.6 / 127.3
	//
	// Nine hundred is where the two stop fighting. It carries more than any
	// other depth measured - more than flagtun on the same path - keeps a
	// single stream within a few percent of the best it ever manages, and
	// still answers under load faster than flagtun does. Six hundred buys
	// fifteen milliseconds more and pays a third of the throughput for them,
	// which is the wrong side of the trade for a link people watch video over.
	//
	// tuning.queue_packets moves it, and the table says what that costs.
	args := []string{"qdisc", "replace", "dev", dev, "root", "fq", "flow_limit", limit}
	if out, err := exec.Command("tc", args...).CombinedOutput(); err != nil {
		logging.Warn("could not put fq on %s (%v: %s) - packets will leave in bursts"+
			" and the path will drop runs of them", dev, err, strings.TrimSpace(string(out)))
		return
	}
	logging.Info("%s now spaces packets with fq, %s packets deep (%s), so a burst"+
		" leaves as a stream (this changes the queue for everything on %s)",
		dev, limit, cfg.Tuning.Profile, dev)
}

// Choosing the rate without being told it.
//
// Half the link speed was the obvious answer and it is not available: every
// server this runs on is a virtual machine, and virtio_net reports its speed
// as -1. Both of ours do. A number in the config is no better - nobody can
// compute what the path between Tehran and Frankfurt will carry, and a wrong
// one either throttles the tunnel or does nothing.
//
// So it is measured. The tunnel knows exactly how many bytes it put on the
// wire, so once a second it works out the rate, keeps the highest it has ever
// managed, and holds the cap half again above that.
//
// The peak only ever rises, which is what makes this safe: the cap cannot fall
// below a rate already achieved, so it can never throttle the tunnel to less
// than it was doing. And it cannot run away either - the peak only grows when
// the path actually carried more, so on a path that stops at 275 Mbit/s the
// cap settles at about 410 and stays there.
//
// Half again is where the measurements pointed. On this path, which carries
// about 275, the sweep was flat between 350 and 700:
//
//	cap      one stream
//	200      181.0 Mbit/s   throttled
//	280      235.0
//	400      253.8
//	600      245.3
//	1000     237.2
//	none     229.7          bursts get through and the path drops runs
const (
	paceHeadroom = 3       // over 2: the cap is one and a half times the peak
	paceIdleBps  = 1 << 20 // below this a second, nothing is being carried
	paceLearnFor = 3       // seconds of real traffic before clamping anything
)

// paceAdaptively keeps the socket's pacing rate a little above the fastest
// this tunnel has been seen to go.
//
// It starts with no cap at all, and that is not an oversight. A cap chosen
// before anything has been measured is a cap chosen at random, and the first
// attempt here proved it: starting at a floor of 25 Mbit/s throttled the TCP
// inside from the first second, so the rate never grew, so the cap never grew.
// It sat at 23 Mbit/s for three runs in a row. A loop that learns from what it
// limits has to be allowed to see the thing unlimited first.
//
// So it watches for a few seconds, takes the best second it saw, and holds the
// cap half again above it. The peak only ever rises, which is what makes this
// safe: the cap can never fall below a rate already achieved, so it cannot
// throttle the tunnel to less than it was doing. It cannot run away either -
// the peak only grows when the path actually carried more - so on a path that
// stops at 275 Mbit/s it settles around 410 and stays there.
func paceAdaptively(pc net.PacketConn, done <-chan struct{}, sent func() uint64) {
	tk := time.NewTicker(time.Second)
	defer tk.Stop()
	var last, peak, applied uint64
	var busy int
	for {
		select {
		case <-done:
			return
		case <-tk.C:
			now := sent()
			rate := now - last
			last = now
			if rate < paceIdleBps {
				continue // idle, and an idle second says nothing about the path
			}
			busy++

			// The peak follows what the tunnel is doing now, not the best it
			// ever did. Sixteen streams push it far above what one stream can
			// use, and a cap set from that is no cap at all: measured, after a
			// sixteen-stream run the cap sat at 793 Mbit/s and a single stream
			// fell back to 228 from the 255 it manages when the cap suits it.
			//
			// So a busy second that is slower than the peak lets the peak down
			// by a sixty-fourth, which halves it in about forty seconds, and it
			// can never fall below the rate actually being carried. An idle
			// second does nothing at all - it is not evidence about the path.
			if rate > peak {
				peak = rate
			} else if peak -= peak / 64; rate > peak {
				peak = rate
			}
			if busy < paceLearnFor {
				continue
			}
			want := peak * paceHeadroom / 2
			// A little hysteresis, so the cap is not rewritten every second
			// for a percent either way.
			if applied > 0 && want < applied+applied/16 && want > applied-applied/16 {
				continue
			}
			if !setPacingRate(pc, int(want)) {
				return // the kernel will not have it; stop asking
			}
			if applied == 0 {
				logging.Info("pacing follows the path: %d Mbit/s, from the %d it carried",
					want*8/1e6, peak*8/1e6)
			} else {
				logging.Debug("pacing now %d Mbit/s", want*8/1e6)
			}
			applied = want
		}
	}
}

// setPacingRate asks the kernel to spread this socket's packets over time, and
// says whether it was allowed to.
func setPacingRate(pc net.PacketConn, bytesPerSecond int) bool {
	sc, ok := pc.(syscall.Conn)
	if !ok {
		return false
	}
	raw, err := sc.SyscallConn()
	if err != nil {
		return false
	}
	ok = false
	_ = raw.Control(func(fd uintptr) {
		if e := syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET,
			soMaxPacingRate, bytesPerSecond); e != nil {
			logging.Debug("could not set a pacing rate: %v", e)
			return
		}
		ok = true
	})
	return ok
}

// pace spaces this socket's packets out. With a rate in the config that rate
// is used and nothing changes it; without one, it follows the path. Either way
// it does nothing at all unless the interface uses fq, which is why
// smoothTheWire runs first.
func pace(pc net.PacketConn, cfg *config.Config, done <-chan struct{}, sent func() uint64) {
	if !cfg.Tuning.Pace {
		return
	}
	if cfg.Tuning.PaceMbitSet {
		if cfg.Tuning.PaceMbit > 0 && setPacingRate(pc, cfg.Tuning.PaceMbit*1000*1000/8) {
			logging.Info("packets are paced at %d Mbit/s, as the config asks", cfg.Tuning.PaceMbit)
		}
		return
	}
	go paceAdaptively(pc, done, sent)
}
PINGIFY_GO_SOURCE_EOF
    cat > "$d/internal/carrier/pace_other.go" <<'PINGIFY_GO_SOURCE_EOF'
//go:build !linux

package carrier

import (
	"net"

	"pingify/internal/config"
)

// Everywhere that is not Linux. There is no fq to ask for and no socket to
// pace; the tunnel only ever runs on Linux servers.

func smoothTheWire(cfg *config.Config) {}

func pace(pc net.PacketConn, cfg *config.Config, done <-chan struct{}, sent func() uint64) {}
PINGIFY_GO_SOURCE_EOF
    cat > "$d/internal/carrier/sockopt_linux.go" <<'PINGIFY_GO_SOURCE_EOF'
//go:build linux

package carrier

import (
	"net"
	"syscall"

	"pingify/internal/config"
	"pingify/internal/logging"
)

// Asking for a socket buffer the kernel will actually give.
//
// SetReadBuffer asks for SO_RCVBUF, and the kernel silently clamps that to
// net.core.rmem_max - which on an ordinary server is 212992 bytes. It does not
// fail, it does not warn, and nothing above ever learns that the buffer it
// asked for is not the buffer it has.
//
// On a raw socket carrying a private link that is the whole ballgame. The old
// core's own counters said it was dropping nothing, and they were right: the
// kernel was dropping them, before the process ever saw them. Read straight
// off the socket on a real server while the tunnel ran:
//
//	skmem:(r0,rb425984,t0,tb425984,f0,w0,o464,bl0,d925)
//	                                                ^^^^ dropped
//
// Nine hundred and twenty-five packets thrown away for want of room, every one
// of them read by the TCP inside the tunnel as congestion. That is what held a
// single stream to a quarter of what the pair could carry.
//
// SO_RCVBUFFORCE and SO_SNDBUFFORCE are the same request without the clamp,
// and a process with CAP_NET_ADMIN may make it - which this one has, because a
// raw socket needs the same privilege. Where it is refused the ordinary call
// still applies, so an unprivileged build keeps the old behaviour rather than
// no buffer at all.
const (
	soSndBufForce = 32
	soRcvBufForce = 33
	soPriority    = 12
)

// tuneSocket gives the carrier's socket the buffers it was configured with,
// then reads back what it got and says so if the kernel cut it anyway.
//
// Never call this on a TCP socket. Setting SO_RCVBUF at all switches off
// tcp_rmem autotuning for that socket and pins the window wherever it was put,
// which is worse than any number you might choose.
func tuneSocket(pc net.PacketConn, cfg *config.Config) {
	sc, ok := pc.(syscall.Conn)
	if !ok {
		return
	}
	raw, err := sc.SyscallConn()
	if err != nil {
		return
	}
	rcv, snd := cfg.Tuning.RcvBufKB*1024, cfg.Tuning.SndBufKB*1024
	var gotRcv, gotSnd int

	_ = raw.Control(func(fd uintptr) {
		f := int(fd)
		if rcv > 0 {
			if syscall.SetsockoptInt(f, syscall.SOL_SOCKET, soRcvBufForce, rcv) != nil {
				_ = syscall.SetsockoptInt(f, syscall.SOL_SOCKET, syscall.SO_RCVBUF, rcv)
			}
		}
		if snd > 0 {
			if syscall.SetsockoptInt(f, syscall.SOL_SOCKET, soSndBufForce, snd) != nil {
				_ = syscall.SetsockoptInt(f, syscall.SOL_SOCKET, syscall.SO_SNDBUF, snd)
			}
		}
		// Interactive class. This queue holds one user's latency, and it should
		// leave the machine ahead of a backup or an apt update.
		_ = syscall.SetsockoptInt(f, syscall.SOL_SOCKET, soPriority, 6)

		// The kernel reports double what it gave, by long-standing convention.
		if v, e := syscall.GetsockoptInt(f, syscall.SOL_SOCKET, syscall.SO_RCVBUF); e == nil {
			gotRcv = v / 2
		}
		if v, e := syscall.GetsockoptInt(f, syscall.SOL_SOCKET, syscall.SO_SNDBUF); e == nil {
			gotSnd = v / 2
		}
	})

	logging.Info("socket buffers: %d KB in, %d KB out", gotRcv/1024, gotSnd/1024)
	if rcv > 0 && gotRcv < rcv*9/10 {
		logging.Warn("asked the kernel for %d KB of receive buffer and got %d KB -"+
			" raise net.core.rmem_max, or packets will be dropped before we see them",
			rcv/1024, gotRcv/1024)
	}
}
PINGIFY_GO_SOURCE_EOF
    cat > "$d/internal/carrier/sockopt_other.go" <<'PINGIFY_GO_SOURCE_EOF'
//go:build !linux

package carrier

import (
	"net"

	"pingify/internal/config"
)

// Everywhere that is not Linux. The tunnel only runs on Linux servers; these
// exist so the rest of the core still compiles and its tests still run on a
// laptop.

func tuneSocket(pc net.PacketConn, cfg *config.Config) {}

func attachICMPFilter(pc net.PacketConn, id uint16) error { return errNoFilter }
PINGIFY_GO_SOURCE_EOF
    cat > "$d/internal/carrier/transport.go" <<'PINGIFY_GO_SOURCE_EOF'
package carrier

import (
	"fmt"
	"time"

	"pingify/internal/config"
)

// Choosing a carrier, which is the only place the rest of the core learns
// which transport it is running on.
//
// Everything above this line works against Carrier and cannot tell UDP
// from ICMP. That is what makes adding the next one a new file rather than a
// new set of branches through the private link.

// carrier is a Carrier plus the three things only main needs: how to
// start it, how to keep it alive, and what it has been doing.
type Full interface {
	Carrier
	Run()
	Keepalive(time.Duration)
	Counters() (rx, tx, bad, replay, errs uint64)

	// lost is what the far end sent that never arrived, counted from the gaps
	// in its sequence numbers. Nothing else on either machine can see this.
	Lost() (missing, late, gaps uint64)
}

func Open(cfg *config.Config) (Full, error) {
	switch cfg.Transport.Type {
	case "icmp":
		return newICMPCarrier(cfg)
	case "udp":
		return newUDPCarrier(cfg)
	}
	return nil, fmt.Errorf("no transport called %q", cfg.Transport.Type)
}
PINGIFY_GO_SOURCE_EOF
    cat > "$d/internal/carrier/udp.go" <<'PINGIFY_GO_SOURCE_EOF'
package carrier

import (
	"errors"
	"fmt"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"pingify/internal/buf"
	"pingify/internal/config"
	"pingify/internal/logging"
)

// UDP: a framed datagram in a UDP datagram, and nothing else.
//
// What happened when this was first run between Tehran and Frankfurt: the
// tunnel came up, carried exactly one round trip at 81.0 ms, and went silent.
// It was not this code. A plain python socket on the same pair of servers,
// with no tunnel anywhere near it, gets the same answer:
//
//	udp/8444    6 of 30 back   111111........................
//	udp/8445    6 of 15 back   111111.........
//	udp/8446    6 of 15 back   111111.........
//
// Six, and only ever six. A fresh destination port gets six, a fresh source
// port gets six, waiting a minute gets six, forty packets fired back to back
// get six. Captures on both ends at the same time say which direction: Germany
// received every packet and answered every one, and six of the answers reached
// Iran.
//
// So UDP is not a slow transport on this path. It is an unusable one, and no
// amount of tuning here changes that - which is why ICMP is the transport
// worth making good rather than the fallback.
//
// This carrier stays anyway. It is what proved the shape the framer and the
// private link now share, it is the one place to test a carrier without a raw
// socket, and this is one path on one ISP on one day. Somebody else's will
// carry UDP happily.
const udpMaxDgram = 1500

var ErrNoPeer = errors.New("no peer yet")

type udpCarrier struct {
	pc *net.UDPConn
	fr *framer

	peer     atomic.Pointer[net.UDPAddr]
	onPacket atomic.Pointer[func([]byte)]

	done chan struct{}
	once sync.Once

	rxBytes, txBytes uint64
	sendErrs         uint64
}

func newUDPCarrier(cfg *config.Config) (*udpCarrier, error) {
	c := &udpCarrier{
		fr:   newFramer(cfg.Token, "pingify udp v1"),
		done: make(chan struct{}),
	}

	if cfg.Dials() {
		// Iran dials out. The socket stays unconnected and the peer is
		// remembered instead, because the abroad side may answer from a
		// different source port when anything on the way rewrites addresses.
		raddr, err := net.ResolveUDPAddr("udp4",
			net.JoinHostPort(cfg.Transport.Kharej, fmt.Sprint(cfg.Transport.Port)))
		if err != nil {
			return nil, fmt.Errorf("resolve %s: %v", cfg.Transport.Kharej, err)
		}
		pc, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: 0})
		if err != nil {
			return nil, fmt.Errorf("open udp socket: %v", err)
		}
		c.pc = pc
		c.peer.Store(raddr)
		tuneSocket(pc, cfg)
		smoothTheWire(cfg)
		pace(pc, cfg, c.done, func() uint64 { return atomic.LoadUint64(&c.txBytes) })
		logging.Info("carrier: dialling %s over udp", raddr)
		return c, nil
	}

	pc, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: cfg.Transport.Port})
	if err != nil {
		return nil, fmt.Errorf("listen on udp/%d: %v", cfg.Transport.Port, err)
	}
	c.pc = pc
	tuneSocket(pc, cfg)
	smoothTheWire(cfg)
	pace(pc, cfg, c.done, func() uint64 { return atomic.LoadUint64(&c.txBytes) })
	logging.Info("carrier: waiting on udp/%d", cfg.Transport.Port)
	return c, nil
}

// Burst is one: this carrier sends a packet per call, so there is nothing to
// be gained by collecting them first.
func (c *udpCarrier) Burst() int      { return 1 }
func (c *udpCarrier) Headroom() int   { return c.fr.headroom() }
func (c *udpCarrier) MaxPayload() int { return udpMaxDgram - c.fr.headroom() }
func (c *udpCarrier) Up() bool        { return c.peer.Load() != nil }

func (c *udpCarrier) OnPacket(f func([]byte)) { c.onPacket.Store(&f) }

// udpSender sends a batch one packet at a time. There is no sendmmsg here
// because there is no point: this carrier is for paths where UDP works, and
// those are not the paths where the last ten percent is being fought over.
type udpSender struct{ c *udpCarrier }

func (c *udpCarrier) NewSender() Sender { return &udpSender{c: c} }

func (s *udpSender) Send(bps []*[]byte) {
	for _, bp := range bps {
		_ = s.c.Send(bp)
	}
}

func (c *udpCarrier) Send(bp *[]byte) error {
	peer := c.peer.Load()
	b := *bp
	if peer == nil || len(b) < c.fr.headroom() {
		buf.Put(bp)
		if peer == nil {
			return ErrNoPeer
		}
		return nil
	}
	c.fr.seal(b)
	n, err := c.pc.WriteToUDP(b, peer)
	buf.Put(bp)
	if err != nil {
		atomic.AddUint64(&c.sendErrs, 1)
		return err
	}
	atomic.AddUint64(&c.txBytes, uint64(n))
	return nil
}

// run reads datagrams until the socket closes, handing each one that carries
// the right tag to the layer above - on this goroutine, with nothing in
// between. See link.fromWire for why there is nothing in between.
func (c *udpCarrier) Run() {
	buf := make([]byte, udpMaxDgram)
	for {
		n, from, err := c.pc.ReadFromUDP(buf)
		if n > 0 {
			c.handle(buf[:n], from)
		}
		if err != nil {
			select {
			case <-c.done:
			default:
				logging.Warn("udp read: %v", err)
			}
			return
		}
	}
}

func (c *udpCarrier) handle(b []byte, from *net.UDPAddr) {
	body, ok := c.fr.open(b)
	if !ok {
		return
	}

	// The tag was right, so this is the far end, wherever it is speaking from.
	// The side that waits learns the address here and nowhere else.
	if p := c.peer.Load(); p == nil || p.Port != from.Port || !p.IP.Equal(from.IP) {
		cp := *from
		c.peer.Store(&cp)
		logging.Info("carrier: the far end is at %s", from)
	}

	atomic.AddUint64(&c.rxBytes, uint64(len(b)))
	if len(body) == 0 {
		return // a keepalive, which has done its whole job by arriving
	}
	if f := c.onPacket.Load(); f != nil {
		(*f)(body)
	}
}

func (c *udpCarrier) Keepalive(every time.Duration) {
	keepaliveLoop(c, c.done, every)
}

func (c *udpCarrier) Close() error {
	c.once.Do(func() { close(c.done) })
	return c.pc.Close()
}

func (c *udpCarrier) Lost() (missing, late, gaps uint64) { return c.fr.lost() }

func (c *udpCarrier) Counters() (rx, tx, bad, replay, errs uint64) {
	return atomic.LoadUint64(&c.rxBytes), atomic.LoadUint64(&c.txBytes),
		c.fr.badTag, c.fr.replayed, atomic.LoadUint64(&c.sendErrs)
}

// keepaliveLoop holds the path open, and on the side that waits it is the only
// thing that says where the far end is. The side that dials sends it, because
// before a datagram arrives the other side has nothing to send to.
func keepaliveLoop(c Carrier, done <-chan struct{}, every time.Duration) {
	tk := time.NewTicker(every)
	defer tk.Stop()
	for {
		select {
		case <-done:
			return
		case <-tk.C:
			bp := buf.Take(c.Headroom(), 0)
			if err := c.Send(bp); err != nil && !errors.Is(err, ErrNoPeer) {
				logging.Debug("keepalive: %v", err)
			}
		}
	}
}
PINGIFY_GO_SOURCE_EOF
    cat > "$d/internal/config/config.go" <<'PINGIFY_GO_SOURCE_EOF'
package config

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
)

// The configuration file, and the one line that differs between the two
// servers.
//
// The old core called the two ends "server" and "client", which was wrong in
// the way that costs support time: the Iran server was the "server" and it was
// also the side that dialled out, so the word predicted neither who listened
// nor who connected. Here they are called what they are. Everything else in
// the file is written from the point of view of both ends at once - the tun
// addresses are named `iran` and `kharej` rather than `local` and `remote` -
// so the same file is correct on both servers and only `side` changes.
//
// A file that is identical on both ends cannot drift on one of them, and
// drift between the two configs was the single most common way a tunnel came
// up carrying nothing.
//
//	[tunnel]
//	name = "b"
//	side = "iran"          # the only line that differs; "kharej" over there
//	mode = "tun"
//
//	[transport]
//	type   = "udp"
//	kharej = "46.247.109.83"   # the abroad server, which is the one that waits
//	port   = 8443
//
//	[security]
//	token = "a phrase typed on both servers"
//
//	[tun]
//	name   = "pfy0"
//	iran   = "10.99.1.1/24"
//	kharej = "10.99.1.2/24"
//	mtu    = 1320
//
//	[logging]
//	level = "info"

const (
	// MaxSendBatch is the largest burst any carrier will be asked for. The
	// value that is actually used comes from the carrier - see Carrier.Burst.
	MaxSendBatch = 64

	SideIran   = "iran"
	SideKharej = "kharej"
)

type Config struct {
	Name string
	Side string // iran | kharej
	Mode string // tun

	Transport struct {
		Type      string // udp
		Kharej    string // the abroad server's address
		Port      int
		Keepalive int // seconds
	}

	Token string

	Tuning struct {
		RcvBufKB  int
		SndBufKB  int
		SendBatch int    // packets per crossing into the kernel; 0 means choose
		Pace      bool   // put fq on the way out, so bursts leave as a stream
		PaceMbit  int    // and cap the rate; unset means the tunnel works it out
		Profile   string // gaming | balanced | download
		QueuePkts int    // how deep that queue may get; the profile sets it

		// Whether the file said anything, so a default can tell itself apart
		// from a deliberate zero.
		PaceSet     bool
		PaceMbitSet bool
	}

	TUN struct {
		Name   string
		Iran   string
		Kharej string
		MTU    int
		Queues int // 0 means choose one
	}

	Level string

	// Where to answer questions about itself. Loopback only, and zero turns
	// it off.
	StatusPort int
}

// Dials reports whether this side is the one that opens the connection.
//
// Iran Dials out, always. Connections into the Iran server are blackholed
// after about six exchanges - measured, repeatedly - so the side that owns the
// ports users connect to is not the side that waits for the tunnel. This is
// settled and nothing above needs to ask again.
func (c *Config) Dials() bool { return c.Side == SideIran }

// Mine returns this side's tun address, and theirs.
func (c *Config) Mine() (string, string) {
	if c.Side == SideIran {
		return c.TUN.Iran, c.TUN.Kharej
	}
	return c.TUN.Kharej, c.TUN.Iran
}

func Load(path string) (*Config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	c := &Config{}
	if err := parseTOML(string(raw), c); err != nil {
		return nil, err
	}
	return c, c.check()
}

// parseTOML reads the small subset of TOML this tool writes: `[table]`
// headers and bare `key = value` lines, with strings, integers and booleans.
// Pingify generates these files, so a full TOML implementation would be a
// dependency bought for nothing - and a dependency is what the offline build
// path in Iran cannot afford.
func parseTOML(text string, c *Config) error {
	sc := bufio.NewScanner(strings.NewReader(text))
	sc.Buffer(make([]byte, 0, 64*1024), 1<<20)
	table, line := "", 0

	for sc.Scan() {
		line++
		s := stripComment(sc.Text())
		if s == "" {
			continue
		}
		if strings.HasPrefix(s, "[") {
			if !strings.HasSuffix(s, "]") {
				return fmt.Errorf("line %d: unterminated table header", line)
			}
			table = strings.ToLower(strings.Trim(s[1:len(s)-1], " \t\""))
			continue
		}
		eq := strings.Index(s, "=")
		if eq < 0 {
			return fmt.Errorf("line %d: not a key = value", line)
		}
		key := strings.ToLower(strings.TrimSpace(s[:eq]))
		val := strings.TrimSpace(s[eq+1:])
		if err := assign(c, table, key, val); err != nil {
			return fmt.Errorf("line %d: %v", line, err)
		}
	}
	return sc.Err()
}

// assign puts one value where it belongs. An unknown key is an error rather
// than a shrug: a typo in a config file that is silently ignored is a tunnel
// that comes up with the wrong settings and no way to tell.
func assign(c *Config, table, key, raw string) error {
	str := func() (string, error) { return unquote(raw) }
	num := func() (int, error) { return strconv.Atoi(strings.Trim(raw, `"' `)) }

	var err error
	switch table + "." + key {
	case "tunnel.name":
		c.Name, err = str()
	case "tunnel.side":
		c.Side, err = str()
	case "tunnel.mode":
		c.Mode, err = str()

	case "transport.type":
		c.Transport.Type, err = str()
	case "transport.kharej":
		c.Transport.Kharej, err = str()
	case "transport.port":
		c.Transport.Port, err = num()
	case "transport.keepalive_sec":
		c.Transport.Keepalive, err = num()

	case "security.token":
		c.Token, err = str()

	case "tuning.rcvbuf_kb":
		c.Tuning.RcvBufKB, err = num()
	case "tuning.sndbuf_kb":
		c.Tuning.SndBufKB, err = num()
	case "tuning.send_batch":
		c.Tuning.SendBatch, err = num()
	case "tuning.pace":
		c.Tuning.Pace, err = boolean(raw)
		c.Tuning.PaceSet = true
	case "tuning.pace_mbit":
		c.Tuning.PaceMbit, err = num()
		c.Tuning.PaceMbitSet = true
	case "tuning.profile":
		c.Tuning.Profile, err = str()
	case "tuning.queue_packets":
		c.Tuning.QueuePkts, err = num()

	case "tun.name":
		c.TUN.Name, err = str()
	case "tun.iran":
		c.TUN.Iran, err = str()
	case "tun.kharej":
		c.TUN.Kharej, err = str()
	case "tun.mtu":
		c.TUN.MTU, err = num()
	case "tun.queues":
		c.TUN.Queues, err = num()

	case "logging.level":
		c.Level, err = str()

	case "status.port":
		c.StatusPort, err = num()

	default:
		return fmt.Errorf("unknown setting %q", table+"."+key)
	}
	return err
}

// The profiles, and the one number they move.
//
// Everything else this tunnel tunes was measured to have one right answer
// whatever it is carrying - the socket buffers, one packet per crossing into
// the kernel, a pacing rate it works out for itself - so a profile that
// changed those would be changing them for show.
//
// What genuinely trades is how deep a queue the kernel may hold for us. A deep
// one absorbs bursts and carries more; a shallow one is emptier when a small
// packet arrives, so that packet waits less. Measured on the real path,
// restarted fresh at each depth:
//
//	profile     queue    16 streams   one stream   under load
//	gaming        600     397 Mbit/s   167 Mbit/s   84.5 / 92.5 ms
//	balanced      900     448          254          93.3 / 106.5
//	download     1500     466          253         115.8 / 139.3
//
// Gaming gives up a third of a single stream for nine milliseconds at the
// median and fourteen at the ninetieth, which is the right trade when what
// crosses the link is a game and the wrong one when it is a film. Download
// buys eighteen megabits of aggregate for twenty-three milliseconds. Balanced
// is not the average of the other two: it carries a single stream faster than
// either and answers under load faster than flagtun does.
//
// The quiet round trip does not move at all - 81.0, 81.1, 81.2 - because an
// empty queue is an empty queue however deep it was allowed to get. What a
// profile changes is what happens when the link is busy, which is the only
// time any of it is felt.
const (
	ProfileGaming   = "gaming"
	ProfileBalanced = "balanced"
	ProfileDownload = "download"
)

func (c *Config) profile() error {
	depth := 0
	switch strings.ToLower(strings.TrimSpace(c.Tuning.Profile)) {
	case "":
		c.Tuning.Profile = ProfileBalanced
		depth = 900
	case ProfileGaming:
		depth = 600
	case ProfileBalanced:
		depth = 900
	case ProfileDownload:
		depth = 1500
	default:
		return fmt.Errorf("tuning.profile %q: it is %q, %q or %q",
			c.Tuning.Profile, ProfileGaming, ProfileBalanced, ProfileDownload)
	}

	// An explicit depth wins. The profiles are three points on a line, and
	// somebody measuring their own path may want a fourth.
	if c.Tuning.QueuePkts == 0 {
		c.Tuning.QueuePkts = depth
		return nil
	}
	if c.Tuning.QueuePkts < 200 {
		return fmt.Errorf("tuning.queue_packets %d: below two hundred the queue stops"+
			" smoothing bursts and starts refusing work the link could have carried"+
			" - one stream fell to 75 Mbit/s", c.Tuning.QueuePkts)
	}
	if c.Tuning.QueuePkts > 20000 {
		return fmt.Errorf("tuning.queue_packets %d: that is a quarter of a second of"+
			" queue and it behaves like one", c.Tuning.QueuePkts)
	}
	return nil
}

func boolean(raw string) (bool, error) {
	switch strings.ToLower(strings.Trim(raw, `"' `)) {
	case "true", "yes", "on", "1":
		return true, nil
	case "false", "no", "off", "0":
		return false, nil
	}
	return false, fmt.Errorf("%q is not true or false", raw)
}

func stripComment(s string) string {
	out, quoted := make([]byte, 0, len(s)), false
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '"':
			quoted = !quoted
		case '#':
			if !quoted {
				return strings.TrimSpace(string(out))
			}
		}
		out = append(out, s[i])
	}
	return strings.TrimSpace(string(out))
}

func unquote(s string) (string, error) {
	s = strings.TrimSpace(s)
	if len(s) >= 2 && s[0] == '"' && s[len(s)-1] == '"' {
		return s[1 : len(s)-1], nil
	}
	if len(s) >= 2 && s[0] == '\'' && s[len(s)-1] == '\'' {
		return s[1 : len(s)-1], nil
	}
	return s, nil
}

// check fills in what has a sensible default and refuses what does not. It
// runs before anything opens a socket, so a bad config fails at the moment
// the user can still read the message.
func (c *Config) check() error {
	if c.Side != SideIran && c.Side != SideKharej {
		return fmt.Errorf("tunnel.side must be %q or %q, not %q", SideIran, SideKharej, c.Side)
	}
	if c.Mode == "" {
		c.Mode = "tun"
	}
	if c.Mode != "tun" {
		return fmt.Errorf("tunnel.mode %q: only \"tun\" is built so far", c.Mode)
	}
	if c.Transport.Type == "" {
		c.Transport.Type = "udp"
	}
	if c.Transport.Type != "udp" && c.Transport.Type != "icmp" {
		return fmt.Errorf("transport.type %q: udp and icmp are what exist so far", c.Transport.Type)
	}
	// ICMP has no ports. There is nothing to listen on and nothing to
	// misconfigure, which is half of why it is the transport that survives.
	if c.Transport.Type != "icmp" && (c.Transport.Port <= 0 || c.Transport.Port > 65535) {
		return fmt.Errorf("transport.port %d is not a port", c.Transport.Port)
	}
	if c.Dials() && c.Transport.Kharej == "" {
		return fmt.Errorf("transport.kharej: the Iran side needs the address it Dials")
	}
	if c.Transport.Keepalive <= 0 {
		c.Transport.Keepalive = 10
	}
	if len(c.Token) < 8 {
		return fmt.Errorf("security.token is too short to be worth having")
	}
	if c.TUN.Name == "" {
		c.TUN.Name = "pfy0"
	}
	if c.TUN.Iran == "" || c.TUN.Kharej == "" {
		return fmt.Errorf("tun.iran and tun.kharej are both needed, on both servers")
	}
	if c.TUN.MTU == 0 {
		c.TUN.MTU = 1320
	}
	if c.TUN.MTU < 576 || c.TUN.MTU > 9000 {
		return fmt.Errorf("tun.mtu %d is outside anything that works", c.TUN.MTU)
	}
	if c.TUN.Queues < 0 || c.TUN.Queues > 16 {
		return fmt.Errorf("tun.queues %d is not a number of queues", c.TUN.Queues)
	}
	if c.Name == "" {
		c.Name = "pingify"
	}
	if c.StatusPort < 0 || c.StatusPort > 65535 {
		return fmt.Errorf("status.port %d is not a port", c.StatusPort)
	}
	// Measured on the real path, sweeping the receive buffer against latency
	// and throughput: below about two megabytes the kernel drops packets the
	// process never sees, and above about six the queue is deep enough to be
	// felt as lag. Three is where both were good.
	if c.Tuning.RcvBufKB == 0 {
		c.Tuning.RcvBufKB = 3072
	}
	if c.Tuning.SndBufKB == 0 {
		c.Tuning.SndBufKB = 16384
	}
	// On by default. It is a change to the whole interface, so it is logged
	// where anyone can see it, and one line of config turns it off.
	if !c.Tuning.PaceSet {
		c.Tuning.Pace = true
	}
	if err := c.profile(); err != nil {
		return err
	}
	if c.Tuning.PaceMbit < 0 {
		return fmt.Errorf("tuning.pace_mbit %d is not a rate", c.Tuning.PaceMbit)
	}
	// Zero means "let the carrier choose", which is what happens: how many
	// packets fit in one crossing into the kernel is the carrier's business
	// and differs by platform, so the number is not decided here.
	if c.Tuning.SendBatch < 0 || c.Tuning.SendBatch > MaxSendBatch {
		return fmt.Errorf("tuning.send_batch %d is outside 0..%d", c.Tuning.SendBatch, MaxSendBatch)
	}
	return nil
}
PINGIFY_GO_SOURCE_EOF
    cat > "$d/internal/link/link.go" <<'PINGIFY_GO_SOURCE_EOF'
package link

import (
	"fmt"
	"os"
	"sync"
	"sync/atomic"

	"pingify/internal/buf"
	"pingify/internal/carrier"
	"pingify/internal/config"
	"pingify/internal/logging"
)

// The private link: a layer-3 interface on each server, and one datagram on
// the carrier for each IP packet that crosses it.
//
// There is nothing under it. No ordering, no windows, no retransmission, no
// acknowledgements - and that is not a shortcut, it is the point. Everything
// that travels through this link is already TCP or QUIC, which have spent
// thirty years learning to recover from exactly the losses a second layer
// underneath would be hiding. Hiding them does not make them stop happening;
// it makes them arrive late instead of not at all, and late is worse, because
// the sender inside has already sent another copy.
//
// The old core got this backwards: the link was built on a stream multiplexer
// with per-stream credit windows, and the direct path had to be added beside
// it later. Here the direct path is the only path.
type Link struct {
	cfg *config.Config
	car carrier.Carrier

	dev  []*os.File
	name string

	closing chan struct{}
	once    sync.Once
	wg      sync.WaitGroup

	toWire, toDevice uint64
	dropped          uint64
	short            uint64

	burst int // how many packets may go on the wire in one crossing
}

func New(cfg *config.Config, car carrier.Carrier) (*Link, error) {
	l := &Link{cfg: cfg, car: car, name: cfg.TUN.Name, closing: make(chan struct{}),
		burst: car.Burst()}

	n := cfg.TUN.Queues
	if n == 0 {
		n = defaultQueues()
	}

	for i := 0; i < n; i++ {
		f, err := openTUN(l.name, n > 1)
		if err != nil {
			l.closeDevices()
			return nil, err
		}
		l.dev = append(l.dev, f)
	}

	mine, _ := cfg.Mine()
	if err := configureDevice(l.name, mine, cfg.TUN.MTU); err != nil {
		l.closeDevices()
		return nil, err
	}
	logging.Info("private link %s up: %s, mtu %d, %d queues", l.name, mine, cfg.TUN.MTU, n)
	return l, nil
}

// start puts the link to work: one reader per queue taking packets to the
// wire, and the carrier bringing them back the other way.
func (l *Link) Start() {
	l.car.OnPacket(l.fromWire)
	for i := range l.dev {
		l.wg.Add(1)
		go func(f *os.File, q int) {
			defer l.wg.Done()
			l.readQueue(f, q)
		}(l.dev[i], i)
	}
}

// readQueue takes packets off one device queue and puts them on the wire.
//
// It blocks for the first packet, then takes whatever else is already waiting
// behind it - without waiting for it - and hands the lot to the carrier as one
// batch. A link with one packet on it therefore sends one packet immediately,
// and a link with a hundred sends them in one crossing into the kernel.
//
// The goroutine that read the packets is the one that sends them. Batching
// behind a channel with a single draining goroutine was tried first, and it is
// the obvious design: it cost a single stream 245 Mbit/s down to 164, because
// one flow is read by one device queue, so every one of its packets crossed
// the channel and waited to be scheduled on the far side. Sixteen streams
// never noticed - there was always something to batch - which is exactly how a
// design like that survives a benchmark.
//
// Each packet is read straight into a buffer that already has the carrier's
// headroom in front of it, so nothing is copied and nothing is shifted along
// afterwards to make room for a header that was known about before the read.
func (l *Link) readQueue(f *os.File, q int) {
	head, max := l.car.Headroom(), l.car.MaxPayload()
	sender := l.car.NewSender()
	rc := rawOf(f)
	held := make([]*[]byte, 0, l.burst)

	for {
		bp := buf.Take(head, max)
		n, err := f.Read((*bp)[head:])
		if n > 0 {
			*bp = (*bp)[:head+n]
			held = append(held, bp)
		} else {
			buf.Put(bp)
		}

		// Whatever else is already there comes along for the same crossing.
		for rc != nil && len(held) > 0 && len(held) < l.burst {
			nb := buf.Take(head, max)
			m, ok := readNow(rc, (*nb)[head:])
			if !ok {
				buf.Put(nb)
				break
			}
			*nb = (*nb)[:head+m]
			held = append(held, nb)
		}

		if len(held) > 0 {
			atomic.AddUint64(&l.toWire, uint64(len(held)))
			sender.Send(held)
			held = held[:0]
		}

		if err != nil {
			select {
			case <-l.closing:
			default:
				logging.Warn("device queue %d: %v", q, err)
			}
			return
		}
	}
}

// fromWire writes one packet that arrived on the carrier to the device.
//
// It runs on the goroutine that read the datagram off the socket, and writes
// from there. See udpCarrier.run for why there is nothing in between.
func (l *Link) fromWire(b []byte) {
	if len(b) < 20 {
		atomic.AddUint64(&l.short, 1)
		return
	}
	f := l.dev[flowHash(b)%uint32(len(l.dev))]
	if _, err := f.Write(b); err != nil {
		select {
		case <-l.closing:
		default:
			logging.Debug("device write: %v", err)
		}
		return
	}
	atomic.AddUint64(&l.toDevice, 1)
}

// flowHash picks a device queue from the packet's addresses and ports, so that
// every packet of one connection lands on the same queue and the receiver
// inside is not handed its own stream out of order.
//
// Round robin was tried and is wrong for exactly that reason: it spreads one
// connection across every queue, and the reordering it causes looks to the TCP
// inside like loss.
func flowHash(p []byte) uint32 {
	if len(p) < 20 || p[0]>>4 != 4 {
		return 0
	}
	ihl := int(p[0]&0x0f) * 4
	h := uint32(2166136261)
	for _, c := range p[12:20] { // source and destination address
		h = (h ^ uint32(c)) * 16777619
	}
	h = (h ^ uint32(p[9])) * 16777619 // protocol
	if (p[9] == 6 || p[9] == 17) && len(p) >= ihl+4 {
		for _, c := range p[ihl : ihl+4] { // source and destination port
			h = (h ^ uint32(c)) * 16777619
		}
	}
	// A last mix, because the low bits of an FNV hash of four bytes are not
	// well spread on their own and the low bits are the ones a modulo takes.
	h ^= h >> 16
	h *= 2246822507
	h ^= h >> 13
	return h
}

// defaultQueues is how many device queues to open when the config does not
// say. See the note on reordering in readQueue for why more is not better.
func defaultQueues() int { return 1 }

// Dropped is how many packets the link could not put on the wire, and Packets
// is how many crossed it each way. The three of them are what a report is made
// of; nothing else above needs to see inside.
func (l *Link) Dropped() uint64 { return atomic.LoadUint64(&l.dropped) }

func (l *Link) Packets() (toWire, toDevice uint64) {
	return atomic.LoadUint64(&l.toWire), atomic.LoadUint64(&l.toDevice)
}

func (l *Link) closeDevices() {
	for _, f := range l.dev {
		f.Close()
	}
}

func (l *Link) Close() error {
	l.once.Do(func() {
		close(l.closing)
		l.closeDevices()
	})
	return nil
}

func (l *Link) String() string {
	return fmt.Sprintf("%s: %d packets to the wire, %d to the device, %d dropped",
		l.name, atomic.LoadUint64(&l.toWire), atomic.LoadUint64(&l.toDevice),
		atomic.LoadUint64(&l.dropped))
}
PINGIFY_GO_SOURCE_EOF
    cat > "$d/internal/link/readnow_linux.go" <<'PINGIFY_GO_SOURCE_EOF'
//go:build linux

package link

import (
	"os"
	"syscall"
)

// Taking whatever else is already there, without waiting for it.
//
// The device is read by a goroutine that blocks for the first packet. Once it
// has one, anything already queued behind it can be collected for the same
// crossing into the kernel - but only what is already there. Waiting even
// briefly for a batch to fill would put the delay back that batching was
// supposed to remove, and a link with one packet on it must send one packet.
//
// rc.Control runs on the descriptor without asking the poller to wait, which
// is exactly the difference between this and an ordinary Read.
func rawOf(f *os.File) syscall.RawConn {
	rc, err := f.SyscallConn()
	if err != nil {
		return nil
	}
	return rc
}

// readNow returns a packet if one is waiting, and false if none is.
func readNow(rc syscall.RawConn, b []byte) (int, bool) {
	var n int
	var ok bool
	_ = rc.Control(func(fd uintptr) {
		m, err := syscall.Read(int(fd), b)
		if err == nil && m > 0 {
			n, ok = m, true
		}
	})
	return n, ok
}
PINGIFY_GO_SOURCE_EOF
    cat > "$d/internal/link/readnow_other.go" <<'PINGIFY_GO_SOURCE_EOF'
//go:build !linux

package link

import (
	"os"
	"syscall"
)

// Everywhere that is not Linux: never take a second packet without waiting,
// which leaves batches of one and is correct if slower.

func rawOf(f *os.File) syscall.RawConn { return nil }

func readNow(rc syscall.RawConn, b []byte) (int, bool) { return 0, false }
PINGIFY_GO_SOURCE_EOF
    cat > "$d/internal/link/tun_linux.go" <<'PINGIFY_GO_SOURCE_EOF'
//go:build linux

package link

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"unsafe"
)

// The device, opened the only way Linux offers: /dev/net/tun and one ioctl.
const (
	tunsetiff       = 0x400454ca
	iffTun          = 0x0001
	iffNoPI         = 0x1000
	iffMultiQueue   = 0x0100
	ifNameSize      = 16
	ifreqSize       = 40
	deviceQueuesMin = 2
	deviceQueuesMax = 8
)

// openTUN attaches one queue to the named device, creating it if this is the
// first. Every queue after the first must ask for multi-queue too, and so must
// the first, which is why the flag is not conditional on the count here.
//
// The descriptor is put in non-blocking mode and handed to os.NewFile, which
// gives it to Go's poller. Two things depend on that. An ordinary Read still
// blocks the goroutine and not the thread, as it would either way; and a read
// that goes straight to the descriptor - see readNow - returns at once when
// there is nothing there, instead of waiting for the next packet.
//
// That second one is not a nicety. With a blocking descriptor, a reader that
// had one packet and looked for a second would wait for it, and the first
// packet would sit built and unsent until more traffic happened to arrive.
// A lone SYN never gets sent at all, and the tunnel comes up carrying nothing.
func openTUN(name string, multi bool) (*os.File, error) {
	if len(name) >= ifNameSize {
		return nil, fmt.Errorf("device name %q is too long", name)
	}
	fd, err := syscall.Open("/dev/net/tun", syscall.O_RDWR|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, fmt.Errorf("open /dev/net/tun: %v (is the tun module loaded?)", err)
	}

	var req [ifreqSize]byte
	copy(req[:ifNameSize-1], name)
	flags := uint16(iffTun | iffNoPI)
	if multi {
		flags |= iffMultiQueue
	}
	*(*uint16)(unsafe.Pointer(&req[ifNameSize])) = flags

	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), tunsetiff,
		uintptr(unsafe.Pointer(&req[0]))); e != 0 {
		syscall.Close(fd)
		return nil, fmt.Errorf("attach to %s: %v", name, e)
	}
	if err := syscall.SetNonblock(fd, true); err != nil {
		syscall.Close(fd)
		return nil, fmt.Errorf("%s: could not be made non-blocking: %v", name, err)
	}
	return os.NewFile(uintptr(fd), "/dev/net/tun"), nil
}

// configureDevice gives the interface its address and brings it up, by asking
// iproute2 rather than by opening a netlink socket. It runs once at startup,
// where a fork costs nothing and a hand-rolled netlink implementation would
// cost several hundred lines that only ever run once.
func configureDevice(name, addr string, mtu int) error {
	run := func(args ...string) error {
		out, err := exec.Command("ip", args...).CombinedOutput()
		if err != nil {
			return fmt.Errorf("ip %s: %v: %s",
				strings.Join(args, " "), err, strings.TrimSpace(string(out)))
		}
		return nil
	}
	// The queue is set with the address because the default is far too short
	// for this. A tun device holds txqueuelen packets between the kernel
	// putting them there and us reading them, and the default is 500 - while
	// one TCP stream through an eighty millisecond path runs a window of eight
	// hundred and more. A burst does not fit, and the device throws away the
	// remainder.
	//
	// Those drops are invisible from inside this process: they happen before
	// the read, so the carrier's counters show nothing lost, and ss shows the
	// consequence instead - retransmissions, and a congestion window that
	// never grows. Counted over eighteen seconds of one stream:
	//
	//	  txqueuelen    dropped by the device    one stream
	//	     500          47, 1167, 2320         116, 116, 98 Mbit/s
	//	   10000              0, 0, 0            117, 140, 137 Mbit/s
	//
	// Ten thousand is not a deep queue in time. At four hundred megabits it is
	// about thirty milliseconds, and it only ever fills when the reader is
	// behind - which, unlike a queue on the wire, is a burst rather than a
	// standing backlog.
	if err := run("link", "set", "dev", name, "mtu", fmt.Sprint(mtu),
		"txqueuelen", "10000", "up"); err != nil {
		return err
	}
	return run("addr", "add", addr, "dev", name)
}
PINGIFY_GO_SOURCE_EOF
    cat > "$d/internal/link/tun_other.go" <<'PINGIFY_GO_SOURCE_EOF'
//go:build !linux

package link

import (
	"errors"
	"os"
)

// Everywhere that is not Linux. The tunnel only ever runs on Linux servers;
// these exist so that the rest of the core still compiles and its tests still
// run on a laptop.
const (
	deviceQueuesMin = 2
	deviceQueuesMax = 8
)

var errNoTUN = errors.New("a tun device needs Linux")

func openTUN(name string, multi bool) (*os.File, error) { return nil, errNoTUN }

func configureDevice(name, addr string, mtu int) error { return errNoTUN }
PINGIFY_GO_SOURCE_EOF
    cat > "$d/internal/logging/log.go" <<'PINGIFY_GO_SOURCE_EOF'
package logging

import (
	"fmt"
	"os"
	"strings"
	"sync/atomic"
	"time"
)

// Four levels, and the only one that costs anything is debug - which is why
// the check happens before the arguments are formatted rather than inside the
// call that formats them.
const (
	levelDebug = iota
	levelInfo
	levelWarn
	levelError
)

var level int32 = levelInfo

func SetLevel(name string) {
	switch strings.ToLower(strings.TrimSpace(name)) {
	case "debug":
		atomic.StoreInt32(&level, levelDebug)
	case "", "info":
		atomic.StoreInt32(&level, levelInfo)
	case "warn", "warning":
		atomic.StoreInt32(&level, levelWarn)
	case "error":
		atomic.StoreInt32(&level, levelError)
	}
}

func at(level int32, tag, format string, args ...any) {
	if atomic.LoadInt32(&level) > level {
		return
	}
	fmt.Fprintf(os.Stderr, "%s  %-6s %s\n",
		time.Now().Format("2006-01-02 15:04:05.000"), tag,
		fmt.Sprintf(format, args...))
}

func Debug(f string, a ...any) { at(levelDebug, "DEBUG", f, a...) }
func Info(f string, a ...any)  { at(levelInfo, "INFO", f, a...) }
func Warn(f string, a ...any)  { at(levelWarn, "WARN", f, a...) }
func Error(f string, a ...any) { at(levelError, "ERROR", f, a...) }

// Die says why and stops. Used only for what cannot be recovered from at
// startup, never once traffic is flowing.
func Die(format string, args ...any) {
	Error(format, args...)
	os.Exit(1)
}
PINGIFY_GO_SOURCE_EOF
    cat > "$d/internal/status/status.go" <<'PINGIFY_GO_SOURCE_EOF'
package status

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"strings"
	"sync/atomic"
	"time"

	"pingify/internal/config"
	"pingify/internal/logging"
)

// What the tunnel will tell you about itself.
//
// A manager script needs to answer three questions and it should not have to
// read a log to do it: is the tunnel up, is it carrying anything, and is the
// path taking packets away from it. The last one is the reason this exists at
// all - nothing else on either machine can see it, and a person looking at a
// tunnel that feels slow has no other way to find out that four hundred
// packets a minute are being dropped somewhere between Tehran and Frankfurt.
//
// It listens on the loopback address only. There is nothing secret in here,
// but there is nothing here anybody else needs either, and a port open on a
// public address is a port somebody will knock on.

// Source is what the tunnel gives this package to report on. It is an
// interface so that status depends on nothing: the carrier and the link do not
// know it exists, and cannot be made slower by it.
type Source interface {
	Counters() (rx, tx, bad, replay, errs uint64)
	Lost() (missing, late, gaps uint64)
	Up() bool
}

// Link is the little the report needs from the private link.
type Link interface {
	Dropped() uint64
	Packets() (toWire, toDevice uint64)
}

type Report struct {
	Version string `json:"version"`
	Name    string `json:"name"`
	Side    string `json:"side"`
	Mode    string `json:"mode"`
	Profile string `json:"profile"`

	Transport string `json:"transport"`
	Up        bool   `json:"up"`
	UptimeSec int64  `json:"uptime_sec"`

	InMbit  float64 `json:"in_mbit"`
	OutMbit float64 `json:"out_mbit"`
	InBytes uint64  `json:"in_bytes"`
	OutByte uint64  `json:"out_bytes"`

	// What the path took. Counted from gaps in a sequence number that is
	// consecutive at the sender, which is the only place it is visible.
	PathLost      uint64 `json:"path_lost"`
	PathReordered uint64 `json:"path_reordered"`
	PathGaps      uint64 `json:"path_gaps"`

	NotOurs    uint64 `json:"not_ours"`
	AlreadySee uint64 `json:"already_seen"`
	SendErrors uint64 `json:"send_errors"`

	ToWire   uint64 `json:"to_wire"`
	ToDevice uint64 `json:"to_device"`
	Dropped  uint64 `json:"dropped"`
}

type Server struct {
	cfg   *config.Config
	car   Source
	link  Link
	start time.Time
	ver   string

	lastRx, lastTx uint64
	lastAt         time.Time
	inRate, outRA  uint64 // most recent rates, in bytes per second
}

func New(cfg *config.Config, ver string, car Source, l Link) *Server {
	return &Server{cfg: cfg, car: car, link: l, start: time.Now(), ver: ver, lastAt: time.Now()}
}

// Serve answers on the loopback address until the process ends. A port that
// cannot be opened is not fatal: the tunnel's job is to carry traffic, and it
// carries it just as well with nobody watching.
func (s *Server) Serve(port int) {
	if port <= 0 {
		return
	}
	go s.sample()

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		_ = enc.Encode(s.Report())
	})
	// Something for a shell script to test without parsing anything: up is 200
	// and down is 503, and that is the whole protocol.
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		if !s.car.Up() {
			http.Error(w, "down", http.StatusServiceUnavailable)
			return
		}
		fmt.Fprintln(w, "up")
	})

	addr := fmt.Sprintf("127.0.0.1:%d", port)
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		logging.Warn("no status on %s (%v) - the tunnel runs either way", addr, err)
		return
	}
	logging.Info("status on http://%s", addr)
	srv := &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	_ = srv.Serve(ln)
}

// sample turns the counters into a rate once a second, because a byte total is
// not what anybody wants to know and dividing it by uptime is a lie about the
// last hour.
func (s *Server) sample() {
	tk := time.NewTicker(time.Second)
	defer tk.Stop()
	for range tk.C {
		rx, tx, _, _, _ := s.car.Counters()
		now := time.Now()
		if secs := now.Sub(s.lastAt).Seconds(); secs > 0 {
			atomic.StoreUint64(&s.inRate, uint64(float64(rx-s.lastRx)/secs))
			atomic.StoreUint64(&s.outRA, uint64(float64(tx-s.lastTx)/secs))
		}
		s.lastRx, s.lastTx, s.lastAt = rx, tx, now
	}
}

func (s *Server) Report() Report {
	rx, tx, bad, replay, errs := s.car.Counters()
	missing, late, gaps := s.car.Lost()
	toWire, toDevice := s.link.Packets()
	return Report{
		Version:       s.ver,
		Name:          s.cfg.Name,
		Side:          s.cfg.Side,
		Mode:          s.cfg.Mode,
		Profile:       s.cfg.Tuning.Profile,
		Transport:     s.cfg.Transport.Type,
		Up:            s.car.Up(),
		UptimeSec:     int64(time.Since(s.start).Seconds()),
		InMbit:        float64(atomic.LoadUint64(&s.inRate)) * 8 / 1e6,
		OutMbit:       float64(atomic.LoadUint64(&s.outRA)) * 8 / 1e6,
		InBytes:       rx,
		OutByte:       tx,
		PathLost:      missing,
		PathReordered: late,
		PathGaps:      gaps,
		NotOurs:       bad,
		AlreadySee:    replay,
		SendErrors:    errs,
		ToWire:        toWire,
		ToDevice:      toDevice,
		Dropped:       s.link.Dropped(),
	}
}

// Fetch reads a report from a running tunnel.
func Fetch(addr string) (*Report, error) {
	if !strings.Contains(addr, ":") {
		addr = "127.0.0.1:" + addr
	}
	c := &http.Client{Timeout: 4 * time.Second}
	resp, err := c.Get("http://" + addr + "/")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("the tunnel answered %s", resp.Status)
	}
	var r Report
	if err := json.NewDecoder(resp.Body).Decode(&r); err != nil {
		return nil, err
	}
	return &r, nil
}

// Print writes a report the way a person reads one. The manager script draws
// its own; this is for someone at a prompt with no manager in front of them.
func Print(r *Report) {
	up := "down"
	if r.Up {
		up = "up"
	}
	fmt.Printf("%s %s, %s side, %s over %s, %s profile\n",
		r.Name, r.Version, r.Side, r.Mode, r.Transport, r.Profile)
	fmt.Printf("  %s for %s\n", up, dur(r.UptimeSec))
	fmt.Printf("  carrying %.1f Mbit/s in, %.1f Mbit/s out\n", r.InMbit, r.OutMbit)
	fmt.Printf("  %s in, %s out since it started\n", size(r.InBytes), size(r.OutByte))
	if r.PathLost > 0 {
		per := float64(r.PathLost) / float64(max(r.PathGaps, 1))
		fmt.Printf("  the path has taken %d packets in %d runs, %.0f at a time\n",
			r.PathLost, r.PathGaps, per)
	} else {
		fmt.Printf("  the path has taken nothing\n")
	}
	if r.Dropped > 0 {
		fmt.Printf("  %d packets could not be put on the wire\n", r.Dropped)
	}
}

func dur(sec int64) string {
	switch {
	case sec < 60:
		return fmt.Sprintf("%ds", sec)
	case sec < 3600:
		return fmt.Sprintf("%dm", sec/60)
	case sec < 86400:
		return fmt.Sprintf("%dh %dm", sec/3600, (sec%3600)/60)
	}
	return fmt.Sprintf("%dd %dh", sec/86400, (sec%86400)/3600)
}

func size(b uint64) string {
	const k = 1024
	switch {
	case b < k:
		return fmt.Sprintf("%d B", b)
	case b < k*k:
		return fmt.Sprintf("%.1f KB", float64(b)/k)
	case b < k*k*k:
		return fmt.Sprintf("%.1f MB", float64(b)/(k*k))
	}
	return fmt.Sprintf("%.2f GB", float64(b)/(k*k*k))
}

func max(a, b uint64) uint64 {
	if a > b {
		return a
	}
	return b
}
PINGIFY_GO_SOURCE_EOF
}

# go_version_needed reads the go directive out of the go.mod that is baked
# into the function above, so there is one statement of the minimum and the
# build cannot disagree with the module. The old script kept its own
# GO_MIN_MINOR=19 beside a module that said 1.24, accepted a toolchain four
# years too old, and then died inside go build with a message about toolchain
# downloads that named none of that.
#
# declare -f prints a function's heredocs verbatim, so the whole embedded
# tree is readable without touching the disk. It is fed to awk with a here
# string rather than a pipe on purpose: awk exits at the first match, and a
# printf pouring a hundred kilobytes into a pipe that just closed takes
# SIGPIPE and reports 141 under pipefail.
go_version_needed() {
    local body v=
    body=$(declare -f write_core_sources 2>/dev/null) || body=
    if [ -n "$body" ]; then
        v=$(awk '/^go [0-9]/ { print $2; exit }' <<<"$body")
    fi
    # If bash ever stops reproducing heredocs, fall back to reading the file
    # this writes. Slower, and correct for the same reason.
    if [ -z "$v" ]; then
        local tmp
        tmp=$(mktemp -d) || return 1
        write_core_sources "$tmp" >/dev/null 2>&1 &&
            v=$(awk '/^go [0-9]/ { print $2; exit }' "$tmp/go.mod")
        rm -rf "$tmp"
    fi
    [ -n "$v" ] || return 1
    printf '%s' "$v"
}

# ver_ge compares two dotted versions, missing parts counting as zero, so
# 1.24 and 1.24.0 are the same version. String comparison gets 1.9 and 1.24
# the wrong way round, which is exactly the pair that matters here.
ver_ge() {
    local i av bv
    local -a A B
    IFS=. read -r -a A <<<"$1"
    IFS=. read -r -a B <<<"$2"
    for i in 0 1 2; do
        av=${A[i]:-0}
        bv=${B[i]:-0}
        case $av in '' | *[!0-9]*) av=0 ;; esac
        case $bv in '' | *[!0-9]*) bv=0 ;; esac
        [ "$av" -gt "$bv" ] && return 0
        [ "$av" -lt "$bv" ] && return 1
    done
    return 0
}

# --------------------------------------------------------------------------
# a compiler
# --------------------------------------------------------------------------

# ensure_go finds a Go new enough for the module or offers to fetch one, and
# sets GO_BIN. It never installs anything without being asked.
ensure_go() {
    local want cand out v found= arch tar_ver url tmp pid rc

    if ! want=$(go_version_needed); then
        bad "the embedded go.mod could not be read, so I cannot tell what Go this needs"
        fix "rebuild the script from the repository:  ./build.sh"
        return 1
    fi

    # /usr/local/go before PATH: if an earlier run put one there it is the one
    # known to be new enough, and a distro package earlier on PATH usually is
    # not. command -v may print nothing; the quotes keep that an empty word
    # rather than dropping the loop item.
    for cand in /usr/local/go/bin/go "$(command -v go 2>/dev/null)"; do
        [ -x "$cand" ] || continue
        out=$("$cand" version 2>/dev/null) || continue
        v=${out#go version go}
        v=${v%% *}
        case $v in '' | *[!0-9.]*) continue ;; esac
        if ver_ge "$v" "$want"; then
            GO_BIN=$cand
            return 0
        fi
        found=$v
    done

    arch=$(arch_go)
    if [ -z "$arch" ]; then
        bad "$(uname -m) is not a machine this can build for"
        fix "amd64 and arm64 are what the core is built and tested on"
        return 1
    fi

    # A released minor always has a .0, so deriving the tarball from the go
    # directive keeps this from drifting the way a hardcoded GO_FALLBACK did.
    tar_ver=$want
    case $want in *.*.*) ;; *) tar_ver=$want.0 ;; esac
    url=$GO_DL_BASE/go$tar_ver.linux-$arch.tar.gz

    blank
    if [ -n "$found" ]; then
        warn "the Go here is $found and the core needs $want or newer"
    else
        warn "there is no Go on this machine, and the core is built here"
    fi
    blank
    dim "This is the one step that wants the network. It would fetch:"
    field "from" "$url"
    field "size" "about 80 MB, roughly 250 MB unpacked"
    field "into" "/usr/local/go, deleting whatever is there now"
    blank
    dim "Nothing verifies it beyond TLS to go.dev: this script carries no"
    dim "checksum, and one fetched from the same place as the tarball would"
    dim "prove nothing. If that is not good enough, install Go by hand and run"
    dim "this again - it wants a compiler, not that compiler."
    blank

    if ! confirm "fetch it?" y; then
        bad "no compiler, so no core"
        fix "install Go $want or newer, then run this again"
        return 1
    fi

    tmp=$(mktemp) || return 1
    if have curl; then
        curl -fSL --retry 2 --connect-timeout 20 -o "$tmp" "$url" >/dev/null 2>&1 &
        pid=$!
    elif have wget; then
        wget -q -O "$tmp" "$url" &
        pid=$!
    else
        rm -f "$tmp"
        bad "neither curl nor wget is installed, so nothing here can fetch it"
        fix "apt install curl   (or install Go yourself from $url)"
        return 1
    fi
    spin "fetching go$tar_ver for $arch" "$pid"
    rc=$?

    if [ "$rc" != 0 ]; then
        rm -f "$tmp"
        bad "the download failed, exit $rc"
        fix "from a machine that can reach it:  curl -fLO $url"
        fix "copy it here, then:  tar -C /usr/local -xzf go$tar_ver.linux-$arch.tar.gz"
        return 1
    fi

    rm -rf /usr/local/go
    if ! tar -C /usr/local -xzf "$tmp"; then
        rm -f "$tmp"
        bad "the tarball would not unpack - it is probably a truncated download"
        fix "run this again, or unpack it by hand into /usr/local"
        return 1
    fi
    rm -f "$tmp"

    if [ ! -x /usr/local/go/bin/go ]; then
        bad "the tarball unpacked but there is no /usr/local/go/bin/go in it"
        return 1
    fi
    GO_BIN=/usr/local/go/bin/go
    ok "go $tar_ver is installed in /usr/local/go"
    return 0
}

# --------------------------------------------------------------------------
# building
# --------------------------------------------------------------------------

build_core() {
    require_root
    ensure_dirs
    ensure_go || return 1

    local log out rc
    log=$STATE_DIR/build.log
    out=$SRC_DIR/pingify-core

    # Clear the tree first. A file dropped between versions would otherwise
    # sit there and be compiled alongside the new ones, and a stale
    # internal/carrier/*.go is a build error nobody can explain by reading
    # this script. The build cache under gocache/ is kept, so an unchanged
    # rebuild is a couple of seconds rather than forty.
    rm -rf "$SRC_DIR/cmd" "$SRC_DIR/internal" "$SRC_DIR/go.mod"
    if ! write_core_sources "$SRC_DIR"; then
        bad "the core sources could not be written into $SRC_DIR"
        fix "check there is space and that $SRC_DIR is writable:  df -h $SRC_DIR"
        return 1
    fi

    # GOPROXY=off and GOFLAGS=-mod=mod because there is nothing to fetch:
    # saying so turns a confusing "cannot reach proxy.golang.org" into a build
    # that simply works. GOTOOLCHAIN=local because from 1.21 go will otherwise
    # try to download the toolchain the go directive names, over the network
    # this machine may not have - ensure_go has already checked the local one
    # is new enough, so there is nothing to gain and a hang to lose.
    (
        cd "$SRC_DIR" &&
            GOTOOLCHAIN=local GO111MODULE=on GOPROXY=off GOSUMDB=off \
                GOFLAGS=-mod=mod GOPATH="$SRC_DIR/gopath" \
                GOCACHE="$SRC_DIR/gocache" CGO_ENABLED=0 \
                "$GO_BIN" build -trimpath -ldflags "-s -w" -o "$out" ./cmd/pingify
    ) >"$log" 2>&1 &
    spin "building the core - up to a minute on a small server" $!
    rc=$?

    if [ "$rc" != 0 ]; then
        bad "the core did not build, go exited $rc"
        tail -n 20 "$log" | sed 's/^/       /'
        fix "the whole log is in $log"
        return 1
    fi

    # Only now. An install that overwrites the binary before the build is
    # known to have worked leaves a machine with no core and a running tunnel
    # that cannot be restarted.
    if ! install -m 0755 "$out" "$CORE_BIN"; then
        bad "the core built but would not install to $CORE_BIN"
        return 1
    fi
    ok "core $(core_version) is installed at $CORE_BIN"
    return 0
}

# core_version prints what is installed, and nothing at all when there is no
# core to ask. The binary answers "pingify-core 2.0.0"; only the number is of
# use to a caller comparing it with this script's own.
core_version() {
    local out
    [ -x "$CORE_BIN" ] || return 1
    out=$("$CORE_BIN" -version 2>/dev/null) || return 1
    printf '%s' "${out#pingify-core }"
}

# ensure_core is what every path that needs a working core calls first.
#
# The version has to match this script exactly, not merely be present. The two
# halves ship together and a config key the manager writes may be one the
# older core refuses, which surfaces as the core rejecting a file the manager
# just built - a confusing failure a long way from its cause.
#
# Replacing the binary does not disturb a running tunnel: systemd keeps the
# old inode open until the unit is restarted, so nothing is felt until the
# caller restarts it, which is the caller's decision to make and to announce.
ensure_core() {
    local here
    here=$(core_version) || here=

    [ "$here" = "$PINGIFY_VERSION" ] && return 0

    if [ -n "$here" ]; then
        blank
        dim "the core here is $here and this manager is $PINGIFY_VERSION - rebuilding"
    fi
    build_core
}
#!/usr/bin/env bash
#
# The wizard: six questions on the first server, one paste on the second.
#
# That asymmetry is the whole design, and it falls out of one fact about the
# core - the config file is byte-identical on both servers except the line
# side = "iran" / side = "kharej". So the second server does not answer
# questions at all. It takes the first server's file, flips one line, and
# writes it. A setting added to the core needs no change here, and the two ends
# cannot drift apart, which was the most common way a tunnel came up carrying
# nothing.
#
# The old setup token was 31 pipe-separated fields. Both the encoder and the
# decoder had to agree on the order, a new core setting meant editing both, and
# a truncated paste was diagnosed by counting fields. Here the token *is* the
# config file, and one hash catches every kind of damage.
#
# Every question is its own function reading into a T_* variable. That is so a
# test can drive the real wizard through its stdin instead of grepping this
# file for the strings it hopes are in it: the old suite had 130 assertions
# that were greps over the script's own source, and they pinned wording, broke
# on renames, and passed happily on dead code.

# The tunnel being edited may keep its own values. The wizard creates, so this
# is empty here; the manage screens set it before calling the owner lookups.
WIZ_KEEP=

# --------------------------------------------------------------------------
# addresses, and who already has them
# --------------------------------------------------------------------------

# wiz_ip4_int turns a dotted quad into a number so two of them can be compared.
# The 10# prefixes are not decoration: bash reads a leading zero as octal, so
# without them 10.010.0.1 compares as 10.8.0.1 and the answer is quietly wrong.
wiz_ip4_int() {
    local a b c d rest x
    IFS=. read -r a b c d rest <<<"$1"
    [ -z "$rest" ] || return 1
    for x in "$a" "$b" "$c" "$d"; do
        case $x in '' | *[!0-9]*) return 1 ;; esac
        [ "$((10#$x))" -le 255 ] || return 1
    done
    printf '%s' $(((10#$a << 24) + (10#$b << 16) + (10#$c << 8) + 10#$d))
}

# wiz_net_overlap answers whether 10.<octet>.10.0/24 lands inside an address
# already on this host. Comparing the top min(24, prefix) bits is what makes a
# docker bridge on 10.42.0.0/16 count as owning 10.42.10.0/24 - a plain string
# match on the second octet would miss it, and the tunnel would come up on a
# range the kernel already routes somewhere else.
wiz_net_overlap() {
    local addr=$1 plen=$2 oct=$3 a b m
    a=$(wiz_ip4_int "$addr") || return 1
    case $plen in '' | *[!0-9]*) return 1 ;; esac
    # An octet that is not a number would become an arithmetic syntax error
    # below, and inside a validator that error is what the user gets told.
    case $oct in '' | *[!0-9]*) return 1 ;; esac
    b=$(((10 << 24) + (oct << 16) + (10 << 8)))
    m=$plen
    [ "$m" -gt 24 ] && m=24
    # A /0 on an interface is not a claim on anything; treating it as one would
    # make every octet look taken.
    [ "$m" -ge 1 ] || return 1
    [ "$((a >> (32 - m)))" -eq "$((b >> (32 - m)))" ]
}

# wiz_link_owner prints what owns 10.<octet>.10.0/24 here, or returns 1.
wiz_link_owner() {
    local oct=$1 keep=${2:-$WIZ_KEEP} n a dev addr plen
    for n in $(cfg_list); do
        [ "$n" = "$keep" ] && continue
        a=$(toml_get "$(cfg_file "$n")" tun iran)
        case ${a%%/*} in
        10."$oct".*) printf 'the tunnel %s' "$n"; return 0 ;;
        esac
    done
    # Process substitution, not a pipe: a pipe puts the loop in a subshell and
    # the return below would leave only the subshell, so a clash on the host
    # would be found and then thrown away.
    while read -r dev addr; do
        [ -n "$addr" ] || continue
        plen=${addr#*/}
        [ "$plen" = "$addr" ] && plen=32
        if wiz_net_overlap "${addr%%/*}" "$plen" "$oct"; then
            printf '%s on %s' "$addr" "$dev"
            return 0
        fi
    done < <(ip -4 -o addr 2>/dev/null | awk '$3 == "inet" { print $2, $4 }')
    return 1
}

# wiz_device_owner prints what owns a tun device name here, or returns 1.
wiz_device_owner() {
    local dev=$1 n keep=${2:-$WIZ_KEEP}
    for n in $(cfg_list); do
        [ "$n" = "$keep" ] && continue
        [ "$(toml_get "$(cfg_file "$n")" tun name)" = "$dev" ] &&
            { printf 'the tunnel %s' "$n"; return 0; }
    done
    # An interface with no config behind it is another tool's, or one of ours
    # left over from a crash. Either way the core cannot create it again.
    [ -e "/sys/class/net/$dev" ] && { printf 'an interface already on this host'; return 0; }
    return 1
}

wiz_port_owner() {
    local p=$1 keep=${2:-$WIZ_KEEP} n f
    for n in $(cfg_list); do
        [ "$n" = "$keep" ] && continue
        f=$(cfg_file "$n")
        # ICMP has no port, so an icmp tunnel owns no number.
        [ "$(toml_get "$f" transport type)" = icmp ] && continue
        [ "$(toml_get "$f" transport port)" = "$p" ] &&
            { printf 'the tunnel %s' "$n"; return 0; }
    done
    return 1
}

# wiz_port_bound asks whether anything on this host already listens on a udp
# port. When ss is missing the answer is "no": refusing to go on because a
# check could not run is a wall the user cannot climb, and the core will say so
# plainly at start-up if the bind really fails.
wiz_port_bound() {
    have ss || return 1
    ss -lnu 2>/dev/null | awk -v want=":$1\$" 'NR > 1 && $4 ~ want { hit = 1 } END { exit !hit }'
}

# wiz_public_ip is a default for the KHAREJ side, read from the interfaces
# rather than from a lookup service. The first server is in Iran on a path that
# blocks half the internet, so a wizard that pauses to curl an address service
# is a wizard that hangs where it is hardest to debug.
wiz_public_ip() {
    local a
    for a in $(ip -4 -o addr show scope global 2>/dev/null |
        awk '$3 == "inet" { sub("/.*", "", $4); print $4 }'); do
        case $a in
        10.* | 127.* | 192.168.* | 169.254.* | \
            172.1[6-9].* | 172.2[0-9].* | 172.3[01].* | \
            100.6[4-9].* | 100.[7-9][0-9].* | 100.1[01][0-9].* | 100.12[0-7].*) continue ;;
        esac
        printf '%s' "$a"
        return 0
    done
    return 1
}

# --------------------------------------------------------------------------
# choosing what is free
# --------------------------------------------------------------------------

# free_octet is the lowest 1-254 that no tunnel here owns and that is not
# inside any address on this host. It prints nothing when there is none, and
# the caller says so rather than offering a default that will be refused.
free_octet() {
    local i=1
    while [ "$i" -le 254 ]; do
        wiz_link_owner "$i" >/dev/null || { printf '%s' "$i"; return 0; }
        i=$((i + 1))
    done
    return 1
}

free_device() {
    local i=0 dev
    while [ "$i" -lt 64 ]; do
        dev="pfy$i"
        wiz_device_owner "$dev" >/dev/null || { printf '%s' "$dev"; return 0; }
        i=$((i + 1))
    done
    return 1
}

# default_name is <transport>-<octet>, suffixed -2, -3 on collision.
#
# It is built from those two because neither can name a side. The name lives in
# the shared file, so a name like iran-9443 - which is what the old scheme
# produced - is a lie on one of the two servers from the moment it is written.
default_name() {
    local trans=${1:-$T_TRANSPORT} oct=${2:-$T_OCTET} base n i
    base="$trans-$oct"
    n=$base
    i=2
    while [ -e "$(cfg_file "$n")" ]; do
        n="$base-$i"
        i=$((i + 1))
        [ "$i" -gt 20 ] && break
    done
    printf '%s' "$n"
}

# The status endpoint is one loopback port per tunnel. It is written into the
# shared file, so the second server inherits the number; wizard_paste checks it
# again there because the two servers do not have the same tunnels on them.
wiz_free_status_port() {
    local i=0 p n taken
    while [ "$i" -lt 100 ]; do
        p=$((STATUS_BASE + i))
        taken=
        for n in $(cfg_list); do
            [ "$n" = "$WIZ_KEEP" ] && continue
            [ "$(toml_get "$(cfg_file "$n")" status port)" = "$p" ] && { taken=1; break; }
        done
        [ -z "$taken" ] && { printf '%s' "$p"; return 0; }
        i=$((i + 1))
    done
    printf '%s' "$STATUS_BASE"
}

# --------------------------------------------------------------------------
# validators the wizard adds to the ones in the UI
# --------------------------------------------------------------------------

v_wiz_octet() {
    local who
    v_octet "$1" || return 1
    if who=$(wiz_link_owner "$1"); then
        echo "10.$1.10.0/24 is in use here by $who"
        return 1
    fi
    return 0
}

v_wiz_port() {
    local who
    v_port "$1" || return 1
    if who=$(wiz_port_owner "$1"); then
        echo "port $1 already belongs to $who"
        return 1
    fi
    # A bound port only matters on the side that waits. IRAN dials out, so a
    # local listener on the same number there is not a conflict, and refusing
    # it would be a refusal with no action behind it.
    if [ "$T_SIDE" = kharej ] && wiz_port_bound "$1"; then
        echo "udp/$1 is in use here; see: ss -lnup | grep :$1"
        return 1
    fi
    return 0
}

# Two characters are refused, and both were found by writing one and reading it
# back. A double quote ends the TOML string early, because the core's parser
# toggles on every quote it sees. A hash is worse, because it round trips
# through the core perfectly and is truncated by toml_get, which strips from a
# hash without caring whether it is inside a string - so the tunnel works and
# the fingerprint on the review panel is a different token's. Backslashes,
# pipes and spaces all survive both readers and are allowed.
v_wiz_token() {
    v_token "$1" || return 1
    case $1 in
    *'"'* | *'#'*)
        echo 'no " or # in a token - the config file cannot carry them intact'
        return 1
        ;;
    esac
    return 0
}

v_wiz_review() {
    case $1 in
    y | Y | yes | YES | n | N | no | NO | t | T) return 0 ;;
    esac
    echo "y to create it, n to stop, t to type your own token"
    return 1
}

v_wiz_paste() {
    local s=${1//[[:space:]]/}
    case $s in
    '') echo "paste the whole line the other server printed"; return 1 ;;
    PFY2.*) return 0 ;;
    esac
    echo "that is not a Pingify token - the line starts with PFY2."
    return 1
}

# --------------------------------------------------------------------------
# the six questions
# --------------------------------------------------------------------------

q_side() {
    local n
    rule "1 - Which server is this?"
    blank
    item "1" "IRAN     users connect here; this side dials out"
    item "2" "KHAREJ   your panel runs here; this side waits"
    blank
    pick n "select" 1 2 || return 1
    case $n in
    1) T_SIDE=iran ;;
    2) T_SIDE=kharej ;;
    esac
    return 0
}

# Asked on both servers, identically, because the file carries the address of
# the server abroad on both. The old wizard asked one side for "the remote" and
# the other for "the local", and the two answers were the same address written
# from two points of view, which is how the pair came to disagree.
q_kharej() {
    local def=
    rule "2 - The server abroad"
    blank
    dim "Both servers name it, so the file is the same on each."
    blank
    [ "$T_SIDE" = kharej ] && def=$(wiz_public_ip)
    ask T_KHAREJ "address of the KHAREJ server" "$def" v_host || return 1
    return 0
}

q_transport() {
    local n
    rule "3 - How it crosses"
    blank
    item "1" "UDP    fastest, and the usual choice."
    dim "            needs one open port on KHAREJ"
    item "2" "ICMP   ping packets, so there is no port to"
    dim "            open and nothing to block by port. It"
    dim "            survives where UDP does not, and while"
    dim "            it runs neither server answers an"
    dim "            ordinary ping. That is deliberate."
    blank
    pick n "select" 1 2 || return 1
    case $n in
    1) T_TRANSPORT=udp ;;
    2) T_TRANSPORT=icmp ;;
    esac
    return 0
}

# Skipped whole for icmp, which has no ports: there is nothing to listen on and
# nothing to misconfigure, and that is half of why it survives.
q_port() {
    local def=8443 n
    if [ "$T_TRANSPORT" = icmp ]; then
        T_PORT=
        return 0
    fi
    rule "4 - Port"
    blank
    dim "KHAREJ waits on this port and IRAN dials it. The same"
    dim "number goes on both servers."
    blank
    for n in $(cfg_list); do
        [ "$(toml_get "$(cfg_file "$n")" transport type)" = icmp ] && continue
        dim "taken here:  $(toml_get "$(cfg_file "$n")" transport port)/udp   $n"
    done
    while wiz_port_owner "$def" >/dev/null ||
        { [ "$T_SIDE" = kharej ] && wiz_port_bound "$def"; }; do
        def=$((def + 1))
        [ "$def" -gt 8500 ] && { def=8443; break; }
    done
    ask T_PORT "port" "$def" v_wiz_port || return 1
    return 0
}

# One question, not three. The old wizard asked for the octet and then re-asked
# both addresses it had just derived from it, so a hand edit at the second
# prompt walked straight past the checks that guarded the first.
q_link() {
    local def n a dev addr
    rule "5 - The private link"
    blank
    dim "Two addresses nothing else uses. Pick the middle number."
    blank
    for n in $(cfg_list); do
        a=$(toml_get "$(cfg_file "$n")" tun iran)
        [ -n "$a" ] && dim "taken here:  ${a%%/*}/24  ($n)"
    done
    while read -r dev addr; do
        case ${addr%%/*} in
        10.*) dim "taken here:  $addr  ($dev)" ;;
        esac
    done < <(ip -4 -o addr 2>/dev/null | awk '$3 == "inet" { print $2, $4 }')

    def=$(free_octet) || def=
    if [ -z "$def" ]; then
        warn "every 10.x.10.0/24 is inside an address on this host"
        fix "ip -4 -o addr   shows what has them"
    fi
    ask T_OCTET "range  10.x.10.0/24  -  x" "$def" v_wiz_octet || return 1

    T_DEV=$(free_device) || {
        bad "there is no free pfy device left on this host"
        return 1
    }
    blank
    field "IRAN" "10.$T_OCTET.10.1/24"
    field "KHAREJ" "10.$T_OCTET.10.2/24"
    field "device" "$T_DEV"
    return 0
}

# The screen that justifies the tool. Every number here was measured on the
# real path, restarted fresh at each queue depth, and the profile moves exactly
# one setting - tuning.queue_packets. Showing a bare number instead of what it
# buys is how the old tuning menu came to be scrolled past.
q_profile() {
    local n
    local -a UI_COLS=(14 11 11 14)
    rule "6 - What crosses this link"
    blank
    row "" "16 streams" "one stream" "under load"
    row "  1  Gaming" "397 Mbit/s" "167 Mbit/s" "84.5 / 92.5 ms"
    row "$G_CUR 2  Balanced" "448" "254" "93.3 / 106.5"
    row "  3  Download" "466" "253" "115.8 / 139.3"
    blank
    dim "Balanced is not the middle of the three: it carries one"
    dim "stream faster than either. Idle ping is 81 ms for all."
    blank
    pick n "select" 2 3 || return 1
    case $n in
    1) T_PROFILE=gaming ;;
    2) T_PROFILE=balanced ;;
    3) T_PROFILE=download ;;
    esac
    return 0
}

wiz_queue() {
    case $1 in
    gaming) printf '600' ;;
    download) printf '1500' ;;
    *) printf '900' ;;
    esac
}

# --------------------------------------------------------------------------
# the token, which is generated rather than asked for
# --------------------------------------------------------------------------
#
# The core wants eight bytes; eighteen random ones are twenty-four base64
# characters, which removes a question, a validation loop, and the whole class
# of bug where one server has the token with a trailing space and the other
# does not.

wiz_token() {
    local t
    t=$(head -c 18 /dev/urandom 2>/dev/null | base64 2>/dev/null) || t=
    t=${t//$'\n'/}
    [ "${#t}" -ge 16 ] || return 1
    printf '%s' "$t"
}

wiz_sha256() {
    if have sha256sum; then sha256sum | cut -d' ' -f1
    elif have shasum; then shasum -a 256 | cut -d' ' -f1
    elif have openssl; then openssl dgst -sha256 | sed 's/.*= *//'
    else return 1
    fi
}

wiz_fingerprint() {
    local h
    h=$(printf '%s' "$1" | wiz_sha256) || { printf 'unknown'; return 0; }
    printf '%s' "${h:0:8}"
}

# --------------------------------------------------------------------------
# the review panel and the file it describes
# --------------------------------------------------------------------------

wiz_review() {
    local trans prof
    trans=${T_TRANSPORT^^}
    [ -n "$T_PORT" ] && trans="$trans  port $T_PORT"
    prof=${T_PROFILE:-balanced}
    blank
    panel_open "$T_NAME"
    panel_field "This server" "${T_SIDE^^}"
    panel_field "Abroad" "$T_KHAREJ"
    panel_field "Transport" "$trans"
    panel_field "Private link" "10.$T_OCTET.10.1  $G_BOTH  10.$T_OCTET.10.2   $T_DEV"
    panel_field "Profile" "${prof^}   queue $(wiz_queue "$prof") packets"
    panel_field "Token" "${T_TOKEN:0:8}$G_CUT  (fingerprint $(wiz_fingerprint "$T_TOKEN"))"
    panel_close
    blank
}

# wiz_confirm shows the panel and asks, and both entrances use it.
#
# The only difference between them is whether the token may be retyped. On the
# paste path it may not: the token has to be the one the other server already
# has, and a different one produces a pair that links up never and explains
# itself never.
wiz_confirm() {
    local retype=${1:-no} go
    while :; do
        wiz_review
        ask go "create $T_NAME?" y v_wiz_review || return 1
        case $go in
        t | T)
            if [ "$retype" = yes ]; then
                ask T_TOKEN "security token" "" v_wiz_token || return 1
            else
                warn "the token has to match the other server; it came with the paste"
            fi
            continue
            ;;
        n | N | no | NO)
            blank
            dim "nothing was created"
            return 1
            ;;
        esac
        return 0
    done
}

# wiz_render writes the config to stdout.
#
# One space either side of every "=", because that is exactly what toml_set
# writes when it rewrites a line. The second server flips side through
# toml_set, and if the two shapes disagreed then a diff of the two servers'
# files would show a formatting change beside the one real difference - and
# that diff is how anybody checks the pair is a pair.
wiz_render() {
    printf '# Pingify %s\n' "$PINGIFY_VERSION"
    printf '#\n'
    printf '# The same file runs on both servers. Only the side line differs.\n'
    printf '\n[tunnel]\n'
    printf 'name = "%s"\n' "$T_NAME"
    printf 'side = "%s"\n' "$T_SIDE"
    printf 'mode = "tun"\n'
    printf '\n[transport]\n'
    printf 'type = "%s"\n' "$T_TRANSPORT"
    printf 'kharej = "%s"\n' "$T_KHAREJ"
    # No port key at all for icmp. Writing port = 0 would pass the core's check
    # and then sit in the file looking like a setting somebody chose.
    [ -n "$T_PORT" ] && printf 'port = %s\n' "$T_PORT"
    printf '\n[security]\n'
    printf 'token = "%s"\n' "$T_TOKEN"
    printf '\n[tuning]\n'
    printf 'profile = "%s"\n' "$T_PROFILE"
    printf '\n[tun]\n'
    printf 'name = "%s"\n' "$T_DEV"
    printf 'iran = "10.%s.10.1/24"\n' "$T_OCTET"
    printf 'kharej = "10.%s.10.2/24"\n' "$T_OCTET"
    # Not asked. 1320 works on every path we have measured, and Measure MTU on
    # the tunnel screen finds the real number properly.
    printf 'mtu = %s\n' "${T_MTU:-1320}"
    printf '\n[logging]\n'
    printf 'level = "info"\n'
    printf '\n[status]\n'
    printf 'port = %s\n' "${T_STATUS:-$STATUS_BASE}"
}

# --------------------------------------------------------------------------
# writing it, and saying honestly what happened
# --------------------------------------------------------------------------

# tunnel_create NAME [FILE] - FILE is the finished config; with no FILE the
# config is read from stdin.
tunnel_create() {
    local name=$1 src=${2:-} f out
    [ -n "$name" ] || { bad "a tunnel needs a name"; return 1; }
    if ! ensure_dirs; then
        bad "could not create $CFG_DIR"
        fix "run this as root"
        return 1
    fi
    f=$(cfg_file "$name")
    [ -e "$f" ] && { bad "there is already a tunnel called $name here"; return 1; }
    if [ ! -x "$CORE_BIN" ]; then
        bad "the core is not installed at $CORE_BIN"
        fix "install Pingify first - nothing has been changed"
        return 1
    fi

    # The file is 0600 before a single byte of the token exists in it. Writing
    # first and fixing the mode afterwards leaves a window where anyone with an
    # account on the box can read it, and on a shared VPS that window is enough.
    if ! : >"$f"; then
        bad "could not write $f"
        return 1
    fi
    chmod 0600 "$f"
    if [ -n "$src" ]; then
        cat "$src" >"$f" || { rm -f "$f"; return 1; }
    else
        cat >"$f" || { rm -f "$f"; return 1; }
    fi

    if ! out=$("$CORE_BIN" -c "$f" -check 2>&1); then
        bad "the core will not accept that config - nothing created"
        printf '%s\n' "$out" | sed 's/^/       /'
        rm -f "$f"
        return 1
    fi
    # Cut to fit rather than run over the edge: a long tunnel name makes a long
    # path, and this is the one line in the wizard that carries one.
    ok "$(trunc_to "$f" $((UI_W - 30))) accepted by the core"

    # A repair, not a rewrite: the units are written once at install, and doing
    # it per tunnel is how the old script came to rewrite four units whenever
    # anybody added one.
    [ -f "$UNIT_DIR/pingify@.service" ] || unit_write

    # svc_do enable returns the truth about is-active and prints the journal
    # when it failed. Returning its status is the point: the old caller printed
    # a green "is running" over a unit that had never started.
    svc_do enable "$name"
}

# --------------------------------------------------------------------------
# the setup token: PFY2. + base64 of "<sha256 of body>|<the TOML verbatim>"
# --------------------------------------------------------------------------

token_encode() {
    local file=$1 body sum out
    [ -f "$file" ] || { echo "there is no file at $file" >&2; return 1; }
    # Trailing newlines are dropped here and on the way back, on purpose: a
    # command substitution eats them anyway, so checksumming what survives the
    # journey is the only way the two sums can agree.
    body=$(cat "$file") || return 1
    sum=$(printf '%s\n' "$body" | wiz_sha256) || {
        echo "no sha256 tool here, so no token can be made" >&2
        return 1
    }
    out=$( { printf '%s|' "$sum"; printf '%s\n' "$body"; } | base64) || return 1
    printf 'PFY2.%s\n' "${out//$'\n'/}"
}

token_decode() {
    local line=$1 raw sum body have
    # Every kind of whitespace comes out first. The line is long enough to wrap
    # in any terminal, and a paste that picked up the wrap is the single most
    # common way this fails; base64 has no whitespace in it to lose.
    line=${line//[[:space:]]/}
    case $line in
    PFY2.*) ;;
    *) echo "that is not a Pingify token - the line starts with PFY2." >&2; return 1 ;;
    esac
    raw=$(printf '%s' "${line#PFY2.}" | base64 -d 2>/dev/null) || {
        echo "the token is damaged and will not decode - copy the whole line" >&2
        return 1
    }
    # Split on the first pipe only: a hand-typed security token may contain
    # one, and a sha256 never does.
    sum=${raw%%|*}
    body=${raw#*|}
    [ "$sum" != "$raw" ] || {
        echo "the token is damaged and will not decode - copy the whole line" >&2
        return 1
    }
    have=$(printf '%s\n' "$body" | wiz_sha256) || {
        echo "no sha256 tool here, so the token cannot be checked" >&2
        return 1
    }
    if [ "$have" != "$sum" ]; then
        echo "the token checksum does not match - copy the whole line" >&2
        return 1
    fi
    printf '%s\n' "$body"
}

# --------------------------------------------------------------------------
# build a new tunnel
# --------------------------------------------------------------------------

wizard_new() {
    local f other
    WIZ_QUIT=0
    T_SIDE= T_KHAREJ= T_TRANSPORT= T_PORT= T_OCTET= T_PROFILE=
    T_NAME= T_DEV= T_TOKEN= T_MTU=1320 T_STATUS=

    blank
    rule "Build a new tunnel"
    dim "q at any question leaves without building anything"
    blank

    q_side || return 1
    blank
    q_kharej || return 1
    blank
    q_transport || return 1
    blank
    q_port || return 1
    blank
    q_link || return 1
    blank
    q_profile || return 1

    T_NAME=$(default_name)
    T_STATUS=$(wiz_free_status_port)
    if ! T_TOKEN=$(wiz_token); then
        warn "no random source here, so the token has to be typed"
        ask T_TOKEN "security token" "" v_wiz_token || return 1
    fi

    wiz_confirm yes || return 1

    blank
    f=$(mktemp) || { bad "could not make a temporary file"; return 1; }
    wiz_render >"$f"
    if ! tunnel_create "$T_NAME" "$f"; then
        rm -f "$f"
        return 1
    fi
    rm -f "$f"

    other=KHAREJ
    [ "$T_SIDE" = kharej ] && other=IRAN
    wiz_handoff "$T_NAME" "$other"
}

wiz_handoff() {
    local name=$1 other=$2 line
    if ! line=$(token_encode "$(cfg_file "$name")"); then
        bad "the config is written, but the token could not be made"
        fix "copy the file to $other by hand and change side there"
        return 1
    fi
    blank
    rule "Now the other server"
    blank
    dim "Run Pingify on $other, pick \"Finish the pair\", and paste:"
    blank
    # Printed flush left with nothing around it, so a double click or a triple
    # click selects the token and only the token.
    say "$line"
    blank
    warn "treat that like a password: the token is inside it"
    blank
    return 0
}

# --------------------------------------------------------------------------
# finish the pair
# --------------------------------------------------------------------------

wizard_paste() {
    local line f err a own n clash port
    WIZ_QUIT=0
    blank
    rule "Finish the pair"
    blank
    dim "Paste the line the first server printed. It carries"
    dim "the whole config, so there is nothing left to answer."
    blank
    ask line "paste the line from the other server" "" v_wiz_paste || return 1

    f=$(mktemp) || { bad "could not make a temporary file"; return 1; }
    # stderr into the substitution, stdout into the file: the order matters,
    # because 2>&1 copies where stdout points *now*.
    if ! err=$(token_decode "$line" 2>&1 >"$f"); then
        blank
        bad "$err"
        fix "copy the whole line again from the first server"
        rm -f "$f"
        return 1
    fi

    T_NAME=$(toml_get "$f" tunnel name)
    T_SIDE=$(toml_get "$f" tunnel side)
    T_TRANSPORT=$(toml_get "$f" transport type)
    T_KHAREJ=$(toml_get "$f" transport kharej)
    T_PORT=$(toml_get "$f" transport port)
    T_TOKEN=$(toml_get "$f" security token)
    T_PROFILE=$(toml_get "$f" tuning profile)
    T_DEV=$(toml_get "$f" tun name)
    T_MTU=$(toml_get "$f" tun mtu)
    a=$(toml_get "$f" tun iran)
    T_OCTET=${a#10.}
    T_OCTET=${T_OCTET%%.*}

    # The checksum says the file arrived whole; it does not say it was a
    # Pingify config. Everything below indexes on these four, so they are
    # checked here rather than found missing halfway through the collision
    # checks with an arithmetic error for a message.
    if ! v_name "$T_NAME" >/dev/null 2>&1 ||
        ! v_octet "$T_OCTET" >/dev/null 2>&1 ||
        [ -z "$T_DEV" ] || [ -z "$T_TRANSPORT" ]; then
        bad "that token decoded, but it is not a Pingify config"
        fix "paste the line the other server printed"
        rm -f "$f"
        return 1
    fi

    # The side in the file is the *other* server's. This flip is the entire
    # second installation.
    case $T_SIDE in
    iran) T_SIDE=kharej ;;
    kharej) T_SIDE=iran ;;
    *) bad "that token does not say which server made it"; rm -f "$f"; return 1 ;;
    esac
    toml_set "$f" tunnel side "$T_SIDE"

    # The file is shared, so a clash here can only be fixed on both servers.
    # This is the one thing the shared-file design costs, and it is the
    # manager's job to spell out, not the user's to work out.
    clash=0
    if [ -e "$(cfg_file "$T_NAME")" ]; then
        bad "there is already a tunnel called $T_NAME here"
        fix "delete that one first, or use a different octet"
        clash=1
    fi
    if own=$(wiz_link_owner "$T_OCTET"); then
        bad "10.$T_OCTET.10.0/24 is in use here by $own"
        fix "change the range on both servers, and paste again"
        clash=1
    fi
    if own=$(wiz_device_owner "$T_DEV"); then
        bad "the device $T_DEV is in use here by $own"
        fix "the device is in the shared file - change both"
        clash=1
    fi
    if [ "$T_SIDE" = kharej ] && [ "$T_TRANSPORT" != icmp ]; then
        if own=$(wiz_port_owner "$T_PORT"); then
            bad "port $T_PORT already belongs to $own"
            fix "change the port on both servers, and paste again"
            clash=1
        elif wiz_port_bound "$T_PORT"; then
            bad "something here already listens on udp/$T_PORT"
            fix "ss -lnup | grep :$T_PORT   shows what has it"
            clash=1
        fi
    fi
    if [ "$clash" = 1 ]; then
        blank
        dim "nothing was created"
        rm -f "$f"
        return 1
    fi

    # The status port is loopback-only and per host, so it is the one number
    # that may legitimately differ between the two files. It is checked again
    # here because this server does not have the same tunnels on it.
    T_STATUS=$(toml_get "$f" status port)
    port=$(wiz_free_status_port)
    for n in $(cfg_list); do
        [ "$(toml_get "$(cfg_file "$n")" status port)" = "$T_STATUS" ] || continue
        warn "status port $T_STATUS is taken here by $n"
        dim "this file uses $port, so the two differ there too"
        T_STATUS=
        break
    done
    if [ -z "$T_STATUS" ]; then
        T_STATUS=$port
        toml_set "$f" status port "$T_STATUS"
    fi

    wiz_confirm no || { rm -f "$f"; return 1; }

    blank
    if ! tunnel_create "$T_NAME" "$f"; then
        rm -f "$f"
        return 1
    fi
    rm -f "$f"
    blank
    ok "both ends are configured now - nothing else to paste"
    dim "give it a few seconds and look at it on the home screen"
    blank
    return 0
}

# --------------------------------------------------------------------------
# the way in
# --------------------------------------------------------------------------

# The two entrances, and nothing else.
#
# menu_key rather than pick, because 0 is a key here and pick only answers 1..N
# on purpose - a question with a numbered list of answers must not accept a
# number that is not one of them. Navigation screens have a Back key; questions
# do not.
wizard_menu() {
    local k
    blank
    rule "New tunnel"
    blank
    item2 "1" "Build a new tunnel" "six questions"
    item2 "2" "Finish the pair" "one paste"
    item "0" "Back"
    blank
    menu_key k || return 0
    case $k in
    1) wizard_new ;;
    2) wizard_paste ;;
    esac
    return 0
}
#!/usr/bin/env bash
#
# The screen a person looks at most: one tunnel, what it is doing, and the
# things they might want to do to it.
#
# It is one screen and it fits on a phone. The old manager put the same
# information behind three menus and then listed the tunnels twice on the way
# in - once as a status table and again as a numbered list of the same names -
# so choosing one meant reading the same six words in two places and matching
# them up by eye.

# --------------------------------------------------------------------------
# what a tunnel is doing
# --------------------------------------------------------------------------

# tun_line fills TL_* for one tunnel: enough for a row on the home screen.
#
# Two sources and no third. systemd says whether the unit is running, and the
# core's own status endpoint says whether it is carrying anything. Nothing here
# reads the log, because a log line is prose and prose gets reworded - the old
# manager took the eighth field of an English sentence and broke the day
# somebody improved the sentence.
tun_line() {
    local name=$1 state
    TL_STATE=unknown TL_RATE= TL_PEER= TL_RTT= TL_TRANSPORT= TL_SIDE=

    local f
    f=$(cfg_file "$name")
    TL_TRANSPORT=$(toml_get "$f" transport type)
    TL_SIDE=$(toml_get "$f" tunnel side)
    TL_PEER=$(peer_addr "$name")

    state=$(svc_state "$name")
    case $state in
    disabled | stopped)
        TL_STATE=$state
        return
        ;;
    esac

    if tun_stats "$name"; then
        # Running and the far end has been seen is the only state that earns a
        # green dot. Running and alone looks identical from here and is not
        # the same thing at all.
        if [ "$ST_UP" = true ]; then
            TL_STATE=running
        else
            TL_STATE=idle
        fi
        TL_RATE="$(round1 "$ST_IN")/$(round1 "$ST_OUT") Mbit/s"
    else
        # The unit is up but the endpoint does not answer. That is a real
        # state and it is not a failure to report in red: it happens for the
        # first second of every start.
        TL_STATE=idle
    fi
    TL_RTT=$(tun_rtt "$name")
}

# peer_addr is the other end of the private link, without its prefix.
peer_addr() {
    local f side a
    f=$(cfg_file "$1")
    side=$(toml_get "$f" tunnel side)
    if [ "$side" = iran ]; then
        a=$(toml_get "$f" tun kharej)
    else
        a=$(toml_get "$f" tun iran)
    fi
    printf '%s' "${a%%/*}"
}

my_addr() {
    local f side a
    f=$(cfg_file "$1")
    side=$(toml_get "$f" tunnel side)
    if [ "$side" = iran ]; then
        a=$(toml_get "$f" tun iran)
    else
        a=$(toml_get "$f" tun kharej)
    fi
    printf '%s' "${a%%/*}"
}

# tun_rtt is the round trip across the private link, or nothing.
#
# Nothing, on an ICMP tunnel, and that is the correct answer rather than a
# missing one. An ICMP carrier stops both kernels answering echo - it has to,
# or every packet it sends is answered twice - so a ping across the link goes
# out and is deliberately ignored. The old manager would have drawn that in red
# and told the user their working tunnel was dead.
tun_rtt() {
    local name=$1 t out
    t=$(toml_get "$(cfg_file "$name")" transport type)
    [ "$t" = icmp ] && return 0
    have ping || return 0
    out=$(ping -c 2 -W 2 -q "$(peer_addr "$name")" 2>/dev/null |
        awk -F'/' '/^rtt|^round-trip/ {printf "%.0f", $5}')
    printf '%s' "$out"
}

# --------------------------------------------------------------------------
# the tunnel screen
# --------------------------------------------------------------------------

screen_tunnel() {
    local name=$1 f
    f=$(cfg_file "$name")
    [ -f "$f" ] || { bad "there is no tunnel called $name"; return 1; }

    while :; do
        tun_line "$name"
        blank
        printf '  %s%s%s%s%s %s\n' "$C_B" "$name" "$C_OFF" \
            "$(rep ' ' $((UI_W - ${#name} - 16)))" \
            "$(state_dot "$TL_STATE")" "$TL_STATE"
        blank

        local side kharej port transport mtu dev prof
        side=$(toml_get "$f" tunnel side)
        kharej=$(toml_get "$f" transport kharej)
        port=$(toml_get "$f" transport port)
        transport=$(toml_get "$f" transport type)
        mtu=$(toml_get "$f" tun mtu)
        dev=$(toml_get "$f" tun name)
        prof=$(toml_get "$f" tuning profile)

        if [ "$side" = iran ]; then
            if [ "$transport" = icmp ]; then
                field "Side" "IRAN, dials $kharej over icmp"
            else
                field "Side" "IRAN, dials $kharej:$port/udp"
            fi
        else
            if [ "$transport" = icmp ]; then
                field "Side" "KHAREJ, waits for echo"
            else
                field "Side" "KHAREJ, waits on udp/$port"
            fi
        fi
        field "Link" "$(my_addr "$name") $G_BOTH $(peer_addr "$name")   $dev   mtu $mtu"

        if [ -n "$TL_RATE" ]; then
            local rtt=$TL_RTT
            if [ -n "$rtt" ]; then
                field "Carrying" "$TL_RATE      $(rtt_colour "$rtt")$rtt ms$C_OFF"
            else
                field "Carrying" "$TL_RATE"
            fi
        fi

        # Losses only when there are some. A line saying zero every time is a
        # line people stop reading, and then they do not see it change.
        if [ -n "${ST_LOST:-}" ] && [ "${ST_LOST:-0}" -gt 0 ]; then
            local per=$((ST_LOST / (ST_GAPS > 0 ? ST_GAPS : 1)))
            field "Path took" "$ST_LOST packets in $ST_GAPS runs, about $per at a time"
        fi

        local fw
        fw=$(forwards_of "$name" 2>/dev/null || true)
        [ -n "$fw" ] && field "Ports" "$fw  $G_ARROW  $(peer_addr "$name")"

        blank
        group "RUN"
        case $TL_STATE in
        stopped | disabled) item 1 "Start" ;;
        *) item 1 "Restart" ;;
        esac
        item 2 "Stop"
        item 3 "Live view"
        blank
        group "CHECK"
        item 4 "Health check          what is wrong, and what to do about it"
        item 5 "Log"
        item 6 "Measure MTU"
        item 7 "Speed test"
        blank
        group "CHANGE"
        if [ "$side" = iran ]; then
            item2 8 "Ports" "${fw:-none}"
        else
            item2 8 "Ports" "IRAN forwards them, not this side"
        fi
        item2 9 "Profile" "$prof"
        item a "Advanced             mtu, log level, what it says"
        item d "Delete this tunnel"
        item 0 "Back"
        blank

        local k
        menu_key k || return 0
        case $k in
        1) svc_do restart "$name"; pause ;;
        2) svc_do stop "$name"; pause ;;
        3) screen_live "$name" ;;
        4) health_check "$name"; pause ;;
        5) show_log "$name" ;;
        6) measure_mtu "$name"; pause ;;
        7) speed_test "$name"; pause ;;
        8) [ "$side" = iran ] && { screen_ports "$name"; } ||
            { warn "ports are forwarded from the IRAN side"; pause; } ;;
        9) edit_profile "$name" ;;
        a | A) screen_advanced "$name" ;;
        d | D) delete_tunnel "$name" && return 0 ;;
        0 | '') return 0 ;;
        esac
    done
}

pause() {
    blank
    printf '  %spress enter%s' "$C_MUTE" "$C_OFF" >&2
    IFS= read -r _ || true
}

show_log() {
    blank
    rule "Log $G_DASH $1"
    blank
    journalctl -u "pingify@$1" -n 40 --no-pager -o cat 2>/dev/null |
        sed 's/^/    /' || dim "there is no journal for this tunnel yet"
    pause
}

# --------------------------------------------------------------------------
# changing one
# --------------------------------------------------------------------------

# edit_profile is the screen that justifies the whole tool: it does not show a
# setting, it shows what the setting buys. Every number here was measured on a
# real path between Tehran and Frankfurt.
edit_profile() {
    local name=$1 cur choice
    cur=$(toml_get "$(cfg_file "$name")" tuning profile)

    blank
    rule "What crosses this link"
    blank
    printf '    %s%s%s\n' "$C_KEY" \
        "$(pad_to '' 14)16 streams   one stream   under load" "$C_OFF"
    profile_row 1 gaming "$cur" "397 Mbit/s" "167 Mbit/s" "84.5 / 92.5 ms"
    profile_row 2 balanced "$cur" "448" "254" "93.3 / 106.5"
    profile_row 3 download "$cur" "466" "253" "115.8 / 139.3"
    blank
    dim "Balanced is not the middle: it carries one stream faster than either"
    dim "of the others. Idle ping is 81 ms whichever you choose."
    blank

    local def=2
    case $cur in gaming) def=1 ;; download) def=3 ;; esac
    pick choice "select" "$def" 3 || return 0

    local want
    case $choice in 1) want=gaming ;; 2) want=balanced ;; 3) want=download ;; esac
    [ "$want" = "$cur" ] && return 0

    PROFILE_WANT=$want
    if cfg_apply "$name" _edit_profile yes; then
        ok "$name is on the $want profile"
    fi
    pause
}

_edit_profile() { toml_set "$1" tuning profile "$PROFILE_WANT"; }

profile_row() {
    local key=$1 name=$2 cur=$3 a=$4 b=$5 c=$6 mark=' '
    [ "$name" = "$cur" ] && mark=$G_CUR
    printf '  %s%s%s %s%s%s  %s%s%s%s\n' \
        "$C_ACCENT" "$mark" "$C_OFF" \
        "$C_ACCENT" "$key" "$C_OFF" \
        "$(pad_to "${name^}" 11)" "$(pad_to "$a" 13)" "$(pad_to "$b" 13)" "$c"
}

screen_advanced() {
    local name=$1 f k
    f=$(cfg_file "$name")
    while :; do
        blank
        rule "Advanced $G_DASH $name"
        blank
        item2 1 "MTU" "$(toml_get "$f" tun mtu)"
        item2 2 "Log level" "$(toml_get "$f" logging level)"
        item2 3 "Queue depth" "$(toml_get "$f" tuning queue_packets) packets, from the profile"
        item2 4 "Device queues" "$(toml_get "$f" tun queues)"
        item 5 "Show the config file"
        item 0 "Back"
        blank
        menu_key k || return 0
        case $k in
        1) local v
            ask v "mtu" "$(toml_get "$f" tun mtu)" v_mtu || continue
            MTU_WANT=$v; cfg_apply "$name" _edit_mtu yes; pause ;;
        2) local v
            blank; dim "debug says a great deal; info says what changed"; blank
            ask v "level" "$(toml_get "$f" logging level)" v_level || continue
            LEVEL_WANT=$v; cfg_apply "$name" _edit_level yes; pause ;;
        3) blank
            dim "This comes from the profile and is the one number a profile moves."
            dim "Set it directly only if you have measured your own path."
            local v
            ask v "packets" "$(toml_get "$f" tuning queue_packets)" v_queue || continue
            QUEUE_WANT=$v; cfg_apply "$name" _edit_queue yes; pause ;;
        4) local v
            ask v "queues (0 lets the core choose)" "$(toml_get "$f" tun queues)" v_queues || continue
            QUEUES_WANT=$v; cfg_apply "$name" _edit_queues yes; pause ;;
        5) blank; sed 's/^/    /' "$f"; pause ;;
        0 | '') return 0 ;;
        esac
    done
}

_edit_mtu() { toml_set "$1" tun mtu "$MTU_WANT"; }
_edit_level() { toml_set "$1" logging level "$LEVEL_WANT"; }
_edit_queue() { toml_set "$1" tuning queue_packets "$QUEUE_WANT"; }
_edit_queues() { toml_set "$1" tun queues "$QUEUES_WANT"; }

v_level() {
    case $1 in
    debug | info | warn | error) return 0 ;;
    esac
    echo "debug, info, warn or error"
    return 1
}

v_queue() {
    case $1 in '' | *[!0-9]*) echo "a number of packets"; return 1 ;; esac
    { [ "$1" -ge 200 ] && [ "$1" -le 20000 ]; } || {
        echo "200 to 20000 - below that the queue refuses work the link could carry"
        return 1
    }
}

v_queues() {
    case $1 in '' | *[!0-9]*) echo "a number"; return 1 ;; esac
    [ "$1" -le 16 ] || { echo "0 to 16"; return 1; }
}

delete_tunnel() {
    local name=$1
    blank
    warn "this removes the tunnel $name from this server"
    dim "the other server keeps its own copy until you remove it there too"
    blank
    confirm "delete $name?" n || return 1

    svc_do stop "$name" 2>/dev/null || true
    systemctl disable "pingify@$name" >/dev/null 2>&1 || true
    nat_drop "$name" 2>/dev/null || true
    rm -f "$(cfg_file "$name")" "$STATE_DIR/$name.forwards"
    ok "$name is gone"
    pause
    return 0
}
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
            fwd_no "$tok" "that is $wide ports, and more than 512 in one range is a mistake being made"
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
                fwd_no "$tok" "a range cannot go to one port - forward $lo-$hi as it stands, or the ports one at a time"
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

# fwd_listeners prints "proto port who" for everything bound on this host.
#
# Loopback-only listeners are left out on purpose: PREROUTING takes the packet
# long before it reaches 127.0.0.1, so such a service never saw the outside
# traffic and calling it a clash is a false alarm - and false alarms are how
# people learn to ignore a collision check.
fwd_listeners() {
    have ss || return 0
    ss -lntup 2>/dev/null | awk '
        NR > 1 {
            addr = $5
            n = split(addr, p, ":")
            port = p[n]
            host = substr(addr, 1, length(addr) - length(port) - 1)
            if (host == "127.0.0.1" || host == "[::1]") next
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
    bad "the kernel is not forwarding packets, so nothing would reach the other side"
    fix "sysctl -w net.ipv4.ip_forward=1"
    return 1
}

# nat_rules_for appends one tunnel's rules to the already flushed chains. A
# tunnel whose stored list no longer parses is skipped with a complaint rather
# than aborting the rebuild: the rebuild is doing the other tunnels' work too,
# and one bad state file must not take their ports down with it.
nat_rules_for() {
    local name=$1 f side dev peer tuples proto lo hi dsth dstp dport target
    f=$(cfg_file "$name")
    [ -f "$f" ] || return 0
    side=$(toml_get "$f" tunnel side)
    [ "$side" = iran ] || return 0

    tuples=$(forward_specs "$(forwards_of "$name")") || return 1
    [ -n "$tuples" ] || return 0
    dev=$(tun_dev_of "$name")
    peer=$(peer_tun_addr "$name")
    [ -n "$dev" ] && [ -n "$peer" ] || return 1

    while read -r proto lo hi dsth dstp; do
        [ -n "$proto" ] || continue
        [ "$dsth" = - ] && dsth=$peer
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

# nat_apply rebuilds everything from every tunnel's state, then reports on the
# one it was called for. Everything, because the chains are shared: flushing
# them to write one tunnel's rules and not writing the others back is how a
# second tunnel silently loses its ports.
nat_apply() {
    local name=$1 t n peer word
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
        nat_rules_for "$t" || warn "$t: its stored ports could not be applied"
    done < <(cfg_list)

    n=$(forwards_of "$name" | grep -c .) || n=0
    peer=$(peer_tun_addr "$name")
    if [ "$n" -gt 0 ]; then
        word=ports
        [ "$n" = 1 ] && word=port
        ok "$name sends $n $word to $peer"
    else
        ok "$name forwards nothing now"
    fi
    return 0
}

# nat_drop removes one tunnel's forwarding. Call it before the config file is
# deleted: the tun device name comes out of the config, and without it the
# FORWARD rules for that device can never be found again.
nat_drop() {
    local name=$1 dev t left=0
    rm -f "$(fwd_file "$name")"
    have iptables || return 0
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

    while :; do
        side=$(toml_get "$f" tunnel side)
        blank
        rule "Ports $G_CUR $name"
        blank
        if [ "$side" != iran ]; then
            warn "this is the KHAREJ side, and nothing is forwarded from here"
            fix "run this on the IRAN server - that is the side users connect to"
            blank
            return 0
        fi

        peer=$(peer_tun_addr "$name")
        dim "what arrives on these ports is handed to $peer, across the tunnel"
        blank
        cur=$(forwards_of "$name" | tr '\n' ' ')
        cur=${cur% }
        if [ -z "$cur" ]; then
            dim "nothing is forwarded yet"
        elif ! tuples=$(forward_specs "$cur"); then
            warn "the stored list cannot be read, so this tunnel forwards nothing"
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
#!/usr/bin/env bash
#
# Diagnostics: the screens you open when something is wrong, and the two
# measurements worth taking when nothing is.
#
# Four decisions shape this whole part.
#
#   Every failure carries a fix. A health check that lists problems and stops
#   is a list of reasons to be worried with no way to stop being worried. That
#   was the old check's one good idea, and it is kept without its 320 lines.
#
#   Grey is a verdict. Red means "this is broken", never "this could not be
#   measured". An ICMP tunnel switches off echo replies on both servers while
#   it runs, so a ping across it is answered by nobody - the design working,
#   not the link failing. The old manager drew that in red and told a healthy
#   tunnel it was dead. Here it is one grey line.
#
#   Status comes from the core, never from its prose. `tun_stats` reads the
#   JSON the core serves on loopback. The old manager took the eighth field of
#   an English sentence out of the journal with awk, and broke the day somebody
#   reworded the sentence.
#
#   Every message fits in sixty columns, which is UI_W's floor. None of
#   ok/warn/bad/fix/dim truncates - they carry prose, and prose that overruns
#   wraps and destroys the indentation that carries the meaning. The budgets
#   are 54 characters for a verdict, 46 for a fix, 56 for a grey note.

# --------------------------------------------------------------------------
# collecting a verdict
# --------------------------------------------------------------------------
#
# health_check buffers its result rather than printing as it goes, so the text
# screen and --json are one pass rendered twice. Two passes would eventually
# disagree, and the one a script reads is the one nobody looks at.

CHK_STATE=() CHK_ID=() CHK_TEXT=() CHK_FIX=()
CHK_NBAD=0 CHK_NWARN=0

chk_reset() {
    CHK_STATE=() CHK_ID=() CHK_TEXT=() CHK_FIX=()
    CHK_NBAD=0 CHK_NWARN=0
}

# chk_add STATE ID TEXT [FIX...]
#
# STATE is ok, warn, bad or note. note is the grey one: something worth saying
# that is not a fault, and it is never counted as one. Every warn and every bad
# passes at least one fix; nothing else passes any.
chk_add() {
    local state=$1 id=$2 text=$3 joined= one
    shift 3
    for one in "$@"; do joined=$joined$one$'\n'; done
    CHK_STATE+=("$state")
    CHK_ID+=("$id")
    CHK_TEXT+=("$text")
    CHK_FIX+=("$joined")
    case $state in
    bad) CHK_NBAD=$((CHK_NBAD + 1)) ;;
    warn) CHK_NWARN=$((CHK_NWARN + 1)) ;;
    esac
}

# count_word turns a small number into the word for it. "one problem" reads;
# "1 problem(s)" is a form to be filled in.
count_word() {
    case $1 in
    1) printf 'one' ;; 2) printf 'two' ;; 3) printf 'three' ;;
    *) printf '%s' "$1" ;;
    esac
}

# plural_s prints the s, or nothing, inline, so a count and its noun cannot
# drift apart in an edit.
plural_s() { [ "$1" = 1 ] || printf 's'; }

chk_tally() {
    local out=
    [ "$CHK_NBAD" = 0 ] && [ "$CHK_NWARN" = 0 ] &&
        { printf 'nothing wrong here'; return; }
    [ "$CHK_NBAD" -gt 0 ] &&
        out="$(count_word "$CHK_NBAD") problem$(plural_s "$CHK_NBAD")"
    if [ "$CHK_NWARN" -gt 0 ]; then
        [ -n "$out" ] && out="$out, "
        out="$out$(count_word "$CHK_NWARN") warning$(plural_s "$CHK_NWARN")"
    fi
    printf '%s' "$out"
}

chk_render() {
    local name=$1 i line
    blank
    rule "Health of $name"
    blank
    for ((i = 0; i < ${#CHK_ID[@]}; i++)); do
        case ${CHK_STATE[i]} in
        ok) ok "${CHK_TEXT[i]}" ;;
        warn) warn "${CHK_TEXT[i]}" ;;
        bad) bad "${CHK_TEXT[i]}" ;;
        # ok/warn/bad each spend two columns on a glyph before their text. A
        # grey note has no glyph, so it is padded into the same column; without
        # that it sits two to the left and reads as a different list.
        *) dim "  ${CHK_TEXT[i]}" ;;
        esac
        if [ -n "${CHK_FIX[i]}" ]; then
            while IFS= read -r line; do
                [ -n "$line" ] && fix "$line"
            done <<<"${CHK_FIX[i]}"
        fi
    done
    blank
    dim "$(chk_tally)"
    blank
}

# json_esc covers what can actually appear in these strings: backslashes,
# quotes and tabs. Nothing here builds a check line out of text with a newline
# in it - the one place that could, the core's own refusal, is cut to its first
# line before it gets here.
json_esc() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\t'/ }
    printf '%s' "$s"
}

chk_json() {
    local name=$1 i last first line
    last=$((${#CHK_ID[@]} - 1))
    printf '{\n'
    printf '  "tunnel": "%s",\n' "$(json_esc "$name")"
    printf '  "problems": %s,\n' "$CHK_NBAD"
    printf '  "warnings": %s,\n' "$CHK_NWARN"
    printf '  "checks": [\n'
    for ((i = 0; i <= last; i++)); do
        printf '    {"id": "%s", "state": "%s", "text": "%s", "fixes": [' \
            "$(json_esc "${CHK_ID[i]}")" "${CHK_STATE[i]}" \
            "$(json_esc "${CHK_TEXT[i]}")"
        first=1
        if [ -n "${CHK_FIX[i]}" ]; then
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                [ "$first" = 1 ] || printf ', '
                printf '"%s"' "$(json_esc "$line")"
                first=0
            done <<<"${CHK_FIX[i]}"
        fi
        printf ']}'
        [ "$i" -lt "$last" ] && printf ','
        printf '\n'
    done
    printf '  ]\n}\n'
}

# --------------------------------------------------------------------------
# reading a tunnel's own idea of itself
# --------------------------------------------------------------------------
#
# Eight values every screen here needs, read once into CK_* globals. Reading
# them per screen meant eight awk passes over one file and, in the old script,
# two of the readers disagreed about which side we were on.

chk_load() {
    local name=$1
    CK_FILE=$(cfg_file "$name")
    [ -f "$CK_FILE" ] || return 1
    CK_SIDE=$(toml_get "$CK_FILE" tunnel side)
    CK_TRANSPORT=$(toml_get "$CK_FILE" transport type)
    CK_PORT=$(toml_get "$CK_FILE" transport port)
    CK_KHAREJ=$(toml_get "$CK_FILE" transport kharej)
    CK_DEV=$(toml_get "$CK_FILE" tun name)
    CK_MTU=$(toml_get "$CK_FILE" tun mtu)
    # The core fills these in when the file leaves them out, so the manager has
    # to agree with it or it reports a mismatch that is not one.
    [ -n "$CK_TRANSPORT" ] || CK_TRANSPORT=udp
    [ -n "$CK_DEV" ] || CK_DEV=pfy0
    [ -n "$CK_MTU" ] || CK_MTU=1320
    if [ "$CK_SIDE" = iran ]; then
        CK_MINE=$(toml_get "$CK_FILE" tun iran)
        CK_THEIRS=$(toml_get "$CK_FILE" tun kharej)
    else
        CK_MINE=$(toml_get "$CK_FILE" tun kharej)
        CK_THEIRS=$(toml_get "$CK_FILE" tun iran)
    fi
    CK_PEER=${CK_THEIRS%%/*}
    return 0
}

# link_rtt pings the other end of the private link and prints the round trip in
# milliseconds. It is bound to the tun device, so the answer is the tunnel's
# latency and not the carrier's. Prints nothing and returns 1 when no reply
# comes, which on an ICMP tunnel is always - see the note in health_check.
link_rtt() {
    local dev=$1 peer=$2 out
    out=$(ping -n -c1 -W1 -I "$dev" "$peer" 2>/dev/null) || return 1
    case $out in
    *time=*) out=${out#*time=}; printf '%s' "${out%% *}" ;;
    *) return 1 ;;
    esac
}

# tcp_reach says whether something accepts a connection at HOST:PORT. bash's
# own /dev/tcp is tried first because it is always there and needs no package;
# nc is the fallback for the builds that compile it out.
tcp_reach() {
    local host=$1 port=$2
    if timeout 2 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
        return 0
    fi
    have nc && nc -z -w2 "$host" "$port" >/dev/null 2>&1
}

# The forwarding part owns the port spec and where it is kept; this only reads
# it. When forwarding was never set up the check says nothing about ports
# rather than inventing a failure out of an absent file.
chk_forward_spec() {
    local f=$STATE_DIR/$1.ports
    [ -f "$f" ] || return 1
    tr -d '\r\n' <"$f"
}

# --------------------------------------------------------------------------
# health_check
# --------------------------------------------------------------------------
#
# One pass, in the order things fail. A check whose evidence is missing says so
# in grey and does not guess: with no core installed there is no verdict to
# give about whether it accepts the config, and giving one anyway is how a
# health report comes to be ignored. Exit 0 clean, 1 warnings, 2 problems, so
# `pingify --check NAME` is usable from cron; the old one ended in `pause`.

health_check() {
    local name=$1 mode=${2:-}
    local core_ver out st since addr fl live_mtu lpm
    local spec proto lo hi rhost rport total missing unknown

    chk_reset
    if ! chk_load "$name"; then
        chk_add bad config "there is no tunnel called $name" \
            "run pingify with no arguments to see the list"
        chk_finish "$name" "$mode"
        return 2
    fi

    # 1. the core itself. Everything below is a question about what the core is
    # doing, so a missing core makes the rest unanswerable rather than failed.
    if [ ! -x "$CORE_BIN" ]; then
        chk_add bad core "the core is not installed at $CORE_BIN" \
            "choose Update in pingify to build or fetch it"
        chk_add note core-rest "nothing below could be checked without it"
        chk_finish "$name" "$mode"
        return 2
    fi
    if core_ver=$("$CORE_BIN" -version 2>&1); then
        core_ver=${core_ver%%$'\n'*}
        core_ver=${core_ver##* }
        if [ "$core_ver" = "$PINGIFY_VERSION" ]; then
            chk_add ok core "core $core_ver, matching this script"
        else
            chk_add warn core "core $core_ver, this script is $PINGIFY_VERSION" \
                "an older core can lack a setting this writes" \
                "update both:  pingify --update"
        fi
    else
        chk_add bad core "$CORE_BIN will not run" \
            "it may be built for another architecture" \
            "reinstall it:  pingify --update"
    fi

    # 2. the config, judged by the only judge that counts. The core's refusal
    # is one long sentence, so it goes through the UI's own cut rather than
    # over the right-hand edge of a phone terminal.
    if out=$("$CORE_BIN" -c "$CK_FILE" -check 2>&1); then
        chk_add ok config "the core accepts $CK_FILE"
    else
        chk_add bad config \
            "the core refuses it: $(trunc_to "${out%%$'\n'*}" $((UI_W - 26)))" \
            "edit $CK_FILE" \
            "the same change is needed on both servers"
    fi

    # 3. systemd. svc_state tells stopped (enabled, not running) from disabled
    # (not even wanted), and the two need different advice.
    st=$(svc_state "$name")
    case $st in
    active)
        since=$(systemctl show -p ActiveEnterTimestamp --value \
            "pingify@$name" 2>/dev/null)
        chk_add ok service "running since ${since:-a moment ago}"
        ;;
    stopped)
        chk_add bad service "the service is enabled but not running" \
            "systemctl start pingify@$name" \
            "read why:  journalctl -u pingify@$name -n 30"
        ;;
    *)
        chk_add bad service "the service is neither running nor enabled" \
            "systemctl enable --now pingify@$name"
        ;;
    esac

    # 4. the private link. operstate on a tun device reads "unknown" even when
    # it is carrying perfectly - the driver has no carrier to report - so the
    # flags word is the thing to look at. Bit 0 of it is IFF_UP.
    if [ ! -d "/sys/class/net/$CK_DEV" ]; then
        chk_add bad link "the private link $CK_DEV does not exist" \
            "the core makes it at start, so it never started" \
            "journalctl -u pingify@$name -n 30"
    else
        fl=$(cat "/sys/class/net/$CK_DEV/flags" 2>/dev/null)
        addr=$(ip -4 -o addr show dev "$CK_DEV" 2>/dev/null | awk '{print $4; exit}')
        live_mtu=$(cat "/sys/class/net/$CK_DEV/mtu" 2>/dev/null)
        if [ $((${fl:-0} & 1)) -ne 1 ]; then
            chk_add bad link "$CK_DEV exists but is down" \
                "restart it:  systemctl restart pingify@$name"
        elif [ -z "$addr" ]; then
            chk_add bad link "$CK_DEV is up but has no address" \
                "restart it:  systemctl restart pingify@$name"
        elif [ "$addr" != "$CK_MINE" ]; then
            chk_add bad link "$CK_DEV carries $addr, not $CK_MINE" \
                "something else set it; restart the tunnel"
        else
            chk_add ok link "link $CK_DEV is up, $addr, mtu ${live_mtu:-?}"
        fi
        if [ -n "$live_mtu" ] && [ "$live_mtu" != "$CK_MTU" ]; then
            chk_add warn mtu "device mtu $live_mtu, the config says $CK_MTU" \
                "a hand-set mtu is lost on the next restart" \
                "put the number in the config instead"
        fi
    fi

    # 5. has the far end ever been heard from. Nothing else stands in for it:
    # the link can be up, the config right and the service running with no
    # packet from over there having ever arrived.
    if tun_stats "$name"; then
        case $ST_UP in
        true | 1 | yes)
            chk_add ok peer "the far end is there, up for $(human_secs "$ST_UPTIME")"
            ;;
        *)
            if [ "$CK_TRANSPORT" = icmp ]; then
                chk_add bad peer "the far end has never been seen" \
                    "on KHAREJ:  systemctl status pingify@$name" \
                    "watch there:  tcpdump -ni any icmp" \
                    "if nothing arrives at all, use udp instead"
            else
                chk_add bad peer "the far end has never been seen" \
                    "on KHAREJ:  systemctl status pingify@$name" \
                    "open it there:  ufw allow $CK_PORT/udp" \
                    "from here:  nc -uzv $CK_KHAREJ $CK_PORT" \
                    "a token edited on one side only does this"
            fi
            ;;
        esac
    else
        if have curl; then
            chk_add bad status \
                "no answer on 127.0.0.1:$(status_port "$name")" \
                "systemctl status pingify@$name" \
                "status.port 0 in the config turns it off"
        else
            # Not knowing is a warning, not a note: a note is something that is
            # fine, and a tunnel nobody can question is not fine.
            chk_add warn status "curl is missing, so nothing could ask it" \
                "install curl:  apt-get install -y curl"
        fi
    fi

    # 6. loss, as a rate. There is no denominator in the report - the core
    # counts what it missed, not what it should have had - so this is losses
    # per minute since it started, and it is not called a percentage.
    if [ "$ST_UP" = true ] && [ -n "$ST_UPTIME" ]; then
        lpm=$(awk -v l="${ST_LOST:-0}" -v s="$ST_UPTIME" \
            'BEGIN { if (s + 0 < 30) print "early"; else printf "%.1f", l * 60 / s }')
        case $lpm in
        early)
            chk_add note loss "too early to say anything about loss yet"
            ;;
        *)
            if [ "${lpm%%.*}" -ge 60 ]; then
                chk_add bad loss "the path is losing $lpm packets a minute" \
                    "run Measure MTU; a large mtu loses big packets" \
                    "if the mtu is right, the path is congested"
            elif [ "${lpm%%.*}" -ge 5 ]; then
                chk_add warn loss "the path is losing $lpm packets a minute" \
                    "run Measure MTU: a slightly large mtu does this"
            else
                chk_add ok loss "loss is $lpm a minute, ${ST_LATE:-0} arrived late"
            fi
            ;;
        esac
    fi

    # 7. the forwarded ports, and whether anything is behind them. IRAN only:
    # KHAREJ forwards nothing, because nobody connects to it.
    if [ "$CK_SIDE" = iran ]; then
        spec=$(chk_forward_spec "$name") || spec=
        if [ -z "$spec" ]; then
            chk_add note ports "no ports are forwarded from this server"
        elif ! declare -F forward_specs >/dev/null 2>&1; then
            chk_add note ports "ports unchecked: forwarding is not loaded"
        else
            total=0 missing=0 unknown=0
            while read -r proto lo hi rhost rport; do
                [ -n "$proto" ] || continue
                total=$((total + 1))
                if [ "$proto" != tcp ]; then
                    # There is no way to ask a udp port whether anybody is
                    # behind it. "Closed" would be a guess dressed up as a
                    # measurement, and this screen does not do that.
                    unknown=$((unknown + 1))
                    continue
                fi
                if ! tcp_reach "$rhost" "$rport"; then
                    missing=$((missing + 1))
                    chk_add warn "port-$lo" \
                        "$lo/tcp goes to $rhost:$rport, nothing there" \
                        "on KHAREJ, listen on $rhost:$rport" \
                        "from here:  nc -zv $rhost $rport"
                fi
            done < <(forward_specs "$spec" 2>/dev/null)
            if [ "$total" = 0 ]; then
                chk_add warn ports "the forwarded port list parsed to nothing" \
                    "open Ports on the tunnel screen and set them again"
            elif [ "$missing" = 0 ]; then
                chk_add ok ports \
                    "$total forwarded port$(plural_s "$total"), each one answers"
            fi
            [ "$unknown" -gt 0 ] &&
                chk_add note ports-udp "$unknown are udp and cannot be tested here"
        fi
    fi

    # The ICMP note, last, because it explains an absence rather than reporting
    # one. Grey, uncounted, and one line. This line is why the health check has
    # the shape it does.
    if [ "$CK_TRANSPORT" = icmp ]; then
        chk_add note icmp "ping does not answer across an ICMP tunnel: by design"
    fi

    chk_finish "$name" "$mode"
    [ "$CHK_NBAD" -gt 0 ] && return 2
    [ "$CHK_NWARN" -gt 0 ] && return 1
    return 0
}

# chk_finish picks the renderer. One place, so an early return in health_check
# cannot forget the --json case and print a screen at a caller that wanted
# something a machine could read.
chk_finish() {
    if [ "$2" = --json ]; then
        chk_json "$1"
    else
        chk_render "$1"
    fi
}

# --------------------------------------------------------------------------
# the live view
# --------------------------------------------------------------------------
#
# A fixed block repainted in place about once a second. It moves the cursor up
# with \033[<n>A and erases each line as it rewrites it, and never clears the
# screen: over a link with 100 ms of delay and real loss, the scrollback above
# is where you look when the connection stutters.
#
# The cursor is hidden on entry and put back by a trap on EXIT and INT. The old
# spinner hid it and had no trap, so one Ctrl-C left the cursor invisible for
# the rest of the ssh session. This is the only EXIT trap in the script; if
# another is ever added, this one has to save and restore it.

LIVE_STOP=0

live_cursor_on() { printf '\033[?25h'; }

# spark_bar is one column of the round-trip history. A reply that never came is
# drawn as the failure glyph, not as a low bar: a low bar is the same shape as
# a fast reply and would read as good news.
spark_bar() {
    local ms=$1 bars i
    case $ms in
    '' | *[!0-9.]*) printf '%s' "$G_BAD"; return ;;
    esac
    if [ "$UI_GLYPH" = utf8 ]; then bars='▁▂▃▄▅▆▇█'; else bars='._-=+*#@'; fi
    ms=${ms%%.*}
    if [ "$ms" -lt 60 ]; then i=0
    elif [ "$ms" -lt 80 ]; then i=1
    elif [ "$ms" -lt 100 ]; then i=2
    elif [ "$ms" -lt 130 ]; then i=3
    elif [ "$ms" -lt 170 ]; then i=4
    elif [ "$ms" -lt 220 ]; then i=5
    elif [ "$ms" -lt 300 ]; then i=6
    else i=7; fi
    printf '%s' "${bars:i:1}"
}

screen_live() {
    local name=$1
    local -a lines
    local painted=0 spark= rtt= key rxp txp last_rx= last_tx= din dout w

    chk_load "$name" || { bad "there is no tunnel called $name"; return 1; }

    blank
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        # Nothing to repaint into and nobody to press a key. One frame, plain,
        # so a script or a test gets an answer instead of a spin.
        live_frame "$name" '' ''
        return 0
    fi

    w=$((UI_W - 34))
    [ "$w" -lt 10 ] && w=10

    LIVE_STOP=0
    trap 'LIVE_STOP=1' INT
    trap 'live_cursor_on' EXIT
    printf '\033[?25l'

    while :; do
        rxp=$(cat "/sys/class/net/$CK_DEV/statistics/rx_packets" 2>/dev/null)
        txp=$(cat "/sys/class/net/$CK_DEV/statistics/tx_packets" 2>/dev/null)
        din= dout=
        if [ -n "$last_rx" ] && [ -n "$rxp" ]; then
            din=$((rxp - last_rx))
            dout=$((txp - last_tx))
        fi
        last_rx=$rxp last_tx=$txp

        # One ping per frame, bound to the tun. On an ICMP tunnel there is
        # nothing to ping, so that row becomes the grey explanation and the
        # block keeps its height. The ping and the status read add about a
        # tenth of a second, so a frame is about a second, not exactly.
        rtt=
        if [ "$CK_TRANSPORT" != icmp ]; then
            rtt=$(link_rtt "$CK_DEV" "$CK_PEER") || rtt=
            spark=$spark$(spark_bar "$rtt")
            # Trim only once it is over the width. ${spark: -w} on a string
            # shorter than w returns nothing at all, so trimming on every frame
            # left the sparkline empty until it had run for w seconds.
            [ "${#spark}" -gt "$w" ] && spark=${spark: -w}
        fi

        lines=()
        while IFS= read -r key; do lines+=("$key"); done < <(
            live_frame "$name" "$spark" "$rtt" "$din" "$dout"
        )

        [ "$painted" -gt 0 ] && printf '\033[%dA' "$painted"
        for key in "${lines[@]}"; do printf '\r\033[K%s\n' "$key"; done
        painted=${#lines[@]}

        [ "$LIVE_STOP" = 1 ] && break
        # read returns non-zero for both a timeout and a keystroke, so the
        # variable is what tells them apart: only a keystroke sets it.
        key=
        read -rsn1 -t 1 key
        [ -n "$key" ] && break
        [ "$LIVE_STOP" = 1 ] && break
    done

    trap - INT
    trap - EXIT
    live_cursor_on
    blank
    return 0
}

# live_frame prints the block once, from the CK_* screen_live loaded. Separate,
# so the non-interactive path and the loop draw the same thing and the height
# of the block is a property of one function rather than of the loop.
live_frame() {
    local name=$1 spark=$2 rtt=$3 din=${4:-} dout=${5:-} state=unknown
    local carrying losses packets

    if tun_stats "$name"; then
        [ "$ST_UP" = true ] && state=running || state=idle
    else
        [ "$(svc_state "$name")" = active ] && state=idle || state=stopped
    fi

    carrying="$(round1 "$ST_IN") Mbit/s in, $(round1 "$ST_OUT") out"
    losses="${ST_LOST:-0} lost, ${ST_LATE:-0} late, ${ST_GAPS:-0}"
    losses="$losses gap$(plural_s "${ST_GAPS:-0}")"
    if [ -n "$din" ]; then
        packets="$din in, $dout out in the last second"
    else
        packets="counting"
    fi

    rule "$name  $(state_dot "$state")"
    field "Carrying" "$carrying"
    if [ "$CK_TRANSPORT" = icmp ]; then
        field "Round trip" "$(printf '%snot measurable while ICMP runs%s' \
            "$C_MUTE" "$C_OFF")"
    else
        field "Round trip" "$(printf '%s%s ms%s  %s' "$(rtt_colour "$rtt")" \
            "${rtt:-?}" "$C_OFF" "$spark")"
    fi
    field "Losses" "$losses"
    field "Packets" "$packets"
    field "Uptime" "$(human_secs "$ST_UPTIME")"
    dim "any key to leave"
}

# --------------------------------------------------------------------------
# measuring the mtu
# --------------------------------------------------------------------------
#
# A binary search for the largest packet that crosses the private link intact.
# `ping -M do` sets don't-fragment, so a packet too big for the carrier path is
# dropped rather than quietly cut in half and the search finds the boundary.
# The device's own mtu is the ceiling - the kernel will not send a bigger
# don't-fragment packet - so this measures whether the configured mtu is
# honest, and when it is not, what is.

MTU_WANT=

mtu_editor() { toml_set "$1" tun mtu "$MTU_WANT"; }

# One probe. -s is the payload, so the packet on the wire is 28 bytes larger:
# 20 of IP and 8 of ICMP. Getting that 28 wrong is the classic way to set an
# mtu a little too big and then lose exactly the full-size packets.
mtu_probe() {
    local dev=$1 peer=$2 total=$3
    ping -n -c1 -W2 -M do -s $((total - 28)) -I "$dev" "$peer" >/dev/null 2>&1
}

measure_mtu() {
    local name=$1 lo hi mid best=0 tries=0

    chk_load "$name" || { bad "there is no tunnel called $name"; return 1; }
    blank
    rule "Measure MTU for $name"
    blank

    if [ "$CK_TRANSPORT" = icmp ]; then
        dim "This cannot be measured on an ICMP tunnel. The core"
        dim "stops both kernels answering echo while one runs, so"
        dim "a probe is answered by nobody, every size looks too"
        dim "big, and the search sets the floor on no evidence."
        blank
        say "  Use a number instead of a measurement:"
        # Short enough to survive field's cut at UI_W-20 on a 60-column
        # terminal: a truncated explanation explains nothing.
        field "1320" "the default, and right on a 1500 path"
        field "1280" "survives PPPoE, mobile, double tunnels"
        blank
        if [ "$CK_MTU" != 1280 ] && confirm "set the mtu to 1280?" n; then
            MTU_WANT=1280
            cfg_apply "$name" mtu_editor restart &&
                ok "mtu 1280 - set the same number on KHAREJ"
        fi
        return 0
    fi

    if [ ! -d "/sys/class/net/$CK_DEV" ]; then
        bad "$CK_DEV does not exist, so there is nothing to measure"
        fix "start the tunnel:  systemctl start pingify@$name"
        return 1
    fi

    dim "Probing $CK_PEER over $CK_DEV, don't-fragment set."
    dim "One ping per size, so this takes a few seconds."
    blank

    lo=576 hi=$CK_MTU
    while [ "$lo" -le "$hi" ]; do
        mid=$(((lo + hi) / 2))
        tries=$((tries + 1))
        if mtu_probe "$CK_DEV" "$CK_PEER" "$mid"; then
            dim "$(printf '%5s  crosses' "$mid")"
            best=$mid
            lo=$((mid + 1))
        else
            dim "$(printf '%5s  does not' "$mid")"
            hi=$((mid - 1))
        fi
    done
    blank

    if [ "$best" = 0 ]; then
        # Nothing crossed, not even the smallest legal packet. That is a dead
        # link or a firewall eating echo, and lowering the mtu on this evidence
        # would be exactly the wrong move: it would hide a real fault behind a
        # setting nobody would think to put back.
        bad "nothing crossed at any size: not an mtu problem"
        fix "check the tunnel first:  pingify --check $name"
        fix "echo may be blocked; the mtu was left alone"
        return 2
    fi

    if [ "$best" -ge "$CK_MTU" ]; then
        ok "$CK_MTU crosses intact, in $tries probes"
        dim "The device mtu is the ceiling, so more may work."
        return 0
    fi

    warn "the largest that crosses is $best, config says $CK_MTU"
    fix "the difference is lost as whole packets"
    blank
    if confirm "set the mtu to $best?" y; then
        MTU_WANT=$best
        if cfg_apply "$name" mtu_editor restart; then
            ok "mtu $best"
            dim "Set the same on KHAREJ: the file is shared."
        fi
    fi
    return 1
}

# --------------------------------------------------------------------------
# the speed test
# --------------------------------------------------------------------------
#
# Honest, or nothing. Only one thing is reachable across a private /24 without
# cooperation from the far server - the far kernel's echo reply - and that is
# rate limited to about a thousand a second, so a figure built from it would be
# net.ipv4.icmp_msgs_per_sec reported as the link's throughput. The old
# bench_menu had the same shape of fault: it curl'd a third-party script that
# measured the machine's own path to the internet and printed the answer as if
# it were the tunnel.
#
# A real test needs a listener at the other end. Ask for one, use it, and when
# there is not one say so, and show what the link is actually carrying instead
# of inventing a number.

speed_test() {
    local name=$1 out rc ref

    chk_load "$name" || { bad "there is no tunnel called $name"; return 1; }
    blank
    rule "Speed test for $name"
    blank

    if [ "$(svc_state "$name")" != active ]; then
        bad "the tunnel is not running: nothing to push"
        fix "systemctl start pingify@$name"
        return 1
    fi
    if tun_stats "$name" && [ "$ST_UP" != true ]; then
        bad "the far end has not been seen; nothing is there"
        fix "check it first:  pingify --check $name"
        return 1
    fi

    say "  What the link is carrying right now:"
    field "in" "$(round1 "$ST_IN") Mbit/s"
    field "out" "$(round1 "$ST_OUT") Mbit/s"
    blank

    if ! have iperf3; then
        warn "iperf3 is missing, and it is the honest way"
        fix "apt-get install -y iperf3"
        fix "dnf install -y iperf3 on Rocky or Alma"
        blank
        dim "Nothing else on the far server can be pushed into,"
        dim "and a figure built from pings would measure the far"
        dim "kernel's echo rate limit, not this link."
        return 1
    fi

    dim "This needs a listener there. On KHAREJ, run:"
    say "       iperf3 -s"
    blank
    confirm "is it running there?" y || {
        dim "Nothing measured."
        return 1
    }

    # Sixteen streams and six seconds, so the answer is directly comparable
    # with the table the profiles come from: gaming 397 Mbit/s over 16 streams,
    # balanced 448, download 466. A four-stream figure would be smaller for
    # reasons that have nothing to do with this link.
    blank
    dim "16 streams for six seconds, matching the numbers"
    dim "the profiles were measured at."
    blank
    out=$(iperf3 -c "$CK_PEER" -t 6 -P 16 2>&1)
    rc=$?
    printf '%s\n' "$out" | sed 's/^/       /'
    blank

    if [ "$rc" -ne 0 ]; then
        bad "iperf3 did not finish"
        case $out in
        *"onnection refused"*)
            fix "nothing on $CK_PEER:5201 - run iperf3 -s there"
            ;;
        *"o route to host"* | *"imed out"*)
            fix "the link is up but nothing crosses it"
            fix "pingify --check $name"
            ;;
        *)
            fix "read the message above, then:"
            fix "pingify --check $name"
            ;;
        esac
        return 1
    fi

    case ${ST_PROFILE:-$(toml_get "$CK_FILE" tuning profile)} in
    gaming) ref="gaming measured 397 Mbit/s over 16 streams" ;;
    download) ref="download measured 466 Mbit/s over 16 streams" ;;
    *) ref="balanced measured 448 Mbit/s over 16 streams" ;;
    esac
    ok "done"
    dim "$ref on the reference path."
    dim "A slower path abroad reads lower; that is the path."
    return 0
}
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

    cat >"$HOST_SYSCTL" <<SYSCTL
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
        cat >>"$HOST_SYSCTL" <<'SYSCTL'

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
    cat >"$HOST_LIMITS" <<'LIMITS'
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

host_tuning_screen() {
    local key p n bbr cc qd
    while :; do
        blank
        rule "Host tuning"
        dim "the kernel's own settings. The tunnel's queue profile is a different"
        dim "thing with the same three names, and it lives on the tunnel screen."
        blank
        p=$(host_profile)
        bbr=$(host_bbr_state)
        # Read back from the kernel, not from the file we wrote. A drop-in that
        # says bbr and a kernel running cubic is exactly the state worth seeing,
        # and the file alone cannot show it.
        cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
        qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
        field "Profile" "${p:-not applied}"
        field "BBR" "$bbr, and the kernel is running ${cc:-unknown} over ${qd:-unknown}"
        field "Open files" "$(ulimit -n) here, $([ -f "$HOST_LIMITS" ] && printf '1048576 at next login' || printf 'unchanged at login')"
        field "Drop-in" "$HOST_SYSCTL"
        blank
        item2 "1" "Profile" "${p:-none}"
        item2 "2" "BBR" "$bbr"
        item2 "3" "Raise descriptor limits" "$([ -f "$HOST_LIMITS" ] && printf 'done' || printf 'not done')"
        item "4" "Revert everything this screen did"
        item "0" "Back"
        blank
        menu_key key || return 0
        case $key in
        1)
            blank
            group "WHAT THIS MACHINE MOSTLY CARRIES"
            item "1" "Gaming     small queues, so a small packet waits behind less"
            item "2" "Balanced   the one to pick if the answer is 'everything'"
            item "3" "Download   deep queues and long drain cycles, for bulk"
            blank
            pick n "select" 2 3 || continue
            case $n in
            1) p=gaming ;;
            3) p=download ;;
            *) p=balanced ;;
            esac
            blank
            host_write_sysctl "$p" "$(host_bbr_state)" && ok "$p host tuning applied"
            ;;
        2)
            blank
            if [ "$(host_bbr_state)" = on ]; then
                host_write_sysctl "${p:-balanced}" off &&
                    ok "back to $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
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
block_ipt() { iptables "$@" 2>/dev/null; }

block_state() { [ -f "$STATE_DIR/block-$1" ] && printf 'on' || printf 'off'; }

block_summary() {
    local out= w
    for w in icmp quic speedtest; do
        [ "$(block_state "$w")" = on ] && out="$out$w "
    done
    [ -n "$out" ] && printf '%s' "${out% }" || printf 'none'
}

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
    local c i
    # -D removes one match. An older script that inserted its hook twice leaves
    # the second behind, still sending every packet through a chain nothing
    # maintains, so take them off in a bounded loop rather than once.
    for i in 1 2 3 4 5; do block_ipt -D INPUT -j PINGIFY_IN || break; done
    for i in 1 2 3 4 5; do block_ipt -D OUTPUT -j PINGIFY_OUT || break; done
    for c in PINGIFY_IN PINGIFY_OUT; do
        block_ipt -F "$c"
        block_ipt -X "$c"
    done
    return 0
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
    local quiet=${1:-} ifc h any
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
            block_ipt -A PINGIFY_IN -i "$ifc" -p icmp --icmp-type echo-request -j ACCEPT
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
            block_ipt -A PINGIFY_IN -p icmp --icmp-type echo-request -j DROP
        fi
    fi

    if [ "$(block_state quic)" = on ]; then
        # Rejected on the way out, not dropped: a browser that gets a port
        # unreachable falls back to TCP now, and one that gets silence waits
        # for a timeout first, which is felt as the page hanging.
        block_ipt -A PINGIFY_OUT -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable
        block_ipt -A PINGIFY_IN -p udp --dport 443 -j DROP
    fi

    if [ "$(block_state speedtest)" = on ]; then
        hosts_block_on
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

    firewall_unit_write
    [ "$quiet" = quiet ] || ok "blocking rules rebuilt from the state files"
    return 0
}

# iptables forgets everything at reboot, so one oneshot unit replays the state
# files. It calls back into this same script, which means there is one apply
# path and the boot path cannot drift from the interactive one.
firewall_unit_write() {
    cat >"$UNIT_DIR/pingify-firewall.service" <<UNIT
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

remove_blocking() {
    rm -f "$STATE_DIR"/block-icmp "$STATE_DIR"/block-quic "$STATE_DIR"/block-speedtest
    hosts_block_off
    have iptables && block_drop_chains
    systemctl disable --now pingify-firewall.service >/dev/null 2>&1 || true
    rm -f "$UNIT_DIR/pingify-firewall.service"
    systemctl daemon-reload >/dev/null 2>&1 || true
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

blocking_screen() {
    local key
    while :; do
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
                rule "PINGIFY_IN"
                iptables -S PINGIFY_IN 2>/dev/null | grep -v '^-N ' | sed 's/^/    /'
                rule "PINGIFY_OUT"
                iptables -S PINGIFY_OUT 2>/dev/null | grep -v '^-N ' | sed 's/^/    /'
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
#
# The front door: getting the manager onto the machine, working out what the
# command line asked for, and the one screen everything else hangs off. It is
# last so that everything it dispatches to is already defined when the guard
# at the bottom calls main.
#
# Two rules shape it. A non-interactive flag must work with no terminal at all
# - a monitoring script calling --status has no stdin and no tty - so nothing
# on that path asks a question or draws a menu. And there is one renderer for
# a tunnel's line: home draws it with a key beside it, --status draws it
# without one, and they are the same function, because two renderers of the
# same five numbers drift apart and then disagree in front of the user.

# --------------------------------------------------------------------------
# putting the manager where the pingify command can find it
# --------------------------------------------------------------------------

# install_self copies this script over /usr/local/bin/pingify when the copy
# sitting there is not this one. It runs on every interactive launch, and it
# has to, because "update" for most people means re-running the install line
# from the README: that leaves a fresh script in the current directory and a
# fresh core in /usr/local/bin, with the *old* manager still on PATH beside
# it - the one combination the two of them are not built to work in.
#
# The new copy is renamed into place rather than written over the destination.
# bash reads a script as it runs, a few kilobytes at a time, so truncating the
# file it is still reading turns the rest of the run into whatever lands at
# that offset. A rename leaves the running copy's inode alone.
install_self() {
    local src=${BASH_SOURCE[0]} dir tmp stamp
    if [ ! -f "$src" ]; then
        # Started from a process substitution - bash <(curl ...) - so there is
        # no file on disk to copy from. Nothing is broken; say what is missing.
        warn "the pingify command was not installed - this script has no file on disk"
        fix "save it first:  curl -fsSLo pingify <url> && bash pingify"
        return 1
    fi

    if ! cmp -s "$src" "$PINGIFY_BIN"; then
        dir=${PINGIFY_BIN%/*}
        tmp=$(mktemp "$dir/.pingify.XXXXXX") || return 1
        if ! { cat "$src" >"$tmp" && chmod 0755 "$tmp" && mv -f "$tmp" "$PINGIFY_BIN"; }; then
            rm -f "$tmp"
            warn "could not write $PINGIFY_BIN"
            return 1
        fi
    fi

    # The unit is a template. It changes with the script and never with a
    # tunnel, so it is written here, once, and on a version change - which is
    # what stops it being rewritten four times whenever somebody adds a fifth
    # tunnel.
    stamp=$STATE_DIR/script.version
    if [ "$(cat "$stamp" 2>/dev/null)" != "$PINGIFY_VERSION" ]; then
        unit_write
        printf '%s\n' "$PINGIFY_VERSION" >"$stamp"
    fi
    return 0
}

# --------------------------------------------------------------------------
# home
# --------------------------------------------------------------------------

# The keys tunnels are given, in order. The fixed actions own n p h u x q and
# 0, so none of those appear here: a key that means "Uninstall" on a server
# with four tunnels and "the fifth tunnel" on a server with five is how
# somebody uninstalls from muscle memory.
HOME_KEYS='123456789abcdefgijklmorstvwyz'
HOME_NAMES=()

# The line under the name: which core, which side of the border this server is
# on, and how long the machine has been up. The side is here rather than in
# every row because one server is one side - the config's `side` line is the
# only thing that differs between the two ends, and it is the same in all of
# this server's configs.
home_subtitle() {
    local core=$G_DASH side= up= rest= first=
    [ -x "$CORE_BIN" ] && core=$(core_version)

    while IFS= read -r first; do break; done < <(cfg_list)
    [ -n "$first" ] && side=$(toml_get "$(cfg_file "$first")" tunnel side)
    case $side in
    iran) side=IRAN ;;
    kharej) side=KHAREJ ;;
    *) side="no tunnel yet" ;;
    esac

    read -r up rest </proc/uptime 2>/dev/null || up=
    printf 'core %s  %s  %s  %s  up %s' \
        "$core" "$G_V" "$side" "$G_V" "$(human_secs "${up%%.*}")"
}

# home_row is one tunnel, and it is also the menu item for that tunnel. The
# old manager printed a status table and then a second numbered list of the
# same names under it, so every name was on the screen twice and the numbers
# on the second list matched nothing on the first.
#
# The round trip is measured only for a tunnel that is running: probing a
# stopped one costs three seconds of ping timeout for an answer already known.
home_row() {
    local name=$1 key=$2 st=stopped dot=stopped rtt=$G_DASH rate= transport=
    st=$(svc_state "$name")
    transport=$(toml_get "$(cfg_file "$name")" transport type)
    [ -n "$transport" ] || transport=udp
    rate=$st

    case $st in
    active)
        dot=idle
        if tun_stats "$name"; then
            [ "$ST_UP" = true ] && dot=running
            [ -n "$ST_TRANSPORT" ] && transport=$ST_TRANSPORT
            rate="$(round1 "$ST_IN")/$(round1 "$ST_OUT") Mbit/s"
        else
            rate="no answer"
        fi
        rtt=$(tun_rtt "$name")
        # Grey, never red. An ICMP tunnel cannot be pinged across - both
        # kernels have stopped answering echo, deliberately - so "no number"
        # here means "not measurable", not "slow".
        case $rtt in
        '' | *[!0-9.]*) rtt=$G_DASH ;;
        *) rtt="$(rtt_colour "$rtt")$rtt ms$C_OFF" ;;
        esac
        ;;
    disabled) dot=unknown ;;
    esac

    row " $key $(state_dot "$dot")" "$name" "${transport^^}" "$rtt" "$rate"
}

# The widths the tunnel list is drawn at, in one place, because home and
# --status both draw it. The old script kept four magic numbers in the header
# and four more in the row and they had already drifted apart.
#
# Everything but the name is a known width - "412.3/38.1 Mbit/s" is the widest
# thing the last column ever holds - so the name takes the slack, up to the 24
# characters v_name allows and no further. A wide window should not stretch one
# column across half the screen.
home_cols() {
    local nw=$((UI_W - 46))
    [ "$nw" -gt 26 ] && nw=26
    [ "$nw" -lt 8 ] && nw=8
    UI_COLS=(4 "$nw" 6 8 17)
}

screen_home() {
    local n i=0 key
    HOME_NAMES=()
    while IFS= read -r n; do HOME_NAMES+=("$n"); done < <(cfg_list)

    banner "$(home_subtitle)"
    blank
    group "TUNNELS"
    if [ "${#HOME_NAMES[@]}" -eq 0 ]; then
        blank
        dim "no tunnels on this server yet."
        dim "press n to build one, or to paste the line the other server gave you."
    else
        home_cols
        while [ "$i" -lt "${#HOME_NAMES[@]}" ]; do
            key=${HOME_KEYS:i:1}
            home_row "${HOME_NAMES[i]}" "$key"
            i=$((i + 1))
        done
    fi
    blank
    item "n" "New tunnel"
    blank
    group "HOST"
    item "p" "Ports and firewall"
    item2 "h" "Host tuning" "$(host_summary)"
    blank
    group "MAINTENANCE"
    item "u" "Update"
    item "x" "Uninstall"
    item "0" "Exit"
    blank
}

# home_pick turns a keystroke back into the tunnel it was drawn beside.
home_pick() {
    local k=$1 i=0
    while [ "$i" -lt "${#HOME_NAMES[@]}" ]; do
        [ "${HOME_KEYS:i:1}" = "$k" ] && { printf '%s' "${HOME_NAMES[i]}"; return 0; }
        i=$((i + 1))
    done
    return 1
}

main_menu() {
    local c name
    while :; do
        screen_home
        menu_key c || return 0
        case $c in
        n) screen_new ;;
        p) screen_firewall ;;
        h) screen_host ;;
        u) update_pingify ;;
        x) uninstall_all && exit 0 ;;
        0 | q | Q) blank; return 0 ;;
        '') ;;
        *)
            if name=$(home_pick "$c"); then
                screen_tunnel "$name"
            else
                blank
                warn "there is nothing on $c"
            fi
            ;;
        esac
    done
}

# --------------------------------------------------------------------------
# what the command line asked for
# --------------------------------------------------------------------------

usage() {
    cat <<USAGE

  Pingify $PINGIFY_VERSION - a tunnel between a server in Iran and one abroad

    pingify                    the menu
    pingify --new              straight to building a tunnel
    pingify --status [NAME]    one line per tunnel, or one named tunnel
    pingify --check NAME       health check; exits 0 clean, 1 warnings, 2 problems
    pingify --json             with --status or --check, machine readable
    pingify --version          the version of this script, and of the core
    pingify --uninstall        take Pingify off this server
    pingify --help             this

  Configs   $CFG_DIR/<name>.toml - identical on both servers but for one line
  Core      $CORE_BIN

USAGE
}

# --status is what a monitoring script calls. It draws the same line home
# draws, with a blank where the menu key would be, and it exits non-zero if
# any tunnel it was asked about is not running.
cmd_status() {
    local n names=() rc=0
    if [ -n "$ARG_NAME" ]; then
        [ -f "$(cfg_file "$ARG_NAME")" ] || die "there is no tunnel called $ARG_NAME"
        names=("$ARG_NAME")
    else
        while IFS= read -r n; do names+=("$n"); done < <(cfg_list)
    fi
    [ "${#names[@]}" -gt 0 ] || { warn "no tunnels are configured"; return 1; }

    if [ -n "$ARG_JSON" ]; then
        for n in "${names[@]}"; do status_json "$n"; done
        return 0
    fi

    home_cols
    for n in "${names[@]}"; do
        home_row "$n" " "
        [ "$(svc_state "$n")" = active ] || rc=1
    done
    return "$rc"
}

# One object per tunnel, one per line, so `--status --json | while read` is a
# whole integration. The field names are the core's own; inventing a second
# vocabulary for the same numbers is how the two come to mean different things.
status_json() {
    local n=$1 st
    st=$(svc_state "$n")
    # A tunnel that does not answer is not up, and saying so is the report,
    # not a failure to make one.
    tun_stats "$n" || ST_UP=false
    printf '{"name":"%s","service":"%s","up":%s,"transport":"%s","profile":"%s"' \
        "$n" "$st" "${ST_UP:-false}" "$ST_TRANSPORT" "$ST_PROFILE"
    printf ',"side":"%s","in_mbit":%s,"out_mbit":%s,"lost":%s,"reordered":%s,"uptime_sec":%s}\n' \
        "$ST_SIDE" "${ST_IN:-0}" "${ST_OUT:-0}" "${ST_LOST:-0}" "${ST_LATE:-0}" "${ST_UPTIME:-0}"
}

argv() {
    ARG_MODE=menu ARG_NAME= ARG_JSON=
    while [ "$#" -gt 0 ]; do
        case $1 in
        --status)
            ARG_MODE=status
            # The name is optional, so only take the next word if it is one.
            case ${2:-} in '' | -*) ;; *) ARG_NAME=$2; shift ;; esac
            ;;
        --check)
            # A flag here is a missing name, not a name. `--check --json` used
            # to become a health check on a tunnel called "--json".
            ARG_MODE=check
            case ${2:-} in '' | -*) die "--check needs the name of a tunnel" ;; esac
            ARG_NAME=$2
            shift
            ;;
        --json) ARG_JSON=1 ;;
        --new) ARG_MODE=new ;;
        --uninstall) ARG_MODE=uninstall ;;
        --version | -v) ARG_MODE=version ;;
        --help | -h) ARG_MODE=help ;;
        *)
            usage >&2
            die "$1 is not an option this script has"
            ;;
        esac
        shift
    done
}

# --------------------------------------------------------------------------
# taking it all off again
# --------------------------------------------------------------------------

# uninstall_all prints the whole list before it touches any of it.
#
# The firewall goes first, and the order is not cosmetic: a DNAT rule pointing
# at a tun address that no longer exists does not error. It quietly swallows
# every connection to that port, and whatever is installed on that port next
# looks broken for a reason nothing on the machine explains.
uninstall_all() {
    local names=() n keep=yes unit
    while IFS= read -r n; do names+=("$n"); done < <(cfg_list)

    blank
    rule "Uninstall"
    field "manager" "$PINGIFY_BIN"
    field "core" "$CORE_BIN"
    field "units" "$UNIT_DIR/pingify@.service and every pingify-* unit"
    field "firewall" "the PINGIFY_* chains, flushed and removed"
    field "sources" "$SRC_DIR"
    field "state" "$STATE_DIR"
    [ "${#names[@]}" -gt 0 ] && field "tunnels" "${names[*]}"
    field "configs" "$CFG_DIR - kept, unless you say so below"
    blank
    confirm "remove all of that?" n || { dim "nothing was removed"; return 1; }
    confirm "delete the configs in $CFG_DIR as well?" n && keep=no
    blank

    for n in "${names[@]}"; do
        nat_drop "$n"
        svc_do stop "$n"
        svc_do disable "$n"
    done
    nat_clear
    block_clear

    for unit in "$UNIT_DIR"/pingify@.service "$UNIT_DIR"/pingify-*.service \
        "$UNIT_DIR"/pingify-*.timer; do
        [ -e "$unit" ] || continue
        systemctl disable --now "${unit##*/}" >/dev/null 2>&1
        rm -f "$unit"
    done
    systemctl daemon-reload >/dev/null 2>&1
    ok "services stopped and removed"

    rm -rf "$SRC_DIR" "$STATE_DIR"
    rm -f "$CORE_BIN"
    if [ "$keep" = no ]; then
        rm -rf "$CFG_DIR"
        ok "configs deleted"
    else
        ok "configs left in $CFG_DIR"
    fi
    rm -f "$PINGIFY_BIN"
    ok "Pingify is removed"

    # The ICMP carrier sets net.ipv4.icmp_echo_ignore_all=1 and nothing puts
    # it back, this included: the sysctl is the core's, and a tunnel still
    # running elsewhere on this box would start answering its own echoes and
    # double its own traffic. So the command is printed, not run.
    if [ "$(cat /proc/sys/net/ipv4/icmp_echo_ignore_all 2>/dev/null)" = 1 ]; then
        blank
        warn "this server is still not answering pings; an ICMP tunnel turned that on"
        fix "sysctl -w net.ipv4.icmp_echo_ignore_all=0"
    fi
    blank
    return 0
}

# --------------------------------------------------------------------------

main() {
    argv "$@"

    # Neither of these reads a config or writes anything, so neither needs to
    # be root, and --version is the first thing anybody runs when a pair does
    # not come up.
    case $ARG_MODE in
    help) usage; exit 0 ;;
    version)
        say "Pingify $PINGIFY_VERSION"
        [ -x "$CORE_BIN" ] && say "core $(core_version)"
        exit 0
        ;;
    esac

    require_root
    ensure_dirs

    # The exit status is the answer on these three, so it is passed straight
    # out rather than being replaced by whatever the last printf returned.
    case $ARG_MODE in
    status) cmd_status; exit $? ;;
    check) health_check "$ARG_NAME" "${ARG_JSON:+json}"; exit $? ;;
    uninstall) uninstall_all; exit $? ;;
    esac

    # Only the interactive paths reinstall the manager. A cron line calling
    # --status every minute has no business rewriting /usr/local/bin, and if
    # it did it would rewrite it from whatever stale copy that cron line
    # happens to point at.
    install_self

    # A missing core warns rather than exits: Uninstall and the host screens
    # still work without one, and a server that cannot reach GitHub and has no
    # Go toolchain is exactly the server whose operator needs to get at them.
    ensure_core || warn "there is no working core installed; Update can fetch or build one"

    case $ARG_MODE in
    new) screen_new ;;
    *) main_menu ;;
    esac
}

# build.sh and the tests source this file to get at its functions; that must
# not launch the menu.
[ -n "${PINGIFY_NO_MAIN:-}" ] || main "$@"
