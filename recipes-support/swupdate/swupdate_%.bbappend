# On-target SWUpdate configuration for the Torizon OS A/B variant.
#
# Enables the GRUB environment backend so SWUpdate and GRUB share one grubenv,
# and the handlers needed to raw-write an ext4 rootfs to a slot partition.
#
# REVIEW: meta-swupdate builds SWUpdate via kconfig. The fragment below is
# merged on top of the machine defconfig; confirm the option names against the
# SWUpdate version pulled by your meta-swupdate (scarthgap). Adjust as needed.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append:torizon-ab = " file://torizon-ab.cfg"

# Ensure the bootloader (GRUB) integration is compiled in.
PACKAGECONFIG:append:torizon-ab = " bootloader-grub"
