# meta-torizon-bsp applies 0001-rules-whitelist-hd-devices.patch on
# genericx86-64, but its context predates systemd 259 and no longer applies
# (do_patch fails). Swap in the same change rebased onto systemd 259.
# Drop this once meta-torizon-bsp carries a rebased patch.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:remove:genericx86-64 = "file://0001-rules-whitelist-hd-devices.patch"
SRC_URI:append:genericx86-64 = " file://0001-rules-whitelist-hd-devices-systemd259.patch"
