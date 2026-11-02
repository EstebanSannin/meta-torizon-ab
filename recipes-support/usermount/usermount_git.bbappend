# The usermount daemon mounts every new udisks filesystem, including the
# inactive A/B slot (marked UDISKS_IGNORE by torizon-ab-slots-udev), which then
# blocks the update from writing it. Make it honour UDISKS_IGNORE (x86 for
# now; the ARM handlers still unmount the slot themselves).
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append:torizon-ab:genericx86-64 = " file://0001-Skip-devices-udisks-is-told-to-ignore.patch"
