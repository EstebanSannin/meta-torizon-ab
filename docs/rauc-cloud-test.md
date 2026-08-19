# RAUC A/B — end-to-end cloud update test (aktualizr + Torizon Cloud)

Validates the full production path: provision the device to Torizon Cloud, push
a RAUC bundle as a custom package for the OS rootfs secondary, and let aktualizr
+ `rauc_actions.sh` apply it to the inactive A/B slot.

This is the same aktualizr generic-secondary seam as the SWUpdate variant; only
the handler (`rauc_actions.sh` → `rauc install`) and payload (`.raucb`) differ.

## Build the artifacts

```sh
# MACHINE=genericx86-64 DISTRO=torizon-ab-rauc  (in local.conf or the environment)
bitbake torizon-minimal-ab torizon-ab-bundle
```

Outputs land in `${DEPLOY_DIR_IMAGE}` (i.e. `<build>/deploy/images/<machine>/`;
note the Torizon distro places `DEPLOY_DIR` under the build directory, not under
`tmp/`):

- Flashable A/B image: `torizon-minimal-ab-<machine>.wic`
- RAUC bundle (upload this): `torizon-ab-bundle-<machine>.raucb`
- Secondary hardware id: **`<machine>-rootfs`** (e.g. `genericx86-64-rootfs`)
- Bundle compatible string: `torizon-ab-rauc-<machine>`

## Run a device (QEMU)

For QEMU iteration, boot the `.wic` with `runqemu`. Use a **writable, persistent**
disk (no `snapshot`) so provisioning and the applied update survive reboots:

```sh
runqemu genericx86-64 ovmf wic nographic slirp
```

`runqemu` forwards host `localhost:2222` → the guest's SSH. For a from-scratch
run, re-flash the `.wic` (or use a fresh copy) to get a clean, unprovisioned
slot-A image.

> On real x86 hardware, flash the `.wic` to the target medium instead; the flow
> below is identical once the device has network access to Torizon Cloud.

## Log in

Default user `torizon` / password `torizon`; the first login forces a password
change (stock Torizon). Console, or SSH:

```sh
ssh -p 2222 torizon@localhost
```

## Provision to Torizon Cloud

Provision the running device to your Torizon Cloud account using your normal
flow (shared/offline provisioning credentials). aktualizr config lives under
`/var/sota` (`sota.toml`, `conf.d/`); the OS-update secondary is registered in
`/var/sota/storage/rootfs/` and `secondaries.json` (hwid `<machine>-rootfs`).

Confirm registration:

```sh
sudo aktualizr-info          # shows the primary + the '<machine>-rootfs' secondary
```

## Push the update

1. Upload `torizon-ab-bundle-<machine>.raucb` to Torizon Cloud as a **custom
   "Other" package** for `ecu_hardware_id = <machine>-rootfs` (Web UI is the
   reliable path for large rootfs artifacts — see the cloud-delivery note in
   [updates-and-rollback.md](./updates-and-rollback.md#cloud-delivery-note-both-backends)).
2. Create/launch an update targeting that secondary for the device.

## Watch it apply (on the device)

```sh
sudo journalctl -fu aktualizr-torizon
sudo tail -f /var/lib/rollback-manager/rootfs-update.log     # rauc_actions.sh + rauc output
sudo rauc status                                              # slot states / activation
```

Expected sequence:

1. aktualizr downloads + Uptane-verifies the bundle to
   `/var/sota/storage/rootfs/rootfs.raucb`, then calls `rauc_actions.sh install`.
2. The handler unmounts any auto-mounted inactive slot and runs `rauc install`,
   which writes the inactive slot, verifies the bundle signature against
   `/etc/rauc/keyring.pem`, and arms the bootloader (grubenv `ORDER`).
3. `/run/need-reboot` → `torizon-ab-pending-reboot` reboots.
4. GRUB boots the freshly-installed slot (`rauc.slot=B`, `root=PARTLABEL=rootfs_b`).
5. greenboot health check passes → `rauc status mark-good`.
6. aktualizr `complete-install` reports success; the cloud shows the new version
   installed on `<machine>-rootfs`.

Verify on device:

```sh
cat /proc/cmdline           # rauc.slot=<A|B>
findmnt -no SOURCE /         # /dev/disk/by-partlabel/rootfs_<a|b>
sudo rauc status             # booted=<new slot> good; other slot retained (rollback)
```

## Notes / gotchas

- The bundle is **plain**-format and **dev-signed** (`/etc/rauc/keyring.pem` is a
  development cert — NOT for production).
- The target kernel must have `CONFIG_SQUASHFS` (RAUC mounts the bundle squashfs
  on-target); provided by `recipes-kernel/linux/linux-yocto_%.bbappend`.
- RAUC addresses slots by GPT PARTLABEL (`rootfs_a`/`rootfs_b`); the slots carry
  no ext4 label, so the automounter leaves the inactive slot alone.
- If `rauc install` ever reports the slot device busy, something auto-mounted it;
  `rauc_actions.sh` unmounts inactive slots defensively before installing.
