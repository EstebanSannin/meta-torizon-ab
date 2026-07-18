#!/bin/bash
#
# Aktualizr Subsystem-Update action handler for the OS rootfs on an
# A/B (dual rootfs) + SWUpdate system, GRUB/x86 flavour.
#
# Contract (see Toradex "First Steps With Subsystem Updates"):
#   $1 = get-firmware-info | install | complete-install
#   env: SECONDARY_FIRMWARE_PATH, SECONDARY_FIRMWARE_SHA256, SECONDARY_CUSTOM_METADATA
#   stdout: JSON {"status": "ok|need-completion|failed", "message": "..."}
#   exit:  0 handled, 64 request-normal-processing, 65 request-error
#
# Model:
#   - Two rootfs partitions labelled otaroot_a / otaroot_b, each carrying its
#     own /boot (kernel + initramfs).
#   - The .swu payload is the full rootfs ext4 image; SWUpdate raw-writes it to
#     the INACTIVE slot (selected by SWUpdate mode slot_a / slot_b).
#   - GRUB env (grubenv) drives slot selection + rollback:
#       default            0 -> slot A entry, 1 -> slot B entry
#       upgrade_available  1 while a freshly-flashed slot is on trial
#       bootcount/bootlimit boot-attempt counter (GRUB rolls back when exceeded)
#       ab_target          label of the slot we just flashed (trial target)

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

# Path to the grubenv on the shared EFI partition (grub prefix = /EFI/BOOT,
# ESP mounted at /boot/efi). Must match grub.cfg's load_env/save_env location
# and the grub-ab grubenv-create service.
GRUBENV="${AB_GRUBENV:-/boot/efi/EFI/BOOT/grubenv}"

LABEL_A="otaroot_a"
LABEL_B="otaroot_b"

set -o pipefail

req_program "/usr/bin/grub-editenv" && alias GRUBEDITENV="$_"
req_program "/usr/bin/lsblk"        && alias LSBLK="$_"
req_program "/usr/bin/findmnt"      && alias FINDMNT="$_"
req_program "/usr/bin/swupdate"     && alias SWUPDATE="$_"
req_program "/usr/bin/touch"        && alias TOUCH="$_"

maybe_run() {
    if [ "$DRY_RUN" = "1" ]; then
        log "WOULD RUN:" "$@"; return 0
    fi
    log "RUN:" "$@"
    eval "$@"
}

# --- Slot helpers ------------------------------------------------------------

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

# $1: label -> output: grub 'default' index (A=0, B=1)
label_to_index() {
    [ "$1" = "$LABEL_A" ] && { echo "0"; return 0; }
    [ "$1" = "$LABEL_B" ] && { echo "1"; return 0; }
    die "Bad label '$1'"
}

# $1: label -> output: SWUpdate selection mode (slot_a|slot_b)
label_to_mode() {
    [ "$1" = "$LABEL_A" ] && { echo "slot_a"; return 0; }
    [ "$1" = "$LABEL_B" ] && { echo "slot_b"; return 0; }
    die "Bad label '$1'"
}

grubenv_get() {
    GRUBEDITENV "$GRUBENV" list 2>/dev/null | sed -Ene "s/^$1=(.*)$/\1/p"
}

# --- Actions -----------------------------------------------------------------

do_get_firmware_info() {
    # Let aktualizr determine the installed version from the target_name file it
    # keeps alongside the firmware (exit 64 = request normal processing), exactly
    # like the reference bl_actions.sh. Reporting a slot label here would not
    # match the pushed target name and could make a successful update look
    # not-applied. The active/installed slot is logged for debugging only.
    local active
    active=$(get_active_label 2>/dev/null) || active="unknown"
    log "get-firmware-info: running slot=$active (deferring to aktualizr)"
    exit 64
}

do_install() {
    before_dying 'on_install_failed'
    check_install_vars
    check_target_sha256

    local active inactive mode idx_new idx_old
    active=$(get_active_label)
    inactive=$(get_inactive_label "$active")
    mode=$(label_to_mode "$inactive")
    idx_new=$(label_to_index "$inactive")
    idx_old=$(label_to_index "$active")

    log "Installing rootfs update"
    log "Active slot:   $active (index $idx_old)"
    log "Inactive slot: $inactive (index $idx_new), swupdate mode=$mode"
    log "Payload:       $SECONDARY_FIRMWARE_PATH"

    # Defensive: make sure the inactive slot is NOT mounted before SWUpdate
    # raw-writes it (a udev rule keeps the automounter off it, but belt &
    # suspenders in case something mounted it).
    local inactive_dev="/dev/disk/by-label/${inactive}"
    if findmnt -rn -S "$inactive_dev" >/dev/null 2>&1; then
        log "Inactive slot $inactive is mounted; unmounting before write"
        maybe_run umount "$inactive_dev" || die "Could not unmount $inactive before write"
    fi

    # Write the .swu into the inactive slot. The sw-description inside the .swu
    # maps mode slot_a -> /dev/disk/by-label/otaroot_a and slot_b -> ...b.
    maybe_run SWUPDATE -v -i "$SECONDARY_FIRMWARE_PATH" -e "stable,$mode" \
        || die "SWUpdate failed writing slot $inactive"

    # Point GRUB at the freshly-flashed slot on trial.
    maybe_run GRUBEDITENV "$GRUBENV" set \
        default="$idx_new" \
        upgrade_available="1" \
        bootcount="0" \
        ab_prev="$idx_old" \
        ab_target="$inactive" \
        || die "Could not update grub environment"

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
    target=$(grubenv_get ab_target)

    log "complete-install: running slot=$active, trial target=$target"

    if [ -z "$target" ]; then
        # Nothing pending (e.g. handler invoked spuriously): normal processing.
        exit 64
    fi

    if [ "$active" = "$target" ]; then
        # We booted the new slot successfully. Confirm it: clear the trial flag.
        # Greenboot's health checks provide the deeper "is it healthy" gate.
        maybe_run GRUBEDITENV "$GRUBENV" set upgrade_available="0"
        maybe_run GRUBEDITENV "$GRUBENV" unset ab_target
        log "Rootfs update to slot $target confirmed"
        echo '{"status": "ok", "message": "rootfs update confirmed"}'
        return 0
    fi

    # We are NOT running the trial slot -> GRUB rolled us back. Report failure.
    maybe_run GRUBEDITENV "$GRUBENV" set upgrade_available="0"
    maybe_run GRUBEDITENV "$GRUBENV" unset ab_target
    log "Rootfs update failed; system rolled back to slot $active"
    echo '{"status": "failed", "message": "rootfs update failed; rolled back"}'
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
