# meta-torizon-ab — task backlog & roadmap

Working backlog for the OSTree-free A/B + SWUpdate Torizon variant. Each task
has an acceptance criterion ("Done when…"). **Priority is left as `TBD`** for us
to set together. Status: `Done`, `In progress`, `Todo`, `Idea`.

Legend: **AC** = acceptance criteria.

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
`docs/architecture.md`, `docs/updates-and-rollback.md`, `docs/persistence.md`.
**AC:** a new engineer can build, flash, update, and understand persistence from
the docs. ✅

---

## Backlog (Todo)

### B1 — Ready-to-build `repo` manifest (priority: TBD)
A dedicated manifest repo (`torizon-ab-manifest`) that fetches the Torizon base +
`meta-swupdate` + `meta-torizon-ab` and pre-registers layers + `DISTRO`.
**AC:** from scratch, `repo init -u <manifest> && repo sync && . setup-environment build && bitbake torizon-ab-swu`
produces the image and `.swu` with no manual layer/DISTRO edits; revisions
pinned for reproducibility.

### B2 — Multi-machine: `verdin-imx8mp` (U-Boot) + generalization (priority: TBD)
Abstract the bootloader/rollback/partition layer behind per-machine overrides;
add a U-Boot-env rollback path (real `fw_setenv`), an eMMC WKS, and boot-script
A/B selection.
**AC:** `MACHINE=verdin-imx8mp DISTRO=torizon-ab bitbake torizon-minimal-ab`
builds; device boots slot A; a cloud rootfs update switches to slot B and rolls
back on failure; x86 remains unaffected. Work happens on a branch.

### B3 — Production image/slot sizing (priority: TBD)
Shrink the rootfs image (`IMAGE_OVERHEAD_FACTOR=1` or fixed `IMAGE_ROOTFS_SIZE`)
so slots and the `.swu` are minimal.
**AC:** slots sized to ≤ ~1.2× the rootfs; `.swu` noticeably smaller; A→B update
still succeeds; documented sizing rationale.

### B4 — Signed `.swu` (priority: TBD)
Enable SWUpdate image signing (`SWUPDATE_SIGNING`) + on-device verification, in
addition to aktualizr's Uptane verification.
**AC:** an unsigned/tampered `.swu` is rejected by SWUpdate; a properly signed
one installs; keys/process documented.

### B5 — End-to-end rollback validation (priority: TBD)
Use `torizon-ab-rollback-test` to ship a deliberately-unhealthy slot.
**AC:** device boots the bad slot, greenboot fails, `redboot-auto-reboot`
reboots, and after `bootlimit` GRUB rolls back to the previous good slot; the OS
update is reported failed in the cloud.

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
