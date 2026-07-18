SUMMARY = "GRUB A/B environment bootstrap and rollback glue for Torizon OS A/B"
DESCRIPTION = "Creates the shared grubenv on first boot and resets the boot \
counter on a healthy boot (greenboot hook), complementing the A/B rollback \
logic in grub.cfg."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd allarch

SRC_URI = " \
    file://grubenv-create.sh \
    file://grubenv-create.service \
    file://00_reset_bootcount.sh \
"

# grub-editenv comes from grub-efi; greenboot provides the health-check hooks.
RDEPENDS:${PN} = "grub-efi greenboot"

SYSTEMD_SERVICE:${PN} = "grubenv-create.service"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/grubenv-create.sh ${D}${bindir}/grubenv-create.sh

    install -d ${D}${systemd_unitdir}/system
    install -m 0644 ${WORKDIR}/grubenv-create.service ${D}${systemd_unitdir}/system/grubenv-create.service

    install -d ${D}${sysconfdir}/greenboot/green.d
    install -m 0755 ${WORKDIR}/00_reset_bootcount.sh ${D}${sysconfdir}/greenboot/green.d/00_reset_bootcount.sh
}

FILES:${PN} = " \
    ${bindir}/grubenv-create.sh \
    ${systemd_unitdir}/system/grubenv-create.service \
    ${sysconfdir}/greenboot/green.d/00_reset_bootcount.sh \
"
