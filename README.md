# meta-torizon-ab

A Torizon OS variant **without OSTree**, using a classic **A/B dual-partition**
scheme updated by **SWUpdate**, while keeping the Torizon update stack:
aktualizr (as a download+verify-only *primary*), Remote Access Client (RAC),
tzn-mqtt and auto-provisioning. Based on `torizon-minimal` (no container engine).

Target of this first cut: **x86-64 GRUB/EFI** — works with either
**`genericx86-64`** (best for QEMU iteration via `runqemu`) or
**`intel-corei7-64`** (real Intel hardware). Both use the same GRUB/EFI/`bzImage`
boot path. All partition access is by filesystem **label**, so the disk device
name (sda / nvme0n1) does not matter at runtime.

Note: `intel-corei7-64` auto-installs `grub-ota-fallback` (the OSTree GRUB
rollback package); this layer removes it (it would collide with `grub-ab`).

## How it works

- **No `sota` DISTRO_FEATURE** → `sota.bbclass` and the OSTree image pipeline are
  never pulled in. The distro (`torizon-ab`) re-adds the update stack explicitly.
- **Partitions** (`wic/torizon-ab-x86.wks`): shared EFI (`efi`), rootfs A
  (`otaroot_a`), rootfs B (`otaroot_b`), shared data (`data`). Kernel + initramfs
  are bundled into the kernel image and live inside each rootfs slot's `/boot`.
- **Boot / rollback** (`wic/grub.cfg` + `grub-ab`): GRUB picks the active slot
  from a shared `grubenv` (`default`, `bootcount`, `bootlimit`,
  `upgrade_available`) and rolls back to the other slot after `bootlimit`
  failed trial boots. greenboot resets the counter on a healthy boot.
- **Update flow** (Torizon *Subsystem Update* / generic secondary):
  1. aktualizr primary = `[pacman] type = "none"` (download + Uptane-verify only,
     via `aktualizr-pacman-none` → `90-pacman.toml`).
  2. The OS rootfs is a generic secondary `"<machine>-rootfs"` added to
     `secondaries.json` (`aktualizr-default-sec.bbappend`), whose action handler
     `/usr/bin/swupdate_actions.sh` runs `swupdate -i rootfs.swu -e stable,slot_X`
     against the **inactive** slot, flips grubenv, and reboots.
  3. After reboot, `complete-install` confirms (or reports rollback).
- The `.swu` is produced by `torizon-ab-swu.bb` (rootfs ext4 + A/B
  `sw-description`).

## Prerequisites

This layer depends on **meta-swupdate** (Sebastian Babic), which is **not** in
the Torizon manifest. Add it, matching the Yocto release (**scarthgap**):

```
cd layers
git clone -b scarthgap https://github.com/sbabic/meta-swupdate.git
```

(or add it to your `repo` manifest so it is fetched on `repo sync`).

## Enable the layers

`meta-toradex-torizon` is added dynamically by `setup-environment`, so the most
robust way to register these two layers is **after** sourcing the environment:

```
bitbake-layers add-layer ../layers/meta-swupdate
bitbake-layers add-layer ../layers/meta-torizon-ab
```

(Alternatively, append both paths to the `BBLAYERS` list in
`layers/meta-toradex-distro/buildconf/bblayers.conf` before the first setup.)

## Build

```
. export        # or: MACHINE=genericx86-64 DISTRO=torizon-ab . setup-environment build

# Minimal (no container engine):
bitbake torizon-minimal-ab      # the A/B OS image (wic)
bitbake torizon-ab-swu          # its .swu update artifact

# Docker (with container engine):
bitbake torizon-docker-ab       # the A/B OS image (wic)
bitbake torizon-docker-ab-swu   # its .swu update artifact
```

The Docker variant is much larger than minimal; if `do_image_wic` fails with a
"does not fit" error, increase the two `otaroot_*` `--fixed-size` values in
`wic/torizon-ab-x86.wks` (e.g. to 4096). Container storage lives under
`/var/lib/docker` on the shared `data` partition, so it persists across A/B
updates.

Set in `build/conf/local.conf` (or the environment):

```
MACHINE = "genericx86-64"
DISTRO  = "torizon-ab"
```

## Deploy / update

- Flash the `.wic` to the device (slot A is populated, slot B empty).
- Register the rootfs `.swu` on Torizon Cloud as a **custom package** for the
  subsystem `ecu_hardware_id = "<machine>-rootfs"` (TorizonCore Builder
  `platform push`, or the Web UI), then trigger the update as usual.

## REVIEW checklist (validate on the build machine / target)

These points are marked `REVIEW` in the files and need a build/boot pass:

1. **grubenv path** — `/boot/efi/EFI/BOOT/grubenv` must match what
   `bootimg-efi`/grub-efi actually writes (`grub.cfg`, `swupdate_actions.sh`,
   `grubenv-create.*`).
2. **Kernel filename** in `grub.cfg` (`/boot/bzImage`) with
   `INITRAMFS_IMAGE_BUNDLE=1`.
3. **SWUpdate kconfig** option names in `torizon-ab.cfg` and the
   `bootloader-grub` PACKAGECONFIG name (version-dependent).
4. **sw-description** filename/`@sha256` handling for your meta-swupdate version.
5. **Slot sizes** in the `.wks` (equal, large enough for a full rootfs).
6. **`[pacman]` override ordering** — confirm `90-pacman.toml` wins over the
   credential fragment's default.
7. **Primary Uptane target** — decide what the (inert) primary tracks.
