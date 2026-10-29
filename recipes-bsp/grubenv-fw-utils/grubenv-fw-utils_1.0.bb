SUMMARY = "fw_printenv/fw_setenv emulation on the GRUB environment (x86)"
DESCRIPTION = "U-Boot-style fw_printenv/fw_setenv wrappers over the shared \
grubenv, so greenboot's stock rollback scripts (redboot-auto-reboot, the \
U-Boot variable cleanup) and the action handlers can read and set the \
'upgrade_available' trial flag on x86, which has no U-Boot environment."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# x86/GRUB only: on U-Boot machines the real tools (libubootenv) provide these.
PACKAGE_ARCH = "${MACHINE_ARCH}"
COMPATIBLE_MACHINE = "(genericx86-64|intel-corei7-64)"

SRC_URI = " \
    file://fw_printenv \
    file://fw_setenv \
"

RDEPENDS:${PN} = "grub-efi bash"

# Same file names as the U-Boot tools (never installed on x86).
RCONFLICTS:${PN} = "u-boot-fw-utils"
RREPLACES:${PN} = "u-boot-fw-utils"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${UNPACKDIR}/fw_printenv ${D}${bindir}/fw_printenv
    install -m 0755 ${UNPACKDIR}/fw_setenv ${D}${bindir}/fw_setenv
}

FILES:${PN} = "${bindir}/fw_printenv ${bindir}/fw_setenv"
