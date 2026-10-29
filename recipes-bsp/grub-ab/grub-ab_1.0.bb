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
    file://bootenv.sh \
"

# grub-editenv comes from grub-efi; greenboot provides the health-check hooks;
# grubenv-fw-utils lets greenboot's stock rollback scripts work on x86.
RDEPENDS:${PN} = "grub-efi greenboot bash grubenv-fw-utils"

SYSTEMD_SERVICE:${PN} = "grubenv-create.service"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${UNPACKDIR}/grubenv-create.sh ${D}${bindir}/grubenv-create.sh

    install -d ${D}${systemd_unitdir}/system
    install -m 0644 ${UNPACKDIR}/grubenv-create.service ${D}${systemd_unitdir}/system/grubenv-create.service

    install -d ${D}${sysconfdir}/greenboot/green.d
    install -m 0755 ${UNPACKDIR}/00_reset_bootcount.sh ${D}${sysconfdir}/greenboot/green.d/00_reset_bootcount.sh

    # Boot-env helper sourced by the rootfs action handler.
    install -d ${D}${libdir}/torizon-ab
    install -m 0644 ${UNPACKDIR}/bootenv.sh ${D}${libdir}/torizon-ab/bootenv.sh
}

FILES:${PN} = " \
    ${bindir}/grubenv-create.sh \
    ${systemd_unitdir}/system/grubenv-create.service \
    ${sysconfdir}/greenboot/green.d/00_reset_bootcount.sh \
    ${libdir}/torizon-ab/bootenv.sh \
"

# The action handler (aktualizr-default-sec) sources /usr/lib/torizon-ab/bootenv.sh.
RPROVIDES:${PN} += "torizon-ab-bootenv"
