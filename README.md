# meta-torizon-ab

A Torizon OS variant **without OSTree**, using a classic **A/B dual-rootfs**
scheme updated by **SWUpdate**, while keeping the Torizon update/cloud stack:
aktualizr (as a download+verify-only *primary*), Remote Access Client (RAC),
tzn-mqtt and auto-provisioning.

Images: `torizon-minimal-ab` (no container engine) and `torizon-docker-ab`
(with Docker).

First target: **x86-64 GRUB/EFI** — `genericx86-64` (best for QEMU iteration via
`runqemu`) or `intel-corei7-64` (real Intel hardware).

## Features

- **No OSTree.** The `torizon-ab` distro does not enable the `sota` feature, so
  `sota.bbclass` and the OSTree image pipeline are never pulled in; the update
  stack is re-added explicitly.
- **A/B rootfs + SWUpdate.** Two rootfs slots (`otaroot_a`/`otaroot_b`), a shared
  EFI partition, and a shared data partition. Kernel+initramfs live inside each
  slot, so one `.swu` write updates kernel+userspace atomically.
- **Torizon-native delivery.** The OS update rides aktualizr's **generic
  secondary** ("Subsystem Update") mechanism; the primary is verify-only
  (`[pacman] type = "none"`).
- **Rollback.** GRUB `bootcount`/`bootlimit` + greenboot health checks roll back
  to the previous slot on a bad update.
- **Persistence.** Config (`/etc` overlay), `/home`, and `/var` persist across
  slots on the shared data partition — passwords, SSH host keys, `machine-id`,
  NetworkManager, user data all survive updates.

## Documentation

- [docs/architecture.md](./docs/architecture.md) — components, partition layout,
  layer map, and why it isn't stock Torizon.
- [docs/updates-and-rollback.md](./docs/updates-and-rollback.md) — the end-to-end
  update flow, rollback mechanism, and how to test it.
- [docs/persistence.md](./docs/persistence.md) — `/etc` overlay + `/home` +
  `/var` design, first-boot seeding, and tradeoffs.

## Prerequisites

Depends on **meta-swupdate** (not in the Torizon manifest). Add it, matching the
Yocto release (**scarthgap**):

```sh
cd layers
git clone -b scarthgap https://github.com/sbabic/meta-swupdate.git
```

(or add it to your `repo` manifest so it is fetched on `repo sync`).

## Enable the layers

`meta-toradex-torizon` is added dynamically by `setup-environment`, so register
these layers **after** sourcing the environment:

```sh
bitbake-layers add-layer ../layers/meta-swupdate
bitbake-layers add-layer ../layers/meta-torizon-ab
```

## Build

```sh
# MACHINE=genericx86-64 DISTRO=torizon-ab in local.conf (or the environment)

# Minimal (no container engine):
bitbake torizon-minimal-ab      # A/B OS image (.wic)
bitbake torizon-ab-swu          # its .swu update artifact

# Docker:
bitbake torizon-docker-ab
bitbake torizon-docker-ab-swu
```

`bitbake torizon-ab-swu` builds the OS image as a dependency, so it produces both
the flashable `.wic` and the `.swu`.

## Deploy / update

1. Flash the `.wic` to the device (slot A populated, slot B empty), boot,
   provision to Torizon Cloud.
2. Upload the rootfs `.swu` to Torizon Cloud as a **custom "Other" package** for
   `ecu_hardware_id = "<machine>-rootfs"` (Web UI is the reliable path — see
   [updates-and-rollback](./docs/updates-and-rollback.md#cloud-delivery-note)).
3. Create/launch the update targeting the `<machine>-rootfs` secondary.

## Status

Working end-to-end on `genericx86-64` (QEMU): flash, provision, A→B update via
the cloud, boot into the new slot, rollback, and persistent `/etc` / `/home` /
`/var`.

### Known follow-ups / tuning

- **Production image sizing.** The rootfs `.ext4` is ~1.5× content
  (`IMAGE_OVERHEAD_FACTOR`); slots must exceed it (currently 4 GiB). Shrink it
  (`IMAGE_OVERHEAD_FACTOR=1` / fixed `IMAGE_ROOTFS_SIZE`) to reduce slot and
  `.swu` size.
- **Signed `.swu`** (SWUpdate signature) for defense-in-depth (optional; the
  `.swu` is already Uptane-verified by aktualizr).
- **Primary Uptane target** — the primary is inert (`type=none`); decide what,
  if anything, it should track for cloud reporting.
- **Multi-machine** — U-Boot targets (e.g. `verdin-imx8mp`) need a U-Boot-env
  bootloader/rollback path and an eMMC WKS; the machine-specific bits are
  intentionally isolated (grub-ab, wks, fw wrappers) to make that port tractable.
