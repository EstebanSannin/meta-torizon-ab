SUMMARY = "GRUB A/B environment bootstrap and rollback glue for Torizon OS A/B"
DESCRIPTION = "Creates the shared grubenv on first boot and resets the boot \
counter on a healthy boot (greenboot hook), complementing the A/B rollback \
logic in grub.cfg."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

# x86/GRUB only. This must NOT be a candidate on U-Boot machines (imx8mp), where
# uboot-ab provides torizon-ab-bootenv + the green.d hook — otherwise both get
# pulled to satisfy the virtual and their files conflict. (allarch + machine
# restriction don't mix, so use MACHINE_ARCH.)
PACKAGE_ARCH = "${MACHINE_ARCH}"
COMPATIBLE_MACHINE = "(genericx86-64|intel-corei7-64)"

SRC_URI = " \
    file://grubenv-create.sh \
    file://grubenv-create.service \
    file://00_reset_bootcount.sh \
    file://fw_printenv \
    file://fw_setenv \
    file://bootenv.sh \
"

# grub-editenv comes from grub-efi; greenboot provides the health-check hooks.
RDEPENDS:${PN} = "grub-efi greenboot bash"

SYSTEMD_SERVICE:${PN} = "grubenv-create.service"

# We provide fw_printenv/fw_setenv as grubenv wrappers so greenboot's stock
# rollback scripts work on x86. This conflicts with u-boot-fw-utils (not
# installed on x86), so declare it to avoid a packaging clash if it ever is.
RCONFLICTS:${PN} = "u-boot-fw-utils"
RREPLACES:${PN} = "u-boot-fw-utils"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/grubenv-create.sh ${D}${bindir}/grubenv-create.sh
    install -m 0755 ${WORKDIR}/fw_printenv ${D}${bindir}/fw_printenv
    install -m 0755 ${WORKDIR}/fw_setenv ${D}${bindir}/fw_setenv

    install -d ${D}${systemd_unitdir}/system
    install -m 0644 ${WORKDIR}/grubenv-create.service ${D}${systemd_unitdir}/system/grubenv-create.service

    install -d ${D}${sysconfdir}/greenboot/green.d
    install -m 0755 ${WORKDIR}/00_reset_bootcount.sh ${D}${sysconfdir}/greenboot/green.d/00_reset_bootcount.sh

    # Boot-env helper sourced by the rootfs action handler.
    install -d ${D}${libdir}/torizon-ab
    install -m 0644 ${WORKDIR}/bootenv.sh ${D}${libdir}/torizon-ab/bootenv.sh
}

FILES:${PN} = " \
    ${bindir}/grubenv-create.sh \
    ${bindir}/fw_printenv \
    ${bindir}/fw_setenv \
    ${systemd_unitdir}/system/grubenv-create.service \
    ${sysconfdir}/greenboot/green.d/00_reset_bootcount.sh \
    ${libdir}/torizon-ab/bootenv.sh \
"

# The action handler (aktualizr-default-sec) sources /usr/lib/torizon-ab/bootenv.sh.
RPROVIDES:${PN} += "torizon-ab-bootenv"
