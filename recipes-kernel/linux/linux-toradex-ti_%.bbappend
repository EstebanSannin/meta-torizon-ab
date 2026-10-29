# RAUC requires the target kernel to mount the bundle's squashfs image at
# install time. Add squashfs (+ decompressors) and loop support for the RAUC
# A/B variant on the TI (Verdin AM62p) kernel — the counterpart of the
# linux-yocto bbappend used on x86. Scoped to the RAUC distro so the SWUpdate
# variant is unaffected.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append:torizon-ab-rauc = " file://rauc-squashfs.cfg"

# The 6.18 kernel the BSP pins oopses in the TPS65219 PMIC driver whenever a
# regulator IRQ fires (irq_data->rdev never assigned, CVE-2026-64230). A warm
# reset leaves one pending, so every reboot panics and boot-loops until a cold
# power cycle, breaking the A/B update and rollback reboots. Toradex's kernel
# branch already carries the upstream fix; drop this once the BSP pin moves past
# it (meta-toradex-bsp wrynose bumped to 6.18.51 on 2026-10-28).
SRC_URI:append = " file://0001-regulator-tps65219-fix-irq_data.rdev-not-being-assigned.patch"
