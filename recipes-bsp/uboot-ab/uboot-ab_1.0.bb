SUMMARY = "U-Boot A/B boot script + boot-env glue for Torizon OS A/B (imx8mp)"
DESCRIPTION = "The U-Boot counterpart of grub-ab: a boot.scr that selects the \
rootfs slot (a/b) and rolls back via the stock bootcount/bootlimit mechanism, \
plus the bootenv.sh helper the rootfs action handler sources (real U-Boot env \
via fw_setenv) and a greenboot green.d hook to reset the boot counter. \
DRAFT — the boot script needs bring-up iteration on real hardware."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

COMPATIBLE_MACHINE = "verdin-imx8mp"
PACKAGE_ARCH = "${MACHINE_ARCH}"

# mkimage (build host) to compile boot.cmd -> boot.scr.
DEPENDS = "u-boot-tools-native"
# fw_setenv/fw_printenv (real U-Boot env) at runtime; greenboot hooks.
RDEPENDS:${PN} = "u-boot-fw-utils greenboot"

# The action handler (aktualizr-default-sec) sources /usr/lib/torizon-ab/bootenv.sh.
RPROVIDES:${PN} += "torizon-ab-bootenv"

SRC_URI = " \
    file://boot.cmd \
    file://bootenv.sh \
    file://00_reset_bootcount.sh \
"

do_compile() {
    uboot-mkimage -A arm64 -O linux -T script -C none \
        -n "Torizon A/B boot" -d ${WORKDIR}/boot.cmd ${WORKDIR}/boot.scr
}

do_install() {
    # boot.scr lives in each rootfs slot's /boot (the board's U-Boot scans it).
    # REVIEW: confirm on hardware where the board's U-Boot looks for boot.scr.
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
