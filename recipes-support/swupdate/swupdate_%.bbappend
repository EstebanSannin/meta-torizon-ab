# On-target SWUpdate configuration for the Torizon OS A/B variant.
#
# SWUpdate in meta-swupdate is configured purely via kconfig fragments (.cfg
# files in SRC_URI), NOT via PACKAGECONFIG. The fragment selects BOOTLOADER_NONE
# so SWUpdate does not pull libubootenv (U-Boot env), which is unbuildable on
# x86. Our A/B slot flip is done by swupdate_actions.sh via grub-editenv.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append:torizon-ab = " file://torizon-ab.cfg"

# The A/B update path runs SWUpdate as a one-shot CLI from the aktualizr action
# handler (swupdate_actions.sh: swupdate -i); nothing uses the daemon. Keep it
# and its socket off: meta-swupdate ships the daemon Type=notify, which without
# CONFIG_SYSTEMD times out at boot and leaves the system degraded, and an idle
# install-control socket is attack surface we don't need.
SYSTEMD_AUTO_ENABLE:${PN}:torizon-ab = "disable"
