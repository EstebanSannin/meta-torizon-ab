#!/bin/sh
# greenboot green.d hook: the boot was declared healthy -> tell RAUC the booted
# slot is good. RAUC's u-boot backend resets the slot's BOOT_<slot>_LEFT counter
# and keeps it first in BOOT_ORDER, which is what stops the bootloader from
# rolling back on the next boot.
set -eu
rauc status mark-good
