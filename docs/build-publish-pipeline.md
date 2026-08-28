# Build & Publish Pipeline — spec (DRAFT, for agreement)

> Status: **DRAFT — under discussion.** This document is the agreed spec we build
> from. Nothing here is implemented yet. Decisions still open are marked
> **[OPEN]**; agreed ones **[AGREED]**.

## 1. Goal

Stand up a build + publish service for the OSTree-free A/B Torizon OS variant so
that:

1. Images build automatically (nightly/weekly) and on request, for the proven
   matrix, from a **reproducible checkout** — no manual layer/DISTRO edits.
2. Generated artifacts are **published on a public landing page** with direct
   download links, checksums, build metadata, per-machine **flashing
   instructions**, and a **Toradex Easy Installer (TEZI) feed** so a fresh board
   can pull our image.
3. (Later) Candidate builds are **validated on a local hardware fleet** before
   promotion.
4. (Later) Published builds are offered as **Torizon Cloud OTA updates** via a
   **TUF delegated-targets role** that third parties can add to their own
   Torizon Cloud account.

This rides entirely on the already-proven update seam (aktualizr generic
secondary; see [rauc-cloud-test.md](./rauc-cloud-test.md),
[updates-and-rollback.md](./updates-and-rollback.md)). Nothing here changes the
on-device design.

## 2. Scope / milestones

| Milestone | Contents | Status |
|-----------|----------|--------|
| **M1** | Reproducible checkout (roadmap **B1**) + GH-Actions build matrix on m920x + public landing page with artifacts, checksums, flash docs, TEZI feed + buildbot-style status panel | **this spec's target** |
| **M2** | Local fleet auto-test as a **promotion gate** before an artifact is marked "published" (builds on `tests/hardware/`, pristine-image + serial-injected access) | later |
| **M3** | Production signing keys + **TUF delegated-targets** publishing so third parties get OTA via Torizon Cloud | later |

**[AGREED]** M1 is **build + publish only** — no auto-test, no OTA in the first
cut.

## 3. Build matrix

```
MACHINE ∈ { genericx86-64, verdin-imx8mp, verdin-am62p }
DISTRO  ∈ { torizon-ab (SWUpdate), torizon-ab-rauc (RAUC) }
VARIANT ∈ { minimal, docker, ... }        # extensible axis
```

**[AGREED]** The pipeline carries a **variant axis** end-to-end (matrix,
artifact names, `builds.json`) from day one. **M1 populates only `minimal`**
(all artifacts stay under the 2 GiB GitHub-Releases cap); `docker` and any future
variant are added as config entries, not a refactor. Adding a variant = one row
in the matrix config + its bitbake image target.

Up to **6 machine×distro configs** per variant. Per-config bitbake targets and outputs
(from [rauc-cloud-test.md](./rauc-cloud-test.md) and CLAUDE.md):

| Output | SWUpdate (`torizon-ab`) | RAUC (`torizon-ab-rauc`) |
|--------|-------------------------|--------------------------|
| Flashable image | `torizon-minimal-ab-<machine>.wic` | same |
| OTA payload | `torizon-ab-swu-<machine>.swu` | `torizon-ab-bundle-<machine>.raucb` (signed) |
| TEZI image (Toradex boards) | `teziimg` (B2 Phase 2) | `teziimg` |
| Secondary hwid | `<machine>-rootfs` ⚠️ | `<machine>-rootfs` ⚠️ |
| Bundle compatible | — | `torizon-ab-rauc-<machine>` |

The `docker` `.wic` is the artifact most likely to exceed the 2 GiB
GitHub-Releases cap — see §6; deferring it to a later pass also defers the
lab-server overflow dependency out of M1.

> ⚠️ **HWID caveat (roadmap B14).** Today both backends register the **same**
> secondary hwid `<machine>-rootfs`, so the cloud can't distinguish a RAUC device
> from a SWUpdate one of the same machine — the pipeline's upload `hardwareId` and
> any M3 delegation targeting inherit this ambiguity. Preferred fix is
> backend-specific hwids (`<machine>-rootfs-rauc` / `-swupdate`) **before** the
> pipeline bakes in the old scheme. The pipeline must use whatever hwid B14 lands.

## 4. Build orchestration

**[AGREED]** GitHub Actions, **self-hosted runner on m920x**, driving the
existing crops container + `bb.sh`/`bb-am62.sh`.

- **Triggers [AGREED]:** `schedule` = **weekly** full-matrix build;
  `workflow_dispatch` (on-request, with machine/distro/variant inputs); optional
  git tag for a "release" build.
- **Matrix job** over machine × distro × variant (M1: variant fixed to
  `minimal`). Each job:
  1. Prepare a reproducible tree (see §5 / roadmap B1) at pinned revisions.
  2. Build inside crops: `. setup-environment build`, add layers, set DISTRO,
     `bitbake torizon-minimal-ab <payload-target>` (+ `teziimg` on Toradex).
  3. Collect outputs from `<build>/deploy/images/<machine>/`, compute checksums,
     emit a per-config metadata fragment.
  4. Publish artifacts (§6) and update the site manifest (§7).
- **Concurrency:** heavy Yocto builds; serialize or bound parallelism to what
  m920x can sustain (sstate shared across jobs). **[OPEN]** parallelism policy.
- **Secrets:** artifact-store token(s); later, signing keys (M3) — never in the
  repo, injected as runner/organization secrets.

### Reproducible checkout (roadmap B1 — folded into M1)

**[AGREED] Option A — dedicated manifest repo**, chosen over the roadmap's earlier
B-lean because a public "build it yourself" on-ramp is a first-class goal: A gives
external builders a single command (`repo init -u <our-manifest> -b <branch> &&
repo sync`), whereas B forces the "Toradex `repo init` then copy a fragment into
`.repo/local_manifests/`" multi-step path.

A's only real downside (upstream drift from hand-forking Toradex's manifest) is
neutralized by a **vendored-include structure** — never a blind copy:

```
torizon-ab-manifest/          (public repo)
  default.xml                 # <include name="toradex.xml"/> + our <project> entries
  toradex.xml                 # vendored copy of upstream manifest at a PINNED rev
  Makefile / update-upstream  # refreshes toradex.xml from git.toradex.com @ <rev>
```

`repo` supports same-repo `<include>`, so upstream stays one isolated file and our
overlay (meta-swupdate, meta-torizon-ab, DISTRO guidance) never tangles with it.
Upstream sync = bump `toradex.xml`, a one-file, automatable step.

The workflow (and the manifest) must pin: base manifest rev, `meta-swupdate` rev,
`meta-torizon-ab` rev — so a build is reproducible and a failure is bisectable.
This same repo doubles as the **public build-your-own on-ramp** documented on the
landing page.

## 5. Versioning & artifact identity

Each build produces a **build id** used consistently in filenames, the manifest,
and (later) the OTA package name/version. Proposed:

```
<distro>-<variant>-<machine>-<osversion>-<YYYYMMDDHHMMSS>+build.<n>
# e.g. torizon-ab-rauc-minimal-verdin-am62p-7.7.0-20260826T2210+build.42
```

Captured metadata per artifact: os version, machine, distro/backend, **variant**,
build timestamp, git SHAs (base manifest + meta-swupdate + meta-torizon-ab),
sha256, size, and the source workflow run URL.

**[OPEN]** exact build-id grammar; whether "nightly" and "release" channels are
distinct streams on the site.

## 6. Artifact hosting

**[AGREED, provisional]** **Decouple the page from the store** — each artifact is
just a URL in the manifest, so the physical home is swappable.

- **Primary: GitHub Releases.** Free, unlimited total storage for public repos,
  stable direct links (`.../releases/download/<tag>/<asset>` and
  `/releases/latest/download/<asset>`), zero server maintenance.
  - **Hard limit: 2 GiB per asset.** Minimal variants are safe; `docker` `.wic`
    and some `teziimg` may exceed it.
- **Overflow / permanent mirror: lab server** (access TBD from user). Any
  artifact >2 GiB and, eventually, a full mirror live here.
- **Landing page** links to whatever URL each artifact carries — GitHub today,
  lab server later, or both.

**Measured (2026-08-26, x86 RAUC):** `.raucb` = **794 MB** (fits the 2 GiB cap);
raw `.wic` = **13 GB apparent** (sparse — mostly-empty A/B slots + data). Publish
`.wic` **compressed** (`.wic.gz`/`.xz`/`.zst` + keep the `.bmap` for `bmaptool`
flashing) — a sparse image compresses to a small fraction, comfortably under the
cap. So GitHub Releases works for both once the `.wic` is compressed; only pursue
lab-server overflow if a *compressed* artifact still exceeds 2 GiB (likely the
docker variant). Ties to roadmap B3 (slot sizing) to shrink the raw image too.

**[OPEN]** Retention policy (how many nightly builds kept before pruning) and
whether releases are pruned by age or count.

## 7. Publishing site

Served from **m920x** over its **DDNS hostname + Let's Encrypt TLS**
**[AGREED]** (Caddy or nginx+certbot — **[OPEN]**, recommend Caddy for
auto-TLS simplicity). Static where possible; a tiny bit of JS to render the
manifest.

**Content:**
- **Build index** — per config (machine × backend), latest + history, each with
  version, date, size, sha256, download link, and source run link.
- **Flashing instructions** — per machine: x86 (`.wic` → USB/disk), Verdin boards
  (TEZI). Copy-paste commands, recovery-mode notes.
- **TEZI feed** — an `image_list.json` (+ per-image `image.json`) so users add
  "our feed" in Toradex Easy Installer and install directly. **[OPEN]** confirm
  the exact TEZI feed schema/version we target and that our `teziimg` output
  matches it (ties to roadmap B2 Phase 2 for the Verdin boards).
- **Status panel (buildbot-style)** — renders `builds.json` emitted by the
  workflow: current/in-progress build + last N results (pass/fail, duration,
  per-config). **[AGREED]** GH Actions is the engine; the site is the window.

### `builds.json` (manifest) — sketch

```json
{
  "generated": "2026-08-26T22:10:00Z",
  "current": { "run_url": "...", "state": "running", "configs": ["..."] },
  "builds": [
    {
      "build_id": "torizon-ab-rauc-minimal-verdin-am62p-7.7.0-20260826T2210+build.42",
      "machine": "verdin-am62p", "backend": "rauc", "variant": "minimal",
      "os_version": "7.7.0", "date": "2026-08-26T22:10:00Z", "state": "success",
      "run_url": "https://github.com/.../actions/runs/...",
      "git": { "base": "...", "meta_swupdate": "...", "meta_torizon_ab": "..." },
      "artifacts": [
        { "kind": "wic",    "url": "https://.../....wic",   "sha256": "...", "size": 1234567 },
        { "kind": "raucb",  "url": "https://.../....raucb", "sha256": "...", "size": 830000000 },
        { "kind": "teziimg","url": "https://.../....tar",   "sha256": "...", "size": 900000000 }
      ]
    }
  ]
}
```

## 8. Security / trust (mostly M3, flagged now)

- **In-tree keys are DEV only** (CLAUDE.md Conventions, roadmap B4). Public
  artifacts and any OTA delegation need **production signing keys** with a real
  custody story. For **M1 (publish-only)** we still ship SHA256SUMS for integrity
  and clearly label images as dev-signed; production signing is **M3**.
- **Key custody [OPEN]** — where the delegation / image-signing keys live, and
  whether m920x may hold them online (convenient) or signing is gated.
- Pristine-image invariant is unchanged: the published artifact is
  bit-identical to what the fleet tests (test == deploy). Test access is only ever
  injected at runtime by `tests/hardware/` on the data partition.

## 9. Later milestones (design intent, not M1)

- **M2 — fleet test gate.** Reuse `tests/hardware/` (serial-driven,
  pristine-image, access injected to the data partition). A build is marked
  "published" on the site only after the fleet run passes on the real boards
  (am62p, imx8mp, and an x86 target). Promotion state flows into `builds.json`.
- **M3 — OTA delegation.** Production-sign, then publish a **TUF delegated-targets
  role** (`uptane-sign`/`garage-sign`, `garage-tools` client from
  `credentials.zip`). Third parties add the delegation (public key + role) to
  their Torizon Cloud repo; their fleet then sees our images as OTA targets.
  Upload/launch mechanics already proven via the App REST API
  (see [rauc-cloud-test.md](./rauc-cloud-test.md)). Track `uptane-sign` friction
  from roadmap B11.

## 10. Open decisions (consolidated)

1. **[AGREED]** Reproducible checkout: **Option A**, vendored-include structure
   (doubles as the public build-your-own on-ramp).
2. **[AGREED]** M1 builds **minimal** only; pipeline carries the variant axis so
   docker/future variants are config, not refactor.
3. **[AGREED]** Cadence: **weekly** scheduled + on-request `workflow_dispatch`.
4. **[OPEN]** Build parallelism / sstate policy on m920x.
5. **[OPEN]** Build-id grammar details; nightly vs release channels.
6. **[OPEN]** Retention/pruning policy for artifacts.
7. **[OPEN]** Reverse proxy: Caddy vs nginx+certbot (recommend Caddy).
8. **[OPEN]** TEZI feed schema/version + that `teziimg` matches it.
9. **[OPEN]** (M3) key custody + online-signing posture.
10. **[OPEN]** Lab-server access + whether it's overflow-only or full mirror.
11. **[OPEN]** Backend-specific secondary HWID (**roadmap B14**) — settle before
    the pipeline's upload `hardwareId` and M3 delegation targeting bake in the
    ambiguous `<machine>-rootfs`. Recommend `<machine>-rootfs-{rauc,swupdate}`.
12. **[OPEN — user to clarify] "Tezi image" meaning.** My §7 assumption (emit a
    `teziimg` + `image_list.json` feed so a board installs via Toradex Easy
    Installer) may not match what the user intends — parked pending their
    explanation. Do NOT build the TEZI-feed piece until clarified.

## 11. M1 task breakdown (roadmap style)

- **P1 — Manifest repo + reproducible checkout (B1, Option A).** *Done when:* a
  public `torizon-ab-manifest` (vendored-include: `default.xml` +
  `toradex.xml` + `update-upstream`) lets a clean environment run
  `repo init -u <manifest> -b <branch> && repo sync` and build all 6 minimal
  configs from pinned revisions with no manual layer/DISTRO edits — the same repo
  is the documented public build-your-own on-ramp.
- **P1 — GH Actions matrix + self-hosted runner on m920x.** *Done when:* a
  `workflow_dispatch` builds any chosen machine×distro in the crops container and
  collects the artifacts + metadata.
- **P1 — Scheduled builds.** *Done when:* nightly/weekly runs fire and produce
  artifacts unattended.
- **P1 — Artifact publishing (GH Releases + manifest).** *Done when:* artifacts
  land with stable direct links, SHA256SUMS, and `builds.json` is updated.
- **P1 — Landing page (m920x, DDNS+TLS).** *Done when:* the site lists builds
  with downloads, checksums, and renders the status panel from `builds.json`.
- **P2 — Flashing instructions.** *Done when:* per-machine flash docs are live
  (x86 dd/USB; Verdin TEZI).
- **P2 — TEZI feed.** *Done when:* a fresh Verdin board can add our feed in TEZI
  and install a published image.
```
