SUMMARY = "RAUC bundle (.raucb) carrying the Torizon OS A/B rootfs"
DESCRIPTION = "Packs the torizon-minimal-ab rootfs (ext4) into a signed RAUC \
bundle. Delivered to devices via the aktualizr '<machine>-rootfs' generic \
secondary and applied by RAUC (rauc_actions.sh) to the inactive slot."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit bundle

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
# DEV signing material (NOT FOR PRODUCTION — see B4/production-keys follow-up).
SRC_URI = "file://dev.key.pem file://dev.cert.pem"

RAUC_COMPATIBLE ??= "torizon-ab-rauc-${MACHINE}"
RAUC_BUNDLE_COMPATIBLE = "${RAUC_COMPATIBLE}"
RAUC_BUNDLE_VERSION    = "${DISTRO_VERSION}"
RAUC_BUNDLE_FORMAT     = "plain"

RAUC_KEY_FILE  = "${WORKDIR}/dev.key.pem"
RAUC_CERT_FILE = "${WORKDIR}/dev.cert.pem"

# One rootfs slot class; the payload is the image's raw ext4.
RAUC_BUNDLE_SLOTS = "rootfs"
RAUC_SLOT_rootfs = "torizon-minimal-ab"
RAUC_SLOT_rootfs[fstype] = "ext4"

# Our image recipe overrides IMAGE_LINK_NAME without the ".rootfs" infix that
# bundle.bbclass expects by default, so point it at the actual deployed name.
RAUC_SLOT_rootfs[file] = "torizon-minimal-ab-${MACHINE}.ext4"
