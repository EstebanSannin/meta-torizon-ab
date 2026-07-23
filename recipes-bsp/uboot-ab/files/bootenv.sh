# U-Boot boot-env operations for the A/B rootfs handler (imx8mp / U-Boot).
# Sourced by /usr/bin/swupdate_actions.sh; uses log/die/maybe_run from it.
# Uses the REAL U-Boot environment via fw_setenv/fw_printenv (libubootenv),
# stored in the eMMC boot0 HW partition per /etc/fw_env.config. The U-Boot boot
# script (boot.scr) reads `rootfs_slot` and the stock bootcount/bootlimit/
# upgrade_available/rollback vars.

req_program "/usr/bin/fw_setenv"   && alias FW_SETENV="$_"
req_program "/usr/bin/fw_printenv" && alias FW_PRINTENV="$_"

_bootenv_label_to_slot() {
    [ "$1" = "otaroot_a" ] && { echo a; return 0; }
    [ "$1" = "otaroot_b" ] && { echo b; return 0; }
    die "bootenv(uboot): bad label '$1'"
}

# Arm the bootloader to boot the slot with fs-label $1 on trial.
bootenv_arm_trial() {
    local slot
    slot=$(_bootenv_label_to_slot "$1")
    maybe_run FW_SETENV rootfs_slot "$slot"
    maybe_run FW_SETENV upgrade_available 1
    maybe_run FW_SETENV bootcount 0
    maybe_run FW_SETENV ab_target "$1"
}

# Clear the trial state (mark the current boot good).
bootenv_confirm() {
    maybe_run FW_SETENV upgrade_available 0
    # empty value clears it (fw_setenv NAME with no value unsets)
    maybe_run FW_SETENV ab_target
}

# Echo the recorded trial-target label (empty if none pending).
bootenv_trial_target() {
    FW_PRINTENV ab_target 2>/dev/null | sed -Ene 's/^ab_target=(.*)$/\1/p'
}
