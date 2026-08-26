# Hardware test harness — dev/test access

`enable-access.sh` injects **ephemeral** dev/test access into a running, pristine
Torizon OS A/B device **over the serial console**. It is the runtime counterpart
of the deliberately **pristine** deployable image.

> **It is NOT part of any image.** Nothing here is installed into the
> `.wic`/`.swu`/`.raucb`. Run it on the host physically wired to the board
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

A **reflash** removes all of it (see "Resetting a device" below). The rootfs slots
(the thing actually under test) are never modified, so what you flash, test, and
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
`SER_ATTACH=1 SERLOG=<file>` to force attach explicitly. (`serial-lib.sh` fails
loudly if an attached logger's file stops growing — a dead `cat` reader would
otherwise make every read silently stale.)

## `enable-access.sh` — inject ephemeral access

Logs in on the serial console (handling stock Torizon's forced first-boot
password change: it ships `torizon`/`torizon` and expires it with `passwd -e`),
sets a throwaway session password, installs a session SSH key, enables
passwordless sudo, and normalises password aging so headless key SSH is not
blocked by PAM.

```sh
# on beerus:
SERIAL=/dev/ttyUSB4 SERLOG=/tmp/am62-serial.log \
  TZ_SESSION_PUBKEY_FILE=~/.ssh/ota_ce_vm.pub ./enable-access.sh
SERIAL=/dev/ttyUSB4 SERLOG=/tmp/am62-serial.log ./enable-access.sh --teardown
```

There is **no secret in this repo**: the bootstrap password is Torizon's public
default; the session password is a throwaway on a device that gets reflashed.
Override the session key with `TZ_SESSION_PUBKEY` (a key string) or
`TZ_SESSION_PUBKEY_FILE` (default `~/.ssh/ota_ce_vm.pub`), and the session
password with `TZ_NEW_PW`.

**Validated on real hardware** (2026-08-26) on both the Verdin AM62P (RAUC) and
Verdin iMX8MP (SWUpdate): the dev key is rejected on a fresh flash (proving the
image is pristine), and after `enable-access.sh` the session key + passwordless
sudo work over SSH, with the changes confirmed on the data partition only.

## Resetting a device

**To restore a device to a clean state, reflash it.** Because the pipeline
reflashes for each test image anyway, reflash *is* the reset — and it is the only
true factory reset (once A/B update tests overwrite a slot's original bytes, the
device keeps no copy of the built image, so there is no software way back). See
`../../docs/am62p-hardware-loop.md` for the flash loop.

There is deliberately **no** in-tree software-reset tool. An earlier serial-driven
`runtime-reset.sh` (reboot → U-Boot boot-env defaults → a pre-persist initramfs
shell that wiped the data partition → re-seed) was prototyped and worked on am62p,
but driving the transient initramfs debug shell over serial proved brittle, so it
was dropped in favour of "just reflash".

**Future (not built):** a reset that runs entirely over the reliable SSH/normal
console — e.g. reformat the whole data partition (or clear the `/etc` overlay
upper + `/home` + `/var/sota`) and reset the boot-env via `fw_setenv` — to get a
clean provisioning start without a full reflash. This avoids the initramfs shell
entirely. Scoped as a follow-up.

## Implementation note (`serial-lib.sh`)

A dependency-free POSIX send/expect over the tty (background `cat` into a log +
`printf` into the device + polled `grep`), because pexpect / pyserial are not
reliably present on the bench. Each on-device command is verified with a sentinel
(`… ; echo __RC__$?`) rather than by matching a prompt string. Learnings baked in:

- **One write fd for the session** (`fd 4`, opened once in `ser_open`) — opening
  the port per command glitches the line.
- **Dead-logger guard.** When attaching to an external logger, `ser_open` confirms
  the capture actually grows and `ser_expect` flags a frozen capture — the
  background `cat` can exit on EOF when a board reboots and the USB serial
  re-enumerates, which would otherwise make every read silently stale.
