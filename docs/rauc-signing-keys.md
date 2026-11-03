# RAUC bundle-signing keys and Uptane

**Status:** implemented 2026-11-03 (roadmap B18) for x86 with the RAUC package
manager ([rauc-decisions.md](./rauc-decisions.md) D8).

## How a bundle is trusted

- **On the Uptane path, Uptane alone.** The Image repo target names the bundle's
  manifest hash and RAUC refuses any other bundle (`require-manifest-hash`), as an
  OSTree target's hash binds it in stock Torizon OS. Whoever holds the Image repo
  targets key decides what runs; in Torizon Cloud that key is online (the cloud
  re-signs `targets.json` on every `PATCH /packages`), as it is for OSTree today.
- **RAUC still checks every bundle's signature** and cannot skip it on install:
  `--no-verify` exists only for `info`, `convert`, `resign` and
  `replace-signature`. So the update carries the cert its bundle chains to.
- **A manual `rauc install`** has no Uptane and only the keyring baked into the
  image, `/usr/lib/rauc/keyring.pem` (today the in-tree dev cert).

## How it works

- **Publish:** `scripts/publish-rauc-bundle.sh --keyring <pem>` sets
  `custom.rauc.keyring` (PEM: the signing cert if self-signed, else the root it
  chains to) in the same `PATCH` as the manifest hash.
- **aktualizr:** takes the certs from the Image repo target, as it does the hash
  (the Director's custom metadata wins a merge). It writes each one as
  `<subject-hash>.<n>` (`openssl x509 -hash`) into the keyring directory before
  `InstallBundle` and removes the files it wrote afterwards. A target without a
  cert installs against the baked keyring only. The directory is `[pacman]`
  `rauc_keyring_dir`, `/run/rauc/keyring.d` by default.
- **system.conf:** `[keyring] directory=/run/rauc/keyring.d` next to the baked
  `path=`. aktualizr creates the directory when it needs it; RAUC does not mind
  it missing.
- **No RAUC restart.** RAUC builds a new X.509 store for every bundle it checks
  (`setup_x509_store()` in `check_bundle()`), so it reads the keyring at each
  install; only the keyring paths come from `system.conf` at start.
- **D-Bus, not the CLI.** With the RAUC service running, `rauc install` refuses
  `--keyring` ("Reconfigure the service instead"), and D-Bus also gives the slot
  status (installed manifest hashes) that the package manager reports.
- **Offline updates** (untested): the cert is read like the hash, from the stored
  Image repo metadata.

A cert from the metadata is enough because the manifest hash fixes the content:
anyone can re-sign that manifest with another key, but not change what gets
installed.

*Validated on QEMU through Torizon Cloud (2026-11-03):* a streamed bundle
re-signed (`rauc resign`) with a key the image's keyring does not know. Published
without `--keyring`, the device refused it within a second ("signature
verification failed"), reported to the cloud, with the trial flag cleared and the
keyring directory not even present. Published with `--keyring`, the cert was in
the directory during the install (`<subject-hash>.0`), the same RAUC process
verified the signature, and the update completed: the booted slot holds the
bundle's manifest hash.

## Still open

- **Production keys for the baked keyring**, which manual installs use: replace
  the dev cert with an offline root CA that issues short-lived signing certs
  (intermediates travel with `rauc bundle --intermediate`), ship the next root
  ahead of time, and consider `check-purpose=codesign`, `allowed-signer-cns`,
  `min-bundle-version` (RAUC 1.15).
- **TorizonCore Builder** should set the cert when it publishes (roadmap B17).
- **Offline updates** with a cert in the metadata are untested.

## Alternatives considered

- **Uptane plus an independent RAUC trust anchor** (keyring only in the image,
  managed as a PKI): a cloud compromise could only pick among bundles we signed.
  But a new anchor reaches a device only inside a bundle the old one verifies, so
  a lost or compromised root means reflashing. Not used on the Uptane path; it
  remains the way to manage the baked keyring.
- **The keyring as Uptane metadata with its own key**: a keyring package signed
  by a delegated role with an offline key, or a new top-level role like
  `OfflineUpdates`. Rotatable through Uptane and independent of the per-package
  key, but it needs cloud support (delegations or a new role) and, for a new
  role, aktualizr and signing-tool work. Not needed with Uptane alone.
