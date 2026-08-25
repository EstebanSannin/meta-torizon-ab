# Torizon OS A/B (RAUC): provide our system.conf + verification keyring via the
# meta-rauc 'rauc-conf' recipe (RPROVIDES virtual-rauc-conf, RRECOMMENDED by the
# rauc package). We override the example keyring through FILESEXTRAPATHS and
# rewrite system.conf in do_install:append so it can be templated (compatible
# string + PARTLABEL slot devices).

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Use our dev keyring instead of the meta-rauc example ca.cert.pem.
RAUC_KEYRING_FILE:torizon-ab-rauc = "keyring.pem"

RAUC_COMPATIBLE ??= "torizon-ab-rauc-${MACHINE}"

# RAUC bootloader backend per SoC family:
#   x86            -> grub  (RAUC reads/writes ORDER/*_OK/*_TRY in the grubenv)
#   TI K3 / NXP i.MX -> uboot (RAUC reads/writes BOOT_ORDER/BOOT_<slot>_LEFT in
#                         the U-Boot env via fw_setenv; see recipes-bsp/rauc-uboot-ab)
# Family-scoped so a new K3 / i.MX machine inherits the uboot backend.
RAUC_SYSTEM_BOOTLOADER                   ?= "grub"
RAUC_SYSTEM_BOOTLOADER:k3                = "uboot"
RAUC_SYSTEM_BOOTLOADER:mx8mp-generic-bsp = "uboot"

# The base recipe installs the example system.conf; overwrite it with ours.
# The [system] bootloader line differs by backend; the grubenv path is emitted
# only for the grub backend (the uboot backend locates its env via fw_env.config).
do_install:append:torizon-ab-rauc () {
    {
        echo "[system]"
        echo "compatible=${RAUC_COMPATIBLE}"
        echo "bootloader=${RAUC_SYSTEM_BOOTLOADER}"
        if [ "${RAUC_SYSTEM_BOOTLOADER}" = "grub" ]; then
            echo "grubenv=/boot/efi/EFI/BOOT/grubenv"
        fi
        echo "data-directory=/var/lib/rauc"
        echo "# The running slot is also passed to userspace via 'rauc.slot=' on the"
        echo "# kernel command line (see the machine's boot config)."
        echo ""
        echo "[keyring]"
        echo "path=/etc/rauc/keyring.pem"
        echo ""
        echo "[slot.rootfs.0]"
        echo "device=/dev/disk/by-partlabel/${TORIZON_AB_PARTLABEL_A}"
        echo "type=ext4"
        echo "bootname=A"
        echo ""
        echo "[slot.rootfs.1]"
        echo "device=/dev/disk/by-partlabel/${TORIZON_AB_PARTLABEL_B}"
        echo "type=ext4"
        echo "bootname=B"
    } > ${D}${sysconfdir}/rauc/system.conf
}
