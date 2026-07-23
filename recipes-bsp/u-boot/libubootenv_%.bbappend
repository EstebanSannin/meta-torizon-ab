# meta-toradex-bsp-common's libubootenv bbappend adds
#   RRECOMMENDS:${PN} += "u-boot-default-env"
# assuming a U-Boot target. On x86 (the torizon-ab variant) there is no U-Boot
# and nothing provides u-boot-default-env, so this breaks dependency resolution
# for anything that pulls libubootenv (e.g. swupdate, whose swupdate.inc has an
# unconditional DEPENDS on libubootenv).
#
# Drop the recommendation on the x86 machines ONLY (they have no U-Boot, so
# nothing provides u-boot-default-env). On U-Boot machines (e.g. verdin-imx8mp)
# u-boot-default-env IS provided by u-boot-toradex, so leave it intact there.
RRECOMMENDS:${PN}:remove:genericx86-64   = "u-boot-default-env"
RRECOMMENDS:${PN}:remove:intel-corei7-64 = "u-boot-default-env"
