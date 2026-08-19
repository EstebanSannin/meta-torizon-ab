# On-target RAUC configuration for the Torizon OS A/B (RAUC) variant.
#
# Installs /etc/rauc/system.conf (two rootfs slots addressed by GPT PARTLABEL,
# grub bootloader backend writing the shared grubenv on the ESP) and the dev
# keyring used to verify bundle signatures. Only active for torizon-ab-rauc.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append:torizon-ab-rauc = " file://keyring.pem"

RAUC_COMPATIBLE ??= "torizon-ab-rauc-${MACHINE}"

do_install:append:torizon-ab-rauc () {
    install -d ${D}${sysconfdir}/rauc
    install -m 0644 ${WORKDIR}/keyring.pem ${D}${sysconfdir}/rauc/keyring.pem

    cat > ${D}${sysconfdir}/rauc/system.conf <<EOF
[system]
compatible=${RAUC_COMPATIBLE}
bootloader=grub
grubenv=/boot/efi/EFI/BOOT/grubenv
data-directory=/var/lib/rauc
# The running slot is also passed to userspace via 'rauc.slot=' on the kernel
# command line (see wic/grub-rauc.cfg).

[keyring]
path=/etc/rauc/keyring.pem

[slot.rootfs.0]
device=/dev/disk/by-partlabel/${TORIZON_AB_PARTLABEL_A}
type=ext4
bootname=A

[slot.rootfs.1]
device=/dev/disk/by-partlabel/${TORIZON_AB_PARTLABEL_B}
type=ext4
bootname=B
EOF
}

FILES:${PN}:append:torizon-ab-rauc = " ${sysconfdir}/rauc/keyring.pem ${sysconfdir}/rauc/system.conf"
