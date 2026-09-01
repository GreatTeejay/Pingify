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

    # Two widths, and they are not the same measurement.
    #
    # The frames are drawn at 68 columns whatever the window is. A box pulled
    # across a two hundred column terminal is a box the eye cannot follow from
    # one edge to the other, and 68 is the width this tool has always had.
    #
    # The menu lines get the whole window. Their last column is a sentence
    # saying what the key does, and cutting that short on a wide screen buys
    # nothing - so they are allowed to run past the right edge of the frames
    # above them, which is exactly how they have always looked.
    UI_TERM=${PINGIFY_WIDTH:-$(tput cols 2>/dev/null || echo 80)}
    case "$UI_TERM" in '' | *[!0-9]*) UI_TERM=80 ;; esac
    [ "$UI_TERM" -gt 120 ] && UI_TERM=120
    [ "$UI_TERM" -lt 40 ] && UI_TERM=40
    UI_W=$UI_TERM
    [ "$UI_W" -gt 68 ] && UI_W=68

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
        G_ITEM='▸' G_DOT='·'
    else
        G_H='-' G_V='|' G_TL='+' G_TR='+' G_BL='+' G_BR='+'
        G_CUR='>' G_ON='*' G_OFF='o' G_OK='+' G_BAD='x' G_WARN='!'
        G_ARROW='->' G_BOTH='<->' G_CUT='~' G_DASH='-'
        G_ITEM='>' G_DOT='-'
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
# The same eleven the panels use, so a value on a plain screen stands in the
# same column as a value inside a box.
UI_KEYW=11
field() {
    printf '    %s%s%s  %s\n' \
        "$C_KEY" "$(pad_to "$1" "$UI_KEYW")" "$C_OFF" \
        "$(trunc_to "$2" $((UI_W - UI_KEYW - 8)))"
}

# item is one line of a menu: the number you type, what it does, and - where it
# needs one - the sentence saying what that means.
#
# The hint is its own argument rather than spaces inside the label. Five of
# these had the hint padded into the label by hand, and every one of them went
# crooked the moment somebody renamed the thing beside it; the width here is
# measured, once, from the label that is actually being drawn.
#
# Twenty-four columns for the label, and the key right aligned in two, so that
# the tenth item on a screen starts its label in the same column as the first.
# The hint is measured against the window rather than the frames, because it
# is the last thing on the line and has nothing to push out of place.
UI_ITEMW=24
item() {
    local w=$UI_ITEMW n hint=${3:-} hw
    n=$(vislen "$2")
    [ "$n" -ge "$w" ] && w=$((n + 2))
    hw=$((UI_TERM - w - 9))
    # A hint with four columns left for it is not a hint, it is a cut mark.
    # Below that the label takes the whole line and the note is dropped.
    if [ -n "$hint" ] && [ "$hw" -ge 6 ]; then
        printf '   %s%2s%s %s%s%s %s%s%s%s\n' \
            "$C_ACCENT$C_B" "$1" "$C_OFF" "$C_MUTE" "$G_ITEM" "$C_OFF" \
            "$(pad_to "$2" "$w")" "$C_MUTE" "$(trunc_to "$hint" "$hw")" "$C_OFF"
    else
        printf '   %s%2s%s %s%s%s %s\n' \
            "$C_ACCENT$C_B" "$1" "$C_OFF" "$C_MUTE" "$G_ITEM" "$C_OFF" \
            "$(trunc_to "$2" $((UI_TERM - 9)))"
    fi
}

# item2 was the same line with the current value of a setting on the right of
# it. It is the same call, so there is one renderer and the two cannot drift
# into two different looking menus.
item2() { item "$@"; }

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
panel_top() {
    printf '%s\n' "$(fill_to "  $C_RULE$G_TL" "$G_H" "$G_TR")"
}
panel_open() {
    printf '%s\n' "$(fill_to "  $C_RULE$G_TL$G_H$C_OFF $C_B$1$C_OFF " "$G_H" "$G_TR")"
}
panel_row() {
    local inner=$((UI_W - 6))
    printf '  %s%s%s %s %s%s%s\n' \
        "$C_RULE" "$G_V" "$C_OFF" "$(pad_to "$1" "$inner")" \
        "$C_RULE" "$G_V" "$C_OFF"
}
# Eleven, which is the longest key any panel in the script uses. A wider one
# only pushes every value further from the word it belongs to.
UI_PANELW=11
panel_field() {
    panel_row "$(printf '%s%s%s  %s' "$C_KEY" "$(pad_to "$1" "$UI_PANELW")" "$C_OFF" "$2")"
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

# The name, drawn large, in a frame it fills. It is the first thing on the
# screen and the only decoration in the whole script.
#
# Two renderings and no third. A terminal without a UTF-8 locale - PuTTY out
# of the box, a serial console, a phone client with the wrong setting - draws
# the block glyphs as a screen of question marks, so there is an ASCII one
# beside it, and a test refuses any byte above 127 in it.
banner_art() {
    if [ "$UI_GLYPH" = utf8 ]; then
        printf '%s\n' \
            '██████╗ ██╗███╗   ██╗ ██████╗ ██╗███████╗██╗   ██╗' \
            '██╔══██╗██║████╗  ██║██╔════╝ ██║██╔════╝╚██╗ ██╔╝' \
            '██████╔╝██║██╔██╗ ██║██║  ███╗██║█████╗   ╚████╔╝ ' \
            '██╔═══╝ ██║██║╚██╗██║██║   ██║██║██╔══╝    ╚██╔╝  ' \
            '██║     ██║██║ ╚████║╚██████╔╝██║██║        ██║   ' \
            '╚═╝     ╚═╝╚═╝  ╚═══╝ ╚═════╝ ╚═╝╚═╝        ╚═╝   '
    else
        printf '%s\n' \
            ' ____   ___  _   _   ____  ___  _____ __   __' \
            '|  _ \ |_ _|| \ | | / ___||_ _||  ___|\ \ / /' \
            '| |_) | | | |  \| || |  _  | | | |_    \ V / ' \
            '|  __/  | | | |\  || |_| | | | |  _|    | |  ' \
            '|_|    |___||_| \_| \____||___||_|      |_|  '
    fi
}

# banner_line centres one line inside the frame. Centring is done on the
# measured width rather than the character count, because the block glyphs and
# the escape codes around them are not the same thing as bytes.
banner_line() {
    local text=$1 colour=$2 inner=$((UI_W - 6)) pad
    pad=$(( (inner - $(vislen "$text")) / 2 ))
    [ "$pad" -lt 0 ] && pad=0
    panel_row "$(printf '%*s%s%s%s' "$pad" '' "$colour" "$text" "$C_OFF")"
}

banner() {
    local extra=${1:-} line
    blank
    panel_top
    while IFS= read -r line; do
        banner_line "$line" "$C_ACCENT$C_B"
    done < <(banner_art)
    banner_line "by Teejay   $G_DOT   Iran $G_ITEM Kharej tunnel" "$C_MUTE"
    [ -n "$extra" ] && banner_line "$extra" "$C_MUTE"
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

# menu_key reads the number a screen is waiting for.
#
# A line, and no longer a single keystroke. Every choice in this script is a
# number now, and a screen with more than ten things on it needs two digits -
# which a one-character read cannot take. It also means a pasted answer works,
# and that the answer arrives the same way when there is no terminal at all,
# which is how the tests drive these screens.
menu_key() {
    local _pk_var=$1 _pk_in
    printf '  %s%s%s select: ' "$C_ACCENT" "$G_ITEM" "$C_OFF" >&2
    IFS= read -r _pk_in || return 1
    # Whitespace around a pasted answer is not an answer of its own.
    _pk_in=${_pk_in#"${_pk_in%%[![:space:]]*}"}
    _pk_in=${_pk_in%"${_pk_in##*[![:space:]]}"}
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
