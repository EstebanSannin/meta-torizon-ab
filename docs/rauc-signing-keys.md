# RAUC bundle-signing keys and Uptane (design)

**Status:** proposal, not implemented (2026-11-03). Phase 4 of the x86 RAUC
package manager work ([rauc-decisions.md](./rauc-decisions.md) D8). Written to
decide, with the aktualizr and Torizon Cloud owners, how RAUC's trust anchor is
managed and rotated.

## Where we are

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

## Recommendation

1. **Do A now.** It replaces the dev key, any shipped device needs it whatever we
   choose next, and it changes neither aktualizr nor the cloud.
2. **Keep the two-check model as the default.** Adopt B only if the Image repo
   targets key is held offline. Otherwise it quietly ties RAUC's trust to a key the
   cloud holds.
3. **If Uptane-managed rotation is wanted** (to recover from a lost or compromised
   root), take C to the cloud team: C1 if Torizon Cloud supports delegations with
   a customer-held offline key today, C2 as the design to upstream.

## Open questions

- Product trust model: Uptane alone, or Uptane + RAUC anchor?
- Torizon Cloud: delegations with customer-held offline keys? Is moving the Image
  repo targets key offline the production recommendation?
- Root lifetime and how far ahead to pre-ship its successor (option A).
