# meta-torizon-ab — task backlog & roadmap

Working backlog for the OSTree-free A/B Torizon variant (SWUpdate + RAUC updater
backends). Each task has an acceptance criterion ("Done when…"). **Priority is
left as `TBD`** for us to set together. Status: `Done`, `In progress`, `Todo`,
`Idea`.

Legend: **AC** = acceptance criteria.

---

## U-Boot RAUC hardware bring-up — two machines, one generalized layer

The RAUC A/B variant is proven end-to-end on **two** physical U-Boot boards from
**different vendors**, both driven by the same generalized `rauc-uboot-ab` glue —
each machine supplies only a small per-machine data block in
`conf/distro/include/torizon-ab-uboot.inc` (the "porting contract", see
`docs/uboot-rauc-porting.md`). Branch `feature/rauc-ab-am62p`. See
`docs/am62p-hardware-loop.md` (the build→flash→serial loop is machine-generic;
only the recovery command differs per family).

**Verdin AM62p (TI K3):** M0 flash, M1 boot slot A, M2 `rauc install` A→B, M3
rollback, **M4 Torizon Cloud OTA** — all **Done** on hardware (reported
`Completed`, rollback slot retained; the aktualizr reboot-race did NOT reproduce —
see `rauc-decisions.md` / `rauc-cloud-test.md`).

**Verdin iMX8MP (NXP i.MX):** M0 flash (Tezi + `uuu`/SDPS recovery), M1 boot slot
A, M2 `rauc install` A↔B, M3 rollback, **M4 Torizon Cloud OTA** — all **Done** on
hardware (`Completed` / `UpToDate`, rollback retained). Added as pure per-machine
data on the generalized layer (fdtfile, `/boot/freescale` DTB dir, eMMC = U-Boot
`mmc 2`, decompress scratch `0x60000000`) plus one general fix
(`IMAGE_BOOT_FILES:remove` drops the stock distro `boot.scr` the machine conf
appends) and a `linux-toradex` squashfs fragment.

- **Generalization (Done)** — hardcoded am62p glue factored into
  Tier-1 (parameterized `rauc-uboot-ab` + templated `boot.cmd` with runtime
  GPT-label slot resolution + shared wks), Tier-2 (SoC-family scope `:k3` /
  `:mx8mp-generic-bsp`), Tier-3 (per-machine data). am62p re-verified, no regression.
- **Automount hardening (Done)** — inactive-slot exclusion works by PARTLABEL +
  defensive unmount (both boards hit the same boot-race automount of the inactive slot).
- **x86-ism audit fix (Done)** — no-ESP fstab is the default; only x86 mounts the ESP.
- **Efficiency pass (Todo)** — the imx8mp bring-up hit three bugs (mmc index, stock
  `boot.scr` clobber, decompress scratch) that all stem from `boot.cmd`
  reimplementing what the BSP already does per machine; delegate load+boot to the
  BSP to remove those per-machine axes, and widen the i.MX family scope.

---

## Delivered (Done)

These are already implemented and validated on `genericx86-64` (QEMU) unless noted.

### D1 — OSTree-free A/B distro + images
Distro `torizon-ab` (no `sota`/OSTree); images `torizon-minimal-ab` and
`torizon-docker-ab`.
**AC:** image builds and boots to slot A; no OSTree packages/classes present;
Torizon stack (aktualizr, RAC, tzn-mqtt, auto-provisioning) installed. ✅

### D2 — OS update via aktualizr subsystem secondary + SWUpdate
Primary `[pacman] type=none`; rootfs delivered as `<machine>-rootfs` generic
secondary; `swupdate_actions.sh` applies the `.swu` to the inactive slot.
**AC:** push a rootfs `.swu` from the cloud → device writes the inactive slot,
flips grubenv, reboots into it; `findmnt /` shows the new slot. ✅

### D3 — A/B boot + rollback wiring
GRUB `default`/`bootcount`/`bootlimit`/`upgrade_available`; greenboot resets on
healthy boot; grubenv `fw_printenv`/`fw_setenv` wrappers so greenboot rollback
works on x86; auto-reboot on `/run/need-reboot`.
**AC:** manual slot switch works; grubenv trial-exhaustion flips slots. (Full
greenboot-failure rollback still to validate — see B5.) ✅ (partial)

### D4 — Persistence across slots
`/etc` overlay (persistent upper on data), `/var` = data partition, `/home`
bind; first-boot seeding; via initramfs `92-persist`.
**AC:** change password / add `/etc` + `/home` files on slot A → update → they
persist on slot B. ✅

### D5 — Data partition auto-expand on first boot
`resize-data-helper` grows the last (data) partition + ext4 to fill the medium.
**AC:** flashed to a medium larger than the image, `/var` fills the device after
first boot; runs once; no-op when no free space. ✅ (validated logic; confirm on
real hardware — see B10)

### D6 — Remote access (RAC)
**AC:** after provisioning + reboot, `remote-access` starts automatically and a
cloud remote session yields a working shell. ✅ (needed the devpts `gid=5` fstab
fix)

### D7 — Documentation
`docs/architecture.md`, `docs/updates-and-rollback.md`, `docs/persistence.md`,
plus RAUC-specific `docs/rauc-decisions.md` and `docs/rauc-cloud-test.md`; all
kept backend-neutral (SWUpdate + RAUC) where the two share behavior.
**AC:** a new engineer can build, flash, update, and understand persistence and
both updater backends from the docs. ✅

### D8 — RAUC updater backend (`torizon-ab-rauc`)
A second updater backend in the same layer, selected by distro, sharing
everything above the aktualizr generic-secondary seam. RAUC applies the OS
update (`.raucb`) via its native GRUB backend; slots addressed by GPT PARTLABEL.
**AC:** `DISTRO=torizon-ab-rauc bitbake torizon-minimal-ab torizon-ab-bundle`
builds a bootable A/B `.wic` + a signed `.raucb`; QEMU boots slot A; a local
`rauc install` and a full **Torizon Cloud + aktualizr** update both switch A→B
with a rollback slot retained. ✅ (validated on genericx86-64/QEMU)
See [rauc-decisions.md](./rauc-decisions.md), [rauc-cloud-test.md](./rauc-cloud-test.md).
Caveat: the cloud update applies correctly on-device but aktualizr may report it
*failed* due to a reboot race — see **B13**.

### D9 — Fix missing `/etc/os-release`
The variant dropped the OSTree image classes that generate os-release in stock
Torizon (and Torizon's systemd bbappend drops it from RRECOMMENDS), so
`/usr/lib/os-release` was never installed — `/etc/os-release` was a dangling
symlink. Re-add the oe-core `os-release` package (shared, both backends) + a
rootfs post-process that sets the Torizon-style `VARIANT` from `IMAGE_VARIANT`.
**AC:** on a booted image `cat /etc/os-release` shows correct `ID`/`NAME`/
`VERSION`/`VARIANT` and the symlink resolves through the `/etc` overlay. ✅
(verified on a live genericx86-64 QEMU boot; `VARIANT=Minimal-AB`)

---

## Backlog (Todo)

### B1 — Ready-to-build `repo` manifest (priority: TBD)
Make a fresh checkout build the AB variant with (near) one command, fetching the
Torizon base + `meta-swupdate` + `meta-torizon-ab` and pre-registering layers +
`DISTRO=torizon-ab`.

Base manifest (starting point): `https://git.toradex.com/toradex-manifest.git`
(several manifests/branches exist there; pick the Torizon one we build from).

Two shapes considered (see also the reasoning in chat/design notes):
- **Option A — dedicated manifest repo** (e.g. `torizon-ab-manifest`): copy of
  the Toradex manifest + `<project>` entries for `meta-swupdate` and
  `meta-torizon-ab`, revisions pinned. Best UX (single `repo init`), but it forks
  the base manifest and can drift from upstream.
- **Option B (recommended) — `local_manifests` fragment hosted in this repo**
  (`meta-torizon-ab/manifests/torizon-ab.xml`): user does the normal Toradex
  `repo init`, then drops the fragment into `.repo/local_manifests/`, adding only
  `meta-swupdate` + `meta-torizon-ab`. No fork/drift, lives in one repo; one
  extra step.

Gotcha: do NOT put a *full* manifest inside `meta-torizon-ab` — `repo` would use
the layer repo as the manifest repo AND list it as a project, fetching it twice.
`repo` also can't `<include>` a manifest from a different remote, so there's no
"include upstream + overlay" middle ground — it's fork (A) or `local_manifests`
overlay (B).

**Decision:** TBD (leaning B).
**AC:** from a clean checkout, the documented steps (Option A: `repo init -u <manifest> && repo sync`;
Option B: Toradex `repo init` + copy fragment + `repo sync`) followed by
`. setup-environment build && bitbake torizon-ab-swu` produce the image and
`.swu` with no manual layer/DISTRO edits; revisions pinned for reproducibility;
steps captured in the README.

### B2 — Multi-machine: `verdin-imx8mp` (U-Boot) + generalization (In progress)
Branch: `multi-machine-imx8mp`. Abstract the bootloader/rollback/partition layer
behind per-machine overrides; add a U-Boot-env rollback path (real `fw_setenv`)
and a boot-script A/B selection.

Machine-abstraction done (keeps x86 working):
- `torizon-ab.conf` image output is machine-conditional (x86 → wic; imx8mp →
  `tar.bz2` + `ext4.gz`, no wic/GRUB).
- The action handler `swupdate_actions.sh` is machine-agnostic; boot-env ops
  (`bootenv_arm_trial`/`bootenv_confirm`/`bootenv_trial_target`) come from a
  per-machine `/usr/lib/torizon-ab/bootenv.sh`: `grub-ab` (grubenv) on x86,
  `uboot-ab` (real `fw_setenv`) on imx8mp.
- Image installs `grub-ab` on x86 / `uboot-ab` on imx8mp; `kernel-devicetree`
  added on imx8mp; `libubootenv` `u-boot-default-env` removal scoped to x86.
- `uboot-ab`: U-Boot A/B `boot.scr` (draft), U-Boot `bootenv.sh`, green.d
  bootcount reset.

**Phase 1 (bring-up, reuse the board's U-Boot):** deploy the A/B rootfs + data
+ our `boot.scr`; iterate the boot script from the U-Boot console.
**AC (Phase 1):** `MACHINE=verdin-imx8mp DISTRO=torizon-ab bitbake torizon-minimal-ab`
builds a rootfs; on hardware the board boots slot A via our `boot.scr`; a cloud
rootfs update writes slot B and reboots into it; a failed trial rolls back to A.

**Phase 2 (native flashing):** produce a `teziimg` with the A/B eMMC layout
(imx-boot in boot0, rootfs_a/rootfs_b/data) flashable with Toradex tools.
**AC (Phase 2):** a `teziimg` flashes via TEZI and boots to slot A with the full
update/rollback/persistence flow working.

Open HW-iteration points (draft `boot.cmd`): device/partition scan, load
addresses, DTB name, and where the board's U-Boot looks for `boot.scr`.
x86 remains unaffected throughout.

### B3 — Production image/slot sizing (priority: TBD)
Shrink the rootfs image (`IMAGE_OVERHEAD_FACTOR=1` or fixed `IMAGE_ROOTFS_SIZE`)
so slots and the `.swu` are minimal.
**AC:** slots sized to ≤ ~1.2× the rootfs; `.swu` noticeably smaller; A→B update
still succeeds; documented sizing rationale.

### B4 — Signed `.swu` (priority: TBD)
> Note: the RAUC backend already signs its bundles (mandatory in RAUC); this
> item is the SWUpdate-side signing. Production key management is a follow-up
> for both (RAUC currently uses in-tree DEV keys).
Enable SWUpdate image signing (`SWUPDATE_SIGNING`) + on-device verification, in
addition to aktualizr's Uptane verification.
**AC:** an unsigned/tampered `.swu` is rejected by SWUpdate; a properly signed
one installs; keys/process documented.

### B5 — End-to-end rollback validation (both backends) (priority: TBD)
Use `torizon-ab-rollback-test` to ship a deliberately-unhealthy slot. Neither
backend has had a full greenboot-driven *rollback event* validated yet (only the
rollback slot being retained).
**AC (SWUpdate):** device boots the bad slot, greenboot fails,
`redboot-auto-reboot` reboots, and after `bootlimit` GRUB rolls back to the
previous good slot; the OS update is reported failed in the cloud.
**AC (RAUC):** same, but rollback is driven by RAUC's GRUB backend
(`ORDER`/`_OK`/`_TRY`) — the unhealthy slot is never `rauc status mark-good`'d,
so the next boot falls through `ORDER` to the previous good slot.

### B6 — Container-app persistence across OS update (priority: TBD)
**AC:** with a docker-compose app running (see `docs/examples/hello-app`), an OS
A→B update completes and the containers/images are still present and running
afterward (proving `/var/lib/docker` persistence).

### B7 — Primary target / cloud version reporting (priority: TBD)
Decide what the inert primary reports, and make the rootfs subsystem's installed
version show meaningfully in the cloud (improve `get-firmware-info`).
**AC:** the cloud UI shows a sensible installed OS/rootfs version per device;
re-pushing the same version is recognized as already installed.

### B8 — Secondary hygiene (priority: TBD)
Drop the `docker-compose` secondary on the minimal image (no engine); confirm
the bootloader secondary is cleanly removed on x86.
**AC:** `aktualizr-info` on minimal shows only the `rootfs` secondary; no
per-cycle errors from non-functional secondaries.

### B9 — Secure Offline Updates (priority: TBD)
Validate the `.swu`/rootfs update via aktualizr's offline (lockbox) path (the
`offline-updates` PACKAGECONFIG is already built in).
**AC:** an offline lockbox containing a rootfs `.swu` applies an A→B update with
no network; rollback still works.

### B10 — Repeatable test harness + real-hardware validation (priority: TBD)
A `docs/testing.md` with the QEMU bring-up + full validation checklist, incl.
enlarging the QEMU disk to exercise auto-expand; plus at least one real x86
device pass.
**AC:** the checklist reproduces flash→provision→update→rollback→persistence on
QEMU and on real hardware; auto-expand verified on a larger-than-image medium.

**Dev/test access — delivered (pristine-image design).** The deployable image is
kept **pristine**: no dev SSH key, no passwordless sudo, no provisioning identity
baked into any rootfs slot, so the deployed artifact (`.wic`/`.swu`/`.raucb`) is
**bit-identical to the tested one** (test == deploy). Access is injected at runtime
by the serial harness in `tests/hardware/` (`enable-access.sh`), touching only the
**data partition** — never a rootfs slot; a reflash removes it. HW-validated on both
the Verdin AM62P (RAUC) and iMX8MP (SWUpdate): dev key rejected on a fresh flash,
then key + passwordless sudo injected over serial. This replaced the earlier
`torizon-ab-devaccess` recipe, which wrongly baked the dev key + enabling service
into the rootfs.

**Reset = reflash (by design).** To restore a device to a clean state, reflash it;
since the pipeline reflashes for each test image, reflash *is* the reset (and the
only true factory reset). A serial-driven `runtime-reset.sh` (U-Boot boot-env
defaults → pre-persist initramfs shell → wipe data partition → re-seed) was
prototyped and worked on am62p, but driving the transient initramfs debug shell
over serial proved brittle, so it was dropped. **Backlog:** an SSH/console-driven
reset (reformat the data partition or clear the `/etc` overlay upper + `/home` +
`/var/sota`, and `fw_setenv` the boot-env) for a clean provisioning start without a
full reflash — avoids the initramfs shell entirely.

### B11 — Upstream tooling issues (tracking) (priority: TBD)
Track/report: `uptane-sign` S3 multipart-completion bug on large `.swu` uploads;
`torizoncore-builder platform push` routing a file to the OSTree path when it
isn't visible in the container.
**AC:** internal bug(s) filed with repro; workaround (Web UI upload) documented
in `docs/updates-and-rollback.md` (done) until fixed.

### B12 — Define requirements for offline rootfs customization / image tooling (priority: TBD)
Decide the full feature set of a Yocto-free tool (ideally a TorizonCore Builder
output mode) that customizes a base rootfs and produces artifacts — *this task is
the requirements/scope definition, not the implementation.*
**AC:** a reviewed `docs/customization-tool-requirements.md` capturing the agreed
scope, constraints, and open questions, sufficient to plan implementation.

Candidate requirements to refine (starting point):
- **Inputs:** base rootfs (tarball and/or ext4); a "changes" directory; optional
  scripts run cross-arch (qemu-user); a config file (à la `tcbuild.yaml`).
- **Outputs:** (a) `.swu` A/B update for the `<machine>-rootfs` secondary;
  (b) full **flashable `.wic`** (factory image); possibly raw ext4 / tarball.
- **Customizations:** `/etc` defaults & files; splash; kernel modules/firmware;
  DTB & overlays (ARM); kernel cmdline (note: lives on the ESP, not the rootfs
  `.swu` — needs a separate path on x86); NOT `/var` content (persistent — use
  the docker-compose secondary for containers).
- **Environment:** no Yocto; containerized; rootless (e.g. `mke2fs -d` +
  `fakeroot`, or libguestfs/`virt-customize`); reproducible.
- **Multi-machine:** x86 now, `verdin-imx8mp`/eMMC later — machine-aware sizing
  and partition/bootloader differences.
- **Sizing:** produced ext4 must fit the A/B slot (ties to B3).
- **Signing + delivery:** optional `.swu` signing; push to Torizon Cloud
  (`platform push` / API) or emit for Web-UI upload.
- **Packaging tech:** `.swu` via `swugenerator`/`mkimage` or the existing
  `sw-description` template; `.wic` via wic or a standalone partitioner.
- **Home:** standalone prototype first vs a TCB output target (productized).
- **Open questions:** versioning/metadata scheme; how `.wic` and `.swu` share the
  same customized rootfs; secure-boot/signed-image interplay (S2).

### B13 — RAUC cloud update reported failed (reboot race) (priority: TBD)
A Torizon Cloud + aktualizr update applies correctly on-device (boots the new
slot) but aktualizr reports it **failed**: the handler triggers the reboot
(`touch /run/need-reboot`) inside the install action, outrunning aktualizr's
durable `kPending` write, so `complete-install` never runs. aktualizr won't
self-reboot here (OS is a secondary; primary `[pacman]=none`). Fix direction:
observed-state reconciliation via `get-firmware-info` (report the booted slot's
real installed image) — **no `sleep`/timing hacks** (not power-cut safe). Likely
affects the SWUpdate variant too. Diagnosis in
[rauc-decisions.md](./rauc-decisions.md) (Open items) + a sequence diagram.
**AC:** after a cloud A→B update the device is on the new slot **and** Torizon
Cloud shows it installed/succeeded; correct across a power cut at any point.

---

## Ideas / stretch

### S1 — Delta updates (priority: TBD)
Reduce `.swu` size via SWUpdate delta/zchunk or a binary-diff scheme.
**AC:** an A→B update transfers substantially less than a full rootfs for a
small change.

### S2 — Secure boot / rootfs integrity / encryption (priority: TBD)
Explore UEFI secure boot + dm-verity/dm-crypt for the A/B slots (currently out
of scope; OSTree/composefs handled this in stock Torizon).
**AC:** to be defined.

### S3 — SBOM / traceability (priority: TBD)
Ensure SBOM/VEX generation works for the AB images.
**AC:** SBOM produced for `torizon-minimal-ab`/`torizon-docker-ab`.

---

## How we'll use this
- Fill in **priority** per task (e.g., P0/P1/P2) when we plan.
- Add new tasks as they come up (append with an ID + AC).
- Move tasks to **Delivered** with the AC result when done.
