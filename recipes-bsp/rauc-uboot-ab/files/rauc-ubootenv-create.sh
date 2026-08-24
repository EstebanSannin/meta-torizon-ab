#!/bin/sh
# Seed RAUC's A/B boot-selection variables into the U-Boot environment on first
# boot if they are missing. Slot A is the factory-good slot.
#   BOOT_ORDER        slot boot priority (bootnames, space-separated)
#   BOOT_<slot>_LEFT  remaining boot attempts for a slot on trial
# RAUC's 'uboot' backend maintains these afterwards; the boot.scr consumes them.
set -eu

# fw_printenv returns non-zero if the var is unset.
if ! fw_printenv BOOT_ORDER >/dev/null 2>&1; then
    fw_setenv BOOT_ORDER "A B"
    fw_setenv BOOT_A_LEFT 3
    fw_setenv BOOT_B_LEFT 0
fi
