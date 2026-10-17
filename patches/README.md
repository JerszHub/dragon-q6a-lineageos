# Patches

Each patch applies to a different repository of the LineageOS 24 source tree. Apply them
from the root of the repository named below. `series` lists the same in machine-readable
form, in order; `scripts/setup_tree.sh` applies it.

| Patch | Repository | Purpose |
|---|---|---|
| `0001-kernel-dts-q6a-display-dp.patch` | `kernel/mainline/android-mainline` (at `1e8ffda06e4c`, see [BUILD.md](../docs/BUILD.md)) | Enables the display: MDSS, DP, QMP PHY and USB nodes, the RA620 bridge and the HDMI connector, plus the lane-orientation fix described in the README. |
| `0003-zstd-visibility-generic-init.patch` | `external/zstd` | `generic_init` has `libzstd` in `static_libs` but nothing grants it visibility. A package outside `vendor/` may only name `//vendor:__subpackages__`, not a specific subpackage — see `build/soong/android/visibility.go:363` and `build/soong/README.md:349`. **To be dropped** once `vendor/mainline` is synced: upstream guards the `libzstd` dependency in `generic_init` instead (Gerrit 505913), and the visibility approach was abandoned (496520). |
| `0004-device-mainline-generic-q6a.patch` | `device/mainline/generic` | Board wiring: Mesa driver whitelist, Wi-Fi/BT kernel modules and firmware, the `usb.gadget` APEX guard, and the init service that loads the Wi-Fi/BT modules. Also: the V4L2 Codec2 HAL for hardware video codecs, the multifile EGL blob cache with limits sized for games (4 GiB and 262,144 entries; one game's shader warm-up alone writes about 70,000 entries and 550 MiB), `vm.max_map_count` raised to 1048576 (Genshin Impact passes the default 65530 mappings and crashes), the GL renderer override that Genshin Impact needs (Mesa names this GPU `FD643`, which the game does not recognise, and its 3D scenes render corrupted), and `q6a_debug_net` only when the build sets `Q6A_DEBUG_NET=true`. |
| `0005-prebuilts-misc-disable-protobuf-vendorcompat.patch` | `prebuilts/misc` | `libprotobuf-cpp-{full,lite}-21.12-vendorcompat` declare `srcs` only under `android_arm` (32-bit) and none for arm64, which breaks an arm64-only build. From AOSP, not LineageOS. |
| `0006-soong-gomemlimit.patch` | `build/soong` | Lets `SOONG_BUILD_GOMEMLIMIT` reach `soong_build`, which is started with `env -i`. Only needed on memory-constrained hosts. |
| `0007-generic_init-canonical-mount-point.patch` | `vendor/mainline` | fs_mgr refuses a mount point that is not canonical, and on a system-as-root image `/product` and `/system_ext` are symlinks into `/system` — so the `product` and `system_ext` images that `generic_init` claims to support can never mount. Resolving the path at mount time fixes it. No Gerrit report. |
| `0008-frameworks-native-egl-multifile-get-value-size.patch` | `frameworks/native` | `MultifileBlobCache::get()` compares the stored value size with the caller's buffer size instead of with the size it recorded, so every lookup with a larger buffer is a miss. Mesa always looks up with 64 KiB, so in multifile mode its shader cache was written and never read. For AOSP; not reported yet. |
| `0009-frameworks-native-egl-multifile-dir-suffix.patch` | `frameworks/native` | Local workaround, not for upstream: names the multifile cache directory `.blobs` instead of `.multifile`, because Genshin Impact deletes `<cache>.multifile` on every start. Applies on top of 0008. |
| `0010-mesa-freedreno-a6xx-texture-state-index.patch` | `external/mesa` | Deleting a sampler view or sampler state walked the whole texture-state cache under the screen lock. A reverse index from seqno to cache entries makes it proportional to the entries affected; in Genshin Impact that walk was about 16% of the process's CPU time. For Mesa; not submitted yet. |
| `0011-v4l2_codec2-encoder-input-plane-length.patch` | `external/v4l2_codec2` | For a single-planar input format the encoder set the V4L2 plane `length` to the frame data size (933,888 bytes at 1024x608) instead of the buffer size the driver asked for (`sizeimage`, 946,176 with Venus NV12 padding), so videobuf2 rejected every input buffer with "invalid dmabuf length". The multi-planar branch already used the driver's size. Same code in AOSP main; not reported yet. |
| `0012-device-mainline-common-v4l2-hevc-decoder.patch` | `device/mainline/common` | The example `media_codecs_c2.xml` lists no `c2.v4l2.hevc.decoder`, although the HAL provides one when `ro.vendor.v4l2_codec2.decoder.supported.hevc` is set, so the framework drops it ("not found in xml"). For LineageOS; not submitted yet. |
| `0013-v4l2_codec2-decoder-input-size-zero.patch` | `external/v4l2_codec2` | The decoder set its input format with a default `ui::Size`, which is -1x-1, not 0x0. The V4L2 stateful decoder interface allows 0x0 (the size is parsed from the stream). Venus clamped -1 to its limits; iris aligns it, the value wraps to 0, and `VIDIOC_REQBUFS` fails with "current session not supported". For AOSP; not reported yet. |
| `0014-v4l2_codec2-encoder-key-frame-fallback.patch` | `external/v4l2_codec2` | The encoder required `V4L2_CID_MPEG_VIDEO_FORCE_KEY_FRAME` and failed on the first frame without it, and it set MB rate control and GOP size in one call, so a driver without the former also rejected the latter. Now set one by one, with the GOP size as the key frame period when key frames cannot be requested. iris gained the control in Linux 7.3, so this is robustness, not a requirement for this board. For AOSP; not reported yet. |
| `0015-vendor-lineage-kernel-kconfig-ext-prefix.patch` | `vendor/lineage` | Cherry-pick of the open LineageOS change [489817](https://review.lineageos.org/c/489817), which adds `TARGET_KERNEL_KCONFIG_EXT_PREFIX`. `android-mainline` deleted its empty `Kconfig.ext` placeholder on 2026-07-31 (Kleaf generates one), but the top-level `Kconfig` still sources it, so a make-based kernel build stops with `can't open file "Kconfig.ext"`. `board.mk` points the prefix at an empty file in `device/radxa/dragon_q6a/kernel/kconfig-ext/`. |
| `0016-kernel-dpu-single-mixer-when-dspp-short.patch` | `kernel/mainline/android-mainline` | Since SC7280 gained 3D merge (Linux 7.0), `dpu_crtc_get_topology()` splits every mode wider than `MAX_HDISPLAY_SPLIT` (1080 px) across two mixers. drm_hwcomposer always sets a CTM, so both mixers then need a DSPP, but SC7280 has one DSPP, on LM_0, and its only mixer pair (LM_2+LM_3) has none: the commit fails with -119, the composer gets no display and SurfaceFlinger crashes in a loop. Any 1080p monitor reproduces it; 1024x600 does not. The patch keeps a mode that fits one mixer on one mixer when there are not enough DSPPs for two. Verified on hardware with a 1920x1080 TV (`lm[0]` + `dspp[0]`, no -119). For linux-arm-msm; not submitted yet. |
| `aic8800/0001-q6a-uninitialised-variables-and-linux-7.3-cfg80211.patch` | `radxa-pkg/aic8800` (prepared by `scripts/build_aic8800.sh`) | Three variables used uninitialised (found by clang), and the Linux 7.3 `cfg80211` changes: `.probe_client` renamed to `.probe_peer` and a `link_id` argument for `cfg80211_probe_status()`. The new API is detected through `NL80211_CMD_PROBE_CLIENT`, which became a `#define` in the same series, because `android-mainline` already carries it while still reporting 7.2. For Radxa; not submitted yet. |

| `embloader/0001-boot-recovery-from-bcb.patch` | [BigfootACA/embloader](https://github.com/BigfootACA/embloader) at `9f8e74bd` | Boots the `twrp` entry once when the Android bootloader message in the `misc` partition says `boot-recovery`. Built into `prebuilt/embloader/BOOTAA64.EFI`, the boot loader on every image; see [its README](../prebuilt/embloader/README.md). Not submitted. |

The untracked files that belong with patch 0004 are shipped as real files under
`device/mainline/generic/` in this repository, not as a patch.

## Not included

- **`lineage-sdk` build fix for Android 17** (formerly 0002) — we believed several `Settings`
  constants had moved to `ConnectivitySettingsManager`, but `LineageSettingsProvider` builds
  without the patch on the current tree (verified 2026-10-11).
- **Mesa `_mesa3d` suffix for `vulkan.lvp`** — merged upstream as
  [#503205](https://review.lineageos.org/c/503205); `external/mesa` on `lineage-24.0`
  already carries it.
- **`build/soong/scripts/gen_build_prop.py`** — we carried a fix for a `KeyError` on
  `RecoveryDefaultTouchRotation`, but that only happens when building an `aosp_*` product
  inside a LineageOS tree. With `lineage_Generic_arm64` the key is present and the patch
  is unnecessary.

## `experimental/`

Not applied by any script and not part of any image: changes kept for reference.

- `kernel-dts-gpu-opp-overclock.patch` exposes 840/900 MHz GPU points. The board did not boot with it, games are not GPU-bound, and LDSR requires clocks within the SoC vendor's binning.
- `generic_init-q6a-bootlog.patch` adds a boot log recorder to `generic_init`, enabled by
  `androidboot.q6a_bootlog=1`: it copies `/dev/kmsg` to `q6a-bootlog/boot-0.log` on the ESP for the
  whole boot, synced batch by batch, so a board that resets still leaves a log. Used by
  `scripts/mk_a17_diag.sh` to build diagnostic images; never part of a normal build.
- `mesa-freedreno-glthread-default.patch` turns on glthread by default in freedreno. **Not applied by
  the scripts, but present in the working tree since 2026-09-29**, so every image built since then
  carries it, including all the Genshin Impact measurements. It was never measured against a build
  without it.
