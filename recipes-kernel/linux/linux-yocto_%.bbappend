# RAUC requires the target kernel to mount the bundle's squashfs image at
# install time. Add squashfs (+ decompressors) and loop support for the RAUC
# A/B variant. (Harmless but unneeded for the SWUpdate variant, so scoped.)
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append:torizon-ab-rauc = " file://rauc-squashfs.cfg"

# meta-torizon-bsp's linux-torizon.inc sets CONFIG_KERNEL_LZ4 (torizon.cfg) for
# linux-yocto but declares lz4-native only for linux-intel, so the bzImage
# compression step fails with "lz4: not found". Drop once upstream adds it.
DEPENDS:append = " lz4-native"
