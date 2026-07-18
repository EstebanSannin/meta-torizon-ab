SUMMARY = "SWUpdate .swu artifact carrying the Torizon OS A/B rootfs (Docker)"
DESCRIPTION = "Packs the torizon-docker-ab rootfs (ext4, gzip-compressed) into \
a .swu update file with an A/B sw-description. Delivered to devices via the \
aktualizr '<machine>-rootfs' generic secondary and applied by SWUpdate to the \
inactive slot."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit swupdate

SRC_URI = "file://sw-description"

# The rootfs image whose .ext4.gz becomes the SWUpdate payload.
SWUPDATE_IMAGES = "torizon-docker-ab"
SWUPDATE_IMAGES_FSTYPES[torizon-docker-ab] = ".ext4.gz"

# Stable, machine-independent payload filename referenced by sw-description.
SWUPDATE_IMAGES_NOAPPEND_MACHINE = "1"

# REVIEW: to produce a signed .swu, set SWUPDATE_SIGNING and provide keys.
# SWUPDATE_SIGNING = "RSA"
