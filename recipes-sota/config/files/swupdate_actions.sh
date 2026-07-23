#!/bin/bash
#
# Aktualizr Subsystem-Update action handler for the OS rootfs on an A/B (dual
# rootfs) + SWUpdate system. MACHINE-AGNOSTIC: the bootloader specifics (how the
# active slot is selected and how the trial/rollback state is stored) live in a
# per-machine helper sourced from /usr/lib/torizon-ab/bootenv.sh —
#   x86     -> provided by grub-ab   (grubenv)
#   imx8mp  -> provided by uboot-ab  (real U-Boot env via fw_setenv)
#
# Contract (Toradex "Subsystem Updates"):
#   $1 = get-firmware-info | install | complete-install
#   env: SECONDARY_FIRMWARE_PATH, SECONDARY_FIRMWARE_SHA256, SECONDARY_CUSTOM_METADATA
#   stdout: JSON {"status": "ok|need-completion|failed", "message": "..."}
#   exit:  0 handled, 64 request-normal-processing, 65 request-error
#
# Slots: ext4 labels otaroot_a / otaroot_b, each carrying its own /boot. The .swu
# payload is the full rootfs ext4 image; SWUpdate raw-writes it to the INACTIVE
# slot (SWUpdate mode slot_a/slot_b), then we restore the ext4 label and arm the
# bootloader to boot that slot on trial.

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

LABEL_A="otaroot_a"
LABEL_B="otaroot_b"

set -o pipefail

req_program "/usr/bin/lsblk"    && alias LSBLK="$_"
req_program "/usr/bin/findmnt"  && alias FINDMNT="$_"
req_program "/usr/bin/swupdate" && alias SWUPDATE="$_"
req_program "/usr/bin/touch"    && alias TOUCH="$_"
# Required by common_actions.sh (get_file_sha256 uses the SED alias but does not
# define it — the sourcing script must, like bl_actions.sh does).
req_program "/usr/bin/sed"      && alias SED="$_"
req_program "/usr/sbin/e2label" && alias E2LABEL="$_"

maybe_run() {
    if [ "$DRY_RUN" = "1" ]; then
        log "WOULD RUN:" "$@"; return 0
    fi
    log "RUN:" "$@"
    # Redirect command output to the log. The action handler's stdout must
    # contain ONLY the final JSON status (aktualizr parses stdout as JSON);
    # swupdate -v in particular is very chatty and would corrupt it.
    eval "$@" >>"${LOG_FILE}" 2>&1
}

# --- Slot helpers (machine-agnostic) -----------------------------------------

# output: label of the currently-running rootfs slot (otaroot_a|otaroot_b)
get_active_label() {
    local src label
    src=$(FINDMNT -n -o SOURCE /) || die "Cannot determine root device"
    label=$(LSBLK -ndo LABEL "$src" 2>/dev/null)
    [ "$label" = "$LABEL_A" -o "$label" = "$LABEL_B" ] \
        || die "Root slot has unexpected label: '$label'"
    echo "$label"
}

# $1: active label -> output: inactive label
get_inactive_label() {
    [ "$1" = "$LABEL_A" ] && { echo "$LABEL_B"; return 0; }
    [ "$1" = "$LABEL_B" ] && { echo "$LABEL_A"; return 0; }
    die "Bad active label '$1'"
}

# $1: label -> output: SWUpdate selection mode (slot_a|slot_b)
label_to_mode() {
    [ "$1" = "$LABEL_A" ] && { echo "slot_a"; return 0; }
    [ "$1" = "$LABEL_B" ] && { echo "slot_b"; return 0; }
    die "Bad label '$1'"
}

# --- Per-machine boot-env operations -----------------------------------------
# Provides: bootenv_arm_trial <label>, bootenv_confirm, bootenv_trial_target
# (see grub-ab / uboot-ab). Sourced after maybe_run/log/die are defined so the
# helper can use them.
source "/usr/lib/torizon-ab/bootenv.sh"

# --- Actions -----------------------------------------------------------------

do_get_firmware_info() {
    # Defer to aktualizr (exit 64), like bl_actions.sh — reporting a slot label
    # here would not match the pushed target name.
    local active
    active=$(get_active_label 2>/dev/null) || active="unknown"
    log "get-firmware-info: running slot=$active (deferring to aktualizr)"
    exit 64
}

do_install() {
    before_dying 'on_install_failed'
    check_install_vars
    # No check_target_sha256: aktualizr already Uptane-verifies the target.

    local active inactive mode
    active=$(get_active_label)
    inactive=$(get_inactive_label "$active")
    mode=$(label_to_mode "$inactive")

    log "Installing rootfs update"
    log "Active slot:   $active"
    log "Inactive slot: $inactive (swupdate mode=$mode)"
    log "Payload:       $SECONDARY_FIRMWARE_PATH"

    # Resolve the inactive slot's device NOW, while its ext4 label still exists
    # (the raw write replaces the label, so by-label/${inactive} disappears).
    local inactive_dev
    inactive_dev="$(readlink -f "/dev/disk/by-label/${inactive}" 2>/dev/null || true)"
    [ -b "$inactive_dev" ] || die "Cannot resolve device for inactive slot $inactive"
    log "Inactive slot device: $inactive_dev"

    # Defensive: ensure the inactive slot is not mounted before the raw write.
    if findmnt -rn -S "$inactive_dev" >/dev/null 2>&1; then
        log "Inactive slot $inactive is mounted; unmounting before write"
        maybe_run umount "$inactive_dev" || die "Could not unmount $inactive before write"
    fi

    # Write the .swu into the inactive slot (sw-description maps slot_a/slot_b to
    # /dev/disk/by-label/otaroot_a|b).
    maybe_run SWUPDATE -v -i "$SECONDARY_FIRMWARE_PATH" -e "stable,$mode" \
        || die "SWUpdate failed writing slot $inactive"

    # Restore the ext4 label the raw write clobbered.
    maybe_run E2LABEL "$inactive_dev" "$inactive" \
        || die "Could not restore ext4 label $inactive on $inactive_dev"

    # Arm the bootloader to boot the freshly-flashed slot on trial (per-machine).
    bootenv_arm_trial "$inactive" || die "Could not arm bootloader for slot $inactive"

    maybe_run TOUCH "${REBOOT_SENTINEL_FILE}"
    echo '{"status": "need-completion", "message": "rootfs written to inactive slot; rebooting"}'
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

    local active target
    active=$(get_active_label)
    target=$(bootenv_trial_target)

    log "complete-install: running slot=$active, trial target=$target"

    if [ -z "$target" ]; then
        exit 64   # nothing pending
    fi

    bootenv_confirm   # clear the trial state either way

    if [ "$active" = "$target" ]; then
        log "Rootfs update to slot $target confirmed"
        echo '{"status": "ok", "message": "rootfs update confirmed"}'
    else
        log "Rootfs update failed; system rolled back to slot $active"
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
