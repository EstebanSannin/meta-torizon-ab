# Updates and rollback

## Update flow (A → B)

The OS rootfs is delivered through aktualizr's **generic secondary** mechanism
(Torizon "Subsystem Updates"), not as an OSTree primary target. The aktualizr
**primary** is neutralized to `[pacman] type = "none"` (download + Uptane-verify
only); the rootfs rides a secondary ECU `"<machine>-rootfs"` whose
`action_handler_path` is `/usr/bin/swupdate_actions.sh`.

```
Torizon Cloud (Uptane/TUF)
   │  rootfs .swu (custom "Other" package for <machine>-rootfs)
   ▼
aktualizr-torizon      download + Uptane-verify -> /var/sota/storage/rootfs/rootfs.swu(.new)
   │  calls the action handler: install
   ▼
/usr/bin/swupdate_actions.sh (install)
   1. resolve inactive slot device (/dev/disk/by-label/otaroot_b) BEFORE the write
   2. unmount it if mounted
   3. swupdate -i <swu> -e stable,slot_b     -> raw-write decompressed rootfs to slot B
   4. e2label <dev> otaroot_b                -> restore the ext4 label the raw write clobbered
   5. grub-editenv set default=1 upgrade_available=1 bootcount=0 ab_target=otaroot_b
   6. touch /run/need-reboot                 -> return {"status":"need-completion"}
   ▼
torizon-ab-pending-reboot.path -> reboot
   ▼
GRUB: default=1 -> boot slot B  (upgrade_available=1 -> bootcount++)
   ▼
greenboot health check on B
   • healthy -> reset bootcount; aktualizr complete-install confirms
               (upgrade_available=0). Stable on B.
   • unhealthy -> rollback (below)
```

### Key design points

- **Slot identity by ext4 label** (`otaroot_a`/`otaroot_b`). A raw image write
  replaces the label, so the handler restores it with `e2label` right after
  SWUpdate — keeping GRUB (`search --label`), the kernel (`root=LABEL=`), and the
  next update's `by-label` resolution all working.
- **The action handler prints ONLY JSON on stdout** (aktualizr parses it);
  all command output (incl. SWUpdate's verbose log) is redirected to
  `/var/lib/rollback-manager/rootfs-update.log`.
- **No per-image sha in `sw-description`, `CONFIG_HASH_VERIFY=n`.** aktualizr
  already Uptane-verifies the whole `.swu`, so a redundant SWUpdate hash is
  unnecessary (and avoids the compressed-vs-decompressed hash ambiguity).
- **`CONFIG_HW_COMPATIBILITY=n`.** aktualizr targets the right device via Uptane
  hardware IDs; the `sw-description` carries no `hardware-compatibility` list.
- The handler's `get-firmware-info` returns exit 64 (defer to aktualizr) rather
  than reporting a slot label as the version.

## Rollback

Two independent layers implement rollback:

1. **GRUB counting** (`wic/grub.cfg`): while `upgrade_available=1`, each boot
   increments `bootcount`; when `bootcount >= bootlimit` GRUB flips `default` to
   the other slot and clears `upgrade_available`.
2. **greenboot** health checks: on a healthy boot, `grub-ab`'s green.d hook
   resets `bootcount` and aktualizr's `complete-install` clears
   `upgrade_available`. On an unhealthy boot, greenboot's `redboot-auto-reboot`
   reboots (burning through `bootcount`) until GRUB rolls back.

greenboot's stock scripts use `fw_printenv`/`fw_setenv` (U-Boot). On x86 there is
no U-Boot, so `grub-ab` ships **grubenv wrappers** named `fw_printenv`/`fw_setenv`
that operate on `/boot/efi/EFI/BOOT/grubenv`, making greenboot's rollback work
unchanged.

> Rollback protects against a bad rootfs **image**. It does not undo bad
> persistent config in `/etc` (a shared overlay across slots) — see
> [persistence](./persistence.md).

## Testing rollback

**Quick (GRUB logic only)** — only if the other slot already holds a valid OS:

```sh
sudo grub-editenv /boot/efi/EFI/BOOT/grubenv set upgrade_available=1 bootcount=3 bootlimit=3
sudo reboot          # GRUB sees the trial exhausted and flips to the other slot
```

**Full (greenboot → auto-reboot → rollback)** — build a throwaway bad image:

```sh
# build server
echo 'IMAGE_INSTALL:append = " torizon-ab-rollback-test"' >> conf/local.conf
MACHINE=genericx86-64 DISTRO=torizon-ab bitbake torizon-ab-swu
# push as a NEW package version, update the device into it, then observe:
sudo journalctl -u greenboot-healthcheck -u redboot-auto-reboot -b
grub-editenv /boot/efi/EFI/BOOT/grubenv list   # default flips back to the good slot
# afterwards: remove the local.conf line and rebuild a clean image
```

`torizon-ab-rollback-test` installs a required greenboot check that always
fails; baked into the image it lives in the rootfs (overlay *lower*), so only the
bad slot fails and rollback returns to the good slot.

## Manual slot switch

```sh
# default=0 -> slot A, default=1 -> slot B; upgrade_available=0 = permanent (no trial)
sudo grub-editenv /boot/efi/EFI/BOOT/grubenv set default=1 upgrade_available=0 bootcount=0
sudo reboot
```

Only switch to a slot that contains a valid OS.

## Cloud delivery note

Push the rootfs `.swu` as a **custom "Other" package** for the
`<machine>-rootfs` hardware id (Torizon Cloud Web UI, or the API). Note that at
time of writing `torizoncore-builder platform push` routes non-compose/non-ostree
files down the OSTree path unless the file is visible inside its container, and
the bundled `uptane-sign` has an S3 multipart-completion bug on large uploads —
so the Web UI is the reliable path for the large rootfs `.swu`.
