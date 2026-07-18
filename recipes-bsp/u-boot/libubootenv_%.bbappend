# meta-toradex-bsp-common's libubootenv bbappend adds
#   RRECOMMENDS:${PN} += "u-boot-default-env"
# assuming a U-Boot target. On x86 (the torizon-ab variant) there is no U-Boot
# and nothing provides u-boot-default-env, so this breaks dependency resolution
# for anything that pulls libubootenv (e.g. swupdate, whose swupdate.inc has an
# unconditional DEPENDS on libubootenv).
#
# Drop the recommendation for our distro only (other distros built from the same
# layers checkout, e.g. the U-Boot-based Torizon OSTree build, are unaffected).
RRECOMMENDS:${PN}:remove:torizon-ab = "u-boot-default-env"
