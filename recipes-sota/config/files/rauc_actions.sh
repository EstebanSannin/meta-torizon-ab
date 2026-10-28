#!/bin/bash
#
# Aktualizr Subsystem-Update action handler for the OS rootfs on an A/B (dual
# rootfs) + RAUC system. Counterpart to swupdate_actions.sh; the aktualizr seam
# is identical, but RAUC owns slot selection, the raw write, and arming the
# bootloader, so this handler is thin.
#
# Contract (Toradex "Subsystem Updates"):
#   $1 = get-firmware-info | install | complete-install
#   env: SECONDARY_FIRMWARE_PATH, SECONDARY_FIRMWARE_SHA256, SECONDARY_CUSTOM_METADATA
#   stdout: JSON {"status": "ok|need-completion|failed", "message": "..."}
#   exit:  0 handled, 64 request-normal-processing, 65 request-error
#
# Payload: a signed RAUC bundle (.raucb) whose manifest maps the rootfs image to
# the 'rootfs' slot class. `rauc install` writes the INACTIVE slot, verifies the
# bundle signature against the keyring in /usr/lib/rauc, and (via RAUC's bootloader
# backend: grub on x86, U-Boot on ARM) arms that slot to boot next on trial. The
# running slot is read from the 'rauc.slot=A|B' kernel argument set by the boot
# configuration.

shopt -s expand_aliases
source "/usr/bin/common_actions.sh"

# Critical section: ignore SIGTERM from systemd.
trap '' TERM

# --- Configuration -----------------------------------------------------------
DRY_RUN="${AB_DRY_RUN:-0}"
LOG_ENABLED="${AB_LOG_ENABLED:-1}"
LOG_VARS="${AB_LOG_VARS:-0}"
LOG_DIR="/var/lib/rollback-manager"
LOG_FILE="${LOG_DIR}/rootfs-update.log"
# Records the slot we asked RAUC to boot, so complete-install can tell whether
# the trial stuck or rolled back.
TARGET_STATE="${LOG_DIR}/rauc-target"

set -o pipefail

req_program "/usr/bin/rauc" && alias RAUC="$_"
req_program "/usr/bin/touch" && alias TOUCH="$_"
req_program "/usr/bin/sed"   && alias SED="$_"
req_program "/usr/bin/findmnt" && alias FINDMNT="$_"

maybe_run() {
    if [ "$DRY_RUN" = "1" ]; then
        log "WOULD RUN:" "$@"; return 0
    fi
    log "RUN:" "$@"
    # stdout must be JSON only (aktualizr parses it); rauc is chatty -> log file.
    eval "$@" >>"${LOG_FILE}" 2>&1
}

# --- Slot helpers ------------------------------------------------------------

# output: bootname (A|B) of the currently-running slot, from the kernel cmdline.
get_booted_bootname() {
    local s
    s=$(SED -n 's/.*rauc\.slot=\([A-Za-z0-9]\+\).*/\1/p' /proc/cmdline)
    [ "$s" = "A" -o "$s" = "B" ] || die "Cannot determine booted slot from /proc/cmdline (rauc.slot=)"
    echo "$s"
}

# $1: bootname -> output: the other bootname
other_bootname() {
    [ "$1" = "A" ] && { echo "B"; return 0; }
    [ "$1" = "B" ] && { echo "A"; return 0; }
    die "Bad bootname '$1'"
}

# --- Trial state helpers -----------------------------------------------------

# greenboot is the health authority: confirm only a boot it declared healthy.
# Its health check runs before boot-complete.target and aktualizr only after it,
# so the result is final when complete-install runs.
boot_is_unhealthy() {
    systemctl is-failed --quiet greenboot-healthcheck.service
}

# U-Boot machines: mirror the trial in 'upgrade_available', the flag greenboot's
# red path (redboot-auto-reboot) and Torizon's U-Boot env cleanup read to tell an
# update is in progress; RAUC's BOOT_ORDER/BOOT_<slot>_LEFT still choose the
# slot. Without it a failed trial boot is never retried, so never rolled back.
has_uboot_env() {
    [ -r /etc/fw_env.config ] && command -v fw_setenv >/dev/null 2>&1
}

# $1: 1 when a trial is armed, 0 once it is resolved
set_update_in_progress() {
    has_uboot_env || return 0
    maybe_run fw_setenv upgrade_available "$1"
    maybe_run fw_setenv bootcount 0
    if [ "$1" = "1" ]; then
        # A new trial clears the previous rollback flag (as stock aktualizr does).
        maybe_run fw_setenv rollback 0
        # Past bootlimit U-Boot runs altbootcmd. The boot script seeds it too, but
        # it lives in the FAT boot partition, which rootfs updates never rewrite,
        # so make sure here that a device running an older boot script has it.
        # (fw_printenv exits 0 even for an unset variable: test the value.)
        [ -n "$(fw_printenv -n altbootcmd 2>/dev/null)" ] \
            || maybe_run fw_setenv altbootcmd "'setenv rollback 1; run bootcmd'"
    fi
}

# --- Actions -----------------------------------------------------------------

do_get_firmware_info() {
    # Defer to aktualizr (exit 64), like bl_actions.sh / swupdate_actions.sh.
    local booted
    booted=$(get_booted_bootname 2>/dev/null) || booted="unknown"
    log "get-firmware-info: running slot=$booted (deferring to aktualizr)"
    exit 64
}

do_install() {
    before_dying 'on_install_failed'
    check_install_vars
    # No target sha check: aktualizr Uptane-verifies the bundle in transit, and
    # RAUC verifies its signature at install time.

    local booted target
    booted=$(get_booted_bootname)
    target=$(other_bootname "$booted")

    log "Installing rootfs update via RAUC"
    log "Booted slot:  $booted"
    log "Target slot:  $target (RAUC selects the inactive slot automatically)"
    log "Payload:      $SECONDARY_FIRMWARE_PATH"

    # Defensive: the target slot must be free. udisks/usermount may auto-mount an
    # inactive slot; RAUC opens the slot device exclusively and fails if it is
    # busy. Unmount any inactive A/B slot (never the running root at /).
    for _p in rootfs_a rootfs_b; do
        _d="$(readlink -f "/dev/disk/by-partlabel/$_p" 2>/dev/null || true)"
        [ -b "$_d" ] || continue
        _mp="$(findmnt -nro TARGET -S "$_d" 2>/dev/null | head -1 || true)"
        if [ -n "$_mp" ] && [ "$_mp" != "/" ]; then
            log "Unmounting inactive slot $_p ($_d) from $_mp before install"
            maybe_run umount "$_d" || log "warning: could not unmount $_d"
        fi
    done

    # RAUC picks the inactive slot, writes it, verifies the signature, and arms
    # the bootloader to boot it next on trial.
    maybe_run RAUC install "$SECONDARY_FIRMWARE_PATH" \
        || die "rauc install failed"
    set_update_in_progress 1

    # Record the intended boot target for complete-install.
    install -d "${LOG_DIR}"
    echo "$target" > "${TARGET_STATE}"

    maybe_run TOUCH "${REBOOT_SENTINEL_FILE}"
    echo '{"status": "need-completion", "message": "rootfs bundle installed to inactive slot; rebooting"}'
    return 0
}

do_complete_install() {
    if [ -e "${REBOOT_SENTINEL_FILE}" ]; then
        log "Delaying completion due to pending reboot"
        echo '{"status": "need-completion", "message": "delaying completion due to pending reboot"}'
        return 0
    fi

    before_dying 'on_install_failed'
    check_install_vars

    local booted target
    booted=$(get_booted_bootname)
    target=""
    [ -f "${TARGET_STATE}" ] && target=$(cat "${TARGET_STATE}")

    log "complete-install: running slot=$booted, trial target=$target"

    if [ -z "$target" ]; then
        exit 64   # nothing pending
    fi

    # Booted into the trial slot but greenboot failed it: keep the trial armed.
    # greenboot reboots, the slot runs out of attempts, the old slot comes back,
    # and the next complete-install reports the rollback.
    if [ "$booted" = "$target" ] && boot_is_unhealthy; then
        log "Trial slot $target is unhealthy (greenboot); waiting for the rollback"
        echo '{"status": "need-completion", "message": "trial boot unhealthy; waiting for rollback"}'
        return 0
    fi

    rm -f "${TARGET_STATE}"
    set_update_in_progress 0

    if [ "$booted" = "$target" ]; then
        # We booted the freshly-installed slot. greenboot's health check marks
        # it good (rauc status mark-good); report success to the cloud.
        log "Rootfs update to slot $target confirmed"
        echo '{"status": "ok", "message": "rootfs update confirmed"}'
    else
        log "Rootfs update failed; system rolled back to slot $booted"
        echo '{"status": "failed", "message": "rootfs update failed; rolled back"}'
    fi
    return 0
}

# --- Main --------------------------------------------------------------------
prep_log_or_abort
log_action "$@"

case "$1" in
    get-firmware-info) do_get_firmware_info ;;
    install)           do_install; exit 0 ;;
    complete-install)  do_complete_install; exit 0 ;;
    *)                 log "Unknown action: $1"; exit 64 ;;
esac
