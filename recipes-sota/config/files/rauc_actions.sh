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
# bundle signature against /etc/rauc/keyring.pem, and (via RAUC's grub bootloader
# backend) arms that slot to boot next on trial. The running slot is read from
# the 'rauc.slot=A|B' kernel argument set by our grub.cfg.

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

    rm -f "${TARGET_STATE}"

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
