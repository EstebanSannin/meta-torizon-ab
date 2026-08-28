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

**Decision:** **Option A** (chosen over the earlier B-lean because a public
"build it yourself" on-ramp is a first-class goal — single `repo init`). Drift is
neutralized by vendoring upstream at the **root** (repo `<include>` is root-relative,
so the upstream tree must sit at root; can't tuck it under a subpath) at a pinned
rev, refreshed by a script — not a hand-fork. Multi-vendor scalable: mirrors
Toradex's new "everything outside BSP" layout `torizon-ab/<vendor>/<channel>.xml`
with a single shared `overlay.xml` (meta-swupdate + meta-rauc + meta-torizon-ab).

**Status (2026-08-26): DONE — validated end-to-end on m920x.** Separate repo
`torizon-ab-manifest` (sibling dir; not yet pushed — will go to
`github.com/EstebanSannin/torizon-ab-manifest`). Upstream pinned to
`scarthgap-7.x.y` @ `c8749217` via `scripts/update-upstream.sh` + `UPSTREAM.env`.
Channels `release`/`nightly`/`next` (mirroring Toradex's rename of `default.xml`
→ `release.xml`); vendor dirs mirror the new "everything outside BSP" layout
(`torizon-ab/<vendor>/<channel>.xml`, tdx as a vendor). Overlay
`torizon-ab/overlay.xml` = meta-swupdate + meta-rauc + meta-torizon-ab.

Validation (all green):
1. `repo init -m torizon-ab/tdx/release.xml` **and** `.../nightly.xml` flatten
   cleanly with the 3 overlays merged (release pins `meta-toradex-torizon` to a
   SHA; nightly floats it at branch tip).
2. Fresh `repo init/sync` on m920x → full 20-layer tree, `SYNC_EXIT=0`, overlays
   at pinned revs.
3. **Caught a real bug:** `meta-rauc`/`meta-swupdate` `master` target the NEXT
   series (wrynose) and a scarthgap core rejects them (LAYERSERIES_COMPAT). Pinned
   both to the exact tested scarthgap revs (`meta-rauc d63878f`,
   `meta-swupdate 7da41c5`). `meta-torizon-ab` tracks `main` (cd70b1b).
4. `DISTRO=torizon-ab-rauc MACHINE=genericx86-64 bitbake torizon-minimal-ab
   torizon-ab-bundle` → **BUILD_EXIT=0**, 7843 tasks all succeeded, artifacts
   deployed: `torizon-ab-bundle-genericx86-64.raucb` (794 MB) +
   `torizon-minimal-ab-genericx86-64.wic` (13 GB apparent, sparse + `.bmap`).
   Reused the shared sstate/downloads via a new `bb-ab.sh` helper on m920x.
5. **SWUpdate variant too:** `DISTRO=torizon-ab bitbake torizon-minimal-ab
   torizon-ab-swu` → **BUILD_EXIT=0** (7847 tasks, 7554 sstate-reused → fast),
   artifact `torizon-ab-swu-genericx86-64.rootfs.swu` (792 MB). Both backends now
   build through the single manifest on x86 (`bb-ab.sh` takes `BUILD_DIR` to keep
   the two variants' TMPDIRs separate).
6. **ARM too — verdin-am62p RAUC:** `DISTRO=torizon-ab-rauc MACHINE=verdin-am62p
   bitbake torizon-minimal-ab torizon-ab-bundle` → **BUILD_EXIT=0** (9717 tasks,
   4982 sstate-reused), no errors. TI redirects deploy to `deploy-ti/` and builds
   the R5 SPL in a `tmp-k3r5` multiconfig (automatic via the machine include).
   Artifacts: `torizon-ab-bundle-verdin-am62p.raucb` (165 MB) +
   `tiboot3-am62px-hs-fs-verdin.bin`/`tispl.bin`/`u-boot.img` (K3 two-stage boot) +
   `.wic`/`.ext4`(.gz). **Manifest proven across 2 arch × both backends.**

**Note for publishing:** the raw `.wic` is 13 GB apparent (mostly-empty A/B slots
+ data; see B3 sizing) — publish it **compressed** (`.wic.gz`/`.xz`/`.zst`, tiny
for a sparse image) so it fits GitHub Releases' 2 GiB cap; the `.raucb` (794 MB)
already fits. **Remaining before public release:** pin `meta-torizon-ab` to a
tag/SHA for the release channel; add the Tezi image target (`teziimg`, roadmap B2
Phase 2) for the flashing feed; then the on-ramp README + push to GitHub.
(SWUpdate x86 ✅, verdin-am62p RAUC ✅ — arch/backend coverage proven.)

**AC:** from a clean checkout, `repo init -u <manifest> -b <branch> -m
torizon-ab/tdx/release.xml && repo sync` then `. setup-environment build &&
bitbake torizon-ab-swu` produce the image + `.swu` with no manual layer/DISTRO
edits; revisions pinned for reproducibility; steps captured in the README.

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

### B14 — Backend-specific secondary HWID (compatibility contract) (priority: TBD)
The OS-rootfs secondary registers the **same** `ecu_hardware_id`
(`<machine>-rootfs`) for **both** backends
([aktualizr-default-sec.bbappend:55](../recipes-sota/config/aktualizr-default-sec.bbappend#L55),
in the shared `do_install:append:torizon-ab`). The HWID is Uptane's primary
compatibility axis (what the cloud uses to decide whether a target may be offered
to an ECU), so a RAUC device and a SWUpdate device of the **same machine** are
indistinguishable to the cloud — a `.swu` can be launched at a RAUC device and
vice-versa. It fails *safe* today (the wrong-format payload is rejected by
`rauc install` / `swupdate -i`, slots untouched, and each backend also has its own
compatible string — RAUC `torizon-ab-rauc-<machine>` vs `system.conf`, SWUpdate
`hardware-compatibility` in `sw-description`), so it's **not** a brick risk. But
the failure is *late and confusing* (download → try → fail) instead of *early and
clean* (cloud never offers an incompatible target), and it breaks **fleet
targeting** the moment there is a same-machine mixed fleet — which is exactly the
**M3 delegation** scenario (a campaign selects on HWID; half a mixed fleet would
fail).

**Decision:** encode the backend in the HWID → `<machine>-rootfs-rauc` /
`<machine>-rootfs-swupdate` (keep `-rootfs` as the stable stem; match the
`DISTROOVERRIDE` backend tokens). Fix is one line + two vars:
`TORIZON_AB_ECU_SUFFIX:torizon-ab-{swupdate,rauc}` appended at :55.
- **Variant stays OUT of the HWID** — minimal/docker of the same machine+backend
  are interchangeable rootfs payloads; cross-variant *slot-size* fit is a sizing
  concern (B3), not a compatibility key.
- **Breaking change** for already-provisioned devices (HWID is baked into
  `secondaries.json` + cloud registration at provision time) — pre-1.0, re-register
  or reflash. Do it **before** the build/publish pipeline and any third-party
  fleet bake in `<machine>-rootfs`.
- Touches: the bbappend, CLAUDE.md invariant, and every doc that names
  `<machine>-rootfs` (rauc-cloud-test, updates-and-rollback, architecture,
  rauc-decisions, README, build-publish-pipeline) + the pipeline's upload
  `hardwareId`.

**AC:** a RAUC device registers `<machine>-rootfs-rauc` and a SWUpdate device
`<machine>-rootfs-swupdate`; the cloud will not offer a `.raucb` to a SWUpdate ECU
or a `.swu` to a RAUC ECU (target filtered by HWID, no download attempted); a
same-machine mixed fleet is independently targetable; docs + pipeline updated to
the new scheme.

### B15 — Wire the SWUpdate backend for verdin-am62p (K3) (priority: TBD)
Discovered while shaking out the build-publish matrix (2026-08-27): a
`DISTRO=torizon-ab MACHINE=verdin-am62p` build fails to parse —
`Nothing RPROVIDES 'torizon-ab-bootenv'`. The am62p SWUpdate combo was never
wired: `recipes-images/images/torizon-ab-base.inc` installs the bootenv provider
for SWUpdate via **machine-specific** overrides
(`:torizon-ab-swupdate:genericx86-64` → grub-ab, `:torizon-ab-swupdate:verdin-imx8mp`
→ uboot-ab) and no `verdin-am62p`/`:k3` line exists — whereas RAUC already uses
SoC-family overrides (`:torizon-ab-rauc:k3` → rauc-uboot-ab), which is why
am62p-RAUC builds. Bring-up (mirror the imx8mp SWUpdate wiring for K3, likely with
HW validation — the `uboot-ab` boot.scr/bootenv.sh path was only proven on imx8mp):
- `CORE_IMAGE_BASE_INSTALL:append:torizon-ab-swupdate:k3 = " uboot-ab"` (prefer the
  `:k3`/`:mx8mp-generic-bsp` SoC-family form over machine-specific, matching RAUC).
- `IMAGE_BOOT_FILES:torizon-ab-swupdate:k3 = "uboot-ab-boot.scr;boot.scr"`.
- the `do_image_wic[depends]` uboot-ab deploy dep for am62p.
- verify `uboot-ab` (SWUpdate U-Boot backend) has no imx8mp-isms on K3.
**Build-level DONE (2026-08-27, branch `fix/am62p-swupdate-build` commit
`a731236`):** fixed 3 gaps — `torizon-ab-base.inc` (uboot-ab install + boot.scr +
wic dep for `:k3`), `torizon-ab.conf` (`WKS_FILE`/`IMAGE_FSTYPES` for `:k3`),
`uboot-ab_1.0.bb` (`COMPATIBLE_MACHINE` += verdin-am62p). `MACHINE=verdin-am62p
DISTRO=torizon-ab bitbake torizon-minimal-ab torizon-ab-swu` now builds green on
m920x → `torizon-ab-swu-verdin-am62p.rootfs.swu` (164 MB) + `.wic` (4.2 GB).
**HW boot VALIDATED (2026-08-28):** flashed the am62p-SWUpdate A/B image to the
real Verdin AM62p via a Tezi feed (raw .wic.zst, autoinstall) and it booted clean —
serial: `U-Boot 2024.04-ti` → `A/B: booting slot partition rootfs_a` (the uboot-ab
A/B script — the exact B15 wiring) → `root=LABEL=otaroot_a` → greenboot → login.
This retires the B15 risk (whether uboot-ab boots the A/B layout on K3). The
SWUpdate *apply* is unchanged from the imx8mp-proven, machine-agnostic handler, so
a live am62p A→B is confirmatory and will ride in with M2 (cloud OTA per build).
**Remaining:** merge the branch to main (user; my token can't push meta-torizon-ab),
then am62p-swupdate re-enters the matrix.

**AC:** `MACHINE=verdin-am62p DISTRO=torizon-ab bitbake torizon-minimal-ab
torizon-ab-swu` builds ✅; boots slot A on real AM62p; a local + cloud SWUpdate A→B
applies and rolls back. Until HW-proven, am62p-swupdate is excluded from the
build-publish weekly matrix.

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
