# Add the OS rootfs as an aktualizr generic secondary (Subsystem Update).
#
# The rootfs .swu is delivered through this secondary; swupdate_actions.sh
# applies it to the inactive A/B slot via SWUpdate and flips the GRUB env.
# Only active for the torizon-ab distro.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append:torizon-ab = " file://swupdate_actions.sh"

DEPENDS:append:torizon-ab = " jq-native"

# Append a '<machine>-rootfs' entry to the shared secondaries.json (mirrors the
# fuse-secondary pattern already used in aktualizr-default-sec) and install the
# action handler. Runs after the base recipe's do_install:append.
do_install:append:torizon-ab () {
    install -m 0744 ${WORKDIR}/swupdate_actions.sh ${D}${bindir}/swupdate_actions.sh

    local machine="${MACHINE}"
    cat ${D}${libdir}/sota/secondaries.json |\
        jq '.["torizon-generic"] +=
             [{"partial_verifying": false,
               "ecu_hardware_id": "'"$machine"'-rootfs",
               "full_client_dir": "/var/sota/storage/rootfs",
               "ecu_private_key": "sec.private",
               "ecu_public_key": "sec.public",
               "firmware_path": "/var/sota/storage/rootfs/rootfs.swu",
               "target_name_path": "/var/sota/storage/rootfs/target_name",
               "metadata_path": "/var/sota/storage/rootfs/metadata",
               "action_handler_path": "/usr/bin/swupdate_actions.sh"}]' \
        > ${WORKDIR}/secondaries-ab.json

    install -m 0644 ${WORKDIR}/secondaries-ab.json ${D}${libdir}/sota/secondaries.json
}

FILES:${PN}:append:torizon-ab = " ${bindir}/swupdate_actions.sh"

# common_actions.sh (sourced by swupdate_actions.sh) is installed by the base
# recipe when BL_UPDATE_SUPPORT=1 (default on genericx86-64). Ensure it is kept.
RDEPENDS:${PN}:append:torizon-ab = " swupdate"
