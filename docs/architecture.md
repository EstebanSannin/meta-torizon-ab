# Architecture

`meta-torizon-ab` builds a Torizon OS variant **without OSTree**, using a
classic **A/B dual-rootfs** scheme updated by **SWUpdate**, while keeping the
Torizon update/cloud stack (aktualizr, Remote Access Client, tzn-mqtt,
auto-provisioning) and the rest of the Torizon default packages.

First target: **x86-64 / GRUB-EFI** (`genericx86-64`, `intel-corei7-64`).

## Why not just reuse stock Torizon?

Stock Torizon couples the whole update stack to a single `sota` distro feature,
which pulls in `sota.bbclass` and forces the OSTree image classes, the
`ostree`/`ostree-kernel`/`ostree-initramfs` packages, the OTA image fstypes, an
OSTree-layout rootfs, an OSTree-aware initramfs, and OSTree-deployment-switching
bootloaders. This variant deliberately does **not** enable `sota`, and re-adds
only the pieces it wants.

## Components

### Distro
`conf/distro/torizon-ab.conf` requires `common-torizon.inc` (tune, systemd,
users, aktualizr fork, versioning) but **not** `sota.conf.inc`, so OSTree is
never pulled in. It removes the OSTree/TEZI image classes, points at a plain
initramfs, drops `stateless-system`, enables the `swupdate` feature, and selects
the A/B wic.

### Image
`recipes-images/images/torizon-ab-base.inc` is a trimmed `torizon-base.inc`
(no OSTree packages) that explicitly installs the update stack that `:sota`
would otherwise inject: `aktualizr-torizon`, `rac`, `tzn-mqtt`,
`auto-provisioning`, `greenboot`, plus `swupdate`, the A/B glue (`grub-ab`,
`aktualizr-pacman-none`, `torizon-ab-slots-udev`, `torizon-ab-pending-reboot`),
and the kernel/initramfs. Image recipes: `torizon-minimal-ab` (no container
engine) and `torizon-docker-ab` (with Docker).

### Kernel + initramfs
The kernel and initramfs live **inside each rootfs slot** (`/boot`), so a single
`.swu` write updates kernel + userspace atomically per slot. The initramfs
(`initramfs-torizon-ab-image`, plain OE initramfs-framework, no OSTree module)
mounts `root=LABEL=otaroot_a|otaroot_b`, then sets up persistence
(see [persistence](./persistence.md)).

### Partition layout
See `wic/torizon-ab-x86.wks`.

<a name="partition-layout"></a>

| # | Partition | Label       | FS   | Mount        | Notes |
|---|-----------|-------------|------|--------------|-------|
| 1 | ESP       | `efi`       | vfat | `/boot/efi`  | GRUB EFI + `grub.cfg` + grubenv (shared) |
| 2 | rootfs A  | `otaroot_a` | ext4 | `/` (slot A) | kernel+initramfs in its `/boot` |
| 3 | rootfs B  | `otaroot_b` | ext4 | `/` (slot B) | empty at flash, written by first update |
| 4 | data      | `data`      | ext4 | `/var` (+ overlay/binds) | shared persistent state |

Slots must be **larger than the decompressed rootfs ext4 image** (not the
compressed `.swu`), which is sized by `IMAGE_OVERHEAD_FACTOR` (~1.5×). Current
slots are 4 GiB. For production, shrink the rootfs image
(`IMAGE_OVERHEAD_FACTOR=1` / fixed `IMAGE_ROOTFS_SIZE`) so slots and the `.swu`
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
GRUB selects the active slot from the shared grubenv (`default`), and rolls back
via `bootcount`/`bootlimit`/`upgrade_available`. greenboot health checks confirm
a good boot or trigger rollback. See [updates-and-rollback](./updates-and-rollback.md).

### Update stack
aktualizr runs as a download+verify-only primary (`[pacman] type = "none"`); the
OS rootfs is delivered as an aktualizr **generic secondary** (Torizon "Subsystem
Update") whose action handler applies the `.swu` with SWUpdate. See
[updates-and-rollback](./updates-and-rollback.md).

## Layer contents (map)

```
conf/distro/torizon-ab.conf                    distro (no sota/OSTree)
recipes-images/images/torizon-ab-base.inc      shared image contents
recipes-images/images/torizon-minimal-ab.bb    minimal image
recipes-images/images/torizon-docker-ab.bb     docker image
recipes-images/swu/*                            .swu producers + sw-description
wic/torizon-ab-x86.wks, wic/grub.cfg           A/B partition layout + GRUB
recipes-core/images/initramfs-torizon-ab-image.bb   plain initramfs
recipes-core/initramfs-persist/*               /etc overlay + /var + /home (initramfs)
recipes-core/base-files/*                       static /etc/fstab
recipes-core/pending-reboot/*                   auto-reboot on /run/need-reboot
recipes-core/udev/*                             keep A/B slots off the automounter
recipes-bsp/grub-ab/*                           grubenv bootstrap, rollback reset,
                                                fw_printenv/fw_setenv grubenv wrappers
recipes-sota/aktualizr-torizon/*.bbappend       drop OSTree pacman backend
recipes-sota/config/aktualizr-pacman-none.bb    [pacman] type = none
recipes-sota/config/aktualizr-default-sec.bbappend  rootfs secondary + handler,
                                                drop bootloader secondary on x86
recipes-sota/config/files/swupdate_actions.sh   the A/B action handler
recipes-support/swupdate/*                      SWUpdate build config
recipes-support/resize-data-helper/*            grow data partition to fill medium (first boot)
recipes-support/rollback-test/*                 TEST-ONLY failing greenboot check
```
