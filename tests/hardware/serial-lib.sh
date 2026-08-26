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
#
# Only one reader may hold the tty at a time: ser_open kills any stray `cat` on
# the same device first.

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
    : "${SERLOG:=/tmp/tzn-serial-$(basename "$SERIAL").log}"

    # Drop any other reader holding the port (best-effort; needs matching perms).
    pkill -f "cat $SERIAL" 2>/dev/null || true

    stty -F "$SERIAL" "$BAUD" raw -echo -echoe -echok -echoctl -echoke 2>/dev/null \
        || ser_fatal "cannot configure $SERIAL at $BAUD"

    : > "$SERLOG" || ser_fatal "cannot write capture log $SERLOG"
    cat "$SERIAL" >> "$SERLOG" 2>/dev/null &
    SER_CAT_PID=$!
    SER_OFF=0
    _ser_log "[serial] open $SERIAL @ $BAUD -> $SERLOG (reader pid $SER_CAT_PID)"
}

ser_close() {
    [ -n "$SER_CAT_PID" ] && kill "$SER_CAT_PID" 2>/dev/null
    SER_CAT_PID=""
}

# ser_send "text" -- type text followed by CR (as a human pressing Enter).
ser_send() {
    _ser_log "[serial] send: $1"
    printf '%s\r' "$1" > "$SERIAL" || ser_fatal "write to $SERIAL failed"
}

# ser_send_raw "text" -- type text with no trailing CR (for control chars, e.g.
# interrupting autoboot with a stream of newlines/keys).
ser_send_raw() {
    printf '%s' "$1" > "$SERIAL" || ser_fatal "write to $SERIAL failed"
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
