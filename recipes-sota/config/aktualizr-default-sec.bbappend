# Register the OS rootfs as an aktualizr generic secondary (Subsystem Update),
# for BOTH updater backends. The seam is identical; only the action handler and
# the payload filename differ:
#   swupdate -> /usr/bin/swupdate_actions.sh applies a .swu  (rootfs.swu)
#   rauc     -> /usr/bin/rauc_actions.sh    applies a .raucb (rootfs.raucb)
#
# The secondary is registered once (shared, ':torizon-ab'); the handler path and
# payload name come from per-backend variables so the JSON is written correctly
# under either distro.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Only the active backend's handler is fetched/installed.
SRC_URI:append:torizon-ab-swupdate = " file://swupdate_actions.sh"
SRC_URI:append:torizon-ab-rauc     = " file://rauc_actions.sh"

DEPENDS:append:torizon-ab = " jq-native"

# Per-backend action handler + delivered payload filename (used in the JSON).
TORIZON_AB_UPDATE_HANDLER:torizon-ab-swupdate = "/usr/bin/swupdate_actions.sh"
TORIZON_AB_UPDATE_HANDLER:torizon-ab-rauc     = "/usr/bin/rauc_actions.sh"
TORIZON_AB_FW_FILE:torizon-ab-swupdate = "rootfs.swu"
TORIZON_AB_FW_FILE:torizon-ab-rauc     = "rootfs.raucb"

# Install the active backend's handler.
do_install:append:torizon-ab-swupdate () {
    install -m 0744 ${WORKDIR}/swupdate_actions.sh ${D}${bindir}/swupdate_actions.sh
}
do_install:append:torizon-ab-rauc () {
    install -m 0744 ${WORKDIR}/rauc_actions.sh ${D}${bindir}/rauc_actions.sh
}

# Append the '<machine>-rootfs' subsystem secondary to the shared
# secondaries.json (mirrors the fuse-secondary pattern). Shared across backends;
# the handler path + payload name are backend variables. Runs after the base
# recipe's do_install:append.
do_install:append:torizon-ab () {
    local machine="${MACHINE}"
    local secfile=${D}${libdir}/sota/secondaries.json

    # On x86 there is no U-Boot, so the bootloader secondary (bl_actions.sh via
    # fw_printenv/fw_setenv) is non-functional and errors every aktualizr cycle.
    case "${MACHINE}" in
        genericx86-64|intel-corei7-64)
            jq '.["torizon-generic"] |= map(select((.ecu_hardware_id | endswith("-bootloader")) | not))' \
                "$secfile" > ${WORKDIR}/sec-nobl.json
            install -m 0644 ${WORKDIR}/sec-nobl.json "$secfile"
            ;;
    esac

    # Add the '<machine>-rootfs' subsystem secondary (the OS A/B update channel).
    cat "$secfile" |\
        jq '.["torizon-generic"] +=
             [{"partial_verifying": false,
               "ecu_hardware_id": "'"$machine"'-rootfs",
               "full_client_dir": "/var/sota/storage/rootfs",
               "ecu_private_key": "sec.private",
               "ecu_public_key": "sec.public",
               "firmware_path": "/var/sota/storage/rootfs/${TORIZON_AB_FW_FILE}",
               "target_name_path": "/var/sota/storage/rootfs/target_name",
               "metadata_path": "/var/sota/storage/rootfs/metadata",
               "action_handler_path": "${TORIZON_AB_UPDATE_HANDLER}"}]' \
        > ${WORKDIR}/secondaries-ab.json

    install -m 0644 ${WORKDIR}/secondaries-ab.json "$secfile"
}

FILES:${PN}:append:torizon-ab-swupdate = " ${bindir}/swupdate_actions.sh"
FILES:${PN}:append:torizon-ab-rauc     = " ${bindir}/rauc_actions.sh"

# swupdate_actions.sh sources common_actions.sh (base) + /usr/lib/torizon-ab/
# bootenv.sh (per-machine grub-ab/uboot-ab). rauc_actions.sh drives RAUC directly.
RDEPENDS:${PN}:append:torizon-ab-swupdate = " swupdate torizon-ab-bootenv"
RDEPENDS:${PN}:append:torizon-ab-rauc     = " rauc"
