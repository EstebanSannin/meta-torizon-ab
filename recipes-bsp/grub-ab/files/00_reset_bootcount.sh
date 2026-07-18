#!/bin/sh
# greenboot green.d hook: runs when the boot is declared healthy.
# Reset the trial boot counter so the current slot is considered good.
# (aktualizr's complete-install clears 'upgrade_available' on confirmation.)
set -eu

GRUBENV="${GRUBENV:-/boot/efi/EFI/BOOT/grubenv}"

if [ -e "${GRUBENV}" ]; then
    grub-editenv "${GRUBENV}" set bootcount=0
fi
