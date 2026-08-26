#!/bin/sh
# enable-access.sh -- inject EPHEMERAL dev/test access into a running, PRISTINE
# Torizon OS A/B device over the serial console.
#
# WHY THIS EXISTS
#   The A/B image is built pristine on purpose: no dev SSH key, no passwordless
#   sudo, no provisioning identity baked into any rootfs slot, so the deployed
#   artifact is bit-identical to the tested one. Dev/test access is therefore
#   NOT in the image -- the harness adds it at runtime, and every change it makes
#   lands on the DATA PARTITION only (authorized_keys -> /home; sudoers + shadow
#   -> the /etc overlay upper; both backed by LABEL=data), never in a rootfs
#   slot. A reflash (or runtime-reset.sh) removes all of it.
#
# WHAT IT DOES (default mode)
#   1. Logs in on the serial console as 'torizon'. On a fresh flash stock Torizon
#      ships torizon/torizon and EXPIRES it (passwd -e) so first login forces a
#      change -- this handles that, setting our throwaway session password.
#   2. Installs a session SSH public key into ~torizon/.ssh/authorized_keys.
#   3. Enables passwordless sudo (/etc/sudoers.d/90-torizon-nopw).
#   4. Normalises password aging so headless key-based SSH is not blocked by PAM.
#   5. Prints the board's IP so you can SSH in.
#
#   --teardown reverses 2-4 (best-effort). The real reset is a reflash.
#
# THIS FILE IS NOT SHIPPED IN ANY IMAGE. Run it on the host wired to the board
# (beerus). It contains no secret: the bootstrap password is Torizon's public
# default; the session password is a throwaway on a device that gets reflashed.
#
# USAGE
#   SERIAL=/dev/ttyUSB4 ./enable-access.sh              # am62p (imx8mp = ttyUSB3)
#   SERIAL=/dev/ttyUSB4 ./enable-access.sh --teardown
#
# CONFIG (environment)
#   SERIAL              serial device, REQUIRED (imx8mp ttyUSB3 / am62p ttyUSB4;
#                       NEVER ttyUSB5).
#   TZ_BOOTSTRAP_PW     stock first-boot password              [torizon]
#   TZ_NEW_PW           throwaway session password we set      [Xq7#kD2!vLp9]
#                       (must satisfy libpwquality: len>=8, mixed classes,
#                        non-dictionary, differ from bootstrap).
#   TZ_SESSION_PUBKEY       the SSH public key STRING to install, or
#   TZ_SESSION_PUBKEY_FILE  a file to read it from   [~/.ssh/ota_ce_vm.pub]
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=serial-lib.sh
. "$HERE/serial-lib.sh"

: "${TZ_BOOTSTRAP_PW:=torizon}"
: "${TZ_NEW_PW:=Xq7#kD2!vLp9}"

MODE=enable
for a in "$@"; do
    case "$a" in
        --teardown) MODE=teardown;;
        --serial)   ;; # handled below
        /dev/*)     SERIAL="$a";;
        -h|--help)  sed -n '2,40p' "$0"; exit 0;;
        *) ser_fatal "unknown argument: $a";;
    esac
done

resolve_pubkey() {
    if [ -n "${TZ_SESSION_PUBKEY:-}" ]; then
        printf '%s' "$TZ_SESSION_PUBKEY"; return 0
    fi
    _f="${TZ_SESSION_PUBKEY_FILE:-$HOME/.ssh/ota_ce_vm.pub}"
    [ -r "$_f" ] || ser_fatal "no pubkey: set TZ_SESSION_PUBKEY or TZ_SESSION_PUBKEY_FILE (tried $_f)"
    # first non-empty, non-comment line
    grep -Ev '^\s*(#|$)' "$_f" | head -1
}

# --- sentinel-based command execution over the shell we hold ---
# sh_run "cmd" -- run cmd in the torizon shell, verify it exited 0.
_TAG=0
sh_run() {
    _TAG=$((_TAG + 1)); _s="__RC_${_TAG}__"
    ser_send "$1; echo ${_s}\$?"
    ser_expect "${_s}0\\b" 30 || ser_fatal "command failed on device: $1"
}
# sudo_run "cmd" -- run cmd as root; answers the sudo password prompt if asked.
sudo_run() {
    _TAG=$((_TAG + 1)); _s="__RC_${_TAG}__"
    ser_send "sudo -k sh -c '$1'; echo ${_s}\$?"
    # Either sudo asks for a password, or (once NOPASSWD is in place) it doesn't.
    if ser_expect "[Pp]assword.*:|${_s}[0-9]" 20; then
        # If what matched was the password prompt, answer it and wait for the rc.
        if tail -c 400 "$SERLOG" | grep -Eaq "[Pp]assword.*:[^_]*$"; then
            ser_send "$TZ_NEW_PW"
            ser_expect "${_s}[0-9]" 30 || ser_fatal "sudo produced no result: $1"
        fi
    else
        ser_fatal "sudo did not respond: $1"
    fi
    tail -c 200 "$SERLOG" | grep -Eaq "${_s}0\\b" || ser_fatal "sudo command failed: $1"
}

# --- get to a working 'torizon' shell, handling the forced password change ---
ensure_torizon_shell() {
    _ready="__SHELL_READY_$$__"
    _try=0
    while [ "$_try" -lt 4 ]; do
        _try=$((_try + 1))
        # Nudge and see where we are.
        ser_send ""
        if ser_expect "$_ready|login:|[Pp]assword:" 8; then :; fi
        # Are we already at a shell? Ask it to prove it.
        ser_send "echo $_ready"
        if ser_expect "$_ready" 6; then
            # Matched -- but this could be the echo of the command, not output.
            # Confirm by running a second unique sentinel as a command.
            _r2="__SHELL_OK_${_try}_$$__"
            ser_send "echo $_r2"
            if ser_expect "$_r2" 6; then
                _ser_log "[access] have a shell"
                return 0
            fi
        fi
        # Not a shell: drive a login.
        ser_send ""
        if ser_expect "login:" 10; then
            ser_send "torizon"
            ser_expect "[Pp]assword:" 10 || continue
            # First try the throwaway (idempotent re-run), fall back to bootstrap.
            ser_send "$TZ_NEW_PW"
            if ser_expect "incorrect|[Ll]ogin incorrect|login:" 6; then
                # throwaway rejected -> use bootstrap and handle forced change
                ser_expect "login:" 8 || true
                ser_send "torizon"
                ser_expect "[Pp]assword:" 10 || continue
                ser_send "$TZ_BOOTSTRAP_PW"
                handle_forced_change || true
            fi
        fi
    done
    ser_fatal "could not obtain a torizon shell over serial (see $SERLOG)"
}

# After sending the bootstrap password, deal with the enforced change dialog.
handle_forced_change() {
    # Some builds ask "Current password:" first; all ask New + Retype.
    if ser_expect "Current password:|New password:|expired|required to change" 12; then
        if tail -c 300 "$SERLOG" | grep -Eaiq "current password:"; then
            ser_send "$TZ_BOOTSTRAP_PW"
            ser_expect "New password:" 10 || return 1
        elif ! tail -c 300 "$SERLOG" | grep -Eaiq "new password:"; then
            ser_expect "New password:" 10 || return 1
        fi
        ser_send "$TZ_NEW_PW"
        ser_expect "Retype new password:|Re-enter new password:|Reenter" 10 || return 1
        ser_send "$TZ_NEW_PW"
        # login(1) usually drops back to the login prompt afterwards.
        if ser_expect "login:" 12; then
            ser_send "torizon"
            ser_expect "[Pp]assword:" 10 || return 1
            ser_send "$TZ_NEW_PW"
        fi
        return 0
    fi
    return 0
}

# ---------------------------------------------------------------------------
ser_open
ensure_torizon_shell

if [ "$MODE" = enable ]; then
    PUBKEY=$(resolve_pubkey)
    _ser_log "[access] installing session key + passwordless sudo"

    # 1. SSH key -> /home (data partition). Runs as torizon; no root needed.
    sh_run "install -d -m 0700 \$HOME/.ssh"
    # Overwrite authorized_keys with just our session key.
    sh_run "printf '%s\\n' '$PUBKEY' > \$HOME/.ssh/authorized_keys"
    sh_run "chmod 0600 \$HOME/.ssh/authorized_keys"

    # 2. Passwordless sudo -> /etc overlay upper (data partition).
    sudo_run "printf '%s ALL=(ALL) NOPASSWD:ALL\\n' torizon > /etc/sudoers.d/90-torizon-nopw; chmod 0440 /etc/sudoers.d/90-torizon-nopw"

    # 3. Normalise aging so PAM's account phase never blocks headless key SSH
    #    (-> /etc/shadow in the overlay upper). The password change already reset
    #    last-change; this makes it explicit and disables expiry.
    sudo_run "chage -d \$(date +%Y-%m-%d) -m 0 -M -1 -I -1 -E -1 torizon; passwd -x -1 torizon"

    # 4. Report the address to SSH to.
    ser_send "ip -4 -o addr show scope global | awk '{print \"BOARD_IP \" \$2 \" \" \$4}'"
    ser_expect "BOARD_IP " 10 || true
    echo
    echo "== access enabled =="
    ser_dump 600 | grep -Ea "BOARD_IP " || true
    echo "SSH in with the private key matching the installed pubkey:"
    echo "    ssh -i <priv-key> torizon@<board-ip>"
    echo "Session password (sudo / console): $TZ_NEW_PW"
else
    _ser_log "[access] tearing down injected access (best-effort)"
    sudo_run "rm -f /etc/sudoers.d/90-torizon-nopw"
    sh_run   "rm -f \$HOME/.ssh/authorized_keys"
    echo
    echo "== access torn down =="
    echo "Note: the throwaway password ($TZ_NEW_PW) and any /var/sota provisioning"
    echo "remain until a reflash or runtime-reset.sh. A reflash is the true reset."
fi

ser_close
