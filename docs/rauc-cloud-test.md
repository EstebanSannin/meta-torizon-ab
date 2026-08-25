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
6. On the next boot aktualizr finalizes the install and reports to the cloud.

> ⚠️ **Known issue — reboot race (under investigation).** Step 3's reboot is
> triggered from *inside* the install action (`rauc_actions.sh` touches
> `/run/need-reboot`), so it can outrun aktualizr writing its durable
> pending-install (`kPending`) record. The device still ends up correctly on the
> new slot (RAUC armed it in step 2), but aktualizr may report the update as
> **failed** to Torizon Cloud, and `complete-install` never runs on the next
> boot. The physical update and the retained rollback slot are unaffected — this
> is purely a reporting/sequencing bug. Diagnosis and fix direction (observed-
> state reconciliation via `get-firmware-info`, *not* a sleep) are in
> [rauc-decisions.md](./rauc-decisions.md).

Verify on device:

```sh
cat /proc/cmdline           # rauc.slot=<A|B>
findmnt -no SOURCE /         # /dev/disk/by-partlabel/rootfs_<a|b>
sudo rauc status             # booted=<new slot> good; other slot retained (rollback)
```

## Verified on real hardware — Verdin AM62p (2026-08-25)

The full cloud path was driven **headlessly via the Torizon Cloud REST API**
(base `https://app.torizon.io/api/v2`, Bearer auth) against a physical Verdin
AM62p, board on slot B → cloud update **B→A**. See
[am62p-hardware-loop.md](./am62p-hardware-loop.md) for board access.

**Provisioning the running board (no reflash), API-driven.** The stock image is
DeviceCred/implicit (`/usr/lib/sota/conf.d/20-sota-device-cred.toml` → aktualizr
imports `/var/sota/import/{client.pem,pkey.pem}`, CA `/usr/lib/sota/root.crt`,
gateway `dgw.torizon.io`). A Torizon Cloud `credentials.zip` gives two narrowly
scoped OAuth2 clients (`client_credentials` grant at the `kc.torizon.io`
`ota-users` realm): a **provision** client (`create:devices`) and a **garage-tools**
client (repo/TUF). Steps:
1. `POST /devices {deviceId,deviceName}` with the provision token → returns a
   per-device zip (`client.pem`, `pkey.pem`, `root.crt`, `gateway.url`, `info.json`
   with the deviceUuid).
2. Install `client.pem`+`pkey.pem` into `/var/sota/import/` (root:root, 0600) —
   the service is gated by `ConditionPathExists=|/var/sota/import/pkey.pem`.
3. `systemctl start aktualizr-torizon` → it imports the creds, registers the
   primary + secondaries (incl. `<machine>-rootfs`), `Provisioned on server: yes`.

**The provision + garage-tools clients cannot reach `/packages` or `/updates`
(403).** Uploading a package and launching an update need a **broader API client**
(scopes incl. `write:packages`, `write:updates`, `read:devices`) — create one in
the Torizon Cloud console. Then, entirely via API:
- **Upload:** `POST /packages?name=<n>&version=<v>&hardwareId=<machine>-rootfs&targetFormat=BINARY`
  with `Content-Type: application/octet-stream` and the `.raucb` as the body
  (`--data-binary @file`; curl sets `Content-Length`). The resulting
  `packageId = <name>-<version>`.
- **Launch:** `POST /updates {"packageIds":["<packageId>"],"devices":["<uuid>"]}`
  → `201` with `{affected:[…]}` (note: **no** `updateId` in this response — read
  per-device status via `GET /updates/devices/{uuid}`). `PATCH /updates/{id}`
  cancels while still *Pending*.
- Force an immediate check instead of waiting for the 300 s poll:
  `systemctl restart aktualizr-torizon` on the device.
- **Status:** `GET /updates/devices/{uuid}` (→ `Completed`), `GET /devices?deviceUuid=…`
  (→ `UpToDate`). App-API list responses use a `{"values":[…]}` envelope.

**Result:** download + Uptane-verify → `rauc install` to inactive slot A → armed
`BOOT_ORDER=A B`/`BOOT_A_LEFT=3` → pending-reboot rebooted → U-Boot
`RAUC: booting slot A` → `rauc.slot=A`/`root=PARTLABEL=rootfs_a` → greenboot
`mark-good` → `rauc status`: booted A good, **slot B retained good (rollback
intact)**; cloud reports **Completed / UpToDate**.

**The reboot race did *not* reproduce on this hardware.** On boot aktualizr logged
*"current update is pending → Trying to complete pending update … on Secondary
<rootfs> → has been installed → No pending update for Primary"* and reported
success — i.e. it durably recorded `kPending` **before** the (slow: greenboot +
plymouth + shutdown, ~1.5 min) reboot, then reconciled from the secondary's
installed state on the next boot. Real-hardware reboot latency comfortably exceeds
aktualizr's `kPending` write, so the QEMU-observed window is lost. The
`get-firmware-info` observed-state hardening in [rauc-decisions.md](./rauc-decisions.md)
is therefore a belt-and-suspenders robustness item here, not a functional blocker
(still worthwhile for fast-rebooting targets / power-cut safety).

*Minor wart:* a one-shot startup burst `curl error 58 … Problem with the local
SSL certificate` while posting update **events** right after boot (before TLS
settled); the core manifest report still succeeded (cloud went `Completed`). Worth
characterizing, non-blocking.

## Notes / gotchas

- The bundle is **plain**-format and **dev-signed** (`/etc/rauc/keyring.pem` is a
  development cert — NOT for production).
- The target kernel must have `CONFIG_SQUASHFS` (RAUC mounts the bundle squashfs
  on-target); provided by `recipes-kernel/linux/linux-yocto_%.bbappend`.
- RAUC addresses slots by GPT PARTLABEL (`rootfs_a`/`rootfs_b`); the slots carry
  no ext4 label, so the automounter leaves the inactive slot alone.
- If `rauc install` ever reports the slot device busy, something auto-mounted it;
  `rauc_actions.sh` unmounts inactive slots defensively before installing.
