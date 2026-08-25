# ===========================================================================
# Torizon OS A/B — U-Boot RAUC porting data  (the "porting contract" surface)
# ===========================================================================
# The complete set of per-SoC-family and per-machine data the U-Boot A/B glue
# needs. To bring RAUC (or, later, SWUpdate) A/B to a NEW U-Boot machine you edit
# ONLY this file: give its SoC family a DTB directory (Tier-2), add the machine's
# device-tree file (Tier-3), and override the boot device / decompress scratch
# only if they differ from the defaults. Everything below the aktualizr seam (the
# action handler, the cloud path) is machine-agnostic and needs no changes.
#
# The family overrides ride the BSP's own SoC-family MACHINEOVERRIDES:
#   TI K3        -> :k3                (meta-ti-bsp k3.inc, via SOC_FAMILY)
#   NXP i.MX8MP  -> :mx8mp-generic-bsp  (imx-base.inc BSP override)
# so a future machine in either family inherits the family data automatically.
#
# Consumed by:
#   recipes-bsp/rauc-uboot-ab            - templates boot.cmd (DTB path, fdtfile,
#                                          mmc dev, decompress scratch)
#   recipes-support/rauc/rauc-conf.*     - selects the RAUC 'uboot' backend
#   conf/distro/torizon-ab-rauc.conf     - WKS_FILE + wic fstypes
#   recipes-images/.../torizon-ab-base.inc - installs the glue + boot files
# See docs/uboot-rauc-porting.md for the step-by-step porting checklist.

# --- Tier-2: SoC-family data -------------------------------------------------
# Directory, under each rootfs slot's ext4 /boot, that holds the compiled DTBs.
# Kernel deploy path differs by vendor kernel (verify with `debugfs -R "ls /boot"
# <rootfs.ext4>`): the TI kernel installs to /boot/dtb/ti/, the NXP (linux-toradex)
# kernel installs to /boot/freescale/ (NOT /boot/dtb/freescale).
TORIZON_AB_DTB_DIR:k3                = "/boot/dtb/ti"
TORIZON_AB_DTB_DIR:mx8mp-generic-bsp = "/boot/freescale"

# --- Tier-3: per-machine data ------------------------------------------------
# eMMC device carrying the A/B GPT layout: the U-Boot 'mmc' index (NOT the Linux
# mmcblkN). This differs by SoC: TI K3 enumerates the on-module eMMC as mmc 0;
# NXP i.MX8MP puts it on usdhc3 = mmc 2 (mmc 0/1 are the SD/SDIO slots). Verify on
# the board's U-Boot prompt with `mmc list`. Default 0 (TI); override per machine.
TORIZON_AB_MMCDEV ?= "0"
TORIZON_AB_MMCDEV:verdin-imx8mp = "2"

# Scratch load address for the compressed Image.gz, used ONLY when the board's
# ${loadaddr} coincides with ${kernel_addr_r} (in-place unzip would overlap).
# MUST be free DRAM on the target (verify: `ext4load mmc <d>:<p> <addr> /boot/Image.gz`
# must not hit "would overwrite reserved memory"). TI K3 loadaddr==kernel_addr_r
# ==0x88200000, scratch 0x84000000 (below it). i.MX8MP ALSO has
# loadaddr==kernel_addr_r (==0x48200000) so the guard fires; 0x84000000 is ABOVE
# imx8mp usable DRAM (reserved) → use 0x60000000 (mid-DRAM, validated free).
TORIZON_AB_KERNEL_SCRATCH ?= "0x84000000"
TORIZON_AB_KERNEL_SCRATCH:verdin-imx8mp = "0x60000000"

# Device-tree file (module + carrier) loaded from ${TORIZON_AB_DTB_DIR}.
# NOTE (imx8mp): defaulted to the Dahlia carrier; change to match the actual
# carrier of the board under test (dev/dahlia/ivy/mallow/yavia/zinnia, wifi/nonwifi).
TORIZON_AB_FDTFILE:verdin-am62p  = "k3-am62p5-verdin-wifi-yavia.dtb"
TORIZON_AB_FDTFILE:verdin-imx8mp = "imx8mp-verdin-wifi-dahlia.dtb"
