# Torizon OS A/B (RAUC): provide our system.conf + verification keyring via the
# meta-rauc 'rauc-conf' recipe (RPROVIDES virtual-rauc-conf, RRECOMMENDED by the
# rauc package). We override the example keyring through FILESEXTRAPATHS and
# rewrite system.conf in do_install:append so it can be templated (compatible
# string + PARTLABEL slot devices).

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Use our dev keyring instead of the meta-rauc example ca.cert.pem.
RAUC_KEYRING_FILE:torizon-ab-rauc = "keyring.pem"

RAUC_COMPATIBLE ??= "torizon-ab-rauc-${MACHINE}"

# The base recipe installs the example system.conf; overwrite it with ours.
do_install:append:torizon-ab-rauc () {
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
