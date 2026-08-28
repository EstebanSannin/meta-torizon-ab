# Release testing (M2) — design (DRAFT, for agreement)

> Status: **DRAFT — design only, nothing implemented.** This is the plan for
> automatically validating every published build on the local fleet before it is
> promoted to a "tested" release. It builds on the M1 build+publish pipeline
> ([build-publish-pipeline.md](./build-publish-pipeline.md)), the on-device test
> access design ([am62p-hardware-loop.md](./am62p-hardware-loop.md),
> `tests/hardware/`), and the proven cloud path
> ([rauc-cloud-test.md](./rauc-cloud-test.md)). Open items marked **[OPEN]**.

## 1. Goal

Every artifact the pipeline publishes should be **automatically exercised on real
targets** (and x86 in QEMU) and only then marked **tested / recommended**. A
build that fails its gate is visibly *not* recommended for flashing or OTA.

This is milestone **M2** in the pipeline plan: `build → [test gate] → publish`.

## 2. What we already have to build on

- **Pristine-image + runtime-injected access.** The deployable artifact ships no
  dev key / sudo / provisioning identity; the serial harness
  (`tests/hardware/enable-access.sh`) injects test access at runtime, writing only
  to the **data partition**. So **test == deploy** (the tested artifact is
  bit-identical to the shipped one). M2 must preserve this — never test a
  specially-built image.
- **The build→flash→serial loop** (`am62p-hardware-loop.md`): build on m920x →
  stage a Tezi feed on **beerus** → recovery-boot Tezi → auto-install → serial.
- **The API-driven cloud path** (`rauc-cloud-test.md`): provision via
  `POST /devices`, upload via `POST /packages`, launch via `POST /updates`, poll
  `GET /updates/devices/{uuid}` — all headless, both backends.

## 3. The hard constraint: unattended flashing

The one step that is **not** currently automatable is putting a board into
recovery mode: the Yavia **recovery button is momentary** and must be pressed
while power-cycling. Everything else (build, feed, serial, cloud API) is already
headless. Two ways to deal with it:

**(A) Update-only loop — no reflash per test [recommended default].**
Keep each board **provisioned once** to Torizon Cloud, on a known baseline. For
each new build, deliver it as an **OTA update** (cloud or local) to the running
board and assert apply / rollback / persistence. This needs **no recovery
button** — the A/B mechanism is exactly what we're testing. A reflash is only
needed when the **partition layout / boot firmware** changes (rare), or to reset a
wedged board.

**(B) Unattended reflash — for a clean baseline / recovery.**
To make even the flash step hands-free, wire the board's **recovery line + power**
to a **controllable relay on beerus** (USB relay / smart PSU): assert recovery,
power-cycle, run the existing Tezi autoinstall feed, release. This is a **hardware
setup task** for the board-access session; once in place, the full
flash→boot→update→rollback loop is unattended.

> Plan: start with **(A)** (works with today's wiring), add **(B)** during the
> board-access setup so a from-scratch flash is also automated. **[OPEN]** exact
> relay hardware + how recovery is asserted per carrier (Yavia).

## 4. Topology & where the test job runs

m920x is **remote** (builds); beerus is **local**, physically wired to the boards
(serial + USB recovery + feed) — they are on different networks. So:

- **Build job → m920x runner** (as today).
- **Test job → a NEW self-hosted runner on beerus** (labels `beerus`, `fleet`).
  It downloads the just-published artifacts from the GitHub Release, drives the
  wired boards over serial + the cloud API, and reports back.
- **x86 has no wired board** → tested in **QEMU on m920x** (or beerus).

```
GH Actions
  ├─ build   (runs-on: m920x)      bitbake → publish Release (prerelease)
  └─ test    (runs-on: beerus)     needs: build
        ├─ x86:      QEMU boot + local update + rollback
        ├─ am62p:    real board via serial + cloud API
        └─ imx8mp:   real board via serial + cloud API
        → pass ⇒ promote the Release to "tested"; fail ⇒ leave prerelease + report
```

**Fleet (wired to beerus):** verdin-am62p + verdin-imx8mp (the two-board bench in
`am62p-hardware-loop.md`). **[OPEN]** one board per machine means testing *both*
backends on it needs a reflash between (→ needs (B), or accept serialized
backend runs with a reflash, or a second board per machine).

## 5. Test stages (what each build must pass)

Reusing the M1–M4 milestones already proven manually, now automated per build:

| Stage | Asserts | Where |
|-------|---------|-------|
| **T0 boot** | boots slot A; `/etc/os-release` VERSION == the built version (serial banner) | HW + QEMU |
| **T1 local update** | apply payload to inactive slot (`rauc install` / `swupdate -i`), reboot, `findmnt /` shows the other slot | HW + QEMU |
| **T2 rollback** | a deliberately-unhealthy slot → greenboot fails → bootloader rolls back to the previous good slot (roadmap B5) | HW + QEMU |
| **T3 cloud OTA** | provision → `POST /packages` → `POST /updates` → device applies → cloud reports **Completed**, rollback slot retained | HW (real cloud) |
| **T4 persistence** | `/etc` overlay + `/home` + `/var` (and `/var/lib/docker` for docker variant, B6) survive an A→B update | HW + QEMU |
| **T5 data auto-expand** | flashed to a larger medium, `/var` fills the device on first boot (needs a reflash → (B)) | HW |

Each stage emits a machine-readable verdict. **[OPEN]** exact assertion commands
per stage (mostly already scripted in `tests/hardware/` — extend, don't rewrite).

## 6. Secrets & cloud creds

T3 needs Torizon Cloud credentials (the provision client + a broader API client
with `write:packages`/`write:updates`/`read:devices`, per `rauc-cloud-test.md`).
- Stored as **GitHub Actions secrets** (encrypted), injected into the beerus test
  job as env — **never** in the repo, never baked into an image.
- The test job provisions a **dedicated test device** per board; teardown cancels
  pending updates (`PATCH /updates/{id}`) and optionally deprovisions.
- **[OPEN]** one test device per (board), reused across builds, vs fresh per run.

## 7. Promotion gate & how a build's status is shown

- The build job publishes the Release as a **prerelease** (`prerelease: true`).
- The test job, on all-pass, **promotes** it (clears prerelease / adds a `tested`
  marker + per-stage results in the release notes). On failure it stays
  prerelease and the notes carry the failing stage + serial excerpt.
- The **landing page** reads this: tested builds shown as **Recommended**,
  untested/failed as **prerelease / not recommended**. (The Releases API already
  exposes `prerelease` — the page can filter on it with zero new infrastructure.)

## 8. What the harness needs (reuse first)

- `tests/hardware/` already does serial access-injection on the data partition —
  extend it with per-stage assertions (boot banner check, `rauc/swupdate` apply,
  rollback trigger, persistence markers) returning structured pass/fail.
- A small **cloud driver** (curl + jq, like `ci/publish-release.sh`) for the T3
  provision/upload/launch/poll dance.
- A **QEMU driver** on m920x for x86 (T0–T2, T4): `runqemu … nographic`, drive
  over the forwarded SSH, apply a local update, reboot, assert.
- **(B) relay driver** for unattended recovery+power (added at board-access time).

## 9. Phased plan

- **M2.0 — x86 QEMU gate (no boards).** Boot + local update + rollback +
  persistence in QEMU on the runner. Fully automatable **today**, no fleet — a
  real gate for the x86 artifacts and a scaffold for the assertion format.
- **M2.1 — one board, update-only (strategy A).** Provisioned am62p (or imx8mp);
  per build, cloud OTA + rollback + persistence, no reflash. First real-HW gate.
- **M2.2 — unattended reflash (strategy B).** Add the recovery+power relay so T0
  (clean flash + first boot) and T5 (auto-expand) are automated; enables testing
  both backends on one board.
- **M2.3 — full fleet matrix + promotion.** am62p + imx8mp, both backends,
  prerelease→tested promotion wired into the landing page.

## 10. What I need from you (board-access session)

1. **A runner on beerus** (I can stage it like the m920x one; you run the token
   step) with the test harness + QEMU.
2. **The recovery+power relay** for strategy B — the one piece of new hardware;
   tell me what's available (USB relay? smart PSU? Yavia recovery pin exposure?).
3. **Torizon Cloud test creds** as Actions secrets (you create the API client;
   I never handle the token — same rule as the runner registration).
4. Confirm the **fleet**: which boards stay wired to beerus, one or two per machine.

## 11. Open decisions (consolidated)
1. **[OPEN]** Strategy A vs A+B ordering (recommend A now, B at board-access).
2. **[OPEN]** Relay hardware + how recovery is asserted on Yavia.
3. **[OPEN]** One board per machine (reflash to switch backend) vs two.
4. **[OPEN]** Test device lifecycle (persistent vs fresh per run).
5. **[OPEN]** Per-stage assertion commands (extend `tests/hardware/`).
6. **[OPEN]** Where the QEMU x86 gate runs (m920x runner vs beerus).
