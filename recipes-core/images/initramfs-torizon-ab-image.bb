DESCRIPTION = "Torizon OS A/B initramfs image (no OSTree)"

# Same as the Torizon OSTree initramfs but WITHOUT initramfs-module-ostree /
# ostree-switchroot. The standard initramfs-module-rootfs mounts the real root
# passed by GRUB (root=LABEL=otaroot_a|otaroot_b) directly.
PACKAGE_INSTALL = "initramfs-framework-base initramfs-module-udev \
    initramfs-module-rootfs initramfs-module-debug \
    initramfs-module-plymouth ${VIRTUAL-RUNTIME_base-utils} base-passwd \
    initramfs-module-kmod"

SYSTEMD_DEFAULT_TARGET = "initrd.target"

IMAGE_NAME_SUFFIX = ""
IMAGE_FEATURES = "splash"

export IMAGE_BASENAME = "initramfs-torizon-ab-image"
IMAGE_LINGUAS = ""

LICENSE = "MIT"

IMAGE_FSTYPES = "cpio.gz"
IMAGE_FSTYPES:remove = "wic wic.gz wic.bmap wic.vmdk wic.vdi ext4 ext4.gz teziimg"

IMAGE_CLASSES:remove = "image_type_common_torizon image_type_torizon image_types_ostree image_types_ota image_repo_manifest license_image qemuboot"

EXTRA_IMAGEDEPENDS = ""

inherit core-image nopackages

IMAGE_ROOTFS_SIZE = "8192"
IMAGE_ROOTFS_EXTRA_SPACE = "0"
IMAGE_OVERHEAD_FACTOR = "1.0"

BAD_RECOMMENDATIONS += "busybox-syslog"

# Drop post-process commands inherited from Torizon image classes that are
# irrelevant for a plain A/B initramfs.
ROOTFS_POSTPROCESS_COMMAND:remove = "\
    adjust_container_engines; \
    gen_bootloader_ota_files; \
    tweak_os_release_variant; \
"
