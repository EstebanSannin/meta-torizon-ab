SUMMARY = "RAUC U-Boot A/B bootstrap + boot script + greenboot health (generalized)"
DESCRIPTION = "The U-Boot counterpart of rauc-grub-ab, generalized across U-Boot \
RAUC machines. Provides: the A/B boot script (boot.scr) that selects the rootfs \
slot from RAUC's U-Boot-env variables (BOOT_ORDER + BOOT_<slot>_LEFT), resolves \
the slot partition by GPT label at runtime, and rolls back when a slot's attempts \
run out; a first-boot bootstrap that seeds those variables via fw_setenv if \
absent; and a greenboot green.d hook that confirms a healthy boot to RAUC (rauc \
status mark-good). The boot script owns ONLY slot selection and delegates the \
kernel load to stable machine/kernel metadata (KERNEL_IMAGETYPE / KERNEL_DTB_PREFIX \
/ KERNEL_BOOTCMD) plus the board's own U-Boot env (mmc device, carrier fdtfile, \
load addresses, booti auto-decompression) -- so there is NO per-machine boot data. \
See docs/uboot-rauc-porting.md."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd deploy

# U-Boot RAUC machines. Adding a new one is usually just this line (the boot
# script needs no per-machine data); see docs/uboot-rauc-porting.md.
COMPATIBLE_MACHINE = "verdin-am62p|verdin-imx8mp"
PACKAGE_ARCH = "${MACHINE_ARCH}"

# mkimage (build host) to compile boot.cmd -> boot.scr.
DEPENDS = "u-boot-tools-native"
# fw_setenv/fw_printenv (real U-Boot env) at runtime; rauc for mark-good; greenboot.
RDEPENDS:${PN} = "libubootenv-bin rauc greenboot bash"

SYSTEMD_SERVICE:${PN} = "rauc-ubootenv-create.service"

# NOTE: /etc/fw_env.config is provided by the BSP's libubootenv0 (pulled in via
# libubootenv-bin) and already points at the machine's real U-Boot env (am62p:
# mmcblk0boot0@0x680000; imx8mp: /dev/emmc-boot0@-0x2200). We deliberately do NOT
# ship our own to avoid a file conflict — the env location is BSP-owned data, not
# something this layer hardcodes. RAUC's uboot backend and fw_setenv share it.
SRC_URI = " \
    file://boot.cmd \
    file://rauc-ubootenv-create.sh \
    file://rauc-ubootenv-create.service \
    file://00_rauc_mark_good.sh \
"

# Arch-appropriate kernel boot command (mirrors u-boot-distro-boot).
KERNEL_BOOTCMD ??= "bootz"
KERNEL_BOOTCMD:aarch64 = "booti"

# boot.cmd is templated on STABLE machine/kernel metadata only -- no per-machine
# boot data. KERNEL_IMAGETYPE + KERNEL_DTB_PREFIX come from the machine/kernel
# recipe; the rest is resolved at runtime from the board's U-Boot env.
do_compile() {
    if [ -z "${KERNEL_IMAGETYPE}" ] || [ -z "${KERNEL_DTB_PREFIX}" ]; then
        bbfatal "rauc-uboot-ab: KERNEL_IMAGETYPE / KERNEL_DTB_PREFIX unset for ${MACHINE}; these come from the machine/kernel metadata (see docs/uboot-rauc-porting.md)."
    fi
    sed -e 's|@@KERNEL_IMAGETYPE@@|${KERNEL_IMAGETYPE}|g' \
        -e 's|@@KERNEL_DTB_PREFIX@@|${KERNEL_DTB_PREFIX}|g' \
        -e 's|@@KERNEL_BOOTCMD@@|${KERNEL_BOOTCMD}|g' \
        ${WORKDIR}/boot.cmd > ${WORKDIR}/boot.cmd.resolved

    # arm64 for the current aarch64 targets; parameterize if a 32-bit target appears.
    uboot-mkimage -A arm64 -O linux -T script -C none \
        -n "Torizon A/B RAUC boot" -d ${WORKDIR}/boot.cmd.resolved ${WORKDIR}/boot.scr
}

do_install() {
    # boot.scr goes into the FAT boot partition (shared, not per-slot): it is the
    # slot SELECTOR. The wks stages it there; installing it into the rootfs /boot
    # as well keeps it with the payload for reference/regeneration.
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

# Also deploy boot.scr to DEPLOY_DIR_IMAGE so the wks (bootimg-partition) can
# stage it into the FAT boot partition — this A/B boot.scr is the slot SELECTOR
# that U-Boot's bootflow/script bootmeth runs.
do_deploy() {
    install -d ${DEPLOYDIR}
    install -m 0644 ${WORKDIR}/boot.scr ${DEPLOYDIR}/boot.scr
}
addtask deploy after do_compile before do_build
