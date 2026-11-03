# meta-torizon-ab

A Torizon OS variant **without OSTree**, using a classic **A/B dual-rootfs**
scheme, with the OS update applied by **SWUpdate or RAUC** (selectable per
distro), while keeping the Torizon update/cloud stack: aktualizr, Remote Access
Client (RAC), tzn-mqtt and auto-provisioning.

Images: `torizon-minimal-ab` (no container engine) and `torizon-docker-ab`
(with Docker).

Machines: **x86-64 GRUB/EFI**, `genericx86-64` (QEMU) or `intel-corei7-64`
(real Intel hardware), and the U-Boot SoMs **`verdin-am62p`** (TI K3) and
**`verdin-imx8mp`** (NXP i.MX).

## Updater backends: SWUpdate or RAUC

The same layer builds either backend, selected by the distro.

| Distro | Backend | Payload | Slot identity | Boot selection / rollback |
|--------|---------|---------|---------------|---------------------------|
| `torizon-ab`      | SWUpdate | `.swu`            | ext4 FS label (`otaroot_a`/`otaroot_b`) | `bootcount`/`bootlimit` in the grubenv or U-Boot env |
| `torizon-ab-rauc` | RAUC     | `.raucb` (signed, verity) | GPT PARTLABEL (`rootfs_a`/`rootfs_b`) | RAUC's GRUB backend (`ORDER`/`_OK`/`_TRY`) or U-Boot backend (`BOOT_ORDER`/`BOOT_<slot>_LEFT`) |

How aktualizr delivers the OS:

- **Generic secondary** (everywhere except RAUC on `genericx86-64`):
  the rootfs is the `<machine>-rootfs` secondary, whose action handler applies
  the payload to the inactive slot; the primary only downloads and verifies
  (`[pacman] type = "none"`).
- **RAUC package manager** (RAUC on `genericx86-64`, `TORIZON_AB_PACMAN = "rauc"`):
  the rootfs is the primary's own target, as with `ostree` in stock Torizon.
  aktualizr's `rauc` package manager (an aktualizr fork, not yet upstream) drives
  RAUC over D-Bus; RAUC streams the bundle from the cloud instead of downloading
  it. See [docs/rauc-decisions.md](./docs/rauc-decisions.md) D8.

Both backends confirm or roll back via greenboot health checks. The distro is the
only choice you make; the shared foundation lives in
`conf/distro/include/torizon-ab-common.inc`.

## Features

- **No OSTree.** Neither distro enables the `sota` feature, so `sota.bbclass`
  and the OSTree image pipeline are never pulled in; the update stack is re-added
  explicitly.
- **A/B rootfs.** Two rootfs slots and a shared data partition (plus a shared
  EFI partition on x86). Kernel+initramfs live inside each slot, so a single
  write of the update payload (`.swu`/`.raucb`) updates kernel+userspace
  atomically per slot.
- **Torizon-native delivery.** Updates are published to and launched from
  Torizon Cloud, and verified by aktualizr's Uptane client.
- **Rollback.** greenboot health checks plus the backend's boot counting roll
  back to the previous slot on a bad update.
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
- [docs/rauc-signing-keys.md](./docs/rauc-signing-keys.md) — how RAUC's
  bundle-signing keyring is managed: the cert travels with the update, and the
  alternatives considered.
- [docs/uboot-rauc-porting.md](./docs/uboot-rauc-porting.md) — how the variant
  boots on U-Boot machines and what a new machine needs.
- [docs/am62p-hardware-loop.md](./docs/am62p-hardware-loop.md) — the build →
  flash → serial loop on real hardware.
- [docs/persistence.md](./docs/persistence.md) — `/etc` overlay + `/home` +
  `/var` design, first-boot seeding, and tradeoffs.
- [docs/build-publish-pipeline.md](./docs/build-publish-pipeline.md) and
  [docs/release-testing.md](./docs/release-testing.md) — CI build/publish and
  release-testing designs.
- [docs/roadmap.md](./docs/roadmap.md) — task backlog with acceptance criteria
  (delivered + planned work, priorities TBD).

## Prerequisites

The updater layers are not in the Torizon manifest — clone the one for the
backend you build (or both), matching the Yocto release (**wrynose**, Torizon
OS 8):

```sh
cd layers
git clone -b wrynose https://github.com/sbabic/meta-swupdate.git   # SWUpdate backend
git clone -b wrynose https://github.com/rauc/meta-rauc.git         # RAUC backend
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
# --- SWUpdate backend --- (DISTRO=torizon-ab)
bitbake torizon-minimal-ab      # A/B OS image (.wic)
bitbake torizon-ab-swu          # its .swu update artifact
bitbake torizon-docker-ab       # Docker image variant
bitbake torizon-docker-ab-swu

# --- RAUC backend --- (DISTRO=torizon-ab-rauc)
bitbake torizon-minimal-ab      # A/B OS image (.wic)
bitbake torizon-ab-bundle       # its signed .raucb + .raucb.manifest-hash
```

## Deploy / update

1. Flash the `.wic` to the device (the Verdin SoMs over USB recovery, see
   [am62p-hardware-loop.md](./docs/am62p-hardware-loop.md)): slot A populated,
   slot B empty. Boot and provision to Torizon Cloud.
2. Publish the update payload to Torizon Cloud:
   - **Generic secondary:** upload the `.swu`/`.raucb` as a **custom "Other"
     package** for hardware id `<machine>-rootfs`, from the web UI (see
     [updates-and-rollback](./docs/updates-and-rollback.md#cloud-delivery-note-both-backends)).
   - **RAUC package manager (x86):** the bundle is a package for the primary
     (hardware id `<machine>`) with its manifest hash attached, which the web UI
     cannot upload. Use `scripts/publish-rauc-bundle.sh` (`--keyring` to attach
     the signing cert, `--launch` to launch it and wait); see
     [rauc-cloud-test.md](./docs/rauc-cloud-test.md#push-the-update--x86-with-the-rauc-package-manager).
3. Launch the update to the device from the web UI (or the script's `--launch`).

## Status

All six machine × backend combinations are validated on Torizon OS 8: flash,
boot slot A, and an A→B update through Torizon Cloud with the previous slot kept
for rollback — `genericx86-64` on QEMU, `verdin-am62p` and `verdin-imx8mp` on
hardware. The x86 RAUC package manager is validated on QEMU through the cloud:
install and rollback, streaming, and bundles signed by a key the image does not
know (cert shipped with the update). Rollback events, persistence and the details
per combination are in [docs/roadmap.md](./docs/roadmap.md) and
[docs/rauc-cloud-test.md](./docs/rauc-cloud-test.md).

> **Reboot race (generic secondary).** The action handler reboots from inside
> the install, which could outrun aktualizr's pending-install record and make the
> cloud report a good update as failed. Seen on QEMU, not reproduced on hardware;
> it cannot happen with the x86 RAUC package manager. See
> [docs/rauc-decisions.md](./docs/rauc-decisions.md) and roadmap B13.

### Known follow-ups / tuning

- **Production image sizing.** The rootfs `.ext4` is ~1.5× content
  (`IMAGE_OVERHEAD_FACTOR`); slots must exceed it (currently 4 GiB). Shrink it
  (`IMAGE_OVERHEAD_FACTOR=1` / fixed `IMAGE_ROOTFS_SIZE`) to reduce slot and
  payload size.
- **Signing / keys.** RAUC bundles are always signed; the image's built-in
  keyring is still the in-tree **development** cert — replace it with production
  keys before shipping. On the x86 RAUC package manager the cert can travel with
  the update instead ([rauc-signing-keys.md](./docs/rauc-signing-keys.md)). For
  the SWUpdate backend, `.swu` signing is optional (the payload is already
  Uptane-verified by aktualizr) and not yet enabled.
- **Streaming speed.** Torizon Cloud serves bundles from S3 over HTTP/1.1, so a
  full 1.1 GB bundle streams in ~13 min against ~17 s to download (roadmap B16).
- **RAUC package manager on ARM.** It is `genericx86-64` only so far; the U-Boot
  machines still use the generic secondary with an inert primary.
