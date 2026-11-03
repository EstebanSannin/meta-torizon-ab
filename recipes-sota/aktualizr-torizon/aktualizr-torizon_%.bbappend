# Reconfigure aktualizr-torizon for the A/B + SWUpdate variant.
#
# Build WITHOUT the OSTree package-manager backend: the primary is configured
# at runtime as [pacman] type = "none" (download + Uptane-verify only), and the
# actual OS rootfs update is applied by SWUpdate through a generic secondary
# (see aktualizr-rootfs-sec). This drops the libostree build/runtime dependency
# entirely.
#
# NOTE: only meaningful when building the torizon-ab distro; guarded so a shared
# sstate/build for other distros is unaffected.

PACKAGECONFIG:remove:torizon-ab = "ostree"
DEPENDS:remove:torizon-ab = "ostree"

# RAUC package manager (TORIZON_AB_PACMAN = "rauc", x86 only), not yet upstream.
SRC_URI:remove:torizon-ab-rauc:genericx86-64 = "gitsm://github.com/toradex/aktualizr.git;protocol=https;branch=toradex-master"
SRC_URI:prepend:torizon-ab-rauc:genericx86-64 = "gitsm://github.com/EstebanSannin/aktualizr.git;protocol=https;branch=feat/rauc-package-manager "
SRCREV:torizon-ab-rauc:genericx86-64 = "5a297f9de15f43bfec55aa824410a5edc2c88609"
PACKAGECONFIG[rauc] = "-DBUILD_RAUC=ON,-DBUILD_RAUC=OFF,systemd,"
PACKAGECONFIG:append:torizon-ab-rauc:genericx86-64 = " rauc"
