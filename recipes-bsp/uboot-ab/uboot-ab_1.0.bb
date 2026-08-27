SUMMARY = "U-Boot A/B boot script + boot-env glue for Torizon OS A/B (SWUpdate)"
DESCRIPTION = "The U-Boot counterpart of grub-ab for the SWUpdate backend. \
Provides the A/B boot script (SWUpdate bootcount/rootfs_slot slot-selection \
preamble + the shared metadata-driven kernel-load body, see \
recipes-bsp/torizon-ab-boot), the bootenv.sh helper the rootfs action handler \
sources (arm/confirm trials via the real U-Boot env), and a greenboot green.d \
hook to reset the boot counter. Rolls back via the stock U-Boot \
bootcount/bootlimit mechanism. No per-machine boot data (the body delegates to \
KERNEL_* metadata + the board's U-Boot env); see docs/uboot-rauc-porting.md."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# Shared boot-script assembly (do_compile: [preamble]+[body] -> boot.scr; do_deploy).
require recipes-bsp/torizon-ab-boot/torizon-ab-bootscr.inc
BOOT_PREAMBLE = "boot-select-swupdate.cmd"

inherit systemd

COMPATIBLE_MACHINE = "verdin-am62p|verdin-imx8mp"
PACKAGE_ARCH = "${MACHINE_ARCH}"

# fw_setenv/fw_printenv (real U-Boot env) at runtime; greenboot hooks.
RDEPENDS:${PN} = "libubootenv-bin greenboot"

# The action handler (aktualizr-default-sec) sources /usr/lib/torizon-ab/bootenv.sh.
RPROVIDES:${PN} += "torizon-ab-bootenv"

SRC_URI += " \
    file://boot-select-swupdate.cmd \
    file://bootenv.sh \
    file://00_reset_bootcount.sh \
"

do_install() {
    # boot.scr goes into the FAT boot partition (shared slot SELECTOR; staged by
    # the wks). Installing it into the rootfs /boot too keeps it with the payload.
    install -d ${D}/boot
    install -m 0644 ${WORKDIR}/boot.scr ${D}/boot/boot.scr

    install -d ${D}${libdir}/torizon-ab
    install -m 0644 ${WORKDIR}/bootenv.sh ${D}${libdir}/torizon-ab/bootenv.sh

    install -d ${D}${sysconfdir}/greenboot/green.d
    install -m 0755 ${WORKDIR}/00_reset_bootcount.sh ${D}${sysconfdir}/greenboot/green.d/00_reset_bootcount.sh
}

FILES:${PN} = " \
    /boot/boot.scr \
    ${libdir}/torizon-ab/bootenv.sh \
    ${sysconfdir}/greenboot/green.d/00_reset_bootcount.sh \
"
