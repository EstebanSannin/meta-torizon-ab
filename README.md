# meta-torizon-ab

A Torizon OS variant **without OSTree**, using a classic **A/B dual-rootfs**
scheme, with the OS update applied by **SWUpdate or RAUC** (selectable per
distro), while keeping the Torizon update/cloud stack: aktualizr (as a
download+verify-only *primary*), Remote Access Client (RAC), tzn-mqtt and
auto-provisioning.

Images: `torizon-minimal-ab` (no container engine) and `torizon-docker-ab`
(with Docker).

First target: **x86-64 GRUB/EFI** — `genericx86-64` (best for QEMU iteration via
`runqemu`) or `intel-corei7-64` (real Intel hardware).

## Updater backends: SWUpdate or RAUC

The same layer builds either backend, selected by the distro. Everything above
aktualizr's **generic-secondary** ("Subsystem Update") seam is shared; only the
action handler and the update payload differ.

| Distro | Backend | Payload | Slot identity | Boot selection / rollback |
|--------|---------|---------|---------------|---------------------------|
| `torizon-ab`      | SWUpdate | `.swu`            | ext4 FS label (`otaroot_a`/`otaroot_b`) | hand-rolled grubenv `bootcount`/`bootlimit` |
| `torizon-ab-rauc` | RAUC     | `.raucb` (signed) | GPT PARTLABEL (`rootfs_a`/`rootfs_b`)    | RAUC's native GRUB backend (`ORDER`/`_OK`/`_TRY`) |

Both confirm/roll back via greenboot health checks. The distro selection is the
only choice you make; the shared foundation lives in
`conf/distro/include/torizon-ab-common.inc`.

See [docs/rauc-decisions.md](./docs/rauc-decisions.md) for the RAUC architecture
and rationale (and the decisions behind this split), and
[docs/rauc-cloud-test.md](./docs/rauc-cloud-test.md) for the RAUC end-to-end
cloud runbook.

## Features

- **No OSTree.** Neither distro enables the `sota` feature, so `sota.bbclass`
  and the OSTree image pipeline are never pulled in; the update stack is re-added
  explicitly.
- **A/B rootfs.** Two rootfs slots (`otaroot_a`/`otaroot_b`), a shared EFI
  partition, and a shared data partition. Kernel+initramfs live inside each slot,
  so a single write of the update payload (`.swu`/`.raucb`) updates
  kernel+userspace atomically per slot.
- **Torizon-native delivery.** The OS update rides aktualizr's **generic
  secondary** mechanism; the primary is verify-only (`[pacman] type = "none"`).
- **Rollback.** greenboot health checks plus the backend's boot-selection
  counting (SWUpdate: GRUB `bootcount`/`bootlimit`; RAUC: `ORDER`/`_OK`/`_TRY`
  via RAUC's GRUB backend) roll back to the previous slot on a bad update.
- **Persistence.** Config (`/etc` overlay), `/home`, and `/var` persist across
  slots on the shared data partition — passwords, SSH host keys, `machine-id`,
  NetworkManager, user data all survive updates.

## Documentation

- [docs/architecture.md](./docs/architecture.md) — components, partition layout,
  layer map, the updater-backend axis, and why it isn't stock Torizon.
- [docs/updates-and-rollback.md](./docs/updates-and-rollback.md) — the end-to-end
  update flow (SWUpdate and RAUC), rollback mechanism, and how to test it.
- [docs/rauc-decisions.md](./docs/rauc-decisions.md) — RAUC architecture, the
  decisions taken, and rejected alternatives.
- [docs/rauc-cloud-test.md](./docs/rauc-cloud-test.md) — RAUC end-to-end cloud
  test runbook (provision → push `.raucb` → aktualizr + RAUC apply → verify).
- [docs/persistence.md](./docs/persistence.md) — `/etc` overlay + `/home` +
  `/var` design, first-boot seeding, and tradeoffs.
- [docs/roadmap.md](./docs/roadmap.md) — task backlog with acceptance criteria
  (delivered + planned work, priorities TBD).

## Prerequisites

The updater layer is not in the Torizon manifest — clone the one for the backend
you build (or both), matching the Yocto release (**scarthgap**):

```sh
cd layers
git clone -b scarthgap https://github.com/sbabic/meta-swupdate.git   # SWUpdate backend
git clone -b scarthgap https://github.com/rauc/meta-rauc.git         # RAUC backend
```

(or add them to your `repo` manifest so they are fetched on `repo sync`).

## Enable the layers

`meta-toradex-torizon` is added dynamically by `setup-environment`, so register
these **after** sourcing the environment (add only the updater layer for the
backend you build):

```sh
bitbake-layers add-layer ../layers/meta-swupdate   # for torizon-ab (SWUpdate)
bitbake-layers add-layer ../layers/meta-rauc       # for torizon-ab-rauc (RAUC)
bitbake-layers add-layer ../layers/meta-torizon-ab
```

## Build

Set `MACHINE` and the `DISTRO` for the backend you want (in `local.conf` or the
environment), then build the image and its update artifact. The update-artifact
target builds the OS image as a dependency, so it produces both the flashable
`.wic` and the update payload.

```sh
# --- SWUpdate backend --- (MACHINE=genericx86-64 DISTRO=torizon-ab)
bitbake torizon-minimal-ab      # A/B OS image (.wic)
bitbake torizon-ab-swu          # its .swu update artifact
bitbake torizon-docker-ab       # Docker image variant
bitbake torizon-docker-ab-swu

# --- RAUC backend --- (MACHINE=genericx86-64 DISTRO=torizon-ab-rauc)
bitbake torizon-minimal-ab      # A/B OS image (.wic)
bitbake torizon-ab-bundle       # its signed .raucb update artifact
```

## Deploy / update

1. Flash the `.wic` to the device (slot A populated, slot B empty), boot,
   provision to Torizon Cloud.
2. Upload the rootfs update payload — `.swu` for `torizon-ab`, `.raucb` for
   `torizon-ab-rauc` — to Torizon Cloud as a **custom "Other" package** for
   `ecu_hardware_id = "<machine>-rootfs"` (Web UI is the reliable path — see
   [updates-and-rollback](./docs/updates-and-rollback.md#cloud-delivery-note-both-backends)).
3. Create/launch the update targeting the `<machine>-rootfs` secondary.

## Status

Both backends run on `genericx86-64` (QEMU): flash, provision, apply a Torizon
Cloud A→B update (the device boots the new slot), keep the previous slot as a
rollback target, and persist `/etc` / `/home` / `/var`. RAUC is additionally
verified via a local `rauc install`.

> **Known issue — cloud reports failed after a RAUC cloud update (reboot race,
> under investigation).** The OS update is applied correctly on the device (it
> boots the new slot), but aktualizr can report it to Torizon Cloud as **failed**:
> the reboot is triggered from inside the install action and can outrun
> aktualizr's durable pending-install record. See
> [docs/updates-and-rollback.md](./docs/updates-and-rollback.md) and
> [docs/rauc-decisions.md](./docs/rauc-decisions.md). Full greenboot-driven
> *rollback* is wired but not yet validated end-to-end (roadmap B5).

### Known follow-ups / tuning

- **Production image sizing.** The rootfs `.ext4` is ~1.5× content
  (`IMAGE_OVERHEAD_FACTOR`); slots must exceed it (currently 4 GiB). Shrink it
  (`IMAGE_OVERHEAD_FACTOR=1` / fixed `IMAGE_ROOTFS_SIZE`) to reduce slot and
  payload size.
- **Signing / keys.** RAUC bundles are always signed; the RAUC backend currently
  ships in-tree **development** keys — replace with production key management
  before shipping. For the SWUpdate backend, `.swu` signing is optional (the
  payload is already Uptane-verified by aktualizr) and not yet enabled.
- **Primary Uptane target** — the primary is inert (`type=none`); decide what,
  if anything, it should track for cloud reporting.
- **Multi-machine** — U-Boot targets (e.g. `verdin-imx8mp`) need a U-Boot-env
  bootloader/rollback path and an eMMC WKS; the machine-specific bits are
  intentionally isolated (`grub-ab` / `rauc-grub-ab`, wks, boot-env glue) to make
  the port tractable. RAUC also has a u-boot backend, so the updater axis is
  ready for it.
```
