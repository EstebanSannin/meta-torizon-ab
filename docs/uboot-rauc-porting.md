# Porting the U-Boot RAUC A/B variant to a new machine

This is the **porting contract**: the short, concrete checklist to bring the RAUC
A/B Torizon OS variant (`DISTRO=torizon-ab-rauc`) to a new U-Boot machine. It was
factored from two grounded targets — **Verdin AM62p** (TI K3) and **Verdin
i.MX8MP** (NXP) — so most of the work is already done for you: a new machine in
either SoC family supplies only a small data block, not new logic.

Everything **below the aktualizr generic-secondary seam** (the `rauc_actions.sh`
handler, the cloud OTA path) is machine-agnostic and needs **no** porting work —
see [rauc-cloud-test.md](./rauc-cloud-test.md). This document is only about the
bits **below** the seam: the bootloader glue, the disk layout, and flashing.

---

## The three tiers of variation

The U-Boot RAUC glue is split so a port touches as little as possible:

| Tier | What it is | Where it lives | Keyed on |
|------|-----------|----------------|----------|
| **1 — common** | RAUC `uboot` backend, `BOOT_ORDER`/`BOOT_<slot>_LEFT`, the templated `boot.cmd` (runtime GPT-label slot resolution, env-sourced load addresses), the shared A/B wks, the `fw_env.config` *mechanism*, the greenboot `mark-good` hook | `recipes-bsp/rauc-uboot-ab`, `wic/torizon-ab-rauc-uboot.wks` | all U-Boot RAUC machines |
| **2 — SoC family** | DTB directory under `/boot`; boot-firmware flashing method; recovery method | `conf/distro/include/torizon-ab-uboot.inc` (data) + the Tezi wrapper (method) | SoC-family override (`:k3`, `:mx8mp-generic-bsp`, …) |
| **3 — per-machine** | device-tree file (module+carrier); mmc index; decompress scratch (only if `loadaddr==kernel_addr_r`) | `conf/distro/include/torizon-ab-uboot.inc` | machine override (`:verdin-am62p`, …) |

The single file you edit for Tiers 2–3 is
**`conf/distro/include/torizon-ab-uboot.inc`**. The boot firmware is *not* in the
`.wic`; it is laid down separately by the per-family Tezi wrapper at flash time.

---

## Porting checklist

### 0. Find your SoC-family override token (don't guess it)

The family axis rides the BSP's own SoC-family `MACHINEOVERRIDES`. Confirm the real
token before using it — the human-friendly name in the machine `.conf` is often
reformed by the BSP includes (e.g. NXP's bare `mx8mp` becomes `mx8mp-generic-bsp`):

```sh
DISTRO=torizon-ab-rauc MACHINE=<your-machine> ./bb.sh -e 2>/dev/null \
  | grep -E "^(OVERRIDES|MACHINEOVERRIDES)=" | tr ':' '\n'
```

Known tokens: TI K3 → **`k3`**; NXP i.MX8M Plus → **`mx8mp-generic-bsp`**.

### 1. Add the per-machine + family data block

In `conf/distro/include/torizon-ab-uboot.inc`:

```
# Tier-2 (only if your SoC family isn't already listed): DTB directory under /boot.
# Find the real path with: debugfs -R "ls /boot" <rootfs.ext4>  (it varies by vendor
# kernel: TI = /boot/dtb/ti, NXP linux-toradex = /boot/freescale).
TORIZON_AB_DTB_DIR:<family>        = "/boot/<vendor-specific>"

# Tier-3: the device-tree file for this module + carrier.
TORIZON_AB_FDTFILE:<machine>       = "<soc>-<module>-<carrier>.dtb"

# Tier-3 (only if not the defaults): mmc index, decompress scratch address.
TORIZON_AB_MMCDEV:<machine>        = "0"          # default 0
TORIZON_AB_KERNEL_SCRATCH:<machine> = "0x........" # only used if loadaddr==kernel_addr_r
```

The DTB **file name** is per-machine (module + carrier); the DTB **directory** is
per-family (vendor kernel: TI installs to `ti/`, NXP to `freescale/`). Load
addresses (`kernel_addr_r`/`fdt_addr_r`/`ramdisk_addr_r`/`loadaddr`) are **not**
data here — `boot.cmd` reads them from the board's own U-Boot environment.

If you forget the block, `rauc-uboot-ab`'s `do_compile` fails loudly with a
pointer back here (it will not silently ship a broken `boot.scr`).

### 2. Make the glue compatible with the machine

- `recipes-bsp/rauc-uboot-ab/rauc-uboot-ab_1.0.bb`: add the machine to
  `COMPATIBLE_MACHINE = "verdin-am62p|verdin-imx8mp|<your-machine>"`.
- If your SoC family is new, add the family-scoped wiring (mirroring `:k3` /
  `:mx8mp-generic-bsp`) in:
  - `conf/distro/torizon-ab-rauc.conf` — `WKS_FILE` + `IMAGE_FSTYPES` (wic).
  - `recipes-support/rauc/rauc-conf.bbappend` — `RAUC_SYSTEM_BOOTLOADER = "uboot"`.
  - `recipes-images/images/torizon-ab-base.inc` — install `rauc-uboot-ab`,
    `IMAGE_BOOT_FILES = "boot.scr"`, and the `do_image_wic[depends]` on
    `rauc-uboot-ab:do_deploy`.
  - `recipes-kernel/linux/<your-kernel>_%.bbappend` — add `rauc-squashfs.cfg`
    (RAUC mounts the bundle squashfs on-target; a hard requirement).

If your machine is in an **existing** family (`k3` / `mx8mp-generic-bsp`), steps
under "new SoC family" are already done — you only do step 1 + the
`COMPATIBLE_MACHINE` line.

### 3. Build-green + static verification (no board needed)

```sh
DISTRO=torizon-ab-rauc MACHINE=<machine> ./bb.sh torizon-minimal-ab torizon-ab-bundle
```

Then verify the artifacts without hardware:

```sh
cd build-rauc/deploy/images/<machine>
# boot.scr baked the right values, no @@ placeholders, GPT-label resolution present:
tail -c +65 boot.scr | grep -aE "dtb_dir|fdtfile|part number|@@"
# wic GPT part-names:
parted -s -m torizon-minimal-ab-<machine>.wic print   # expect boot/rootfs_a/rootfs_b/data
# system.conf:
debugfs -R "cat /etc/rauc/system.conf" torizon-minimal-ab-<machine>-*.ext4  # bootloader=uboot
```

### 4. The Tezi flash wrapper (Tier-2 method — needed for on-device M0)

The boot firmware is written **separately** from the `.wic`, and *how* differs by
SoC family. Adapt the stock machine's Tezi `image.json`:

| | TI K3 (am62p) | NXP i.MX (imx8mp) |
|---|---|---|
| Boot firmware | `tiboot3` + `tispl` + `u-boot.img` | single `imx-boot` blob |
| Written to | eMMC **boot0** at seeks 0 / 1024 / 5120 | eMMC at `IMX_BOOT_SEEK` (imx8mp: **32 KiB**) |
| Recovery to load Tezi | `dfu-util` + `recovery-linux.sh` | **SDP + `uuu`** (NXP) |

> ⚠️ **i.MX flash risk:** confirm the `imx-boot` blob fits before the first GPT
> partition (p1 is 1 MiB-aligned; `imx-boot` starts at 32 KiB) — check the stock
> Verdin i.MX8MP `image.json` for whether it lands in the user area or `boot0`.

Then flash via the headless loop in [am62p-hardware-loop.md](./am62p-hardware-loop.md)
(the loop itself is machine-generic; only the recovery command differs per family).

### 5. On-device milestones (need the board)

M0 flash+serial → M2 `rauc install` A→B → M3 rollback → M4 cloud OTA. **M2–M4 are
machine-agnostic** — reuse the am62p runbook verbatim (same handler, same REST API
loop). See [rauc-cloud-test.md](./rauc-cloud-test.md).

---

## What you do NOT need to touch

- `rauc_actions.sh` (the aktualizr handler) — machine-agnostic.
- The aktualizr generic-secondary registration/seam — shared.
- greenboot health authority — shared (`rauc status mark-good`).
- The cloud provisioning + upload + launch API flow — machine-agnostic.
- `boot.cmd`'s slot-selection / rollback / partition logic — generalized; a new
  machine changes only the three `@@…@@` data values via Tier-2/3, never the code.

## Reference: the two grounded machines

| | Verdin AM62p | Verdin i.MX8MP |
|---|---|---|
| SoC family override | `k3` | `mx8mp-generic-bsp` |
| DTB dir | `/boot/dtb/ti` | `/boot/freescale` |
| fdtfile | `k3-am62p5-verdin-wifi-yavia.dtb` | `imx8mp-verdin-wifi-dahlia.dtb` |
| U-Boot env (BSP `fw_env.config`) | `mmcblk0boot0 @ 0x680000` | `/dev/emmc-boot0 @ -0x2200` |
| Boot firmware | tiboot3/tispl/u-boot → boot0 | `imx-boot` @ 32 KiB |
| Recovery | dfu-util + recovery-linux.sh | SDP + uuu |
