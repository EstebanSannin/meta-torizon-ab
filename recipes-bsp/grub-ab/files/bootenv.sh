# GRUB boot-env operations for the A/B rootfs handler (x86).
# Sourced by /usr/bin/swupdate_actions.sh; uses log/die/maybe_run from it.
# Operates on the shared grubenv (grub.cfg reads default/bootcount/bootlimit/
# upgrade_available; `default` 0 -> slot A, 1 -> slot B).

GRUBENV="${AB_GRUBENV:-/boot/efi/EFI/BOOT/grubenv}"
req_program "/usr/bin/grub-editenv" && alias GRUBEDITENV="$_"

_bootenv_label_to_index() {
    [ "$1" = "otaroot_a" ] && { echo 0; return 0; }
    [ "$1" = "otaroot_b" ] && { echo 1; return 0; }
    die "bootenv(grub): bad label '$1'"
}

# Arm the bootloader to boot the slot with fs-label $1 on trial.
bootenv_arm_trial() {
    local idx
    idx=$(_bootenv_label_to_index "$1")
    maybe_run GRUBEDITENV "$GRUBENV" set \
        default="$idx" upgrade_available="1" bootcount="0" ab_target="$1"
}

# Clear the trial state (mark the current boot good).
bootenv_confirm() {
    maybe_run GRUBEDITENV "$GRUBENV" set upgrade_available="0"
    maybe_run GRUBEDITENV "$GRUBENV" unset ab_target
}

# Echo the recorded trial-target label (empty if none pending).
bootenv_trial_target() {
    GRUBEDITENV "$GRUBENV" list 2>/dev/null | sed -Ene 's/^ab_target=(.*)$/\1/p'
}
