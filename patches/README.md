# Patches

Each patch applies to a different repository of the LineageOS 24 source tree. Apply them
from the root of the repository named below.

| Patch | Repository | Purpose |
|---|---|---|
| `0001-kernel-dts-q6a-display-dp.patch` | `kernel/mainline/android-mainline` | Enables the display: MDSS, DP, QMP PHY and USB nodes, the RA620 bridge and the HDMI connector, plus the lane-orientation fix described in the README. |
| `0002-lineage-sdk-a17-settings-constants.patch` | `lineage-sdk` | `lineage-sdk` does not compile under Android 17: several `Settings` constants moved to `ConnectivitySettingsManager`. |
| `0003-zstd-visibility-generic-init.patch` | `external/zstd` | `generic_init` has `libzstd` in `static_libs` but nothing grants it visibility. A package outside `vendor/` may only name `//vendor:__subpackages__`, not a specific subpackage — see `build/soong/android/visibility.go:363` and `build/soong/README.md:349`. |
| `0004-device-mainline-generic-q6a.patch` | `device/mainline/generic` | Board wiring: Mesa driver whitelist, Wi-Fi/BT kernel modules and firmware, the `usb.gadget` APEX guard, and the init service that loads the Wi-Fi/BT modules. |
| `0005-prebuilts-misc-disable-protobuf-vendorcompat.patch` | `prebuilts/misc` | `libprotobuf-cpp-{full,lite}-21.12-vendorcompat` declare `srcs` only under `android_arm` (32-bit) and none for arm64, which breaks an arm64-only build. From AOSP, not LineageOS. |
| `0006-soong-gomemlimit.patch` | `build/soong` | Lets `SOONG_BUILD_GOMEMLIMIT` reach `soong_build`, which is started with `env -i`. Only needed on memory-constrained hosts. |
| `0007-generic_init-canonical-mount-point.patch` | `vendor/mainline` | fs_mgr refuses a mount point that is not canonical, and on a system-as-root image `/product` and `/system_ext` are symlinks into `/system` — so the `product` and `system_ext` images that `generic_init` claims to support can never mount. Resolving the path at mount time fixes it. No Gerrit report. |

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
