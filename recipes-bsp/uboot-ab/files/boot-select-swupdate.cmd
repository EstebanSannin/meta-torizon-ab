# SWUpdate A/B slot-selection preamble (prepended to the shared boot body).
#
# Uses the stock Toradex U-Boot bootcount/bootlimit rollback already built into
# the bootloader: on a failed trial, U-Boot runs altbootcmd (rollback=1); we then
# flip rootfs_slot to the other slot and make the fallback permanent. greenboot
# resets bootcount on a healthy boot; aktualizr's complete-install clears
# upgrade_available. The handler (swupdate_actions.sh, via bootenv.sh) arms a
# trial by setting rootfs_slot / upgrade_available / bootcount.
#
# Sets for the shared body: ${rootlabel} (GPT partlabel of the chosen slot, for
# partition resolution) and ${bootargs} (root=LABEL=otaroot_<slot>, resolved by
# the initramfs). Slot partitions carry BOTH a GPT part-name (rootfs_a/b) and an
# ext4 label (otaroot_a/b); the body resolves by the former, the kernel roots on
# the latter.

test -n "${rootfs_slot}" || setenv rootfs_slot a
test -n "${bootlimit}"   || setenv bootlimit 3

# Ensure the bootcount rollback path is wired (mirror stock Toradex boot.cmd).
if test -z "${altbootcmd}"; then
  setenv altbootcmd 'setenv rollback 1; run bootcmd'
  saveenv
fi

# On a failed trial U-Boot set rollback=1 (altbootcmd) and re-ran bootcmd. Mirror
# the stock Torizon boot.cmd: on rollback, clear upgrade_available (makes the
# rollback permanent, avoids env wear) and persist. We additionally flip
# rootfs_slot -- stock selects the rollback rootfs via OSTree, we via the A/B slot
# var. Like stock we do NOT clear 'rollback' here: it is cleared when the next
# trial is armed (bootenv_arm_trial, mirroring how stock aktualizr resets it), so
# the stale flag can't spuriously roll back a fresh update on its first boot.
if test "${rollback}" = "1" && test "${upgrade_available}" = "1"; then
  if test "${rootfs_slot}" = "a"; then setenv rootfs_slot b; else setenv rootfs_slot a; fi
  setenv upgrade_available 0
  setenv bootcount 0
  saveenv
fi

if test "${rootfs_slot}" = "b"; then
  setenv rootlabel rootfs_b; setenv ab_root otaroot_b
else
  setenv rootlabel rootfs_a; setenv ab_root otaroot_a
fi

setenv bootargs "root=LABEL=${ab_root} rootfstype=ext4 rw ${tdxargs}"
