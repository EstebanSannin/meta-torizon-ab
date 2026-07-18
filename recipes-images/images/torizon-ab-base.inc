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

# The kernel + initramfs live INSIDE each rootfs slot (/boot); GRUB loads them
# from the active slot. Make sure they are installed into the rootfs.
# (No kernel-devicetree on x86 — there are no DTBs; add it back per-machine for
#  ARM targets, e.g. CORE_IMAGE_BASE_INSTALL:append:<arm-machine> = " kernel-devicetree".)
CORE_IMAGE_BASE_INSTALL:append = " \
    kernel-image \
    kernel-modules \
"

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
CORE_IMAGE_BASE_INSTALL:append = " \
    aktualizr-torizon \
    auto-provisioning \
    rac \
    tzn-mqtt \
    greenboot \
    aktualizr-pacman-none \
    swupdate \
    grub-ab \
    torizon-ab-slots-udev \
"

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
