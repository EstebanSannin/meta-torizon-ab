SUMMARY = "RAUC GRUB A/B bootstrap + greenboot health confirmation (x86)"
DESCRIPTION = "Creates the shared grubenv with RAUC's boot-selection variables \
(ORDER / <bootname>_OK / <bootname>_TRY) on first boot, and confirms a healthy \
boot to RAUC via a greenboot green.d hook (rauc status mark-good). The A/B \
boot-selection and rollback logic itself lives in wic/grub-rauc.cfg."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

# x86/GRUB only (RAUC 'grub' bootloader backend).
PACKAGE_ARCH = "${MACHINE_ARCH}"
COMPATIBLE_MACHINE = "(genericx86-64|intel-corei7-64)"

SRC_URI = " \
    file://grubenv-create.sh \
    file://grubenv-create.service \
    file://00_rauc_mark_good.sh \
"

# grub-editenv from grub-efi; rauc for mark-good; greenboot for the hook dir;
# grubenv-fw-utils so greenboot's red path sees the trial flag the RAUC action
# handler sets (otherwise a failed trial is never rebooted, so never rolled back).
RDEPENDS:${PN} = "grub-efi rauc greenboot bash grubenv-fw-utils"

SYSTEMD_SERVICE:${PN} = "grubenv-create.service"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${UNPACKDIR}/grubenv-create.sh ${D}${bindir}/rauc-grubenv-create.sh

    install -d ${D}${systemd_unitdir}/system
    install -m 0644 ${UNPACKDIR}/grubenv-create.service ${D}${systemd_unitdir}/system/grubenv-create.service

    install -d ${D}${sysconfdir}/greenboot/green.d
    install -m 0755 ${UNPACKDIR}/00_rauc_mark_good.sh ${D}${sysconfdir}/greenboot/green.d/00_rauc_mark_good.sh
}

FILES:${PN} = " \
    ${bindir}/rauc-grubenv-create.sh \
    ${systemd_unitdir}/system/grubenv-create.service \
    ${sysconfdir}/greenboot/green.d/00_rauc_mark_good.sh \
"
