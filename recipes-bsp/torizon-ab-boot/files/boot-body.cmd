# Shared U-Boot A/B kernel-load body (both RAUC and SWUpdate backends).
#
# The backend-specific PREAMBLE (prepended to this at build time) has already:
#   - selected the slot and set ${rootlabel} to its GPT partition label
#     (rootfs_a | rootfs_b) -- used here to resolve the partition by label;
#   - set ${bootargs} (backend-specific root=: PARTLABEL for RAUC, LABEL for
#     SWUpdate) plus rauc.slot= / etc.
#
# This body then loads the kernel/dtb/initramfs from that slot and boots. It owns
# NO per-machine constant: the mmc device (${devnum}), load addresses, carrier
# ${fdtfile}, and booti auto-decompression all come from the board's own U-Boot
# env; the kernel image name, DTB subdir and boot command come from stable
# machine/kernel metadata (build-time placeholders). See docs/uboot-rauc-porting.md.

# Resolve the slot's partition NUMBER from its GPT label (no hardcoded partnums).
# ${devnum} is the device U-Boot loaded this script from = the eMMC.
if part number mmc ${devnum} ${rootlabel} slotpart; then
  true
else
  echo "A/B: GPT partition '${rootlabel}' not found on mmc ${devnum}; halting."
  exit
fi
echo "A/B: booting slot partition ${rootlabel} (mmc ${devnum}:${slotpart})"

# Device-tree file. U-Boot's carrier auto-detection (${fdt_file}) is unreliable on
# some carriers -- it can leave ${fdtfile} pointing at a -dev DTB, which boots but
# misconfigures peripherals (e.g. no ethernet). So set it DETERMINISTICALLY from a
# build-time value (TORIZON_AB_FDTFILE -> @@FDTFILE@@, the carrier you build for),
# overridable at runtime via ${ab_fdtfile} in the U-Boot env.
if test -n "${ab_fdtfile}"; then
  setenv fdtfile ${ab_fdtfile}
else
  setenv fdtfile @@FDTFILE@@
fi
# DTBs live at /boot/<prefix>/ (e.g. freescale/) on some kernels and
# /boot/dtb/<prefix>/ (e.g. ti/) on others; try both (keyed on KERNEL_DTB_PREFIX).
setenv dtbpath /boot/@@KERNEL_DTB_PREFIX@@${fdtfile}
test -e mmc ${devnum}:${slotpart} ${dtbpath} || setenv dtbpath /boot/dtb/@@KERNEL_DTB_PREFIX@@${fdtfile}

ext4load mmc ${devnum}:${slotpart} ${loadaddr} /boot/@@KERNEL_IMAGETYPE@@
ext4load mmc ${devnum}:${slotpart} ${fdt_addr_r} ${dtbpath}
ext4load mmc ${devnum}:${slotpart} ${ramdisk_addr_r} /boot/initramfs
setenv ramdisk_size ${filesize}

# booti auto-decompresses the compressed Image at ${loadaddr} via kernel_comp_addr_r.
@@KERNEL_BOOTCMD@@ ${loadaddr} ${ramdisk_addr_r}:${ramdisk_size} ${fdt_addr_r}
