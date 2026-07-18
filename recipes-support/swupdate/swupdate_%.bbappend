# On-target SWUpdate configuration for the Torizon OS A/B variant.
#
# SWUpdate in meta-swupdate is configured purely via kconfig fragments (.cfg
# files in SRC_URI), NOT via PACKAGECONFIG. The fragment selects BOOTLOADER_NONE
# so SWUpdate does not pull libubootenv (U-Boot env), which is unbuildable on
# x86. Our A/B slot flip is done by swupdate_actions.sh via grub-editenv.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append:torizon-ab = " file://torizon-ab.cfg"
