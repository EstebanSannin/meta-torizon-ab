#!/bin/sh
# greenboot green.d hook (imx8mp/U-Boot): on a healthy boot, reset the U-Boot
# boot-attempt counter so the current slot is considered good. aktualizr's
# complete-install clears 'upgrade_available'. Uses the real U-Boot env.
set -eu

# No '|| true': a failed write must show up as a failed green script, not be
# reported as SUCCESS while the bootcount keeps counting towards a rollback.
if command -v fw_setenv >/dev/null 2>&1; then
    fw_setenv bootcount 0
fi
