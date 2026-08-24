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

# Two fstab variants:
#   fstab-torizon-ab        - x86: mounts the ESP at /boot/efi (grubenv lives there)
#   fstab-torizon-ab-noesp  - U-Boot SoMs: no ESP, so no /boot/efi mount
# The NO-ESP fstab is the DEFAULT so every ARM/U-Boot machine is safe out of the
# box; the ESP mount is opt-in for x86 ONLY. (Previously this was inverted — the
# ESP fstab was the default and only am62p opted out — which left verdin-imx8mp,
# the other U-Boot target, mounting a nonexistent efi label -> systemd emergency
# mode. Defaulting to no-ESP means a future ARM SoM can never silently inherit
# the x86 ESP mount again.)
TORIZON_AB_FSTAB ?= "fstab-torizon-ab-noesp"
TORIZON_AB_FSTAB:genericx86-64   = "fstab-torizon-ab"
TORIZON_AB_FSTAB:intel-corei7-64 = "fstab-torizon-ab"

SRC_URI:append:torizon-ab = " file://fstab-torizon-ab file://fstab-torizon-ab-noesp"

do_install:append:torizon-ab () {
    install -m 0644 ${WORKDIR}/${TORIZON_AB_FSTAB} ${D}${sysconfdir}/fstab
}
