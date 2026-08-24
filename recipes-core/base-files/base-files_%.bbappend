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

# The x86 fstab mounts the ESP at /boot/efi (grubenv lives there). AM62p (U-Boot)
# has no ESP, so it uses a variant without that line — mounting the nonexistent
# efi label otherwise drops the boot into emergency mode.
TORIZON_AB_FSTAB ?= "fstab-torizon-ab"
TORIZON_AB_FSTAB:verdin-am62p = "fstab-torizon-ab-am62"

SRC_URI:append:torizon-ab = " file://fstab-torizon-ab"
SRC_URI:append:verdin-am62p = " file://fstab-torizon-ab-am62"

do_install:append:torizon-ab () {
    install -m 0644 ${WORKDIR}/${TORIZON_AB_FSTAB} ${D}${sysconfdir}/fstab
}
