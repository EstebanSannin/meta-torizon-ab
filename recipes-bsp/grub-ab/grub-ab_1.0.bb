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
    file://fw_printenv \
    file://fw_setenv \
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
}

FILES:${PN} = " \
    ${bindir}/grubenv-create.sh \
    ${bindir}/fw_printenv \
    ${bindir}/fw_setenv \
    ${systemd_unitdir}/system/grubenv-create.service \
    ${sysconfdir}/greenboot/green.d/00_reset_bootcount.sh \
"
