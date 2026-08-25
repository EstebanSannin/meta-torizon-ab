# RAUC A/B variant — architectural decisions

Design record for the **RAUC-based** A/B Torizon OS variant, added alongside the
original **SWUpdate-based** one in this same layer. Captures the decisions taken,
the rationale, and the alternatives rejected, plus the concrete findings from
bring-up (build host + QEMU + Torizon Cloud).

Status: validated on `genericx86-64` (QEMU) — builds, boots slot A, local
`rauc install` A→B, and a full **Torizon Cloud + aktualizr** update that applies
A→B on the device with the previous slot retained for rollback. **Also validated
end-to-end on real hardware (Verdin AM62p, U-Boot backend, 2026-08-25):** the same
cloud path (provision → upload `.raucb` → launch → apply → reboot → rollback slot
retained) works, driven headlessly via the REST API, and reports **Completed** —
the **reboot race did not reproduce** there (real-HW reboot latency ≫ aktualizr's
`kPending` write). See [rauc-cloud-test.md](./rauc-cloud-test.md) and Open items.

## Context and goal

Reproduce the exact architecture of the SWUpdate A/B variant (no OSTree, classic
dual-rootfs, aktualizr as the cloud update client) but apply the OS update with
**RAUC** instead of SWUpdate. Keep the whole Torizon cloud stack (aktualizr,
RAC, tzn-mqtt, auto-provisioning, greenboot) and the shared A/B machinery.

The key enabling insight: the SWUpdate variant already isolates the updater
behind a single seam — aktualizr's **generic secondary** ("Subsystem Update")
whose `action_handler` applies an opaque payload to the inactive slot. RAUC
slots into that same seam; only what lives *below* it changes.

## Decisions

### D1 — One layer, an "updater backend" axis (not a new repo/branch)

`meta-torizon-ab` builds **either** backend, selected by distro:
- `torizon-ab`      → SWUpdate (unchanged)
- `torizon-ab-rauc` → RAUC (new)

A shared include `conf/distro/include/torizon-ab-common.inc` holds the common
foundation; each distro conf is thin and appends a `DISTROOVERRIDES` token:
`:torizon-ab` (shared to both) plus `:torizon-ab-swupdate` / `:torizon-ab-rauc`
(backend-specific). Every existing `:torizon-ab` override keeps applying to both
variants; only backend-specific bits use the finer token.

*Rejected:* a separate `meta-torizon-ab-rauc` layer or a long-lived branch —
both duplicate the large shared surface (distro base, images, persistence,
initramfs, resize, udev, pending-reboot) and drift. The axis mirrors the
existing per-machine abstraction (`bootenv.sh` provided by `grub-ab`/`uboot-ab`).

### D2 — Reuse the aktualizr generic-secondary seam unchanged

The primary stays inert (`[pacman] type = "none"`, download + Uptane-verify
only). The OS rootfs is delivered as the `<machine>-rootfs` generic secondary.
Only two things differ per backend, parameterised in
`aktualizr-default-sec.bbappend`:
- `action_handler_path`: `swupdate_actions.sh` vs `rauc_actions.sh`
- payload filename: `rootfs.swu` vs `rootfs.raucb`

*Consequence:* cloud delivery is identical — push the `.raucb` as a custom
"Other" package for `ecu_hardware_id = <machine>-rootfs`, exactly as the `.swu`.

### D3 — RAUC's native GRUB bootloader backend (drop the hand-rolled grubenv logic)

RAUC's `grub` backend manages boot selection/rollback via grubenv variables
(`ORDER`, `<bootname>_OK`, `<bootname>_TRY`) and its documented `grub.cfg`
bootchooser. The RAUC variant uses this instead of the SWUpdate variant's
hand-rolled `bootcount`/`bootlimit` counting and the `fw_printenv`/`fw_setenv`
grubenv wrappers. `rauc-grub-ab` ships the grubenv bootstrap + the reference
`wic/grub-rauc.cfg`.

*Rationale:* RAUC owns slot state; re-implementing it would fight the tool. This
also unifies the per-machine bootloader handling the SWUpdate variant hand-rolls
(RAUC has grub and u-boot backends).

*Note:* GRUB's `search` cannot match a GPT partition label, so `grub-rauc.cfg`
references the slot partitions by fixed GPT position (`(hd0,gpt2)`/`(hd0,gpt3)`)
and passes `root=PARTLABEL=…` + `rauc.slot=…` to the kernel. Fine for single-disk
x86/QEMU; revisit for multi-disk hardware.

### D4 — Slot identity by GPT PARTLABEL, and NO ext4 label on slots

RAUC addresses the A/B slots by GPT partition label
(`/dev/disk/by-partlabel/rootfs_a|b`), set once in the `.wks` via `--part-name`.
Partition labels live in the partition table, so a raw ext4 write leaves them
intact — **eliminating the `e2label` relabel step** the SWUpdate variant needs
(it identifies slots by ext4 FS label, which a raw write clobbers).

The RAUC slots deliberately carry **no ext4 filesystem label**. An ext4 label
made Torizon's automounter (usermount/udisks2) mount the inactive slot under
`/media`, so `rauc install` failed with "Device or resource busy". Dropping the
label (plus PARTLABEL entries in the slots-udev ignore rule, plus a defensive
unmount in `rauc_actions.sh`) keeps the inactive slot free.

The kernel resolves `root=PARTLABEL=` via the stock OE initramfs
(`initramfs-module-rootfs`), unchanged.

### D5 — Raw ext4 image slot, "plain" bundle, dev keyring (signing is mandatory)

- Slot type `ext4`, image written raw — the RAUC-standard approach for an A/B
  rootfs (vs a `tar` slot RAUC formats itself). Matches the SWUpdate payload
  shape and needs no relabel given D4.
- Bundle format **plain** (chosen for first bring-up). `verity` remains the path
  to casync/delta updates later.
- RAUC **requires signed bundles**. A development X.509 key/cert signs the bundle
  (`RAUC_KEY_FILE`/`RAUC_CERT_FILE`) and the self-signed cert is the on-device
  `/etc/rauc/keyring.pem`. This subsumes the SWUpdate variant's optional-signing
  follow-up — **production key management is the remaining hardening item**
  (the in-tree dev keys are NOT for production).

RAUC's system config is delivered through meta-rauc's `virtual-rauc-conf`
provider: a `rauc-conf.bbappend` writes the templated `/etc/rauc/system.conf`
(compatible string + PARTLABEL slot devices, `bootloader=grub`, ESP grubenv) and
installs the dev keyring. (Putting `system.conf` in the `rauc` package instead
file-conflicts with `rauc-conf`.)

### D6 — Keep greenboot as the health authority

greenboot stays the health-check framework (Torizon consistency, user health
scripts keep working). Its green.d hook calls `rauc status mark-good` on a
healthy boot (clearing the trial `_TRY` and setting `_OK`); an unhealthy boot
reboots and RAUC's `grub.cfg` counts down and rolls back. This replaces the
SWUpdate variant's "reset bootcount" green.d hook.

### D7 — Target kernel must support squashfs (RAUC-on-target requirement)

RAUC bundles are squashfs containers; the target mounts them at install time.
The kernel therefore needs `CONFIG_SQUASHFS` (+ decompressors + `BLK_DEV_LOOP`),
added via a `linux-yocto` config fragment scoped to `:torizon-ab-rauc`. This is
a hard requirement discovered during bring-up (install failed with "squashfs
support not enabled in kernel" without it).

## What stays shared vs. backend-specific

Shared (`:torizon-ab`, verbatim for both): distro foundation (no sota/OSTree),
plain initramfs, `/etc`-overlay + `/var` + `/home` persistence, `resize-data-
helper`, static fstab, udev slot ignore-list, `pending-reboot`, the images, and
the aktualizr generic-secondary *registration*.

RAUC-specific (`:torizon-ab-rauc`): `rauc` + `rauc-conf` (system.conf + keyring),
`rauc-grub-ab` (grubenv bootstrap + `mark-good` hook), `rauc_actions.sh`,
`grub-rauc.cfg`, the PARTLABEL `.wks`, the squashfs kernel fragment, and the
`.raucb` bundle producer.

## Bring-up findings (non-architectural, but recorded)

- **jq** fails to build out-of-tree on current meta-oe HEAD ("NOT building
  parser.c!"); worked around with `B = "${S}"` in a `jq_%.bbappend`.
- The build host's **IPv6 route to some CDNs** (e.g. download.gnome.org) is
  broken; forced bitbake's wget to IPv4 (`FETCHCMD_wget … --inet4-only`).
- The RAUC handler must set `LOG_ENABLED=1` (as `swupdate_actions.sh` does), or
  `common_actions.sh` never creates `/var/lib/rollback-manager` and the handler
  aborts before `rauc install`.

## Open items / follow-ups

- **Reboot race → wrong cloud status (under investigation).** The handler
  triggers the reboot (`touch /run/need-reboot`) inside the install action, which
  can outrun aktualizr's durable `kPending` write; the device updates correctly
  but aktualizr reports *failed* and never runs `complete-install`. aktualizr
  won't self-reboot here (the OS is a secondary; primary `[pacman]=none` uses the
  fake package manager). Direction: reconcile from **observed state** — have
  `get-firmware-info` report the booted slot's real installed image
  (`TorizonGenericSecondary::getFirmwareInfo` uses the handler's `sha256`/`length`
  output), so any boot (clean or power-cut) matches reality and reports
  correctly. **No `sleep`/timing hacks** (they aren't power-cut safe; the commit
  point — RAUC arming the bootloader — already is). Open sub-decision: observed-
  state alone vs. also re-sequencing the reboot so aktualizr records `kPending`
  first (for the discrete "install succeeded" cloud event).
  - **Update (2026-08-25): did NOT reproduce on real Verdin AM62p hardware.** A
    full cloud A→B (via the REST API, see
    [rauc-cloud-test.md](./rauc-cloud-test.md)) reported **Completed / UpToDate**.
    On boot aktualizr found the update already `kPending` and reconciled from the
    secondary's installed state (*"Trying to complete pending update … has been
    installed"*). The real-hardware reboot latency (greenboot + plymouth +
    shutdown, ~1.5 min) comfortably exceeds aktualizr's durable `kPending` write,
    so the QEMU race window is lost. This makes the observed-state hardening a
    **robustness/defence-in-depth** item (fast-rebooting targets, power-cut) rather
    than a functional blocker on this class of hardware.
  - **Verified implementation spec (Phase 0, 2026-08-25) — banked, not yet built.**
    Contract confirmed from `toradex/aktualizr` (branch `toradex-master`, SRCREV
    `b16069ce`), `src/torizon/generic_secondary/torizongenericsecondary.cc`
    (`TorizonGenericSecondary::getFirmwareInfo` + `callActionHandler`):
    - aktualizr runs `<handler> get-firmware-info` with cwd
      `/var/sota/storage/rootfs`, `SECONDARY_*` in env, and **parses the handler's
      stdout as JSON**.
    - Exit code: `0` → parse JSON; **`64` → fall back to the base class**
      (aktualizr's own stored state — this is today's `exit 64` behavior); `65` →
      info unavailable.
    - Exit-0 JSON keys: **`status` required** (must be `"ok"` or the info is
      rejected); **`sha256`+`length` together** (both or neither) = the installed
      image's hash + byte length — omit both and aktualizr hashes the stored
      `rootfs.raucb` itself; `name` optional; `message` optional (logged).
    - No Toradex reference handler emits this today (`bl_actions.sh`,
      `swupdate_actions.sh`, and `rauc_actions.sh` all `exit 64`).

    Plan when built: (1) in `do_install`, after `rauc install` succeeds, record
    `{sha256:$SECONDARY_FIRMWARE_SHA256, length, name}` for the **target slot**
    (e.g. `/var/lib/rollback-manager/installed-slot-<A|B>.json`) — the slot's
    unpacked ext4 can't be re-hashed to the bundle hash, so it must be recorded;
    (2) in `do_get_firmware_info`, resolve the booted slot and, **only if a valid
    record exists**, emit `{"status":"ok","name":…,"sha256":…,"length":…}` exit 0,
    else `exit 64` (unchanged) — guarded so it is happy-path-equivalent to today and
    diverges only in the kPending-lost race (base = stale, ours = correct); (3)
    validate on HW: a normal cloud update still reports `Completed` (regression) plus
    a deliberate kPending-loss fault injection to prove the race path now reports
    correctly.
- **Startup SSL-58 posting update *events* (new, minor).** Right after a
  post-update boot, aktualizr emits a one-shot burst of
  `curl error 58 … Problem with the local SSL certificate` while posting update
  *events*; the core manifest report still succeeds (device reaches `Completed`).
  Likely a transient before TLS/clock/cert settles at early boot. Characterize;
  non-blocking.
- Production signing keys (replace the in-tree dev key/cert/keyring).
- Multi-disk-robust slot selection in `grub-rauc.cfg` (GPT-position assumption).
- `verity` bundles + delta/casync updates.
- Multi-machine (verdin-imx8mp / U-Boot) — RAUC has a u-boot backend; the axis is
  ready for it.
- Production slot/image sizing (shared with the SWUpdate variant's B3).
