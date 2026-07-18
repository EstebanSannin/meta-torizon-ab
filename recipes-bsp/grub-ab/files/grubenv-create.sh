#!/bin/sh
# Create the shared grubenv with sane defaults on first boot if it is missing.
set -eu

GRUBENV="${GRUBENV:-/boot/efi/EFI/BOOT/grubenv}"

if [ ! -e "${GRUBENV}" ]; then
    grub-editenv "${GRUBENV}" set \
        default=0 \
        bootcount=0 \
        bootlimit=3 \
        upgrade_available=0
fi
