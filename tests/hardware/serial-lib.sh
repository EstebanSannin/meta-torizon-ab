#!/bin/sh
# serial-lib.sh -- minimal send/expect over a serial console, POSIX sh.
#
# Sourced by the hardware test harness (enable-access.sh). It
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
        # LIVENESS GUARD: a dead/stale logger silently freezes the capture, which
        # makes every ser_expect "time out" -- a nasty trap (the background `cat`
        # can exit on EOF when the board reboots and the USB serial re-enumerates).
        # Confirm the capture actually grows (nudge the console with a CR, watch
        # the file). Fail loudly if it does not.
        _lz=$(wc -c < "$SERLOG" | tr -d ' '); printf '\r' >&4 2>/dev/null || true
        _lc=0; while [ "$_lc" -lt 5 ]; do sleep 1
            [ "$(wc -c < "$SERLOG" | tr -d ' ')" -gt "$_lz" ] && break; _lc=$((_lc + 1)); done
        [ "$(wc -c < "$SERLOG" | tr -d ' ')" -gt "$_lz" ] \
            || ser_fatal "attach: $SERLOG is not growing -- the serial logger is dead/stale. Restart it (e.g. the imx8-serial/am62-serial capture) before running."
        SER_OFF=$(wc -c < "$SERLOG" | tr -d ' ')
        _ser_log "[serial] ATTACH $SERIAL, tailing $SERLOG from byte $SER_OFF (logger live)"
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

# ser_expect "ERE" [timeout] -- wait until ERE appears in output produced since
# the last successful expect. Returns 0 and advances the offset on match; returns
# 1 on timeout (offset unchanged, so the caller can try an alternative pattern).
ser_expect() {
    _pat="$1"; _to="${2:-$SER_DEFAULT_TIMEOUT}"; _n=0
    _sz0=$(wc -c < "$SERLOG" 2>/dev/null | tr -d ' ')
    _ser_log "[serial] expect: /$_pat/  (<= ${_to}s)"
    while [ "$_n" -lt "$_to" ]; do
        if tail -c "+$((SER_OFF + 1))" "$SERLOG" 2>/dev/null | grep -Eaq "$_pat"; then
            SER_OFF=$(wc -c < "$SERLOG" | tr -d ' ')
            _ser_log "[serial]   matched"
            return 0
        fi
        sleep 1; _n=$((_n + 1))
    done
    if [ "$(wc -c < "$SERLOG" 2>/dev/null | tr -d ' ')" = "$_sz0" ]; then
        _ser_log "[serial]   TIMEOUT after ${_to}s waiting for /$_pat/ -- capture did NOT grow (serial logger likely dead/stale)"
    else
        _ser_log "[serial]   TIMEOUT after ${_to}s waiting for /$_pat/"
    fi
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
