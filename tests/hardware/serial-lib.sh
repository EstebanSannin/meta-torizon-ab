#!/bin/sh
# serial-lib.sh -- minimal send/expect over a serial console, POSIX sh.
#
# Sourced by the hardware test harness (enable-access.sh, runtime-reset.sh). It
# drives a board's serial console the way we do by hand: a background `cat` of
# the tty appends to a log file, we `printf` into the tty to type, and we poll
# the log for expected output. Kept deliberately dependency-free (busybox on
# beerus is enough) since the docs note pexpect/pyserial are not reliably present.
#
# Meant to run ON the host wired to the board (beerus), where the tty exists.
#
# Config (environment):
#   SERIAL   serial device, REQUIRED (e.g. /dev/ttyUSB3 imx8mp, /dev/ttyUSB4 am62p)
#            NEVER open /dev/ttyUSB5 (sibling of the am62p bridge -- see the memory).
#   BAUD     baud rate                                  [115200]
#   SERLOG   capture file                               [/tmp/tzn-serial-<tty>.log]
#   SER_DEFAULT_TIMEOUT   default ser_expect timeout, s [30]
#   SER_VERBOSE           1 = echo sent/expected lines to stderr [1]
#   SER_ATTACH   1 = ATTACH to an already-running serial logger instead of
#                starting our own reader. REQUIRED on a bench where a persistent
#                `cat $SERIAL > logfile` is already capturing the port (two
#                readers on one tty split the bytes and corrupt BOTH captures).
#                In attach mode we only WRITE to the tty and TAIL the existing
#                logfile; SERLOG must point at that logfile.            [auto]
#   SERLOG       capture file to read (attach) or create (standalone).
#                                            [/tmp/tzn-serial-<tty>.log]
#
# Only one reader may hold a tty at a time. By default ser_open AUTO-DETECTS a
# running logger on the port and attaches to it (never killing it); it starts
# its own reader only when the port has none.

: "${BAUD:=115200}"
: "${SER_DEFAULT_TIMEOUT:=30}"
: "${SER_VERBOSE:=1}"

_ser_log() { [ "$SER_VERBOSE" = 1 ] && printf '%s\n' "$*" >&2; return 0; }
ser_fatal() { printf 'serial-lib: FATAL: %s\n' "$*" >&2; ser_close 2>/dev/null; exit 1; }

# Byte offset into SERLOG already consumed by ser_expect (so each expect only
# looks at output produced since the previous match -- no matching stale text).
SER_OFF=0
SER_CAT_PID=""

ser_open() {
    [ -n "${SERIAL:-}" ] || ser_fatal "SERIAL is not set (e.g. SERIAL=/dev/ttyUSB4)"
    [ -c "$SERIAL" ]     || ser_fatal "$SERIAL is not a character device"
    case "$SERIAL" in
        */ttyUSB5) ser_fatal "refusing to open $SERIAL (reserved sibling; see project memory)";;
    esac

    # Hold ONE write fd (fd 4) for the whole session. Opening the tty per command
    # -- or worse, per character -- glitches the line and drops chars; a single
    # persistent open is the only glitch, which makes even the lossy busybox
    # initramfs console reliable. All send helpers write to fd 4.
    exec 4>"$SERIAL" || ser_fatal "cannot open $SERIAL for writing"

    # Is a logger already reading this port? (Two readers corrupt both captures.)
    _existing=$(pgrep -f "cat $SERIAL" 2>/dev/null | head -1 || true)
    if [ -z "${SER_ATTACH:-}" ] && [ -n "$_existing" ]; then
        SER_ATTACH=1
        _ser_log "[serial] detected an existing reader (pid $_existing) on $SERIAL -> attach mode"
    fi

    if [ "${SER_ATTACH:-0}" = 1 ]; then
        [ -n "${SERLOG:-}" ] || ser_fatal "attach mode needs SERLOG=<the running logger's file> (e.g. /tmp/am62-serial.log)"
        [ -r "$SERLOG" ]     || ser_fatal "attach mode: cannot read $SERLOG"
        # We only WRITE to the tty; do not reconfigure it (the logger owns stty).
        SER_CAT_PID=""
        SER_OFF=$(wc -c < "$SERLOG" | tr -d ' ')   # ignore pre-existing output
        _ser_log "[serial] ATTACH $SERIAL, tailing $SERLOG from byte $SER_OFF (no reader started)"
        return 0
    fi

    # Standalone: we own the port. Refuse if someone else is already reading it.
    [ -z "$_existing" ] || ser_fatal "another reader (pid $_existing) holds $SERIAL; use SER_ATTACH=1 SERLOG=<its file>, or stop it"
    : "${SERLOG:=/tmp/tzn-serial-$(basename "$SERIAL").log}"
    stty -F "$SERIAL" "$BAUD" raw -echo -echoe -echok -echoctl -echoke 2>/dev/null \
        || ser_fatal "cannot configure $SERIAL at $BAUD"
    : > "$SERLOG" || ser_fatal "cannot write capture log $SERLOG"
    cat "$SERIAL" >> "$SERLOG" 2>/dev/null &
    SER_CAT_PID=$!
    SER_OFF=0
    _ser_log "[serial] open $SERIAL @ $BAUD -> $SERLOG (reader pid $SER_CAT_PID)"
}

# Closes our write fd; kills OUR reader only; never touches a logger we attached to.
ser_close() {
    exec 4>&- 2>/dev/null || true
    [ -n "$SER_CAT_PID" ] && kill "$SER_CAT_PID" 2>/dev/null
    SER_CAT_PID=""
}

# ser_send "text" -- type text followed by CR (as a human pressing Enter).
ser_send() {
    _ser_log "[serial] send: $1"
    printf '%s\r' "$1" >&4 || ser_fatal "write to $SERIAL failed"
}

# ser_send_raw "text" -- type text with no trailing CR (for control chars, e.g.
# interrupting autoboot with a stream of newlines/keys).
ser_send_raw() {
    printf '%s' "$1" >&4 || ser_fatal "write to $SERIAL failed"
}

# ser_send_slow "text" -- type one char at a time with a small delay, then CR.
# For consoles that drop characters on a fast burst -- notably the busybox
# initramfs shell ("can't access tty; job control turned off"). CRITICAL: hold
# the tty open for the whole command (fd 3); reopening the port per character
# (`> $SERIAL` each char) glitches the line and drops characters -- that, not the
# receiver, was the real cause of initramfs garbling. Pure parameter expansion,
# no per-char subshell.
: "${SER_SLOW_DELAY:=0.05}"
ser_send_slow() {
    _ser_log "[serial] send (slow): $1"
    _s="$1"
    while [ -n "$_s" ]; do
        printf '%s' "${_s%"${_s#?}"}" >&4
        _s=${_s#?}
        sleep "$SER_SLOW_DELAY"
    done
    printf '\r' >&4
}

# ser_send_verified "cmd" [tries] -- RELIABLY type cmd into a lossy console.
# Types it (fd held, paced), reads the echo, and only presses Enter to COMMIT if
# the console echoed cmd verbatim; otherwise it presses Enter to flush the garbled
# line (which runs as a harmless "not found" against a fresh prompt) and retries.
# This is the only dependable way to drive the busybox initramfs console, which
# drops ~1 char per command even fd-held. Keep cmds guarded (&&) and idempotent so
# a flushed partial is safe. Returns 0 on a verified send.
ser_send_verified() {
    _cmd="$1"; _tries="${2:-8}"; _k=0
    while [ "$_k" -lt "$_tries" ]; do
        _k=$((_k + 1))
        _before=$(wc -c < "$SERLOG" | tr -d ' ')
        _s="$_cmd"
        while [ -n "$_s" ]; do
            printf '%s' "${_s%"${_s#?}"}" >&4
            _s=${_s#?}
            sleep "${SER_SLOW_DELAY:-0.05}"
        done
        sleep 0.6
        # Strip CR/LF from the echo before matching: the console hard-wraps long
        # command lines (inserting a newline mid-command), which would defeat a
        # verbatim substring match even though the command was typed correctly. A
        # genuinely DROPPED char removes a non-newline char, so this still fails
        # (and retries) on real drops -- it only forgives cosmetic line wraps.
        _echo=$(tail -c "+$((_before + 1))" "$SERLOG" 2>/dev/null | tr -d '\r\n')
        case "$_echo" in
            *"$_cmd"*)
                _ser_log "[serial] verified: $_cmd"
                printf '\r' >&4; sleep 0.4; return 0;;
            *)
                _ser_log "[serial] garbled (try $_k), reflushing: $_cmd"
                printf '\r' >&4; sleep 0.8;;
        esac
    done
    ser_fatal "could not reliably type into console after $_tries tries: $_cmd"
}

# ser_expect "ERE" [timeout] -- wait until ERE appears in output produced since
# the last successful expect. Returns 0 and advances the offset on match; returns
# 1 on timeout (offset unchanged, so the caller can try an alternative pattern).
ser_expect() {
    _pat="$1"; _to="${2:-$SER_DEFAULT_TIMEOUT}"; _n=0
    _ser_log "[serial] expect: /$_pat/  (<= ${_to}s)"
    while [ "$_n" -lt "$_to" ]; do
        if tail -c "+$((SER_OFF + 1))" "$SERLOG" 2>/dev/null | grep -Eaq "$_pat"; then
            SER_OFF=$(wc -c < "$SERLOG" | tr -d ' ')
            _ser_log "[serial]   matched"
            return 0
        fi
        sleep 1; _n=$((_n + 1))
    done
    _ser_log "[serial]   TIMEOUT after ${_to}s waiting for /$_pat/"
    return 1
}

# ser_send_expect "text" "ERE" [timeout] -- send then wait; fatal on timeout.
ser_send_expect() {
    ser_send "$1"
    ser_expect "$2" "${3:-$SER_DEFAULT_TIMEOUT}" \
        || ser_fatal "no /$2/ after sending: $1"
}

# ser_dump [n] -- print the last n bytes of the log (default 2000) for debugging.
ser_dump() { tail -c "${1:-2000}" "$SERLOG" 2>/dev/null; }
