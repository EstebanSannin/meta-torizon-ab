# RAUC bundle-signing keys and Uptane (design)

**Status:** decided 2026-11-03 with the aktualizr owner: **Uptane alone**, with
the signing cert shipped with the update (option B). Not implemented yet
(roadmap B18). Phase 4 of the x86 RAUC package manager work
([rauc-decisions.md](./rauc-decisions.md) D8).

## Decision

- **Uptane alone.** On the Uptane path a bundle is trusted because the Image repo
  target names its manifest hash, as an OSTree target is in stock Torizon OS.
- **The cert travels with the update (option B).** RAUC checks the bundle
  signature on every install and cannot skip it: `--no-verify` exists only for
  `info`, `convert`, `resign` and `replace-signature`. So the package carries the
  cert its bundle chains to, and the package manager puts it in RAUC's keyring
  before installing.
- **RAUC reads the keyring at each install, not at service start.** It builds a
  new X.509 store for every bundle it checks (`setup_x509_store()` in
  `check_bundle()`); only the keyring paths come from `system.conf`. Checked on
  QEMU with RAUC 1.15.2: one `rauc service` process refused a bundle signed by an
  unknown key, accepted its signature once the cert was in the
  `[keyring] directory`, and refused it again once the cert was removed.
- **Option A still applies to the baked keyring**, which a manual `rauc install`
  uses. It no longer gates the Uptane path.

## Before the decision

On the Uptane path, two independent checks stand between a bundle and a slot:

| Check | Trust root | Where it lives |
|---|---|---|
| Uptane: RAUC refuses any bundle but the one whose manifest hash the Image repo target names (`require-manifest-hash`) | Image repo targets key | Torizon Cloud. Online in our test account: the cloud re-signs `targets.json` on every `PATCH /packages` |
| RAUC: the bundle's CMS signature must chain to the keyring | `/usr/lib/rauc/keyring.pem` (today a dev self-signed cert) | The rootfs, so each image carries the keyring for the *next* update |

A manual `rauc install` only has the second check.

**The problem.** The keyring lives in the rootfs, so a new trust anchor reaches a
device only inside a bundle that the current anchor still verifies. A planned
rotation works that way; a lost or compromised key does not.

## The real question

On the Uptane path, is a bundle trusted on **Uptane alone** (like an OSTree
target, whose hash is the binding), or on **Uptane plus an independent RAUC
trust anchor**?

- *Uptane alone:* the RAUC keyring follows Uptane, so rotation is free. But
  whoever holds the Image repo targets key can run any code on the device; with
  the key online, that is the cloud.
- *Uptane + RAUC anchor* (what we have now): a cloud compromise can only choose
  among bundles we signed, and RAUC's `min-bundle-version` can block downgrades.
  Rotating the RAUC anchor has to be planned.

## Options

### A — RAUC PKI, keyring in the image

- An offline root CA issues intermediates, which issue short-lived signing certs.
  The keyring holds the root CA, plus the *next* root CA shipped ahead of time.
  Intermediates travel in the bundle signature (`rauc bundle --intermediate`).
- Rotating a signing key means issuing a new cert: no device change. Rotating the
  root is planned by pre-shipping its successor. Revocation uses a CRL in the
  keyring (`check-crl`), shipped with the image.
- RAUC 1.15 hardening: `check-purpose=codesign`, `allowed-signer-cns`,
  `min-bundle-version`.
- Changes: release tooling and the `rauc-conf` keyring only. No aktualizr or cloud
  change; works for every install path.
- Limit: a lost or compromised root without a pre-shipped successor needs a field
  action (reflash).

### B — trust anchor per target, in custom metadata

- Publishing adds `custom.rauc.keyring` (PEM) next to `custom.rauc.manifest-hash`.
  aktualizr reads it from the Image repo target, like the hash, writes it to a
  RAUC keyring directory before `InstallBundle` and removes it afterwards.
  `InstallBundle` takes no keyring argument, but RAUC reloads the keyring from
  disk at every install. The directory goes in system.conf as
  `[keyring] directory=` next to the baked `path=`; its files must be named
  `<X509_NAME_hash>.0`.
- Rotation: publish with the new cert.
- Changes: a small aktualizr change plus tests, the publish step, system.conf.
- Cost: the cert is vouched for by the same key that vouches for the hash, so on
  the Uptane path the RAUC check becomes a formality. This is *Uptane alone*.
  Every package must carry the cert.

### C — the keyring as Uptane metadata with its own role

The trust anchors become signed metadata with their own key and threshold,
rotated through Uptane, independent of the per-package key.

- **C1 — keyring package for a dedicated ECU.** A `<machine>-rauc-keyring`
  generic secondary whose action handler installs the certs into the keyring
  directory. Uses existing machinery, with no aktualizr change. It is only
  independent of the per-package key if keyring packages are signed by a
  delegated role with its own offline key; Torizon Cloud support for that is to
  be confirmed.
- **C2 — a new top-level role**, like the `OfflineUpdates`/`OfflineSnapshot`
  roles in Toradex's aktualizr: e.g. a `rauc-keyring.json` that is
  versioned, expiring and threshold-signed, with its key rotated through
  `root.json`. Cleanest semantics; needs reposerver, signing-tool and aktualizr
  work.

## Comparison

| | A | B | C1 | C2 |
|---|---|---|---|---|
| Trust on the Uptane path | Uptane + RAUC root | Uptane alone | Uptane + role key (if delegated) | Uptane + role key |
| Rotate a signing key | new cert | publish | publish a keyring package | sign new role metadata |
| Lost or compromised root | reflash, unless successor pre-shipped | publish | publish | rotate through `root.json` |
| aktualizr change | none | small | none | large |
| Cloud change | none | none | delegations? | new role |
| Manual `rauc install` | works | baked keyring only | works | works |

## Implementing B

- **Publish:** `scripts/publish-rauc-bundle.sh` sets `custom.rauc.keyring` (PEM:
  the signing cert if self-signed, else the root it chains to) in the same
  `PATCH` as the manifest hash.
- **aktualizr:** takes the cert from the Image repo target, as it does the hash
  (the Director's custom metadata wins a merge). It writes the cert as
  `<subject-hash>.0` (`openssl x509 -hash`) into the keyring directory before
  `InstallBundle` and removes it afterwards. A target without a cert installs
  against the baked keyring only.
- **system.conf:** `[keyring] directory=/run/rauc/keyring.d` next to the baked
  `path=`, the directory created at boot. Nothing in `/run` outlives a reboot.
- **Offline updates:** the cert comes from the offline metadata, like the hash.

A cert from the metadata is enough because the manifest hash fixes the content:
anyone can re-sign that manifest with another key, but not change what gets
installed.

## Open questions

- Root lifetime of the baked keyring and how far ahead to pre-ship its successor
  (option A).
- Should TorizonCore Builder set the cert when it publishes (roadmap B17)?
