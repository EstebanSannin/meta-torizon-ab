SUMMARY = "RAUC U-Boot A/B bootstrap + boot script + greenboot health (generalized)"
DESCRIPTION = "The U-Boot counterpart of rauc-grub-ab. Provides the A/B boot \
script (RAUC BOOT_ORDER slot-selection preamble + the shared metadata-driven \
kernel-load body, see recipes-bsp/torizon-ab-boot), a first-boot bootstrap that \
seeds BOOT_ORDER / BOOT_<slot>_LEFT via fw_setenv, and a greenboot green.d hook \
that confirms a healthy boot to RAUC (rauc status mark-good). RAUC's 'uboot' \
bootloader backend reads/writes the same variables. No per-machine boot data \
(the body delegates to KERNEL_* metadata + the board's U-Boot env); see \
docs/uboot-rauc-porting.md."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# Shared boot-script assembly (do_compile: [preamble]+[body] -> boot.scr; do_deploy).
require recipes-bsp/torizon-ab-boot/torizon-ab-bootscr.inc
BOOT_PREAMBLE = "boot-select-rauc.cmd"

inherit systemd

# U-Boot RAUC machines. Adding a new one is usually just this line (the boot
# script needs no per-machine data); see docs/uboot-rauc-porting.md.
COMPATIBLE_MACHINE = "verdin-am62p|verdin-imx8mp"
PACKAGE_ARCH = "${MACHINE_ARCH}"

# fw_setenv/fw_printenv (real U-Boot env) at runtime; rauc for mark-good; greenboot.
RDEPENDS:${PN} = "libubootenv-bin rauc greenboot bash"

SYSTEMD_SERVICE:${PN} = "rauc-ubootenv-create.service"

# NOTE: /etc/fw_env.config is provided by the BSP's libubootenv0 (pulled in via
# libubootenv-bin) and already points at the machine's real U-Boot env (am62p:
# mmcblk0boot0@0x680000; imx8mp: /dev/emmc-boot0@-0x2200). We deliberately do NOT
# ship our own to avoid a file conflict -- the env location is BSP-owned data.
SRC_URI += " \
    file://boot-select-rauc.cmd \
    file://rauc-ubootenv-create.sh \
    file://rauc-ubootenv-create.service \
    file://00_rauc_mark_good.sh \
"

do_install() {
    # boot.scr goes into the FAT boot partition (shared slot SELECTOR; staged by
    # the wks). Installing it into the rootfs /boot too keeps it with the payload.
    install -d ${D}/boot
    install -m 0644 ${WORKDIR}/boot.scr ${D}/boot/boot.scr

    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/rauc-ubootenv-create.sh ${D}${bindir}/rauc-ubootenv-create.sh

    install -d ${D}${systemd_unitdir}/system
    install -m 0644 ${WORKDIR}/rauc-ubootenv-create.service ${D}${systemd_unitdir}/system/rauc-ubootenv-create.service

    install -d ${D}${sysconfdir}/greenboot/green.d
    install -m 0755 ${WORKDIR}/00_rauc_mark_good.sh ${D}${sysconfdir}/greenboot/green.d/00_rauc_mark_good.sh
}

FILES:${PN} = " \
    /boot/boot.scr \
    ${bindir}/rauc-ubootenv-create.sh \
    ${systemd_unitdir}/system/rauc-ubootenv-create.service \
    ${sysconfdir}/greenboot/green.d/00_rauc_mark_good.sh \
"
