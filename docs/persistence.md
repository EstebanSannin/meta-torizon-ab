# Persistent state across A/B slots

In an A/B system the two rootfs slots are **ephemeral** — an update overwrites
the inactive slot wholesale with a new rootfs image. Anything stored *inside* a
rootfs slot (`/etc`, `/home`, package-provided `/var` defaults) would therefore
be lost the moment you switch or update slots. Stock Torizon avoids this with
OSTree (shared `/var` + a 3-way `/etc` merge); since this variant removes
OSTree, it provides its own persistence layer.

All persistent state lives on a **single shared data partition**
(`LABEL=data`, GPT partition 4), and is wired up **in the initramfs, before
`switch_root`**, by `initramfs-module-torizon-ab-persist`
(`/init.d/92-persist`, which runs after `90-rootfs` mounts the active slot and
before `99-finish` switches into it).

## What persists and how

| Path    | Mechanism                                   | Backing store            |
|---------|---------------------------------------------|--------------------------|
| `/var`  | direct mount of the data partition          | data partition (whole)   |
| `/etc`  | **overlayfs**: lower = slot `/etc`, upper/work on data | `data:/persist/etc/{upper,work}` |
| `/home` | bind mount                                  | `data:/persist/home`     |

Because these are set up under `$ROOTFS_DIR` before `switch_root`, they become
`/var`, `/etc`, and `/home` of the running system and survive the pivot.

### `/etc` overlay semantics

`/etc` is an overlay of two layers:

- **lower** = the booted slot's `/etc` — the *image defaults* for this OS version.
- **upper** = `data:/persist/etc/upper` — *admin changes*, persistent.

Consequences:

- Edits made at runtime (password → `/etc/shadow`, SSH host keys `/etc/ssh`,
  `machine-id`, NetworkManager `system-connections`, …) are written to the
  upper layer on the data partition, so they **persist across slot switches and
  updates**.
- A new image can still change `/etc` defaults: for any file the admin never
  touched, the new slot's lower layer shows through. Only when *both* the admin
  changed a file *and* the update changed the same file does the admin's version
  (upper) win. This is the same tradeoff OSTree's 3-way merge manages, minus the
  automatic merge.

`/var` and `/home` are plain persistent storage (no layering): whatever is
written stays.

## First-boot seeding

On the very first boot of a device the data partition is empty. Before mounting
it over `/var`, the persist module **seeds** it once (keyed by a
`.torizon-ab-seeded` marker on the data partition):

- copies the factory slot's `/var` content onto the data partition (so
  package-provided `/var` defaults are not hidden by an empty partition);
- creates `persist/etc/{upper,work}` and `persist/home`;
- copies the factory `/home` (user skeletons) into `persist/home`.

Subsequent boots — including after an A→B update — skip seeding, so the data
partition (and therefore all persistent state) is untouched by updates.

## Verifying it at runtime

```sh
findmnt /etc          # TYPE = overlay, upperdir/workdir under /var/persist/etc
findmnt /var          # /dev/disk/by-label/data (ext4)
findmnt /home         # data[/persist/home]
```

(The `upperdir=/rootfs/...` string shown by `findmnt` is just the mount-time
path from the initramfs; overlayfs holds the real references, so it is cosmetic.)

## Design notes and caveats

- **overlayfs must be available in the kernel.** On `genericx86-64` it is
  built-in (`CONFIG_OVERLAY_FS=y`). On a kernel where it is a module, add that
  module to the initramfs image; the persist script `modprobe overlay` first.
- **`/etc` and `/home` are NOT in `/etc/fstab`.** The initramfs owns them (along
  with `/var`); fstab only carries `/boot/efi`, `proc`, `/tmp`, and `devpts`. Do
  not re-add `/var` there. Note the `devpts … gid=5,mode=620` line is required:
  we replace oe-core's default fstab, and without that entry `/dev/pts` lacks the
  `tty` group, which breaks RAC's unprivileged spawned sshd (remote access).
- **Rollback protects the rootfs, not persistent config.** Because `/etc` is a
  shared overlay, a bad configuration written to `/etc` at runtime affects
  *both* slots — rolling back the rootfs does not undo it. A/B rollback defends
  against a bad *image* (bad binary/kernel/config shipped in the rootfs), which
  lives in the overlay *lower* and differs per slot.
- **Data partition sizing.** The data partition also holds the downloaded
  `.swu` during an update (`/var/sota`) and, for the docker variant,
  `/var/lib/docker`. Size it accordingly (currently 4 GiB — see
  [partitioning](./architecture.md#partition-layout)).
- **`machine-id`.** Persisted via `/etc`, so device identity is stable across
  updates.
