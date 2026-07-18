SUMMARY = "Keep the A/B rootfs slots out of the usermount automounter"
DESCRIPTION = "Torizon's usermount automounter (usermount-mounter) mounts any \
unmounted, labeled partition under /media unless its device node is listed in \
/etc/usermount/ignorelist. This recipe adds a boot-time oneshot that resolves \
the otaroot_a/otaroot_b labels to device nodes and adds them to that ignorelist \
before usermount runs, so SWUpdate can safely raw-write the inactive slot. \
Also ships a udisks2 UDISKS_IGNORE rule as a secondary hint."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd allarch

SRC_URI = " \
    file://99-torizon-ab-slots.rules \
    file://torizon-ab-slot-ignorelist \
    file://torizon-ab-slot-ignorelist.service \
"

RDEPENDS:${PN} = "usermount"

SYSTEMD_SERVICE:${PN} = "torizon-ab-slot-ignorelist.service"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/torizon-ab-slot-ignorelist ${D}${bindir}/torizon-ab-slot-ignorelist

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/torizon-ab-slot-ignorelist.service ${D}${systemd_system_unitdir}/torizon-ab-slot-ignorelist.service

    install -d ${D}${sysconfdir}/udev/rules.d
    install -m 0644 ${WORKDIR}/99-torizon-ab-slots.rules ${D}${sysconfdir}/udev/rules.d/99-torizon-ab-slots.rules
}

FILES:${PN} = " \
    ${bindir}/torizon-ab-slot-ignorelist \
    ${systemd_system_unitdir}/torizon-ab-slot-ignorelist.service \
    ${sysconfdir}/udev/rules.d/99-torizon-ab-slots.rules \
"
