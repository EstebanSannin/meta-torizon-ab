#!/bin/sh
# Create the shared grubenv with RAUC's A/B boot-selection defaults on first
# boot if it is missing. Slot A is the factory-good slot.
#   ORDER          slot boot priority (bootnames)
#   <name>_OK      slot is known-good
#   <name>_TRY     boot attempts of a slot currently on trial
set -eu

GRUBENV="${GRUBENV:-/boot/efi/EFI/BOOT/grubenv}"

if [ ! -e "${GRUBENV}" ]; then
    grub-editenv "${GRUBENV}" set \
        ORDER="A B" \
        A_OK=1 A_TRY=0 \
        B_OK=0 B_TRY=0
fi
