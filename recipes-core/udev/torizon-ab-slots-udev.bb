SUMMARY = "udev rule to keep the A/B rootfs slots from being auto-mounted"
DESCRIPTION = "Marks the otaroot_a/otaroot_b partitions with UDISKS_IGNORE so \
Torizon's usermount/udisks2 automounter leaves them alone. SWUpdate raw-writes \
the inactive slot, so it must never be mounted."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit allarch

SRC_URI = "file://99-torizon-ab-slots.rules"

do_install() {
    install -d ${D}${sysconfdir}/udev/rules.d
    install -m 0644 ${WORKDIR}/99-torizon-ab-slots.rules ${D}${sysconfdir}/udev/rules.d/99-torizon-ab-slots.rules
}

FILES:${PN} = "${sysconfdir}/udev/rules.d/99-torizon-ab-slots.rules"
