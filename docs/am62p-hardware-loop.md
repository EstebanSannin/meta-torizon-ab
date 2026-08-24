# Verdin AM62p hardware loop — build → flash → serial

This is the **infrastructure runbook** for working on real Verdin AM62p hardware:
how to build a Torizon OS image, flash it onto the module's eMMC **headlessly**
(no display), and watch it boot over the serial console. It is deliberately
independent of the A/B / RAUC work — it is the loop every hardware task depends
on (M0 in the AM62p plan). Proven end-to-end on 2026-08-24: a locally-built
image booted on the board, confirmed by its version string on the serial log.

> If you are picking this up cold: the loop is **build on m920x → copy to beerus
> → serve as a Tezi auto-install feed → recovery-boot Tezi → it flashes eMMC →
> `reboot -f` → confirm on serial**. Details and every gotcha below.

---

## 1. Topology & access

Three machines plus the board. **They are not all on one network** — a common
trap: m920x's LAN and the local LAN both happen to use `192.168.1.x` but are
**different physical networks**.

| Host | Role | Reach it with | Network |
|------|------|---------------|---------|
| **m920x** | Remote Yocto build host (24c/93G) | `ssh m920x` (DDNS tunnel, port 20022) | *Remote*; its `192.168.1.246` is at its own site |
| **beerus** | Local box wired to the board: serial + USB recovery + flash feed | `ssh beerus` (`192.168.1.12`) | **Local LAN** with the board |
| **Mac** | Checkout host + bridge between the two networks | this session | On both: DDNS→m920x, LAN→beerus/board |
| **Verdin AM62p** | Device under test (DUT), eMMC boot | serial + recovery via beerus | Local LAN (`eth0`) + USB-NCM to beerus |

SSH aliases live in `~/.ssh/config` on the Mac (`m920x`, `beerus`), both using
`~/.ssh/ota_ce_vm`. **Do not** write `ssh $VAR '...'` in this session — the shell
is **zsh**, which does not word-split unquoted variables, so the options collapse
into one bogus arg. Use the aliases (or spell options out literally).

Consequence of the topology: **any board-facing service (the Tezi feed, device
SSH) must run on beerus**, not m920x. Copy build artifacts `m920x → Mac → beerus`.

### Board identity (this unit)
`Toradex 0099 Verdin AM62P Quad 2GB WB IT V1.0B`, SoC `AM62PX SR1.0 HS-FS`
(High-Security-Field-Securable → needs the signed `tiboot3-am62px-hs-fs-verdin.bin`,
which the machine config already selects). Boots from **eMMC (MMC1)**.
`MACHINE=verdin-am62p`, kernel `linux-toradex-ti`, bootloader `u-boot-toradex-ti`.

### Serial console (beerus)
Yavia debug bridge = **Silicon Labs CP2105 dual UART**:
- `/dev/ttyUSB0` (CP2105 interface 0) = **A53 Linux/U-Boot console** — use this.
- `/dev/ttyUSB1` (interface 1) = secondary UART, dead.
- **115200 8N1.** Only one reader at a time — kill stray `cat /dev/ttyUSB0` first.

Quick capture (raw, non-interactive):
```sh
ssh beerus 'timeout 60 cat /dev/ttyUSB0 | strings'
```
You can type into the shell by writing to the port (`printf 'cmd\r\n' > /dev/ttyUSB0`)
while a `cat` reads — but it is flaky for long/interactive use (see gotchas).

---

## 2. Build (on m920x)

A dedicated, **clean** build dir `~/code/torizon-os/build-am62` (stock Toradex
`DISTRO=torizon`, **no** meta-torizon-ab/meta-rauc/meta-swupdate) is used for the
reference image; the A/B work gets its own dir later. Helper:

```sh
ssh m920x
cd ~/code/torizon-os
DISTRO=torizon MACHINE=verdin-am62p ./bb-am62.sh torizon-minimal      # or torizon-docker
```

`bb-am62.sh` runs bitbake inside the `torizon/crops:scarthgap-7.x.y` container
against `build-am62`, `MACHINE`/`DISTRO` passed via env. Everything builds in the
container — never on the host directly.

Setup already done in `build-am62/conf/local.conf` (keep these):
- `DL_DIR`/`SSTATE_DIR` → shared `/workdir/downloads`, `/workdir/sstate-cache`.
- `FETCHCMD_wget = "... --inet4-only ..."` — the host has broken IPv6 to some CDNs.
- **jq build fix** `B:pn-jq = "${S}"` + `B:pn-jq-native = "${S}"` — jq fails to
  compile out-of-tree on the current meta-oe HEAD. (meta-torizon-ab carries this
  as a bbappend; build-am62 excludes that layer so it is set in local.conf.)

**TI two-stage boot is automatic**: the `verdin-am62p` machine include pulls
`mc_k3r5.inc` → `BBMULTICONFIG += "k3r5"` → the R5 SPL (`tiboot3.bin`) is built
via the `verdin-am62p-k3r5` multiconfig with no extra wiring.

Output (`build-am62/deploy/images/verdin-am62p/`):
- `torizon-minimal-verdin-am62p-Tezi_<version>.tar` — the **Tezi bundle** (flash this).
- `tiboot3-am62px-hs-fs-verdin.bin`, `tispl.bin`, `u-boot.img` — boot firmware.

A first cold build for this machine is ~1.5–4 h. Launch detached and poll:
```sh
ssh m920x 'cd ~/code/torizon-os && nohup bash -c "DISTRO=torizon MACHINE=verdin-am62p ./bb-am62.sh torizon-minimal > am62-build.log 2>&1; echo EXIT=\$? >> am62-build.log" >/dev/null 2>&1 &'
# progress:
ssh m920x 'grep -aE "Running task [0-9]+ of" ~/code/torizon-os/am62-build.log | tail -1'
```

---

## 3. Flash it headlessly (Toradex Easy Installer auto-install)

Recovery-mode flashing over the **DRP USB-C** port (cabled to beerus) is the only
way to write eMMC — serial cannot flash. We drive Tezi's **network auto-install**:
serve the image from beerus as a Zeroconf-announced feed; a freshly recovery-booted
Tezi discovers it and installs unattended.

### 3a. Stage the feed on beerus
```sh
# copy the built Tezi bundle m920x -> Mac -> beerus, extracted into ~/am62p/feed/
ssh m920x 'cd ~/code/torizon-os/build-am62/deploy/images/verdin-am62p && tar -cf - <Tezi-dir-or-extracted>' \
  | ssh beerus 'mkdir -p ~/am62p/feed && tar -C ~/am62p/feed -xf -'
```
The feed dir must contain the **image directory** plus an **`image_list.json`**:
```json
{ "config_format": 1, "images": ["<image-dir>/image.json"] }
```
Edit the image's `image.json`: set `"autoinstall": true` and **remove the
`"license"` key** (so it installs unattended, no license prompt).

### 3b. Serve it (with a request log so you can SEE progress)
Use **systemd transient units** — `nohup ... &` over SSH does **not** survive the
session closing; systemd units do.
```sh
ssh beerus
sudo systemd-run --unit=tezi-feed-http --collect python3 -m http.server 80 --directory ~/am62p/feed
sudo systemd-run --unit=tezi-avahi --collect avahi-publish -s TeziFeed _tezi._tcp 80 https=0 enabled=1 path=/image_list.json
# watch fetches live:
sudo journalctl -u tezi-feed-http -f
```
(`torizoncore-builder images serve <dir>` also works and announces mDNS itself,
but hides the HTTP request log. The manual pair above is transparent + reusable.)
Verify: `avahi-browse -tr _tezi._tcp` shows the service on port 80 resolving to
beerus (`192.168.11.2` NCM and/or the LAN IP); `curl http://127.0.0.1/image_list.json` → 200.

### 3c. Recovery-boot Tezi
```sh
ssh beerus
cd ~/am62p/tezi/extracted/Verdin-AM62P_ToradexEasyInstaller_<ver>/
sudo ./recovery-linux.sh        # polls for the board's ROM USB (0451:6165), then loads Tezi
```
**Now (human step):** put the module in **recovery mode** (Yavia recovery button —
momentary) and **power-cycle**. `recovery-linux.sh` then dfu-util-pushes
`tiboot3 → tispl → u-boot.img-recoverytezi`, `uuu`-loads `tezi.itb`; the HS-FS
signatures verify and **Tezi boots into RAM** (non-destructive — eMMC untouched
until it installs).

### 3d. Auto-install runs itself — DO NOT INTERFERE
Tezi comes up as `tezi -autoinstall`, gets `eth0` (LAN DHCP) + `usb0` NCM
(`192.168.11.1` ↔ beerus `192.168.11.2`), discovers the mDNS feed, and installs.
You will see the HTTP log fetch, in order:
`image_list.json → image.json → scripts → <image>.ota.tar.zst` (rootfs) `→
tiboot3 / tispl / u-boot.img` (raw to `mmcblk0boot0`). It writes the rootfs to
`mmcblk0` and the boot firmware to `mmcblk0boot0`.
**Do not kill the `tezi` process** — that aborts the install and it does **not**
respawn (the only failure we hit). Just wait; the fetch + eMMC write take a few
minutes. After a successful install Tezi sits on its "done" screen (it does not
auto-reboot, so NCM stays up).

### 3e. Boot the flashed image
Recovery on the Yavia is momentary, so no switch to flip. From the **Tezi serial
shell**:
```sh
# via serial (ttyUSB0):
reboot -f          # plain `reboot` is IGNORED by Tezi's init — must be -f
```
…or just physically power-cycle. The board boots eMMC → U-Boot → our image.

---

## 4. Verify
```sh
ssh beerus 'timeout 60 cat /dev/ttyUSB0 | strings | grep -aE "U-Boot 20|Torizon OS [0-9]|login:"'
```
Success = the login banner shows the **version string of the image you built**
(e.g. `Torizon OS 7.7.0-devel-<timestamp>+build.0 verdin-am62p-...`). The build
timestamp is the unambiguous discriminator vs. whatever was on eMMC before.

---

## 5. Lessons learned / gotchas (read before debugging)

- **Shell is zsh** in the driving session → `ssh $VAR '...'` breaks (no word
  split). Use `~/.ssh/config` aliases `m920x` / `beerus`.
- **Topology:** m920x is remote (DDNS); beerus + board + Mac are the local LAN.
  Board-facing services run on **beerus**. Shared `192.168.1.x` ranges are a
  coincidence, not one network.
- **Serial:** console is `ttyUSB0` (CP2105 if0) @115200; `ttyUSB1` is dead. One
  reader at a time. Driving the shell by writing to the tty while `cat` reads is
  flaky — prefer short, self-contained commands; for anything real, redirect
  board output to a file and `cat` it back.
- **Recovery/flash needs the DRP USB-C** cabled to beerus; serial can't flash.
  eMMC target ⇒ recovery is mandatory (can't swap a card). `uuu` is used *inside*
  Toradex's `recovery-linux.sh` (fastboot stage); the DFU stages use `dfu-util`.
- **jq** won't build out-of-tree on this meta-oe HEAD → `B = "${S}"` (already set).
- **k3r5 multiconfig** is automatic via the machine include — don't hand-add it.
- **systemd-run** for any long-lived service on beerus; `nohup … &` over SSH dies
  with the session.
- **Tezi feed** = `image_list.json` + image dir; `autoinstall:true` + delete the
  `license` key for unattended. Discovery is mDNS `_tezi._tcp`; transport also
  works over the USB-NCM link alone (`192.168.11.2`).
- **Never kill `tezi` mid-install** — aborts, no respawn.
- **`reboot -f`**, not `reboot`, from the Tezi shell.
- Tezi userland is **BusyBox** (`head -n N`, not `-N`). `tezi --help` hangs (wants
  a display). Board exposes **VNC:5900** (documented headless UI) but **no SSH**.
  `vncdotool` on beerus is currently broken (pyopenssl/cryptography conflict) —
  don't depend on it.
- Loading Tezi into RAM is **non-destructive**; eMMC is only touched once Tezi
  actually installs. Safe to load Tezi just to poke around.

---

## 6. One-glance cheat-sheet
```sh
# BUILD (m920x)
ssh m920x 'cd ~/code/torizon-os && DISTRO=torizon MACHINE=verdin-am62p ./bb-am62.sh torizon-minimal'

# COPY m920x -> beerus (via Mac)
ssh m920x 'cd ~/code/torizon-os/build-am62/deploy/images/verdin-am62p && tar -cf - <image>' \
  | ssh beerus 'mkdir -p ~/am62p/feed && tar -C ~/am62p/feed -xf -'
#   then ensure ~/am62p/feed/image_list.json + image.json{autoinstall:true, no license}

# SERVE (beerus)
ssh beerus 'sudo systemd-run --unit=tezi-feed-http --collect python3 -m http.server 80 --directory ~/am62p/feed'
ssh beerus 'sudo systemd-run --unit=tezi-avahi --collect avahi-publish -s TeziFeed _tezi._tcp 80 https=0 enabled=1 path=/image_list.json'

# RECOVERY-LOAD TEZI (beerus)  [human: recovery button + power-cycle]
ssh beerus 'cd ~/am62p/tezi/extracted/Verdin-AM62P_ToradexEasyInstaller_*/ && sudo ./recovery-linux.sh'

# WATCH INSTALL (beerus)
ssh beerus 'sudo journalctl -u tezi-feed-http -f'

# BOOT + VERIFY (beerus, serial)
ssh beerus 'printf "reboot -f\r\n" > /dev/ttyUSB0; timeout 60 cat /dev/ttyUSB0 | strings | grep -aE "Torizon OS [0-9]|login:"'
```
