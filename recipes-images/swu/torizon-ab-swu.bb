SUMMARY = "SWUpdate .swu artifact carrying the Torizon OS A/B rootfs"
DESCRIPTION = "Packs the torizon-minimal-ab rootfs (ext4, gzip-compressed) into \
a .swu update file with an A/B sw-description. Delivered to devices via the \
aktualizr '<machine>-rootfs' generic secondary and applied by SWUpdate to the \
inactive slot."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit swupdate

SRC_URI = "file://sw-description"

# Build the rootfs image before packing the .swu.
IMAGE_DEPENDS = "torizon-minimal-ab"

# The rootfs image whose .ext4.gz becomes the SWUpdate payload. The class copies
# it into the .swu under its deploy basename, which includes the machine suffix
# (torizon-minimal-ab-<machine>.ext4.gz) — the sw-description references it via
# the @@MACHINE@@ placeholder that meta-swupdate expands.
SWUPDATE_IMAGES = "torizon-minimal-ab"
SWUPDATE_IMAGES_FSTYPES[torizon-minimal-ab] = ".ext4.gz"

# REVIEW: to produce a signed .swu (recommended in addition to aktualizr's
# Uptane signature), set SWUPDATE_SIGNING and provide keys per meta-swupdate.
# SWUPDATE_SIGNING = "RSA"
