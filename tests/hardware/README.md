# Hardware test harness — dev/test access & runtime reset

These scripts inject **ephemeral** dev/test access into a running Torizon OS A/B
device, and reset its runtime state, **over the serial console**. They are the
runtime counterpart of the deliberately **pristine** deployable image.

> **They are NOT part of any image.** Nothing here is installed into the
> `.wic`/`.swu`/`.raucb`. Run them on the host physically wired to the board
> (`beerus`).

## Why the image is pristine (the whole point)

The build → test → deploy pipeline requires the **deployed binary artifact to be
bit-identical to the tested one**. So the image ships **no** dev SSH key, **no**
passwordless sudo, and **no** provisioning identity baked into any rootfs slot.
If any of those were in the image, every production device would ship a backdoor
key, open sudo, and a shared identity — and "tested == deployed" would be a lie.

Dev/test access is therefore added **at runtime by this harness**, and every
change it makes lands on the **data partition** only, never in a rootfs slot:

| What the harness writes        | Path            | Backing store (data partition, `LABEL=data`) |
|--------------------------------|-----------------|----------------------------------------------|
| session `authorized_keys`      | `/home/torizon` | bind → `data:/persist/home`                  |
| `sudoers.d`, `/etc/shadow`     | `/etc` (overlay)| `data:/persist/etc/upper`                    |
| provisioning (`/var/sota`)     | `/var`          | the data partition itself                    |

A reflash — or `runtime-reset.sh` — removes all of it. The rootfs slots (the
thing actually under test) are never modified, so what you flash, test, and
deploy is the same bytes. See `../../docs/persistence.md` for the data-partition
layout this relies on.

## Serial ports (this bench)

| Board                | Address        | Backend  | Serial (`beerus`) |
|----------------------|----------------|----------|-------------------|
| Verdin **iMX8MP**    | `192.168.1.7`  | SWUpdate | `/dev/ttyUSB3`    |
| Verdin **AM62P**     | `192.168.1.8`  | RAUC     | `/dev/ttyUSB4`    |

**Never open `/dev/ttyUSB5`** — it is the dead sibling interface of the AM62P
serial bridge. Only one reader may hold a tty at a time.

### Attaching to an existing serial logger

This bench keeps a persistent logger on each port
(`cat /dev/ttyUSB3 > /tmp/imx8-serial.log`, `… ttyUSB4 > /tmp/am62-serial.log`).
Two readers on one tty split the bytes and corrupt both captures, so the harness
**auto-detects** a running logger and attaches to it — writing to the tty and
tailing the logger's file, killing nothing. In attach mode you must tell it which
file to tail:

```sh
SERIAL=/dev/ttyUSB4 SERLOG=/tmp/am62-serial.log ./enable-access.sh      # am62p
SERIAL=/dev/ttyUSB3 SERLOG=/tmp/imx8-serial.log ./enable-access.sh      # imx8mp
```

With no logger running, the harness starts (and later stops) its own reader; pass
`SER_ATTACH=1 SERLOG=<file>` to force attach explicitly.

## `enable-access.sh` — inject ephemeral access

Logs in on the serial console (handling stock Torizon's forced first-boot
password change: it ships `torizon`/`torizon` and expires it with `passwd -e`),
sets a throwaway session password, installs a session SSH key, enables
passwordless sudo, and normalises password aging so headless key SSH is not
blocked by PAM.

```sh
# on beerus:
SERIAL=/dev/ttyUSB4 TZ_SESSION_PUBKEY_FILE=~/.ssh/ota_ce_vm.pub ./enable-access.sh
SERIAL=/dev/ttyUSB4 ./enable-access.sh --teardown      # best-effort removal
```

There is **no secret in this repo**: the bootstrap password is Torizon's public
default; the session password is a throwaway on a device that gets reflashed.
Override the session key with `TZ_SESSION_PUBKEY` (a key string) or
`TZ_SESSION_PUBKEY_FILE` (default `~/.ssh/ota_ce_vm.pub`), and the session
password with `TZ_NEW_PW`.

## `runtime-reset.sh` — runtime/provisioning reset (NOT factory)

Wipes the data partition (so `/var/sota` provisioning, `/home`, the `/etc`
overlay upper, and the seed marker are gone and the initramfs re-seeds factory
`/var`+`/home` next boot) and resets the boot-env A/B selection variables to
their factory defaults. **It does not touch either rootfs slot.**

```sh
SERIAL=/dev/ttyUSB4 ./runtime-reset.sh --backend rauc     --yes   # am62p
SERIAL=/dev/ttyUSB3 ./runtime-reset.sh --backend swupdate --yes   # imx8mp
```

It works entirely over serial via the boot script's `${tdxargs}` passthrough:
reboot → U-Boot sets the boot-env defaults and arms a one-shot
`tdxargs=shell=before:persist`, which drops the initramfs into a shell **before**
the persistence module mounts the data partition; the shell mounts it, `rm -rf`s
it, unmounts, and reboots clean (with `tdxargs` cleared). No image change and no
`fw_setenv`/`grub` tools are needed on the device.

### This is not a factory reset

Once A/B update tests have overwritten a slot's original bytes, the factory image
is gone — the device keeps no copy of the built image, so there is **no software
way back**. A true factory reset = **reflash**, which the pipeline does anyway for
the next test image. Use this only for tests that need a clean provisioning start
without a reflash.

## Implementation note

`serial-lib.sh` is a dependency-free POSIX send/expect over the tty (background
`cat` into a log + `printf` into the device + polled `grep`), because pexpect /
pyserial are not reliably present on the bench. Each on-device command is verified
with a sentinel (`… ; echo __RC__$?`) rather than by matching a prompt string.

Reliability details learned driving real hardware:

- **One write fd for the session.** `ser_open` opens the tty for writing once
  (fd 4) and every send reuses it; opening the port per command/char glitches the
  line.
- **The busybox initramfs console is lossy.** Unlike the full-userspace login
  shell (proper tty line discipline), the pre-persist initramfs shell
  (`sh: can't access tty; job control turned off`) drops ~1 char per command.
  Commands sent there go through `ser_send_verified`, which types slowly, checks
  the console echoed the command back verbatim (ignoring cosmetic line-wraps —
  long lines hard-wrap at ~80 cols), and retries before committing with Enter.
  Keep those commands short, guarded (`cd X && …`), and idempotent.
- **`reboot -f` works from both** a normal OS shell (via passwordless sudo) and
  the initramfs (root, direct syscall); `runtime-reset.sh` logs in on the serial
  console first if it finds a login prompt.
