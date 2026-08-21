# Updates and rollback

This layer has two updater backends (see
[architecture](./architecture.md#two-updater-backends-one-layer)); the flow and
rollback mechanism differ below the aktualizr seam. The **SWUpdate** flow and
its rollback are described first; the **RAUC** flow and rollback are at the end.

## SWUpdate update flow (A → B)

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

## Rollback (SWUpdate)

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

## Testing rollback (SWUpdate)

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

## Manual slot switch (SWUpdate)

```sh
# default=0 -> slot A, default=1 -> slot B; upgrade_available=0 = permanent (no trial)
sudo grub-editenv /boot/efi/EFI/BOOT/grubenv set default=1 upgrade_available=0 bootcount=0
sudo reboot
```

Only switch to a slot that contains a valid OS.

## Cloud delivery note (both backends)

Push the rootfs payload — `.swu` for `torizon-ab`, `.raucb` for
`torizon-ab-rauc` — as a **custom "Other" package** for the `<machine>-rootfs`
hardware id (Torizon Cloud Web UI, or the API). Note that at time of writing
`torizoncore-builder platform push` routes non-compose/non-ostree files down the
OSTree path unless the file is visible inside its container, and the bundled
`uptane-sign` has an S3 multipart-completion bug on large uploads — so the Web UI
is the reliable path for the large rootfs payload.


## RAUC update flow (torizon-ab-rauc)

Same seam as above; the secondary's `action_handler_path` is
`/usr/bin/rauc_actions.sh` and the payload is a signed `.raucb` bundle.

```
Torizon Cloud (Uptane/TUF)
   |  rootfs .raucb (custom "Other" package for <machine>-rootfs)
   v
aktualizr-torizon      download + Uptane-verify -> /var/sota/storage/rootfs/rootfs.raucb
   |  calls the action handler: install
   v
/usr/bin/rauc_actions.sh (install)
   1. unmount any auto-mounted inactive slot (defensive)
   2. rauc install rootfs.raucb   -> verify signature (keyring), raw-write inactive
                                      slot, arm bootloader (grubenv ORDER/_OK/_TRY)
   3. record trial target; touch /run/need-reboot -> {"status":"need-completion"}
   v
torizon-ab-pending-reboot -> reboot
   v
GRUB (grub-rauc.cfg): boot the slot first in ORDER with _OK=1,_TRY=0; set its
   _TRY=1; kernel gets root=PARTLABEL=rootfs_<a|b> rauc.slot=<A|B>
   v
greenboot health check
   - healthy   -> `rauc status mark-good` (clears _TRY, sets _OK); aktualizr
                   complete-install reports success
   - unhealthy -> reboot; the trial _TRY stays set, so the next boot falls
                   through ORDER to the other slot (rollback)
```

### Known issue — cloud reports failed (reboot race, under investigation)

In the flow above, the reboot is triggered from *inside* the install action
(`rauc_actions.sh` touches `/run/need-reboot`, watched by
`torizon-ab-pending-reboot`). Because the OS rides an aktualizr **secondary**
(primary `[pacman]=none`, which never reboots itself), this handler-driven
reboot can fire *before* aktualizr durably records the pending install
(`kPending`) — so on the next boot `checkAndUpdatePendingSecondaries()` finds
nothing to complete, `complete-install` never runs, and aktualizr reports the
update **failed** to the cloud. The device is nonetheless correctly running the
new slot (RAUC armed it), and the previous slot is retained for rollback — this
is a reporting/sequencing bug, not a broken update. The same handler pattern
exists in the SWUpdate variant. Diagnosis and fix direction (observed-state
reconciliation via `get-firmware-info`, **not** a `sleep`) live in
[rauc-decisions.md](./rauc-decisions.md).

### RAUC vs SWUpdate rollback

RAUC's GRUB backend owns the boot-selection/rollback accounting (`ORDER`,
`<bootname>_OK`, `<bootname>_TRY`), replacing the SWUpdate variant's
`bootcount`/`bootlimit` logic and the `fw_printenv`/`fw_setenv` grubenv wrappers.
greenboot remains the health authority; its green.d hook calls
`rauc status mark-good` instead of resetting a counter.

See [rauc-cloud-test.md](./rauc-cloud-test.md) for the full cloud test runbook
and [rauc-decisions.md](./rauc-decisions.md) for the design rationale.

### Testing rollback and manual slot switch (RAUC)

Inspect state with `rauc status` (booted slot, each slot's good/bad flag, and
which slot is activated for the next boot).

**Manual slot switch** — activate the other slot for the next boot:

```sh
sudo rauc status mark-active other
sudo reboot
```

**Force a rollback** — mark the currently-booted slot bad so the bootloader
falls through `ORDER` to the other slot on the next boot:

```sh
sudo rauc status mark-bad booted
sudo reboot
```

**Full greenboot-driven rollback** — ship a deliberately-unhealthy slot with the
`torizon-ab-rollback-test` package (baked into the image, it lives in the rootfs
so only the bad slot fails). After an A→B update into it, the health check
fails, the new slot is never `mark-good`'d, and the next boot falls through to
the previous good slot:

```sh
# build server
echo 'IMAGE_INSTALL:append = " torizon-ab-rollback-test"' >> conf/local.conf
MACHINE=genericx86-64 DISTRO=torizon-ab-rauc bitbake torizon-minimal-ab torizon-ab-bundle
# push the .raucb as a NEW package version, update the device into it, then observe:
sudo journalctl -u greenboot-healthcheck -u redboot-auto-reboot -b
sudo rauc status         # booted slot returns to the previous good slot
# afterwards: remove the local.conf line and rebuild a clean image
```
