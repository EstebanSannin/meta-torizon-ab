# Base include for Torizon OS A/B (no-OSTree) images.
#
# Derived from meta-toradex-torizon's torizon-base.inc, with all OSTree/SOTA-
# feature couplings removed and the update stack that would normally be pulled
# in by ':sota' re-added explicitly.

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit core-image

do_rootfs[cleandirs] += "${IMAGE_ROOTFS}"

IMAGE_NAME = "${IMAGE_BASENAME}${IMAGE_BASENAME_SUFFIX}-${MACHINE}${IMAGE_VERSION_SUFFIX}"
IMAGE_LINK_NAME = "${IMAGE_BASENAME}${IMAGE_BASENAME_SUFFIX}-${MACHINE}"

# Enough free space in each rootfs slot.
IMAGE_OVERHEAD_FACTOR = "1.5"

IMAGE_FEATURES += "ssh-server-openssh bash-completion-pkgs splash"
SPLASH = "plymouth"

# The kernel + initramfs live INSIDE each rootfs slot (/boot); the bootloader
# (GRUB on x86, U-Boot on imx8mp) loads them from the active slot.
CORE_IMAGE_BASE_INSTALL:append = " \
    kernel-image \
    kernel-modules \
"
# Device trees are needed on ARM (U-Boot loads the DTB); x86 has none.
CORE_IMAGE_BASE_INSTALL:append:verdin-imx8mp = " kernel-devicetree"
CORE_IMAGE_BASE_INSTALL:append:verdin-am62p  = " kernel-devicetree"

# Install the initramfs alongside the kernel in each rootfs slot's /boot so GRUB
# can load it (root=LABEL= is resolved by the initramfs, not the kernel). Kept
# per-slot so a rootfs update ships a matching kernel+initramfs atomically.
do_rootfs[depends] += "${INITRAMFS_IMAGE}:do_image_complete"
install_initramfs_to_boot () {
    install -m 0644 "${DEPLOY_DIR_IMAGE}/${INITRAMFS_IMAGE}-${MACHINE}.cpio.gz" \
        "${IMAGE_ROOTFS}/boot/initramfs"
}
ROOTFS_POSTPROCESS_COMMAND += "install_initramfs_to_boot;"

# ---------------------------------------------------------------------------
# Base packages (mirrors torizon-base.inc, minus OSTree-only items:
# ostree-customize-plymouth, ostree-devicetree-overlays, resize-helper).
# ---------------------------------------------------------------------------
CORE_IMAGE_BASE_INSTALL:append = " \
    cpupower \
    curl \
    e2fsprogs-tune2fs \
    ethtool \
    evtest \
    fastfetch \
    fluentbit \
    htop \
    i2c-tools \
    iproute2 \
    iproute2-ip \
    jq \
    ldd \
    less \
    libpwquality \
    mmc-utils \
    nano \
    networkmanager \
    openssh-sftp-server \
    packagegroup-core-full-cmdline-multiuser \
    packagegroup-core-full-cmdline-utils \
    parted \
    rsync \
    sshfs-fuse \
    sudo \
    systemd-analyze \
    torizon-conf \
    torizon-users \
    tzdata \
    usermount \
    vim-tiny \
    wireguard-tools \
    zram \
"

CORE_IMAGE_BASE_INSTALL:append:tdx = " \
    apparmor \
    alsa-ucm-conf-tdx \
    set-hostname \
    tdx-info \
    udev-toradex-rules \
"

# ---------------------------------------------------------------------------
# Update stack. Without the 'sota' feature these are NOT auto-injected, so we
# add them here. This is the set that torizon-base.inc adds via ':sota'
# (aktualizr comes from sota.bbclass) plus greenboot and SWUpdate.
# ---------------------------------------------------------------------------
# aktualizr-torizon RPROVIDES aktualizr / aktualizr-info, so it covers those.
# Machine-agnostic update + A/B stack:
CORE_IMAGE_BASE_INSTALL:append = " \
    aktualizr-torizon \
    auto-provisioning \
    rac \
    tzn-mqtt \
    greenboot \
    aktualizr-pacman-none \
    torizon-ab-slots-udev \
    torizon-ab-pending-reboot \
    resize-data-helper \
"

# NOTE ON DEV/TEST ACCESS: this image is deliberately PRISTINE -- it ships NO dev
# SSH key, NO passwordless sudo, and NO provisioning identity, so the deployable
# artifact (.wic/.swu/.raucb) is bit-identical to what is tested and safe to ship.
# Dev/test access is injected at runtime by the test harness over the serial
# console (writing only to the data partition, never a rootfs slot); it is never
# baked into the image. See meta-torizon-ab/tests/hardware/ (enable-access.sh /
# runtime-reset.sh) and docs/am62p-hardware-loop.md.

# The OS-update engine is backend-specific (selected by the distro).
CORE_IMAGE_BASE_INSTALL:append:torizon-ab-swupdate = " swupdate"
CORE_IMAGE_BASE_INSTALL:append:torizon-ab-rauc     = " rauc rauc-conf"

# Per-machine bootloader + A/B boot-env glue (provides the bootenv helper the
# rootfs action handler sources):
#   x86      -> grub-ab   (grubenv + grub.cfg rollback + fw_* grubenv wrappers)
#   imx8mp   -> uboot-ab  (U-Boot boot script + real fw_setenv env + fw_env.config)
# SWUpdate backend: hand-rolled grubenv counting (grub-ab) / U-Boot env (uboot-ab).
CORE_IMAGE_BASE_INSTALL:append:torizon-ab-swupdate:genericx86-64   = " grub-ab"
CORE_IMAGE_BASE_INSTALL:append:torizon-ab-swupdate:intel-corei7-64 = " grub-ab"
CORE_IMAGE_BASE_INSTALL:append:torizon-ab-swupdate:verdin-imx8mp   = " uboot-ab"
# TI K3 (verdin-am62p, ...) SWUpdate: same uboot-ab glue, family-scoped like RAUC
# (:k3 above) so a new K3 machine inherits it. See roadmap B15.
CORE_IMAGE_BASE_INSTALL:append:torizon-ab-swupdate:k3              = " uboot-ab"
# RAUC backend: RAUC's native grub bootloader backend + its grubenv bootstrap.
CORE_IMAGE_BASE_INSTALL:append:torizon-ab-rauc:genericx86-64       = " rauc-grub-ab"
CORE_IMAGE_BASE_INSTALL:append:torizon-ab-rauc:intel-corei7-64     = " rauc-grub-ab"
# RAUC backend on U-Boot families (TI K3, NXP i.MX): RAUC's native u-boot
# backend + BOOT_ORDER bootstrap + the A/B boot.scr (see recipes-bsp/rauc-uboot-ab).
# Family-scoped so a new K3 / i.MX machine inherits the glue.
CORE_IMAGE_BASE_INSTALL:append:torizon-ab-rauc:k3                = " rauc-uboot-ab"
CORE_IMAGE_BASE_INSTALL:append:torizon-ab-rauc:mx8mp-generic-bsp = " rauc-uboot-ab"

# (uboot-ab for SWUpdate imx8mp is installed above, line ~121. It now uses the
# same FAT-boot A/B layout + the shared boot.scr as the RAUC side.)

# U-Boot families: the FAT boot partition carries only our A/B boot.scr (the slot
# selector U-Boot's script bootmeth runs); kernel/DTB/initramfs live per slot in
# the rootfs /boot. Override the machine's stock multi-file IMAGE_BOOT_FILES with
# the active backend's boot.scr (deployed under a recipe-unique name, renamed to
# boot.scr in the FAT), and make the .wic wait for it.
IMAGE_BOOT_FILES:torizon-ab-rauc:k3                    = "rauc-uboot-ab-boot.scr;boot.scr"
IMAGE_BOOT_FILES:torizon-ab-rauc:mx8mp-generic-bsp     = "rauc-uboot-ab-boot.scr;boot.scr"
IMAGE_BOOT_FILES:torizon-ab-swupdate:mx8mp-generic-bsp = "uboot-ab-boot.scr;boot.scr"
IMAGE_BOOT_FILES:torizon-ab-swupdate:k3                = "uboot-ab-boot.scr;boot.scr"
# Some machine confs (e.g. verdin-imx8mp) do IMAGE_BOOT_FILES:append with the
# stock distro boot script ("boot.scr-${MACHINE};boot.scr"), staged AFTER — and
# thus overwriting — our A/B slot-selector. :remove applies after :append, so drop
# the stock entry. No-op on machines without that token (am62p/x86).
IMAGE_BOOT_FILES:remove = "boot.scr-${MACHINE};boot.scr"
# The .wic waits for the ACTIVE backend's boot.scr deploy.
do_image_wic[depends] += "${@bb.utils.contains('TORIZON_AB_UPDATER', 'rauc',     bb.utils.contains('MACHINE', 'verdin-am62p',  'rauc-uboot-ab:do_deploy', '', d), '', d)}"
do_image_wic[depends] += "${@bb.utils.contains('TORIZON_AB_UPDATER', 'rauc',     bb.utils.contains('MACHINE', 'verdin-imx8mp', 'rauc-uboot-ab:do_deploy', '', d), '', d)}"
do_image_wic[depends] += "${@bb.utils.contains('TORIZON_AB_UPDATER', 'swupdate', bb.utils.contains('MACHINE', 'verdin-imx8mp', 'uboot-ab:do_deploy',      '', d), '', d)}"
do_image_wic[depends] += "${@bb.utils.contains('TORIZON_AB_UPDATER', 'swupdate', bb.utils.contains('MACHINE', 'verdin-am62p',  'uboot-ab:do_deploy',      '', d), '', d)}"

# The rootfs subsystem secondary + swupdate_actions.sh handler are added to the
# shared aktualizr secondaries via a bbappend to aktualizr-default-sec (pulled
# in by aktualizr-torizon's RDEPENDS), so no extra package is needed here.

# Some x86 machine configs (e.g. intel-corei7-64) auto-install grub-ota-fallback,
# the OSTree GRUB rollback package. It collides with our grub-ab (both ship a
# grubenv-create.service and competing rollback logic), so drop it. Harmless on
# machines that never added it (e.g. genericx86-64).
IMAGE_INSTALL:remove = "grub-ota-fallback"

# Firmware/kernel-module packages that must live in the rootfs (per SoC).
CORE_IMAGE_BASE_INSTALL:append:mx8-nxp-bsp   = " kernel-module-imx-gpu-viv"
CORE_IMAGE_BASE_INSTALL:append:mx8mp-nxp-bsp = " kernel-module-isp-vvcam"

# ---------------------------------------------------------------------------
# /etc/os-release
#
# Stock Torizon supplies os-release via the OSTree image classes we dropped, and
# the Torizon systemd bbappend removes os-release from systemd's RRECOMMENDS — so
# without this the os-release package is never installed, /usr/lib/os-release is
# missing, and /etc/os-release is a dangling symlink. Re-add the oe-core
# os-release package (ID/NAME/VERSION come from DISTRO/DISTRO_NAME/DISTRO_VERSION)
# and set the Torizon-style VARIANT from the image's IMAGE_VARIANT, mirroring
# meta-toradex-torizon's tweak_os_release_variant.
# ---------------------------------------------------------------------------
CORE_IMAGE_BASE_INSTALL:append = " os-release"

set_os_release_variant () {
    osr="${IMAGE_ROOTFS}${nonarch_libdir}/os-release"
    if [ -n "${IMAGE_VARIANT}" ] && [ -f "$osr" ]; then
        if grep -q '^VARIANT=' "$osr"; then
            sed -i -e "s/^VARIANT=.*/VARIANT=\"${IMAGE_VARIANT}\"/" "$osr"
        else
            printf 'VARIANT="%s"\n' "${IMAGE_VARIANT}" >> "$osr"
        fi
    fi
}
ROOTFS_POSTPROCESS_COMMAND += "set_os_release_variant;"
