#!/bin/sh
# greenboot green.d hook: the boot was declared healthy -> tell RAUC the booted
# slot is good (clears its _TRY and sets _OK=1 via RAUC's grub backend). This is
# what prevents the bootloader from rolling back on the next boot.
set -eu
rauc status mark-good
