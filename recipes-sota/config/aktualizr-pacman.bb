DESCRIPTION = "Configure the aktualizr primary package manager (TORIZON_AB_PACMAN)"
LICENSE = "MPL-2.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MPL-2.0;md5=815ca599c9df247a0c7f619bab123dad"

SRC_URI = "file://90-pacman.toml"
S = "${UNPACKDIR}"

# TORIZON_AB_PACMAN may differ per machine.
PACKAGE_ARCH = "${MACHINE_ARCH}"

# High numeric prefix (90) so this fragment is merged AFTER the credential
# fragment installed by aktualizr-torizon (20-sota-device-cred.toml), which may
# itself carry a [pacman] block defaulting to "ostree". aktualizr merges
# conf.d/*.toml in lexical order with later files overriding earlier ones, so
# 90- guarantees our type wins.
FILES:${PN} = "${libdir}/sota/conf.d/90-pacman.toml"

do_install() {
    install -m 0700 -d ${D}${libdir}/sota/conf.d
    sed 's/@PACMAN@/${TORIZON_AB_PACMAN}/' ${S}/90-pacman.toml > ${D}${libdir}/sota/conf.d/90-pacman.toml
    chmod 0644 ${D}${libdir}/sota/conf.d/90-pacman.toml
}
