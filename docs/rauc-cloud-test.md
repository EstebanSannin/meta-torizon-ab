# RAUC A/B — end-to-end cloud update test (aktualizr + Torizon Cloud)

Validates the full production path: provision the device to Torizon Cloud, push
a RAUC bundle as a custom package for the OS rootfs secondary, and let aktualizr
+ `rauc_actions.sh` apply it to the inactive A/B slot.

This is the same aktualizr generic-secondary seam as the SWUpdate variant; only
the handler (`rauc_actions.sh` → `rauc install`) and payload (`.raucb`) differ.

## Artifacts

Build (on the build host, in the crops container):

```
DISTRO=torizon-ab-rauc MACHINE=genericx86-64 bitbake torizon-minimal-ab torizon-ab-bundle
```

- Flashable A/B image: `build-rauc/deploy/images/genericx86-64/torizon-minimal-ab-genericx86-64.wic`
- RAUC bundle (upload this):     `build-rauc/deploy/images/genericx86-64/torizon-ab-bundle-genericx86-64.raucb`
- Secondary hardware id:         **`genericx86-64-rootfs`**
- Bundle compatible string:      `torizon-ab-rauc-genericx86-64`

## Run the VM

```
cd ~/code/torizon-os
./run-rauc-vm.sh            # interactive serial console (TCG); SSH forwarded to :2250
KVM=1 ./run-rauc-vm.sh      # faster (uses /dev/kvm; runs the container --privileged)
```

The disk `m2/rauc-vm.wic` is persistent, so provisioning and the applied update
survive reboots. To start over from a clean, unprovisioned slot-A image:

```
cp -f build-rauc/deploy/images/genericx86-64/torizon-minimal-ab-genericx86-64.wic m2/rauc-vm.wic
cp -f build-rauc/deploy/images/genericx86-64/ovmf.qcow2 m2/rauc-vm-ovmf.qcow2
```

## Log in

Console (from `./run-rauc-vm.sh`) or SSH. Default user `torizon` / password
`torizon`; the first login forces a password change (stock Torizon).

```
# on the build host:
ssh -p 2250 torizon@127.0.0.1
# from your laptop (tunnel through the build host):
ssh -L 2250:localhost:2250 claude@192.168.1.246
ssh -p 2250 torizon@localhost
```

## Provision to Torizon Cloud

Provision the running device to your Torizon Cloud account using your normal
flow (shared/offline provisioning credentials). aktualizr config lives under
`/var/sota` (`sota.toml`, `conf.d/`); the OS-update secondary is registered in
`/var/sota/storage/rootfs/` and `secondaries.json` (hwid `genericx86-64-rootfs`).

Confirm registration:

```
sudo aktualizr-info          # shows the primary + the '<machine>-rootfs' secondary
```

## Push the update

1. Upload `torizon-ab-bundle-genericx86-64.raucb` to Torizon Cloud as a **custom
   "Other" package** for `ecu_hardware_id = genericx86-64-rootfs` (Web UI is the
   reliable path for large rootfs artifacts).
2. Create/launch an update targeting that secondary for the device.

## Watch it apply (on the device)

```
sudo journalctl -fu aktualizr-torizon
sudo tail -f /var/lib/rollback-manager/rootfs-update.log     # rauc_actions.sh + rauc output
sudo rauc status                                              # slot states / activation
```

Expected sequence:

1. aktualizr downloads + Uptane-verifies the bundle to
   `/var/sota/storage/rootfs/rootfs.raucb`, then calls `rauc_actions.sh install`.
2. The handler unmounts any auto-mounted inactive slot and runs `rauc install`,
   which writes the inactive slot, verifies the bundle signature against
   `/etc/rauc/keyring.pem`, and arms the bootloader (grubenv ORDER).
3. `/run/need-reboot` → `torizon-ab-pending-reboot` reboots.
4. GRUB boots the freshly-installed slot (`rauc.slot=B`, `root=PARTLABEL=rootfs_b`).
5. greenboot health check passes → `rauc status mark-good`.
6. aktualizr `complete-install` reports success; the cloud shows the new version
   installed on `genericx86-64-rootfs`.

Verify on device:

```
cat /proc/cmdline          # rauc.slot=<A|B>
findmnt -no SOURCE /        # /dev/disk/by-partlabel/rootfs_<a|b>
sudo rauc status            # booted=<new slot> good; other slot retained (rollback)
```

## Notes / gotchas

- The bundle is **plain**-format and **dev-signed** (`/etc/rauc/keyring.pem` is a
  development cert — NOT for production).
- The target kernel has `CONFIG_SQUASHFS` (required to mount RAUC bundles).
- RAUC addresses slots by GPT PARTLABEL (`rootfs_a`/`rootfs_b`); the slots carry
  no ext4 label (so the automounter leaves them alone).
- If `rauc install` ever reports the slot device busy, something auto-mounted it;
  `rauc_actions.sh` unmounts inactive slots defensively before installing.
