# Shared assembly of the U-Boot A/B boot script: [backend preamble] + [shared body].
#
# Required by both backends' recipes (rauc-uboot-ab, uboot-ab). The kernel-load
# body is identical across backends and delegates to stable metadata; only the
# slot-selection preamble differs (RAUC BOOT_ORDER vs SWUpdate bootcount). Each
# including recipe sets BOOT_PREAMBLE to its preamble filename and adds it to
# SRC_URI. See docs/uboot-rauc-porting.md.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://boot-body.cmd"

DEPENDS += "u-boot-tools-native"

# Arch-appropriate kernel boot command (mirrors u-boot-distro-boot).
KERNEL_BOOTCMD ??= "bootz"
KERNEL_BOOTCMD:aarch64 = "booti"

# BOOT_PREAMBLE: the backend's slot-selection fragment (in the recipe's own files/).
BOOT_PREAMBLE ??= ""

# Carrier device-tree file baked into the boot script (U-Boot carrier auto-detect
# is unreliable -- see boot-body.cmd). Defaults to the machine's UBOOT_DTB_NAME;
# set per DEPLOYMENT to your actual carrier. This is the one genuinely
# per-board-instance value; everything else is metadata. See docs/uboot-rauc-porting.md.
TORIZON_AB_FDTFILE ??= "${UBOOT_DTB_NAME}"
# Verdin iMX8MP dev boards here are on the Dahlia carrier.
TORIZON_AB_FDTFILE:verdin-imx8mp = "imx8mp-verdin-wifi-dahlia.dtb"
# Verdin AM62P WB here is on the Yavia carrier. (UBOOT_DTB_NAME is empty on am62p,
# and stock U-Boot carrier auto-detect returns -dev; the stock am62p boot.scr
# likewise hardcodes this. Set to your carrier when deploying elsewhere.)
TORIZON_AB_FDTFILE:verdin-am62p = "k3-am62p5-verdin-wifi-yavia.dtb"

# Assemble [preamble]+[body], substitute the stable metadata, compile to boot.scr.
# No per-machine boot data: KERNEL_IMAGETYPE + KERNEL_DTB_PREFIX come from the
# machine/kernel recipe; everything else is resolved at runtime from U-Boot.
do_compile() {
    if [ -z "${BOOT_PREAMBLE}" ]; then
        bbfatal "torizon-ab boot: BOOT_PREAMBLE unset (which backend preamble to prepend?)."
    fi
    if [ -z "${KERNEL_IMAGETYPE}" ] || [ -z "${KERNEL_DTB_PREFIX}" ]; then
        bbfatal "torizon-ab boot: KERNEL_IMAGETYPE / KERNEL_DTB_PREFIX unset for ${MACHINE}; these come from the machine/kernel metadata (see docs/uboot-rauc-porting.md)."
    fi
    if [ -z "${TORIZON_AB_FDTFILE}" ]; then
        bbfatal "torizon-ab boot: TORIZON_AB_FDTFILE unset for ${MACHINE}; set your carrier device-tree file (see docs/uboot-rauc-porting.md)."
    fi
    cat ${WORKDIR}/${BOOT_PREAMBLE} ${WORKDIR}/boot-body.cmd > ${WORKDIR}/boot.cmd.full
    sed -e 's|@@KERNEL_IMAGETYPE@@|${KERNEL_IMAGETYPE}|g' \
        -e 's|@@KERNEL_DTB_PREFIX@@|${KERNEL_DTB_PREFIX}|g' \
        -e 's|@@KERNEL_BOOTCMD@@|${KERNEL_BOOTCMD}|g' \
        -e 's|@@FDTFILE@@|${TORIZON_AB_FDTFILE}|g' \
        ${WORKDIR}/boot.cmd.full > ${WORKDIR}/boot.cmd.resolved

    # arm64 for the current aarch64 targets; parameterize if a 32-bit target appears.
    uboot-mkimage -A arm64 -O linux -T script -C none \
        -n "Torizon A/B boot" -d ${WORKDIR}/boot.cmd.resolved ${WORKDIR}/boot.scr
}

# boot.scr is deployed for the wic (bootimg-partition) to stage into the FAT boot
# partition -- it is the shared slot SELECTOR that U-Boot's script bootmeth runs.
# Deployed under a recipe-unique name (both backends deploy into the shared
# DEPLOY_DIR; a plain "boot.scr" would collide in sstate). IMAGE_BOOT_FILES
# renames it to boot.scr in the FAT ("${PN}-boot.scr;boot.scr").
inherit deploy
do_deploy() {
    install -d ${DEPLOYDIR}
    install -m 0644 ${WORKDIR}/boot.scr ${DEPLOYDIR}/${PN}-boot.scr
}
addtask deploy after do_compile before do_build
