# Torizon A/B RAUC U-Boot boot script (verdin-am62p) -> compiled to boot.scr.
#
# Slot SELECTOR: reads RAUC's u-boot-backend variables from the environment and
# boots the first slot in BOOT_ORDER that still has attempts left, decrementing
# that slot's trial counter first (power-safe: saveenv before boot). greenboot's
# `rauc status mark-good` resets the counter on a healthy boot; if a trial slot
# never gets marked good, its BOOT_<slot>_LEFT reaches 0 and the next boot falls
# through to the other slot = rollback.
#
#   BOOT_ORDER        e.g. "A B"
#   BOOT_A_LEFT / BOOT_B_LEFT   remaining attempts (0 = don't try)
#
# Partition map (see wic/torizon-ab-rauc-am62.wks):
#   mmc 0: p1 FAT boot (this boot.scr) | p2 rootfs_a | p3 rootfs_b | p4 data
# Kernel (Image.gz) + DTB + initramfs live in each rootfs slot's ext4 /boot.
#
# DRAFT — verify on hardware: that TI U-Boot auto-loads this boot.scr, the load
# addresses (kernel_addr_r/fdt_addr_r/ramdisk_addr_r/loadaddr come from the TI
# default env), the mmc device number, and the DTB name for the carrier.

test -n "${BOOT_ORDER}"  || setenv BOOT_ORDER "A B"
test -n "${BOOT_A_LEFT}" || setenv BOOT_A_LEFT 3
test -n "${BOOT_B_LEFT}" || setenv BOOT_B_LEFT 0

setenv mmcdev 0
setenv fdtfile k3-am62p5-verdin-wifi-yavia.dtb

# pick the first slot in BOOT_ORDER with attempts remaining
setenv raucslot
for slot in ${BOOT_ORDER}; do
  if test -z "${raucslot}"; then
    if test "${slot}" = "A"; then
      if test "${BOOT_A_LEFT}" -gt 0; then
        setexpr BOOT_A_LEFT ${BOOT_A_LEFT} - 1
        setenv raucslot A; setenv rootlabel rootfs_a; setenv rootpartnum 2
      fi
    fi
    if test "${slot}" = "B"; then
      if test "${BOOT_B_LEFT}" -gt 0; then
        setexpr BOOT_B_LEFT ${BOOT_B_LEFT} - 1
        setenv raucslot B; setenv rootlabel rootfs_b; setenv rootpartnum 3
      fi
    fi
  fi
done

if test -z "${raucslot}"; then
  echo "RAUC: no bootable slot left (BOOT_ORDER=${BOOT_ORDER}); halting."
  exit
fi

saveenv

echo "RAUC: booting slot ${raucslot} (mmc ${mmcdev}:${rootpartnum}, root=PARTLABEL=${rootlabel})"
setenv bootargs "root=PARTLABEL=${rootlabel} rootfstype=ext4 rw rauc.slot=${raucslot} ${torizon_extra_bootargs}"

# load kernel + dtb + initramfs from the selected slot's ext4 /boot
ext4load mmc ${mmcdev}:${rootpartnum} ${loadaddr} /boot/Image.gz
unzip ${loadaddr} ${kernel_addr_r}
ext4load mmc ${mmcdev}:${rootpartnum} ${fdt_addr_r} /boot/${fdtfile}
ext4load mmc ${mmcdev}:${rootpartnum} ${ramdisk_addr_r} /boot/initramfs
setenv ramdisk_size ${filesize}

booti ${kernel_addr_r} ${ramdisk_addr_r}:${ramdisk_size} ${fdt_addr_r}
