# Patches

Each patch applies to a different repository of the LineageOS 24 source tree. Apply them
from the root of the repository named below.

| Patch | Repository | Purpose |
|---|---|---|
| `0001-kernel-dts-q6a-display-dp.patch` | `kernel/mainline/android-mainline` | Enables the display: MDSS, DP, QMP PHY and USB nodes, the RA620 bridge and the HDMI connector, plus the lane-orientation fix described in the README. |
| `0002-lineage-sdk-a17-settings-constants.patch` | `lineage-sdk` | `lineage-sdk` does not compile under Android 17: several `Settings` constants moved to `ConnectivitySettingsManager`. |
| `0003-zstd-visibility-generic-init.patch` | `external/zstd` | `generic_init` has `libzstd` in `static_libs` but nothing grants it visibility. A package outside `vendor/` may only name `//vendor:__subpackages__`, not a specific subpackage — see `build/soong/android/visibility.go:363` and `build/soong/README.md:349`. |
| `0004-device-mainline-generic-q6a.patch` | `device/mainline/generic` | Board wiring: Mesa driver whitelist, Wi-Fi/BT kernel modules and firmware, the `usb.gadget` APEX guard, and the init service that loads the Wi-Fi/BT modules. Also: the V4L2 Codec2 HAL for hardware video codecs, the multifile EGL blob cache, the GL renderer override that Genshin Impact needs (Mesa names this GPU `FD643`, which the game does not recognise, and its 3D scenes render corrupted), and `q6a_debug_net` only when the build sets `Q6A_DEBUG_NET=true`. |
| `0005-prebuilts-misc-disable-protobuf-vendorcompat.patch` | `prebuilts/misc` | `libprotobuf-cpp-{full,lite}-21.12-vendorcompat` declare `srcs` only under `android_arm` (32-bit) and none for arm64, which breaks an arm64-only build. From AOSP, not LineageOS. |
| `0006-soong-gomemlimit.patch` | `build/soong` | Lets `SOONG_BUILD_GOMEMLIMIT` reach `soong_build`, which is started with `env -i`. Only needed on memory-constrained hosts. |
| `0007-generic_init-canonical-mount-point.patch` | `vendor/mainline` | fs_mgr refuses a mount point that is not canonical, and on a system-as-root image `/product` and `/system_ext` are symlinks into `/system` — so the `product` and `system_ext` images that `generic_init` claims to support can never mount. Resolving the path at mount time fixes it. No Gerrit report. |
| `0008-frameworks-native-egl-multifile-get-value-size.patch` | `frameworks/native` | `MultifileBlobCache::get()` compares the stored value size with the caller's buffer size instead of with the size it recorded, so every lookup with a larger buffer is a miss. Mesa always looks up with 64 KiB, so in multifile mode its shader cache was written and never read. For AOSP; not reported yet. |
| `0009-frameworks-native-egl-multifile-dir-suffix.patch` | `frameworks/native` | Local workaround, not for upstream: names the multifile cache directory `.blobs` instead of `.multifile`, because Genshin Impact deletes `<cache>.multifile` on every start. Applies on top of 0008. |
| `0010-mesa-freedreno-a6xx-texture-state-index.patch` | `external/mesa` | Deleting a sampler view or sampler state walked the whole texture-state cache under the screen lock. A reverse index from seqno to cache entries makes it proportional to the entries affected; in Genshin Impact that walk was about 16% of the process's CPU time. For Mesa; not submitted yet. |

The untracked files that belong with patch 0004 are shipped as real files under
`device/mainline/generic/` in this repository, not as a patch.

## Not included

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
- `mesa-freedreno-glthread-default.patch` turns on glthread by default in freedreno. Its effect was never measured.
