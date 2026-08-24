# meta-torizon-ab — working notes

An **OSTree-free Torizon OS A/B** (dual-rootfs) Yocto layer with **two updater
backends selectable by distro**:

| Distro | Backend | Payload |
|--------|---------|---------|
| `torizon-ab`      | SWUpdate | `.swu` |
| `torizon-ab-rauc` | RAUC     | `.raucb` (signed) |

The Torizon cloud stack (aktualizr, RAC, tzn-mqtt, auto-provisioning, greenboot)
is kept; only OSTree is removed and re-implemented as classic A/B.

## Read the docs before changing things

The `docs/` folder is treated as first-class — **keep it in sync with behavior**.

- `docs/architecture.md` — components, partition layout, the backend axis, layer map
- `docs/rauc-decisions.md` — RAUC design decisions, rejected alternatives, open items
- `docs/updates-and-rollback.md` — update + rollback flows (both backends)
- `docs/persistence.md` — `/etc` overlay + `/var` + `/home`
- `docs/rauc-cloud-test.md` — end-to-end Torizon Cloud runbook
- `docs/roadmap.md` — delivered work + backlog (D#/B# items)
- **`docs/am62p-hardware-loop.md` — the build → flash → serial loop on real Verdin
  AM62p hardware (m920x/beerus/Tezi). Read this before any hardware task; it is
  the infrastructure everything on-device depends on.**

## Invariants — keep these true when editing

- **The updater seam is aktualizr's generic secondary.** Primary is inert
  (`[pacman] type = "none"`, download + Uptane-verify only); the OS rootfs is the
  `<machine>-rootfs` secondary; its `action_handler` applies the payload to the
  inactive slot. **Everything above this seam is shared by both backends.**
- **Backend axis via `DISTROOVERRIDES`.** Shared foundation in
  `conf/distro/include/torizon-ab-common.inc`; thin distro confs append a token:
  `:torizon-ab` (shared) + `:torizon-ab-swupdate` / `:torizon-ab-rauc` (backend).
  Backend-specific bits use the finer token. A change to shared code affects
  **both** variants — build both before assuming it's fine.
- **Slot identity differs by backend.** SWUpdate → ext4 FS label
  `otaroot_a/b` (a raw write clobbers it, so the handler restores it with
  `e2label`). RAUC → **GPT PARTLABEL** `rootfs_a/b` (survives raw writes; the
  slots carry **no ext4 label** so the usermount/udisks automounter ignores the
  inactive slot).
- **Action handler stdout is JSON only** — `{"status": "ok|need-completion|failed"}`.
  All other output goes to `/var/lib/rollback-manager/rootfs-update.log`. The
  handler must set `LOG_ENABLED=1` or `common_actions.sh` never creates that log
  dir and the handler aborts.
- **Kernel + initramfs live inside each rootfs slot's `/boot`** (one payload
  write updates kernel+userspace atomically per slot). The **RAUC** kernel needs
  `CONFIG_SQUASHFS` (RAUC mounts the bundle squashfs on-target).
- **greenboot is the health authority.** SWUpdate's green.d resets the grubenv
  bootcount; RAUC's green.d runs `rauc status mark-good`.
- **RAUC's commit point is `rauc install` arming the bootloader** (grubenv
  `ORDER`/`_OK`/`_TRY`) — it is atomic and power-safe. The reboot is only a
  trigger; a power cut there is equivalent to the reboot.

## Build & test (generic)

```sh
# after sourcing setup-environment, add the updater layer for your backend + this layer:
bitbake-layers add-layer ../layers/meta-swupdate    # torizon-ab
bitbake-layers add-layer ../layers/meta-rauc        # torizon-ab-rauc
bitbake-layers add-layer ../layers/meta-torizon-ab

# MACHINE=genericx86-64  DISTRO=torizon-ab | torizon-ab-rauc
bitbake torizon-minimal-ab                # A/B image (.wic)
bitbake torizon-ab-swu                     # SWUpdate payload
bitbake torizon-ab-bundle                  # RAUC payload (signed)
# QEMU (persistent disk for update tests): runqemu genericx86-64 ovmf wic
```

First/primary target is `genericx86-64` (QEMU). `verdin-imx8mp` (U-Boot) is
draft scaffolding (and carries dormant x86 assumptions — see below).
**`verdin-am62p` (TI K3, U-Boot) is the real-hardware, primary target** and is
**proven end-to-end on a physical board**: the A/B RAUC image builds, flashes
headlessly (Tezi), boots slot A, takes a `rauc install` A→B update, and rolls
back a bad slot — all via the RAUC U-Boot backend (`rauc-uboot-ab`,
`bootloader=uboot`, `BOOT_ORDER`/`BOOT_<slot>_LEFT`). See
`docs/am62p-hardware-loop.md` for the build→flash→serial loop and on-device
access. The per-machine bootloader glue is isolated (`grub-ab`/`uboot-ab`,
`rauc-grub-ab`/`rauc-uboot-ab`, per-machine wks) to keep each port tractable.

**Portability rule (learned the hard way on AM62p):** x86/GRUB/EFI was only a
bring-up vehicle; the primary targets are ARM SoMs. Never let an x86 assumption
(`/boot/efi`, `LABEL=efi`, grubenv, `sda`, bzImage, flat DTB path) sit in shared
`:torizon-ab` code — scope the x86 case to `:genericx86-64`/`:intel-corei7-64`
and make the ARM/no-ESP path the DEFAULT, so a new SoM can't silently inherit it
(e.g. `TORIZON_AB_FSTAB` defaults to the no-ESP fstab; x86 opts in).

## Hardware test loop (Verdin AM62p) — read `docs/am62p-hardware-loop.md`

Every on-device task rides on this loop. The short version:

1. **Build** on the remote host: `ssh m920x`, `DISTRO=torizon MACHINE=verdin-am62p ./bb-am62.sh <target>`.
2. **Flash headlessly** via beerus (local, wired to the board): serve the Tezi
   image as an `autoinstall` mDNS feed, recovery-boot Tezi (human: recovery
   button + power-cycle), it auto-installs to eMMC, then `reboot -f`.
3. **Watch** the serial console on beerus: `ttyUSB0` @115200.

Access: `ssh m920x` (remote build host, DDNS) and `ssh beerus` (local; serial +
USB recovery + feed). **The shell is zsh — never `ssh $VAR '...'` (no word split);
use the aliases.** m920x is remote — board-facing services (feed) run on beerus.
Hard-won rule: **never kill the `tezi` process mid-install.** Full details,
commands, and every gotcha are in `docs/am62p-hardware-loop.md`.

## Traps we already hit (don't re-learn them)

- **jq** fails to build out-of-tree on current meta-oe → `recipes-devtools/jq/jq_%.bbappend` sets `B = "${S}"`.
- **os-release** is missing unless re-added (we dropped the OSTree classes that
  generated it, and Torizon's systemd bbappend removes it from RRECOMMENDS) —
  handled in `torizon-ab-base.inc` (install `os-release` + set `VARIANT`).
- Some build hosts have a **broken IPv6 route to CDNs** (e.g. gnome) → force
  `wget` to IPv4 in the *build dir's* `local.conf` (`FETCHCMD_wget += --inet4-only`),
  not in this layer.
- **RAUC reboot race (OPEN):** the handler touching `/run/need-reboot` inside the
  install action can outrun aktualizr's durable `kPending` write, so the cloud
  reports the update *failed* even though the device updated. Fix direction is
  **observed-state reconciliation via `get-firmware-info`** — **not** a
  `sleep`/timing hack (not power-cut safe). See `docs/rauc-decisions.md`.

## Conventions

- Dev signing keys shipped in-tree (`recipes-images/bundle/files/`,
  `recipes-support/rauc/files/keyring.pem`) are **NOT for production**.
- Prefer changes that keep the two backends symmetric behind the seam.
