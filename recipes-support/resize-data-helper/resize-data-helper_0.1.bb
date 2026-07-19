SUMMARY = "Grow the A/B data partition to fill the storage medium on first boot"
DESCRIPTION = "First-boot helper that expands the last (data) partition and its \
ext4 filesystem to fill the whole eMMC/SD/NVMe/disk, so a small flashed .wic \
uses all available space at runtime. Machine-agnostic (x86, Verdin, ...). \
Adapted from Toradex's resize-helper, retargeted to the data partition."
LICENSE = "BSD-2-Clause"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/BSD-2-Clause;md5=cb641bc04cda31daea161b1bc15da69f"

inherit allarch systemd

RDEPENDS:${PN} += "e2fsprogs-resize2fs gptfdisk util-linux-fdisk util-linux-blockdev util-linux-partx"

SRC_URI = " \
    file://resize-data-helper \
    file://resize-data-helper.service \
"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/resize-data-helper ${D}${sbindir}/resize-data-helper

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/resize-data-helper.service ${D}${systemd_system_unitdir}/resize-data-helper.service
}

FILES:${PN} = " \
    ${sbindir}/resize-data-helper \
    ${systemd_system_unitdir}/resize-data-helper.service \
"

SYSTEMD_SERVICE:${PN} = "resize-data-helper.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"
