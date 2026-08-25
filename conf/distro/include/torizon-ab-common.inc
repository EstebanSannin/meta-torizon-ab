# Torizon OS A/B (no OSTree) — shared distro foundation for BOTH updater
# backends (SWUpdate and RAUC).
#
# The including distro conf (torizon-ab.conf / torizon-ab-rauc.conf) sets
# DISTRO, DISTRO_NAME, the DISTROOVERRIDES backend token, TORIZON_AB_UPDATER,
# any backend DISTRO_FEATURES, and the WKS_FILE (the A/B disk layout differs by
# backend: SWUpdate addresses slots by ext4 FS label, RAUC by GPT PARTLABEL).
#
# Reuses the Torizon common foundation (tune, systemd, users, aktualizr fork,
# versioning) but deliberately does NOT require sota.conf.inc, so OSTree is
# never pulled in; the update stack is re-added explicitly in the image recipe.

require conf/distro/include/common-torizon.inc

# Per-family / per-machine data for the U-Boot A/B glue (the porting-contract
# surface). Harmless on non-U-Boot machines (nothing consumes it there).
require conf/distro/include/torizon-ab-uboot.inc

# Distro-specific override so recipes can use ':torizon-ab' for content shared
# by both backends. The backend-specific token (':torizon-ab-swupdate' /
# ':torizon-ab-rauc') is appended by the including distro conf.
DISTROOVERRIDES .= ":torizon-ab"

# Which updater backend this distro builds. Recipes can branch on it; the
# canonical selector for overrides is the DISTROOVERRIDES token above.
TORIZON_AB_UPDATER ?= "swupdate"

# ---------------------------------------------------------------------------
# Remove every OSTree/TEZI image-assembly class that common-torizon.inc and
# base-distro.inc pull in, keeping the image pipeline plain (wic + ext4 rootfs).
# ---------------------------------------------------------------------------
IMAGE_CLASSES:remove = "image_type_common_torizon image_type_torizon image_types_ostree image_types_ota image_repo_manifest image_type_tezi"

# imx8mp's machine conf appends teziimg (+ image_type_tezi, removed above).
IMAGE_FSTYPES:remove = "teziimg"

# base-distro.inc points this at the OSTree initramfs; use our plain one.
INITRAMFS_IMAGE = "initramfs-torizon-ab-image"
INITRAMFS_IMAGE_BUNDLE = "0"
INITRAMFS_FSTYPES = "cpio.gz"

# The OSTree 'stateless-system' feature is meaningless for a plain A/B ext4
# rootfs; persistent state lives on the data partition (mounted over /var).
DISTRO_FEATURES:remove = "stateless-system"

# ---------------------------------------------------------------------------
# Image output. ext4.gz is the per-slot rootfs payload on all machines.
# x86 (GRUB/EFI) also builds the flashable A/B wic (WKS_FILE set per backend).
# ---------------------------------------------------------------------------
IMAGE_FSTYPES = "ext4 ext4.gz"
IMAGE_FSTYPES:append:genericx86-64   = " wic wic.bmap"
IMAGE_FSTYPES:append:intel-corei7-64 = " wic wic.bmap"

# verdin-imx8mp SWUpdate draft (U-Boot/eMMC): a rootfs tarball for Phase-1
# bring-up. Scoped to the SWUpdate backend; the RAUC backend builds a flashable
# wic instead (see torizon-ab-rauc.conf).
IMAGE_FSTYPES:append:torizon-ab-swupdate:verdin-imx8mp = " tar.bz2"

# Stable identifiers for the A/B slots, data and boot partitions. SWUpdate
# addresses slots by the ext4 FS label (ROOTLABEL_*); RAUC by GPT partition
# label (PARTLABEL_*). Both are written by the WKS so a single layout serves
# either backend.
TORIZON_AB_ROOTLABEL_A ?= "otaroot_a"
TORIZON_AB_ROOTLABEL_B ?= "otaroot_b"
TORIZON_AB_DATALABEL   ?= "data"
# (No TORIZON_AB_BOOTLABEL: the boot-partition label differs per machine — "efi"
# on x86, "boot" on am62p, none on imx8mp — and nothing consumes it. Any code
# that needs the boot label should take it per-machine from the wks, not from a
# shared x86-flavoured default.)
TORIZON_AB_PARTLABEL_A ?= "rootfs_a"
TORIZON_AB_PARTLABEL_B ?= "rootfs_b"
