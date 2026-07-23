#!/bin/sh
# greenboot green.d hook (imx8mp/U-Boot): on a healthy boot, reset the U-Boot
# boot-attempt counter so the current slot is considered good. aktualizr's
# complete-install clears 'upgrade_available'. Uses the real U-Boot env.
set -eu

if command -v fw_setenv >/dev/null 2>&1; then
    fw_setenv bootcount 0 || true
fi
