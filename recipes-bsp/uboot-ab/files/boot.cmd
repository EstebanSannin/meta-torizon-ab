# Torizon A/B U-Boot boot script (verdin-imx8mp) — compiled to boot.scr.
#
# DRAFT / Phase-1 bring-up: selects the rootfs slot (a/b) from the U-Boot env
# and rolls back via the stock bootcount/bootlimit mechanism already built into
# Toradex U-Boot. Expected to be iterated from the U-Boot console on real
# hardware (load addresses, DTB name, and the device/partition scan differ per
# setup — check `printenv` on the board).
#
# Env used: rootfs_slot (a|b), upgrade_available, bootcount, bootlimit(=3),
#           rollback, altbootcmd (all in the real U-Boot env).
# Layout assumed: eMMC user area, p1=otaroot_a, p2=otaroot_b, p3=data;
#           kernel Image.gz + DTB + initramfs in each slot's /boot.

# --- defaults ---
if test -z "${rootfs_slot}"; then setenv rootfs_slot a; fi
if test -z "${bootlimit}"; then setenv bootlimit 3; fi
if test -z "${devnum}"; then setenv devnum 0; fi          # eMMC (mmc 0); REVIEW on HW
if test -z "${fdtfile}"; then setenv fdtfile imx8mp-verdin-wifi-dev.dtb; fi   # REVIEW per module

# Load addresses (Toradex imx8mp defaults; REVIEW with `printenv` on the board)
if test -z "${kernel_addr_r}"; then setenv kernel_addr_r 0x40480000; fi
if test -z "${fdt_addr_r}"; then setenv fdt_addr_r 0x43000000; fi
if test -z "${ramdisk_addr_r}"; then setenv ramdisk_addr_r 0x43800000; fi
setenv loadaddr 0x48000000    # scratch for the compressed Image.gz

# --- rollback fallback wiring (mirror stock Toradex boot.cmd) ---
if test -z "${altbootcmd}"; then
    setenv altbootcmd 'setenv rollback 1; run bootcmd'
    saveenv
fi
# On a failed trial, U-Boot bootcount>bootlimit runs altbootcmd -> rollback=1.
# Flip to the other slot and make the fallback permanent.
if test "${rollback}" = "1" && test "${upgrade_available}" = "1"; then
    if test "${rootfs_slot}" = "a"; then setenv rootfs_slot b; else setenv rootfs_slot a; fi
    setenv upgrade_available 0
    setenv bootcount 0
    saveenv
fi

# --- map slot -> partition + root label ---
if test "${rootfs_slot}" = "b"; then
    setenv ab_part 2
    setenv ab_root otaroot_b
else
    setenv ab_part 1
    setenv ab_root otaroot_a
fi
echo "Torizon A/B: booting slot ${rootfs_slot} (mmc ${devnum}:${ab_part}, root=LABEL=${ab_root})"

setenv bootargs "root=LABEL=${ab_root} rootfstype=ext4 rw ${torizon_extra_bootargs}"

# --- load kernel (Image.gz), DTB, initramfs from the active slot's /boot ---
load mmc ${devnum}:${ab_part} ${loadaddr} /boot/Image.gz
unzip ${loadaddr} ${kernel_addr_r}
load mmc ${devnum}:${ab_part} ${fdt_addr_r} /boot/${fdtfile}
load mmc ${devnum}:${ab_part} ${ramdisk_addr_r} /boot/initramfs
setenv ramdisk_size ${filesize}

booti ${kernel_addr_r} ${ramdisk_addr_r}:${ramdisk_size} ${fdt_addr_r}
