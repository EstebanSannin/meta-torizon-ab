#!/bin/sh
# runtime-reset.sh -- RUNTIME/PROVISIONING reset of a Torizon OS A/B device over
# the serial console. NOT a factory reset.
#
# SCOPE (honest)
#   Resets only RUNTIME STATE that lives on the DATA PARTITION plus the boot
#   environment:
#     * wipes the data partition (LABEL=data): /var (incl. /var/sota provisioning),
#       the /etc overlay upper, /home, and the .torizon-ab-seeded marker -- so the
#       initramfs re-seeds factory /var + /home on the next boot;
#     * resets the boot-env A/B selection variables to their factory defaults
#       (slot A active, good, no trial), matching the *-env-create bootstrap.
#   It does NOT touch either rootfs slot. Once A/B update tests have overwritten a
#   slot's original bytes, the factory image is gone and there is no software way
#   back: a TRUE factory reset = REFLASH (which the pipeline does anyway for the
#   next test image). This tool is for tests that need a clean provisioning start
#   without a reflash.
#
# HOW (all over serial, nothing added to the image)
#   Both the boot-env reset and the data wipe are reachable from the serial
#   console via the boot script's ${tdxargs} passthrough:
#     1. reboot into U-Boot, set the boot-env defaults, and arm a one-shot
#        `tdxargs=shell=before:persist` so the initramfs drops to a shell right
#        before the persistence module mounts the data partition;
#     2. in that shell the data partition is NOT mounted, so we mount it
#        ourselves, rm -rf its contents (incl. the seed marker), and unmount;
#     3. reboot once more with tdxargs cleared -> normal boot -> the persistence
#        module re-seeds. (The RAUC preamble saveenv's the env, so the explicit
#        clear on the second U-Boot pass is required; harmless for SWUpdate.)
#
# THIS FILE IS NOT SHIPPED IN ANY IMAGE. Run it on the host wired to the board
# (beerus).
#
# USAGE
#   SERIAL=/dev/ttyUSB4 ./runtime-reset.sh --backend rauc     --yes   # am62p
#   SERIAL=/dev/ttyUSB3 ./runtime-reset.sh --backend swupdate --yes   # imx8mp
#
# CONFIG (environment)
#   SERIAL     serial device, REQUIRED (imx8mp ttyUSB3 / am62p ttyUSB4; NEVER ttyUSB5)
#   TZ_BACKEND rauc | swupdate            (or --backend)
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=serial-lib.sh
. "$HERE/serial-lib.sh"

BACKEND="${TZ_BACKEND:-}"
CONFIRM=0
while [ $# -gt 0 ]; do
    case "$1" in
        --backend) BACKEND="${2:?--backend needs rauc|swupdate}"; shift;;
        --yes)     CONFIRM=1;;
        /dev/*)    SERIAL="$1";;
        -h|--help) sed -n '2,40p' "$0"; exit 0;;
        *) ser_fatal "unknown argument: $1";;
    esac
    shift
done
case "$BACKEND" in
    rauc|swupdate) ;;
    *) ser_fatal "set --backend rauc|swupdate (got: '${BACKEND:-}')";;
esac
[ "$CONFIRM" = 1 ] || ser_fatal "this WIPES the data partition; pass --yes to proceed"

# --- U-Boot helpers ---------------------------------------------------------
# Catch the autoboot window and land at the U-Boot prompt.
catch_uboot() {
    _ser_log "[reset] waiting for U-Boot autoboot window (power-cycle the board if it is off)..."
    ser_expect "Hit any key to stop autoboot|U-Boot SPL|U-Boot 20" 180 \
        || ser_fatal "did not see U-Boot -- is the board powered / cabled to $SERIAL?"
    # Spam keys to interrupt autoboot.
    _i=0; while [ "$_i" -lt 40 ]; do ser_send_raw " "; _i=$((_i + 1)); done
    ser_send ""
    # Confirm we own the prompt: 'version' prints the U-Boot banner.
    ser_send "version"
    ser_expect "U-Boot 20" 10 || ser_fatal "could not get the U-Boot prompt"
    _ser_log "[reset] at U-Boot prompt"
}
# ub "cmd" -- run a U-Boot command, verified via a trailing echo sentinel.
ub() {
    _TAG="${_TAG:-0}"; _TAG=$((_TAG + 1)); _m="UBOK_${_TAG}_$$"
    ser_send "$1 && echo $_m || echo ${_m}_ERR"
    ser_expect "$_m(_ERR)?" 15 || ser_fatal "U-Boot command hung: $1"
    tail -c 200 "$SERLOG" | grep -Eaq "${_m}\\b" || ser_fatal "U-Boot command failed: $1"
}

set_env_defaults() {
    if [ "$BACKEND" = rauc ]; then
        ub 'setenv BOOT_ORDER "A B"'
        ub 'setenv BOOT_A_LEFT 3'
        ub 'setenv BOOT_B_LEFT 0'
    else
        ub 'setenv rootfs_slot a'
        ub 'setenv upgrade_available 0'
        ub 'setenv bootcount 0'
        ub 'setenv rollback 0'
    fi
}

# --- trigger the first reboot (best-effort; else ask for a power cycle) ------
trigger_reboot() {
    _ser_log "[reset] trying to reboot the board via a serial shell..."
    ser_send ""
    # If a torizon/root shell answers, reboot through it.
    ser_send "echo RESET_PING_$$"
    if ser_expect "RESET_PING_$$" 6; then
        ser_send "sudo -n reboot 2>/dev/null || reboot 2>/dev/null || echo NEED_POWER_CYCLE"
        sleep 2
    fi
    cat <<EOF >&2

[reset] If the board does NOT reboot on its own now, POWER-CYCLE it.
        (A running-shell reboot needs prior access; a power cycle always works.)
EOF
}

# --- wipe the data partition from the pre-persist initramfs shell ------------
wipe_data() {
    _ser_log "[reset] booting to the pre-persist initramfs shell to wipe LABEL=data"
    ub 'setenv tdxargs "shell=before:persist"'
    ub 'saveenv'
    ser_send "boot"
    # The debug module announces the shell right before the persist module.
    ser_expect "Starting shell before persist" 120 \
        || ser_fatal "did not reach the pre-persist initramfs shell"
    sleep 1
    # We are root in the initramfs; data partition is NOT yet mounted.
    _s="__WIPE_$$__"
    ser_send "D=/dev/disk/by-label/data; [ -b \$D ] || D=\$(blkid -L data); mkdir -p /mnt/reset && mount -t ext4 \$D /mnt/reset && echo MOUNT_OK_$$ || echo MOUNT_ERR_$$"
    ser_expect "MOUNT_OK_$$|MOUNT_ERR_$$" 20 || ser_fatal "no response mounting data"
    tail -c 200 "$SERLOG" | grep -Eaq "MOUNT_OK_$$" || ser_fatal "could not mount the data partition"
    # Remove everything including dotfiles (the .torizon-ab-seeded marker).
    ser_send "for f in /mnt/reset/* /mnt/reset/.[!.]* /mnt/reset/..?*; do [ -e \"\$f\" ] && rm -rf \"\$f\"; done; sync; echo ${_s}\$?"
    ser_expect "${_s}0\\b" 60 || ser_fatal "wipe command failed"
    ser_send "ls -A /mnt/reset | head; umount /mnt/reset && echo UMOUNT_OK_$$ || echo UMOUNT_ERR_$$"
    ser_expect "UMOUNT_OK_$$|UMOUNT_ERR_$$" 20 || ser_fatal "no response unmounting data"
    tail -c 200 "$SERLOG" | grep -Eaq "UMOUNT_OK_$$" || ser_fatal "could not unmount the data partition"
    _ser_log "[reset] data partition wiped"
    # Reboot out of the initramfs (busybox reboot -> direct syscall).
    ser_send "reboot -f"
}

# --- run --------------------------------------------------------------------
ser_open

echo "== runtime/provisioning reset ($BACKEND) -- this WIPES the data partition =="

trigger_reboot
catch_uboot
set_env_defaults          # factory A/B defaults
wipe_data                 # arms shell=before:persist, wipes, reboots

# Second U-Boot pass: clear the one-shot shell arg (RAUC saveenv'd it) and boot
# clean; the persistence module re-seeds because the marker is gone.
catch_uboot
set_env_defaults
ub 'setenv tdxargs ""'
ub 'saveenv'
ser_send "boot"

# Confirm a normal boot completes (re-seed happens here).
if ser_expect "login:" 180; then
    echo
    echo "== reset complete =="
    echo "The device booted clean: data partition re-seeded, /var/sota provisioning"
    echo "cleared, boot-env back to factory A/B defaults (slot A). No rootfs slot was"
    echo "touched. Re-run enable-access.sh if you need access again."
else
    echo "WARNING: did not observe a login prompt after reset; inspect $SERLOG" >&2
fi

ser_close
