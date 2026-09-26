# Status

Last updated: 2026-09-26.

## Verified on hardware

| Area | State | Evidence |
|---|---|---|
| Boot to UI | works | `sys.boot_completed=1`, 134 APKs, Launcher3QuickStep, setup wizard |
| Display | works | HDMI 1024×600@60, DP link HBR2 5.4 Gb/s at voltage level 1 |
| GPU | works | Mesa freedreno/Turnip, `drm_hwcomposer`, `card0-HDMI-A-1` |
| Ethernet | works | RTL8168h via `r8169`, adb over TCP |
| Wi-Fi | works | AIC8800D80 on USB, associated with a 5 GHz network |
| Bluetooth | works | paired with a phone, photo transferred over OBEX |
| Persistent `/data` | works, self-sizing | 231 GB ext4 on `mmcblk1p3`, marker file survived a reboot |
| Audio, 3.5 mm jack | works | WCD9385 via ADSP; PCM `RUNNING`, S16_LE 48 kHz stereo, confirmed by listening |
| Audio over HDMI | declared, unverified | `displayport-dai-link` in DT, `hdmi-audio-codec` registers, no routing yet |
| Bluetooth audio | untested | A2DP profile active in the framework |
| NVMe | untested | `nvme.ko` is in the image |
| HW video codecs | not started | |
| I²C / SPI | broken | board `qupv3fw.elf` missing |
| USB3 SuperSpeed | broken by design | PHY forced to DP-only, see README |
| MIPI-DSI | not started | |

Note that `Trebuchet` does not exist in LineageOS 24 — `Launcher3QuickStep` is the
expected launcher there, its absence is not a defect.

## Persistent `/data`

Working since 2026-09-24. Card layout: partition 1 ESP (3 GB), partition 2 `metadata`
(32 MB), partition 3 `userdata` (235.7 GB).

Completing the setup wizard also persists now (`device_provisioned=1`,
`user_setup_complete=1`); it used to reappear on every boot simply because `userdata`
was a tmpfs and had nowhere to record that it had been completed.

`androidboot.mount_userdata=std_parts` requires more than a `userdata` partition.
In `vendor/mainline/services/generic_init/dynamic_mount_handler.cpp`:

- `:123` — `android_userdata_partitions = {"cache", "userdata", "metadata"}`
- `:701` — the readiness loop in `CanQuitUeventd()` has an exception **only** for `cache`
  (`if (part == "cache" && !need_mount_cache) continue;`); any other missing partition
  makes it return false
- `:528` — `need_mount_cache` is only set when the mounted system contains a `/cache`
  directory, which our `system.img` does not, so `cache` is genuinely unnecessary
- matching is by **GPT partition name** (`uevent.partition_name`); the type GUID is irrelevant
- `:779` — `metadata` mounts at `/metadata`; `:780` gives it `no_fail = true`, while `/data`
  gets `no_fail = false`

So the card needs a GPT partition named `metadata` next to `userdata`. Layout in use:
partition 1 ESP, partition 2 `metadata` (32 MB), partition 3 `userdata` (rest).

### Do not format `/data` with the ext4 `quota` / `project` features

This kernel has `CONFIG_QFMT_V2=m` and `CONFIG_QUOTA_TREE=m` — the quota format is a
module. An ext4 filesystem carrying the `quota` feature calls `ext4_enable_quotas()` at
mount time, which needs a registered `QFMT_VFS_V1`. During first-stage boot no quota
module is loaded, so `ext4_fill_super()` fails and mounting `/data` fails. Because `/data`
has `no_fail = false`, init treats it as fatal, reboots to `recovery`, which does not
exist — producing a boot loop.

`generic_init` never asks for quota: the fstab entry it builds carries only `fs_type`
(`ext4` or `f2fs`). Format with `mkfs.ext4 -L userdata -M /data -m 0` and nothing else.

`scripts/make_userdata_and_quiet_boot.sh` creates the correct layout on a fresh card;
`scripts/fix_data_quota.sh` repairs a card that was formatted with quota.

## Known debt

These work, but they are workarounds rather than fixes, and each is tracked for upstream.

- **`pd_ignore_unused clk_ignore_unused` on the kernel command line.** Without them
  `genpd` powers down the MDSS domain and its clocks about 3 s into boot, while `msm`
  loads roughly 48 s later and reads a DPU register with no clock — the watchdog then
  resets the board. This explains the long-standing non-determinism of that failure.
- **Wi-Fi and Bluetooth modules are loaded by an init service** (`q6a_load_wifi_bt`).
  Nothing on this device reads `modules.load`, and the aliases of our out-of-tree modules
  never reached `vendor_dlkm/modules.alias`. The proper fix is to plumb the aliases.
- **`prebuilts/misc/protobuf_vendorcompat/Android.bp` is disabled.** Its modules declare
  `srcs` only under `android_arm` (32-bit) with no arm64, which breaks an arm64-only build.
  The file comes from AOSP, not LineageOS.
- **USB3 SuperSpeed is sacrificed** for DP; see the README.

### Do not load `aic_btusb`

The AIC8800's Bluetooth interfaces are standard USB class 0xE0 and are handled by the
kernel's generic `btusb`; the Bluetooth firmware is part of the payload that `aic_load_fw`
uploads. `aic_btusb` races `btusb` for the interface and, when it wins, exposes
`/dev/aicbt_dev`, which the stock Android HAL cannot use — Bluetooth then hangs in
`BLE_TURNING_ON`. Not loading it is deterministic, removes an out-of-tree module and
avoids needing AICSemi's `libbt-vendor`.

## Upstream

Findings from this port that belong upstream rather than here. Each was checked against
[LineageOS Gerrit](https://review.lineageos.org) on 2026-09-24.

| Finding | Gerrit |
|---|---|
| Mesa `vulkan.lvp` needs the `_mesa3d` suffix on `lineage-24.0` | [#503205](https://review.lineageos.org/c/503205) — merged |
| `libzstd` invisible to `generic_init` | [#503929](https://review.lineageos.org/c/503929) merged, but only helps builds that *disable* `generic_init`; with `generic_init.enabled=true` the visibility problem returns |
| `lineage-sdk` does not compile under Android 17 (`Settings` constants moved to `ConnectivitySettingsManager`) | no report |
| `LineageSettingsProvider` missing from `lineage_sdk_common.mk` | no report |
| `metadata` treated as mandatory to exist but optional to mount | no report |
| `protobuf_vendorcompat` has no arm64 `srcs` (AOSP) | no report |

⚠️ **Sync `vendor/mainline` and `device/mainline/generic` together.** Gerrit #503929 makes
`libgeneric_init` conditional on the `generic_init.enabled` Soong config variable, and
[#503931](https://review.lineageos.org/c/503931) is what sets it in `device/mainline/generic`.
Syncing only the first disables `generic_init` — which is this port's `rdinit`, so the
image stops booting.
