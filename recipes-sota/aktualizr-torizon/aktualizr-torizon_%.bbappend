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
