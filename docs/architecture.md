# Architecture

`meta-torizon-ab` builds a Torizon OS variant **without OSTree**, using a
classic **A/B dual-rootfs** scheme, with the OS update applied by **SWUpdate or
RAUC** (selectable per distro), while keeping the Torizon update/cloud stack
(aktualizr, Remote Access Client, tzn-mqtt, auto-provisioning) and the rest of
the Torizon default packages.

First target: **x86-64 / GRUB-EFI** (`genericx86-64`, `intel-corei7-64`).

## Why not just reuse stock Torizon?

Stock Torizon couples the whole update stack to a single `sota` distro feature,
which pulls in `sota.bbclass` and forces the OSTree image classes, the
`ostree`/`ostree-kernel`/`ostree-initramfs` packages, the OTA image fstypes, an
OSTree-layout rootfs, an OSTree-aware initramfs, and OSTree-deployment-switching
bootloaders. This variant deliberately does **not** enable `sota`, and re-adds
only the pieces it wants.

## Two updater backends, one layer

The OS update is delivered through the **same seam** regardless of backend —
aktualizr's **generic secondary** ("Subsystem Update"), whose action handler
applies an opaque payload to the inactive slot. The backend is chosen by distro:

| | `torizon-ab` (SWUpdate) | `torizon-ab-rauc` (RAUC) |
|---|---|---|
| Update payload | `.swu` | `.raucb` (signed) |
| Action handler | `swupdate_actions.sh` | `rauc_actions.sh` |
| Slot identity | ext4 FS label `otaroot_a`/`otaroot_b` | GPT PARTLABEL `rootfs_a`/`rootfs_b` |
| Slot write | SWUpdate raw-write + `e2label` relabel | `rauc install` raw-write (no relabel) |
| Boot select / rollback | hand-rolled grubenv `bootcount`/`bootlimit` (`wic/grub.cfg`) | RAUC's GRUB backend `ORDER`/`_OK`/`_TRY` (`wic/grub-rauc.cfg`) |
| WKS | `wic/torizon-ab-x86.wks` | `wic/torizon-ab-rauc-x86.wks` |

Everything **above the seam** is shared: the distro foundation, images,
persistence, initramfs, data auto-expand, udev slot ignore-list, pending-reboot,
and the aktualizr generic-secondary registration. Only the pieces **below the
seam** (handler, payload producer, bootloader glue, on-target updater config)
differ per backend. Full rationale and rejected alternatives:
[rauc-decisions.md](./rauc-decisions.md).

## Components

### Distro
The shared foundation lives in `conf/distro/include/torizon-ab-common.inc`: it
requires `common-torizon.inc` (tune, systemd, users, aktualizr fork, versioning)
but **not** `sota.conf.inc`, so OSTree is never pulled in; it removes the
OSTree/TEZI image classes, points at a plain initramfs, drops `stateless-system`,
and sets the shared image fstypes and slot/partition labels. Two thin distro
confs select the backend by appending a `DISTROOVERRIDES` token:

- `conf/distro/torizon-ab.conf`      → `:torizon-ab:torizon-ab-swupdate`; enables
  the `swupdate` feature; selects the SWUpdate wks.
- `conf/distro/torizon-ab-rauc.conf` → `:torizon-ab:torizon-ab-rauc`; selects the
  RAUC wks; sets `RAUC_COMPATIBLE`.

Every `:torizon-ab` override applies to **both** variants; backend-specific bits
use the finer `:torizon-ab-swupdate` / `:torizon-ab-rauc` token.

### Image
`recipes-images/images/torizon-ab-base.inc` is a trimmed `torizon-base.inc` (no
OSTree packages) that explicitly installs the update stack `:sota` would
otherwise inject — `aktualizr-torizon`, `rac`, `tzn-mqtt`, `auto-provisioning`,
`greenboot`, `aktualizr-pacman-none`, `torizon-ab-slots-udev`,
`torizon-ab-pending-reboot`, `resize-data-helper`, `os-release`, and the kernel/initramfs —
plus the **backend-specific** updater + bootloader glue:

- SWUpdate: `swupdate` + `grub-ab` (x86) / `uboot-ab` (imx8mp).
- RAUC:     `rauc` + `rauc-conf` + `rauc-grub-ab` (x86).

Image recipes: `torizon-minimal-ab` (no container engine) and `torizon-docker-ab`
(with Docker).

### Kernel + initramfs
The kernel and initramfs live **inside each rootfs slot** (`/boot`), so a single
payload write updates kernel + userspace atomically per slot. The initramfs
(`initramfs-torizon-ab-image`, plain OE initramfs-framework, no OSTree module)
mounts the root device passed by GRUB — `root=LABEL=otaroot_a|b` (SWUpdate) or
`root=PARTLABEL=rootfs_a|b` (RAUC) — then sets up persistence (see
[persistence](./persistence.md)). The stock `initramfs-module-rootfs` resolves
both `LABEL=` and `PARTLABEL=`, so no initramfs change is needed per backend.

The **RAUC** backend additionally needs `CONFIG_SQUASHFS` (+ decompressors +
`BLK_DEV_LOOP`) in the kernel, because RAUC mounts the bundle's squashfs on the
target at install time; this is added by
`recipes-kernel/linux/linux-yocto_%.bbappend`.

### Partition layout
Both backends use the same four-partition GPT layout; only the **rootfs-slot
identity** differs. SWUpdate uses `wic/torizon-ab-x86.wks`; RAUC uses
`wic/torizon-ab-rauc-x86.wks`.

<a name="partition-layout"></a>

| # | Partition | FS   | Mount        | SWUpdate id        | RAUC id                         |
|---|-----------|------|--------------|--------------------|---------------------------------|
| 1 | ESP       | vfat | `/boot/efi`  | label `efi`        | label `efi`                     |
| 2 | rootfs A  | ext4 | `/` (slot A) | label `otaroot_a`  | PARTLABEL `rootfs_a` (no fs label) |
| 3 | rootfs B  | ext4 | `/` (slot B) | label `otaroot_b`  | PARTLABEL `rootfs_b` (no fs label) |
| 4 | data      | ext4 | `/var` (+overlay/binds) | label `data` | label `data`             |

The ESP carries GRUB EFI + the backend's `grub.cfg`/`grub-rauc.cfg` + a shared
grubenv; each slot carries its own kernel+initramfs in `/boot`; slot B is empty
at flash and written by the first update. RAUC drops the ext4 label on the slots
so the automounter (usermount/udisks2) leaves the inactive slot alone — otherwise
`rauc install` would fail with the slot "busy" (see rauc-decisions D4).

Slots must be **larger than the decompressed rootfs ext4 image** (not the
compressed payload), which is sized by `IMAGE_OVERHEAD_FACTOR` (~1.5×). Current
slots are 4 GiB. For production, shrink the rootfs image
(`IMAGE_OVERHEAD_FACTOR=1` / fixed `IMAGE_ROOTFS_SIZE`) so slots and the payload
can be smaller.

**Data partition auto-expand.** The `data` partition is the **last** partition
and its size in the `.wks` is only a baked minimum. On first boot,
`resize-data-helper` (`recipes-support/resize-data-helper`) relocates the GPT
backup header, grows the last partition to fill the whole medium
(eMMC/SD/NVMe/disk), and `resize2fs`-grows the ext4 — then marks itself done
with a flag on the data partition so it runs once. This is machine-agnostic
(the same helper works on Verdin/eMMC). It is idempotent and a no-op where there
is no free space (e.g. QEMU, where the disk equals the image — enlarge the disk
to exercise it). `/var` is an online resize since the initramfs has already
mounted it.

### Boot + rollback
GRUB selects the active slot and implements trial-boot rollback, with greenboot
confirming health on each boot:

- **SWUpdate** (`wic/grub.cfg`): grubenv `default` + `bootcount`/`bootlimit`/
  `upgrade_available`; greenboot's green.d hook resets the counter on a healthy
  boot.
- **RAUC** (`wic/grub-rauc.cfg`): RAUC's GRUB-backend variables `ORDER` +
  `<bootname>_OK`/`_TRY`; greenboot's green.d hook calls `rauc status mark-good`
  on a healthy boot.

See [updates-and-rollback](./updates-and-rollback.md).

### Update stack
aktualizr runs as a download+verify-only primary (`[pacman] type = "none"`); the
OS rootfs is delivered as an aktualizr **generic secondary** (`<machine>-rootfs`)
whose action handler applies the payload — `swupdate_actions.sh` (SWUpdate) or
`rauc_actions.sh` (RAUC). The secondary registration
(`recipes-sota/config/aktualizr-default-sec.bbappend`) is shared; only the
handler path and payload filename are per-backend variables. See
[updates-and-rollback](./updates-and-rollback.md).

## Layer contents (map)

```
Shared
  conf/distro/include/torizon-ab-common.inc    shared distro foundation (no sota/OSTree)
  conf/distro/torizon-ab.conf                  SWUpdate distro (thin)
  conf/distro/torizon-ab-rauc.conf             RAUC distro (thin)
  recipes-images/images/torizon-ab-base.inc    shared image contents (+ per-backend installs)
  recipes-images/images/torizon-minimal-ab.bb  minimal image
  recipes-images/images/torizon-docker-ab.bb   docker image
  recipes-core/images/initramfs-torizon-ab-image.bb   plain initramfs
  recipes-core/initramfs-persist/*             /etc overlay + /var + /home (initramfs)
  recipes-core/base-files/*                    static /etc/fstab
  recipes-core/pending-reboot/*                auto-reboot on /run/need-reboot
  recipes-core/udev/*                          keep A/B slots off the automounter (by label + PARTLABEL)
  recipes-support/resize-data-helper/*         grow data partition to fill medium (first boot)
  recipes-support/rollback-test/*              TEST-ONLY failing greenboot check
  recipes-sota/aktualizr-torizon/*.bbappend    drop OSTree pacman backend
  recipes-sota/config/aktualizr-pacman-none.bb [pacman] type = none
  recipes-sota/config/aktualizr-default-sec.bbappend  rootfs secondary (both backends);
                                               per-backend handler path + payload name;
                                               drop bootloader secondary on x86
  recipes-devtools/jq/jq_%.bbappend            build fix: jq in-tree (meta-oe HEAD)

SWUpdate backend
  recipes-support/swupdate/*                   SWUpdate build config
  recipes-sota/config/files/swupdate_actions.sh   the A/B action handler
  recipes-images/swu/*                         .swu producers + sw-description
  wic/torizon-ab-x86.wks, wic/grub.cfg         A/B layout (ext4 labels) + GRUB counting
  recipes-bsp/grub-ab/*                        grubenv bootstrap, rollback reset,
                                               fw_printenv/fw_setenv grubenv wrappers, bootenv.sh
  recipes-bsp/uboot-ab/*                       U-Boot A/B boot script + env (imx8mp)

RAUC backend
  recipes-support/rauc/rauc-conf.bbappend      /etc/rauc/system.conf (PARTLABEL slots) + dev keyring
  recipes-support/rauc/files/keyring.pem       dev verification keyring (NOT for production)
  recipes-sota/config/files/rauc_actions.sh    the A/B action handler (rauc install)
  recipes-images/bundle/*                      signed .raucb producer (+ in-tree dev signing keys)
  wic/torizon-ab-rauc-x86.wks, wic/grub-rauc.cfg  A/B layout (PARTLABEL) + RAUC GRUB bootchooser
  recipes-bsp/rauc-grub-ab/*                   grubenv bootstrap + greenboot `rauc status mark-good`
  recipes-kernel/linux/linux-yocto_%.bbappend  CONFIG_SQUASHFS (+ decompressors, loop)
```
