SUMMARY = "initramfs module: A/B persistence (overlay /etc, persistent /var + /home)"
DESCRIPTION = "Sets up, in the initramfs before switch_root, the persistent \
storage shared across A/B rootfs slots: the data partition mounted at /var, an \
overlay on /etc (persistent upper on the data partition), and a bind-mounted \
/home. First boot seeds the factory /var and /home onto the data partition."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://persist"

# initramfs-framework-base provides the module runner + fatal(); kmod provides
# modprobe for loading the overlay driver in the initramfs.
RDEPENDS:${PN} = "initramfs-framework-base kmod"
# overlay is a kernel module on this kernel (CONFIG_OVERLAY_FS=m); make sure it
# is present in the initramfs so the /etc overlay can be mounted early.
RRECOMMENDS:${PN} = "kernel-module-overlay"

inherit allarch

do_install() {
    install -d ${D}/init.d
    # 92: after 90-rootfs (mounts the slot), before 99-finish (switch_root).
    install -m 0755 ${WORKDIR}/persist ${D}/init.d/92-persist
}

FILES:${PN} = "/init.d/92-persist"
