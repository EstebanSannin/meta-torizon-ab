# Torizon A/B RAUC U-Boot boot script (generalized) -> compiled to boot.scr.
#
# Slot SELECTOR for the RAUC 'uboot' bootloader backend. Reads RAUC's boot-order
# variables from the U-Boot environment and boots the first slot in BOOT_ORDER
# that still has attempts left, decrementing that slot's trial counter first
# (power-safe: saveenv before boot). greenboot's `rauc status mark-good` resets
# the counter on a healthy boot; if a trial slot is never marked good its
# BOOT_<slot>_LEFT reaches 0 and the next boot falls through = rollback.
#
#   BOOT_ORDER                  e.g. "A B"
#   BOOT_A_LEFT / BOOT_B_LEFT   remaining attempts (0 = don't try)
#
# GENERALIZED across U-Boot RAUC machines. Only three things are machine data,
# substituted at build time from conf/distro/include/torizon-ab-uboot.inc:
#   @@MMCDEV@@         U-Boot mmc device index (0)
#   @@DTB_DIR@@        /boot dir holding the DTB (ti/ vs freescale/)
#   @@FDTFILE@@        the device-tree file (module + carrier)
#   @@KERNEL_SCRATCH@@ compressed-image scratch addr (used only on addr overlap)
# Everything else is resolved at RUNTIME from the board itself:
#   - the slot's partition NUMBER is looked up from its GPT label (no hardcoded
#     partition numbers), so the disk layout can change without touching this;
#   - kernel_addr_r / fdt_addr_r / ramdisk_addr_r / loadaddr come from the
#     board's own default U-Boot environment (Toradex/distro env sets them).
#
# Partition map (see wic/torizon-ab-rauc-uboot.wks):
#   mmc @@MMCDEV@@: p1 FAT boot (this boot.scr) | rootfs_a | rootfs_b | data
# Kernel (Image.gz) + DTB + initramfs live in each rootfs slot's ext4 /boot.

test -n "${BOOT_ORDER}"  || setenv BOOT_ORDER "A B"
test -n "${BOOT_A_LEFT}" || setenv BOOT_A_LEFT 3
test -n "${BOOT_B_LEFT}" || setenv BOOT_B_LEFT 0

setenv mmcdev @@MMCDEV@@
setenv dtb_dir @@DTB_DIR@@
setenv fdtfile @@FDTFILE@@

# pick the first slot in BOOT_ORDER with attempts remaining
setenv raucslot
for slot in ${BOOT_ORDER}; do
  if test -z "${raucslot}"; then
    if test "${slot}" = "A"; then
      if test "${BOOT_A_LEFT}" -gt 0; then
        setexpr BOOT_A_LEFT ${BOOT_A_LEFT} - 1
        setenv raucslot A; setenv rootlabel rootfs_a
      fi
    fi
    if test "${slot}" = "B"; then
      if test "${BOOT_B_LEFT}" -gt 0; then
        setexpr BOOT_B_LEFT ${BOOT_B_LEFT} - 1
        setenv raucslot B; setenv rootlabel rootfs_b
      fi
    fi
  fi
done

if test -z "${raucslot}"; then
  echo "RAUC: no bootable slot left (BOOT_ORDER=${BOOT_ORDER}); halting."
  exit
fi

saveenv

# Resolve the slot's partition NUMBER from its GPT partition label at runtime.
# `part number` sets ${rootpartnum}; this removes the hardcoded 2/3 axis and
# keeps the script correct if the layout ever changes.
if part number mmc ${mmcdev} ${rootlabel} rootpartnum; then
  true
else
  echo "RAUC: GPT partition '${rootlabel}' not found on mmc ${mmcdev}; halting."
  exit
fi

echo "RAUC: booting slot ${raucslot} (mmc ${mmcdev}:${rootpartnum}, root=PARTLABEL=${rootlabel})"
setenv bootargs "root=PARTLABEL=${rootlabel} rootfstype=ext4 rw rauc.slot=${raucslot} ${torizon_extra_bootargs}"

# Load the COMPRESSED Image.gz to ${loadaddr}, then unzip up to ${kernel_addr_r}.
# On boards where loadaddr == kernel_addr_r (e.g. TI K3 = 0x88200000) an in-place
# unzip would overlap, so relocate the compressed image to a scratch address.
setenv comp_addr ${loadaddr}
if test "${comp_addr}" = "${kernel_addr_r}"; then
  setenv comp_addr @@KERNEL_SCRATCH@@
fi

ext4load mmc ${mmcdev}:${rootpartnum} ${comp_addr} /boot/Image.gz
unzip ${comp_addr} ${kernel_addr_r}
ext4load mmc ${mmcdev}:${rootpartnum} ${fdt_addr_r} ${dtb_dir}/${fdtfile}
ext4load mmc ${mmcdev}:${rootpartnum} ${ramdisk_addr_r} /boot/initramfs
setenv ramdisk_size ${filesize}

booti ${kernel_addr_r} ${ramdisk_addr_r}:${ramdisk_size} ${fdt_addr_r}
