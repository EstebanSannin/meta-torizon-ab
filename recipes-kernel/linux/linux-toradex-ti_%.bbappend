# RAUC requires the target kernel to mount the bundle's squashfs image at
# install time. Add squashfs (+ decompressors) and loop support for the RAUC
# A/B variant on the TI (Verdin AM62p) kernel — the counterpart of the
# linux-yocto bbappend used on x86. Scoped to the RAUC distro so the SWUpdate
# variant is unaffected.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append:torizon-ab-rauc = " file://rauc-squashfs.cfg"
