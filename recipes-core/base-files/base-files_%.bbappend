# Ship a static /etc/fstab for the A/B variant.
#
# The SWUpdate payload is the standalone rootfs ext4 (not the wic image), so the
# mounts for the shared EFI and data partitions must come from a fstab baked
# into the rootfs itself — otherwise a slot flashed via .swu would boot without
# /boot/efi (breaking grub-editenv / grubenv-create) or /var.
#
# Mounts are by LABEL so both A and B slots use the same fstab. Note there is no
# 'root' entry: the kernel mounts root by LABEL=otaroot_a|otaroot_b via the
# kernel command line set by GRUB.

FILESEXTRAPATHS:prepend:torizon-ab := "${THISDIR}/files:"

SRC_URI:append:torizon-ab = " file://fstab-torizon-ab"

do_install:append:torizon-ab () {
    install -m 0644 ${WORKDIR}/fstab-torizon-ab ${D}${sysconfdir}/fstab
}
