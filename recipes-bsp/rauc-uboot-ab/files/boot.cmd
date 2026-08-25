# Torizon A/B RAUC U-Boot boot script (generic) -> compiled to boot.scr.
#
# Owns ONLY A/B slot selection; delegates the kernel load to values that come
# from stable machine/kernel metadata + the board's own U-Boot env, so there is
# NO per-machine constant here. See docs/uboot-rauc-porting.md.
#
# Build-time placeholders (from the machine/kernel recipe, substituted in do_compile):
#   @@KERNEL_IMAGETYPE@@   kernel image filename        (e.g. Image.gz)
#   @@KERNEL_DTB_PREFIX@@  vendor DTB subdir            (e.g. ti/ , freescale/)
#   @@KERNEL_BOOTCMD@@     arch boot command            (booti | bootz)
# Runtime (the board's own U-Boot env, set before this script runs):
#   ${devnum}             the mmc device we were loaded from (the eMMC)
#   ${fdtfile}            device-tree filename (carrier auto-detected on Toradex)
#   ${loadaddr} ${fdt_addr_r} ${ramdisk_addr_r}   load addresses
#   ${kernel_comp_addr_r} booti auto-decompresses Image.gz -> we manage no scratch
#
# RAUC's 'uboot' bootloader backend maintains BOOT_ORDER / BOOT_<slot>_LEFT; this
# script consumes them, decrements the trial counter (power-safe: saveenv before
# boot), and rolls back when a slot's attempts run out. greenboot's
# `rauc status mark-good` resets the counter on a healthy boot.

# --- A/B slot selection (the only logic we own) ---
test -n "${BOOT_ORDER}"  || setenv BOOT_ORDER "A B"
test -n "${BOOT_A_LEFT}" || setenv BOOT_A_LEFT 3
test -n "${BOOT_B_LEFT}" || setenv BOOT_B_LEFT 0

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

# Resolve the slot's partition NUMBER from its GPT label (no hardcoded partnums).
# ${devnum} is the device U-Boot loaded this script from = the eMMC.
if part number mmc ${devnum} ${rootlabel} slotpart; then
  true
else
  echo "RAUC: GPT partition '${rootlabel}' not found on mmc ${devnum}; halting."
  exit
fi

echo "RAUC: booting slot ${raucslot} (mmc ${devnum}:${slotpart}, root=PARTLABEL=${rootlabel})"
setenv bootargs "root=PARTLABEL=${rootlabel} rootfstype=ext4 rw rauc.slot=${raucslot} ${tdxargs}"

# --- Kernel load + boot (all from metadata / runtime env) ---
# fdtfile is normally carrier-auto-detected by U-Boot; fall back to ${fdt_file}.
test -n "${fdtfile}" || setenv fdtfile ${fdt_file}

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
