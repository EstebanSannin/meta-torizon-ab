SUMMARY = "Automatic reboot when an update requests it (/run/need-reboot)"
DESCRIPTION = "OSTree-free equivalent of ostree-pending-reboot: a systemd path \
unit that watches /run/need-reboot (touched by aktualizr's reboot_command and \
by swupdate_actions.sh) and reboots. In stock Torizon this ships with the \
OSTree recipe, which the A/B variant excludes."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd allarch

SRC_URI = " \
    file://torizon-ab-pending-reboot.path \
    file://torizon-ab-pending-reboot.service \
"

SYSTEMD_SERVICE:${PN} = "torizon-ab-pending-reboot.path torizon-ab-pending-reboot.service"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/torizon-ab-pending-reboot.path ${D}${systemd_system_unitdir}/torizon-ab-pending-reboot.path
    install -m 0644 ${WORKDIR}/torizon-ab-pending-reboot.service ${D}${systemd_system_unitdir}/torizon-ab-pending-reboot.service
}

FILES:${PN} = " \
    ${systemd_system_unitdir}/torizon-ab-pending-reboot.path \
    ${systemd_system_unitdir}/torizon-ab-pending-reboot.service \
"
