# RAUC requires the target kernel to mount the bundle's squashfs image at
# install time. Add squashfs (+ decompressors) and loop support for the RAUC
# A/B variant. (Harmless but unneeded for the SWUpdate variant, so scoped.)
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append:torizon-ab-rauc = " file://rauc-squashfs.cfg"
