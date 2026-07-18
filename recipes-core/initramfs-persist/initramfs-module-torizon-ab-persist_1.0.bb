SUMMARY = "initramfs module: A/B persistence (overlay /etc, persistent /var + /home)"
DESCRIPTION = "Sets up, in the initramfs before switch_root, the persistent \
storage shared across A/B rootfs slots: the data partition mounted at /var, an \
overlay on /etc (persistent upper on the data partition), and a bind-mounted \
/home. First boot seeds the factory /var and /home onto the data partition."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://persist"

# initramfs-framework-base provides the module runner + fatal(); kmod provides
# modprobe (used as a harmless no-op if overlayfs is built into the kernel).
RDEPENDS:${PN} = "initramfs-framework-base kmod"
# NOTE: overlayfs must be available in the kernel. On this x86 kernel it is
# built-in (CONFIG_OVERLAY_FS=y) — there is no kernel-module-overlay package.
# If you retarget to a kernel where it is a module, add that module to the
# initramfs image and it will be modprobe'd by the persist script.

inherit allarch

do_install() {
    install -d ${D}/init.d
    # 92: after 90-rootfs (mounts the slot), before 99-finish (switch_root).
    install -m 0755 ${WORKDIR}/persist ${D}/init.d/92-persist
}

FILES:${PN} = "/init.d/92-persist"
