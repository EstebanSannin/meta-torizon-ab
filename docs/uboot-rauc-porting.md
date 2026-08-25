# U-Boot A/B boot architecture & porting guide

How the OSTree-free A/B variant boots on U-Boot machines, why it is structured
this way, and what it takes to add a new machine. Read this before porting to a
new board — in the common case there is **nothing per-machine to write**.

Applies to both backends (RAUC and SWUpdate); the only per-backend difference is
the slot-selection preamble (see [Backends](#backends)).

---

## The one principle: own slot selection, delegate the kernel boot

An A/B boot is two separable jobs:

1. **Slot selection** — *"which rootfs partition do we boot this time?"* This is
   **ours**. Its shape is universal (pick a slot → boot that partition → pass
   `rauc.slot=`/`root=`); only the *counter mechanism* is backend-specific
   (RAUC's `BOOT_ORDER`/`BOOT_<slot>_LEFT` vs SWUpdate's `bootcount`). It is ~15
   lines and it is the **only** thing this layer owns about booting.

2. **Kernel load + boot** — *"given a partition, load its kernel/dtb/initramfs
   with the right addresses, decompression, dtb path, overlays and boot it."*
   This is the **machine's** job. Every BSP already solves it, and — crucially —
   the machine-specific facts are exposed as **stable OpenEmbedded metadata
   variables**, not baked into any single vendor's boot script.

We therefore **own a small, generic boot script** that does slot selection and
then loads the kernel using those stable variables. We deliberately do **not**
depend on the BSP's own boot script (`meta-toradex-bsp-common`'s
`u-boot-distro-boot/boot.cmd.in`).

### Why not just reuse the BSP boot script?

Because coupling to it is fragile: it is maintained by a different team, changes
without notice, and a change can break us loudly (crash) or — worse — silently.
**Torizon OS itself made exactly this call:** `meta-toradex-torizon` ships its
*own* complete `u-boot-distro-boot.bb` (its own `boot.cmd.in`, `PROVIDES =
"u-boot-default-script"`) that overrides the BSP-common one, precisely to
insulate the product from that team. We do the same.

Owning the script does **not** mean reinventing per-machine logic — the machine
facts come from the stable metadata below, so one generic script serves every
machine. That is the whole trick.

---

## The stable metadata the boot script keys on

All set by the **machine/kernel recipes** (not by any boot script), so they are
stable and vendor-neutral — every BSP that builds a kernel sets them:

| Variable | Meaning | am62p | imx8mp |
|---|---|---|---|
| `KERNEL_IMAGETYPE` | kernel image filename | `Image.gz` | `Image.gz` |
| `KERNEL_DTB_PREFIX` | vendor DTB subdir | `ti/` | `freescale/` |
| `KERNEL_BOOTCMD` | arch boot command | `booti` | `booti` |

The **DTB path** varies only in whether the vendor kernel installs under
`/boot/<prefix>/` (e.g. `/boot/freescale/…`) or `/boot/dtb/<prefix>/` (e.g.
`/boot/dtb/ti/…`). The base dir (`KERNEL_DTBDEST`) is kernel-recipe-scoped and
not reliably readable from our recipe, so the script simply **tries both
layouts** keyed on `KERNEL_DTB_PREFIX` — no per-machine value needed.

Plus these come from the board's own U-Boot at runtime (no build-time value
needed):

| Runtime U-Boot var | Provides |
|---|---|
| `${devnum}` | the mmc device the boot script was loaded from (the eMMC) — replaces any hardcoded "mmc index" |
| `${loadaddr}`, `${fdt_addr_r}`, `${ramdisk_addr_r}` | load addresses |
| `${kernel_comp_addr_r}` | scratch for **`booti` auto-decompression** of `Image.gz` — so we never manage a decompress scratch ourselves |

> These `KERNEL_*` variables are also exactly what the BSP/Torizon boot
> scripts substitute — we consume the same stable facts, without depending on
> their volatile *code*.

### The one genuine per-deployment value: the carrier device tree

The device-tree *filename* is the **only** value that is not derivable from
stable metadata or the running U-Boot, because it depends on the **carrier board**
the SoM is plugged into (Dahlia, Yavia, Mallow, …) — a deployment fact, not a
machine fact.

U-Boot's carrier **auto-detection** (`${fdtfile}`) is **not reliable** for this:
on the Verdin iMX8MP it left `${fdtfile}` pointing at the `-dev` (Verdin
Development Board) DTB, which boots but misconfigures peripherals — observed as
**no ethernet** (the wrong carrier's pinmux). So the boot body does **not** trust
it. Instead the carrier DTB is baked in at build time via **`TORIZON_AB_FDTFILE`**
(→ the `@@FDTFILE@@` placeholder), defaulting to the machine's `UBOOT_DTB_NAME`
and overridable per machine/deployment — e.g. in `torizon-ab-bootscr.inc`:

```
TORIZON_AB_FDTFILE ??= "${UBOOT_DTB_NAME}"
TORIZON_AB_FDTFILE:verdin-imx8mp = "imx8mp-verdin-wifi-dahlia.dtb"   # our carrier
```

A runtime override (`${ab_fdtfile}` in the U-Boot env) takes precedence over the
baked value, so a field unit on a different carrier can be corrected without a
rebuild. **When porting, set `TORIZON_AB_FDTFILE` to the carrier you actually
deploy on** — it is the single thing you must get right per deployment.

---

## What the boot script does (structure)

Built into `boot.scr` by `rauc-uboot-ab`, from a template with `@@KERNEL_*@@`
substituted at build time. Pseudocode:

```
# 1. Slot selection (backend-specific preamble) — the only part we "own"
#    RAUC:     read BOOT_ORDER / BOOT_<slot>_LEFT, pick the first slot with
#              attempts left, decrement it, saveenv (power-safe), roll back when
#              a slot's attempts hit 0.
#    -> sets ${raucslot} (A|B) and ${rootlabel} (rootfs_a|rootfs_b)

# 2. Resolve the slot's partition by GPT label (no hardcoded partition numbers)
part number mmc ${devnum} ${rootlabel} slotpart

# 3. Boot args
setenv bootargs "root=PARTLABEL=${rootlabel} rw rauc.slot=${raucslot} ${tdxargs}"

# 4. Kernel load + boot — all from stable metadata / runtime env
#    DTB: try /boot/<prefix>/ then /boot/dtb/<prefix>/ (keyed on KERNEL_DTB_PREFIX)
ext4load mmc ${devnum}:${slotpart} ${loadaddr}         /boot/@@KERNEL_IMAGETYPE@@
ext4load mmc ${devnum}:${slotpart} ${fdt_addr_r}       ${dtbpath}   # resolved above
ext4load mmc ${devnum}:${slotpart} ${ramdisk_addr_r}   /boot/initramfs
@@KERNEL_BOOTCMD@@ ${loadaddr} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}   # booti auto-decompresses
```

No per-machine constants. `mmc index`, DTB dir, dtb name, decompress scratch,
arch boot command, kernel format — all resolved from metadata or the board.

Kernel + dtb + initramfs live in **each rootfs slot's `/boot`** (so one payload
write updates kernel + userspace atomically per slot). The shared FAT boot
partition carries only `boot.scr`.

---

## Adding a new machine — the porting checklist

For a machine whose **machine conf already sets** `KERNEL_IMAGETYPE`,
`KERNEL_DTBDEST`, `KERNEL_DTB_PREFIX` (all Toradex machines, and any BSP that
builds a device-tree kernel), porting is:

1. Add the machine to `rauc-uboot-ab`'s `COMPATIBLE_MACHINE`.
2. Set **`TORIZON_AB_FDTFILE`** for the machine to the **carrier DTB you deploy
   on** (in `torizon-ab-bootscr.inc`) — the one genuine per-deployment value (see
   [the carrier device tree](#the-one-genuine-per-deployment-value-the-carrier-device-tree)).
   It defaults to `${UBOOT_DTB_NAME}`; override it if that isn't your carrier.
3. Add the family-scoped wiring **only if the SoC family is new** (mirror `:k3` /
   `:mx8mp-generic-bsp`): `WKS_FILE` + wic `IMAGE_FSTYPES` in
   `torizon-ab-rauc.conf`, `RAUC_SYSTEM_BOOTLOADER = "uboot"` in
   `rauc-conf.bbappend`, and install `rauc-uboot-ab` in `torizon-ab-base.inc`.
   A machine in an **existing** family (another `k3` / i.MX) needs only steps 1–2.
4. Add the kernel's squashfs config fragment if that kernel recipe isn't already
   covered (`recipes-kernel/linux/<kernel>_%.bbappend` → `rauc-squashfs.cfg`).
5. Build-green + static check (no board):
   `DISTRO=torizon-ab-rauc MACHINE=<m> bitbake torizon-minimal-ab torizon-ab-bundle`,
   then verify `boot.scr` has no unsubstituted `@@…@@`, the wic GPT is
   `boot/rootfs_a/rootfs_b/data`, and `system.conf` is `bootloader=uboot`.
6. On hardware: M0 flash → M1 boot slot A → M2 `rauc install` A↔B → M3 rollback →
   M4 cloud OTA (M2–M4 are machine-agnostic — reuse `docs/rauc-cloud-test.md`).

Apart from `TORIZON_AB_FDTFILE` (the carrier, step 2), there is **no per-machine
boot data to write.** If a *kernel* fact is genuinely absent (e.g. a board that
sets none of the `KERNEL_*` vars), fix it in that machine's conf where it belongs
— do **not** add a per-machine override here.

### Verifying the assumptions on a new board (first bring-up)

At the U-Boot prompt: `mmc list` (eMMC device), `part list mmc <dev>` (slot
labels present), `printenv fdtfile kernel_comp_addr_r loadaddr` (carrier dtb +
auto-decompress available). These confirm the runtime vars the script relies on.

---

## Non-Toradex / third-party hardware

The mechanism is vendor-neutral by construction: it keys on **standard machine
metadata** (`KERNEL_DTBDEST`/`KERNEL_DTB_PREFIX`/`KERNEL_IMAGETYPE`) that any
BSP's kernel recipe sets, and on **standard U-Boot runtime vars** (`${devnum}`,
load addresses, `kernel_comp_addr_r`). So a third-party board is onboarded the
same way — no per-vendor boot-script adapter and, critically, **no dependency on
that vendor's boot script.** The only requirements a new BSP must meet:

- its machine conf sets the `KERNEL_*` DTB/image variables (standard),
- its U-Boot exposes `${devnum}` to a `script` bootmeth (standard distro-boot /
  bootstd) and sets load addresses (standard),
- boot medium is a GPT block device (eMMC/SD). Raw-NAND (UBI) boards are out of
  scope for this ext4-slot model and would need a separate design.

If a board lacks `kernel_comp_addr_r` (older U-Boot), the script falls back to an
explicit `unzip`; if it also lacks distinct load/decompress addresses, that is
the one case needing a small, board-scoped scratch — add it to that board's
conf, not as a shared default.

---

## Backends

`rauc-uboot-ab` (RAUC) and the SWUpdate `uboot-ab` glue share the **same generic
kernel-load body**; only the slot-selection preamble differs:

- **RAUC:** `BOOT_ORDER` + `BOOT_<slot>_LEFT` (RAUC's uboot bootloader backend
  reads/writes these via `fw_setenv`).
- **SWUpdate:** `rootfs_slot` + `bootcount`/`bootlimit` + `upgrade_available`.

Selected by the distro override (`:torizon-ab-rauc` / `:torizon-ab-swupdate`).
Adding the generic body to the SWUpdate path makes both backends portable
identically.

---

## What not to do

- **Do not** add per-machine boot constants (mmc index, DTB dir, dtb name, load
  addresses, decompress scratch) to this layer. They all come from metadata or
  the board. If you're tempted, the fact belongs in the machine conf.
- **Do not** `require`/bbappend the BSP-common `u-boot-distro-boot` boot script,
  or vendor a copy of it. We own a generic script keyed on stable metadata so we
  are insulated from that team's changes (as Torizon OS itself is).
- **Do not** reintroduce a `torizon-ab-uboot.inc` per-machine data block — the
  point of this architecture is that it isn't needed.
