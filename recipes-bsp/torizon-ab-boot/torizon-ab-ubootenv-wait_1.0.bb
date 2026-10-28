SUMMARY = "Make greenboot wait for the U-Boot env device"
DESCRIPTION = "greenboot runs its green.d/red.d scripts at boot-complete.target, \
which can come before udev has created the U-Boot env device named in \
/etc/fw_env.config (e.g. /dev/emmc-boot0). libubootenv then fails and the boot \
bookkeeping (bootcount reset, trial confirmation) is silently lost. This adds a \
drop-in to both greenboot task runners that waits for that device first; \
rauc-uboot-ab's env seeding unit uses the same wait. Shared by both U-Boot \
backends (uboot-ab, rauc-uboot-ab); no per-machine data."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://wait-ubootenv \
    file://10-wait-ubootenv.conf \
"

RDEPENDS:${PN} = "udev greenboot"

do_install() {
    install -d ${D}${libexecdir}/torizon-ab
    install -m 0755 ${UNPACKDIR}/wait-ubootenv ${D}${libexecdir}/torizon-ab/wait-ubootenv

    for unit in greenboot-task-runner redboot-task-runner; do
        install -d ${D}${systemd_system_unitdir}/${unit}.service.d
        install -m 0644 ${UNPACKDIR}/10-wait-ubootenv.conf \
            ${D}${systemd_system_unitdir}/${unit}.service.d/10-wait-ubootenv.conf
    done
}

FILES:${PN} = " \
    ${libexecdir}/torizon-ab/wait-ubootenv \
    ${systemd_system_unitdir}/greenboot-task-runner.service.d \
    ${systemd_system_unitdir}/redboot-task-runner.service.d \
"
