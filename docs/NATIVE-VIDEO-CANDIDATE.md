# Native Codec2 video and HEVC source candidate (draft)

This review candidate extends the Dragon Q6A release project's retained Codec2
patches with the native video/HEVC source work developed on that port. The
release-project base is `8af4f9a0fea2a031233d2240e8492e10ee900e1e`; its pinned
`external/v4l2_codec2` input is
`6685af1c65467d0b550d7b904418f65059bc3cbb`.

The new patch is kept in `patches/experimental/` for review. It is not added to
`patches/series` and therefore does not change default builds or installed images.

## Patch base and scope

`patches/experimental/v4l2_codec2-native-video-hevc-candidate.patch` applies to
`external/v4l2_codec2` after the release's six existing Codec2 patches:

- 0011 encoder input plane length
- 0013 decoder zero input size
- 0014 encoder key-frame fallback
- 0017 decoder input DMA-BUF synchronization
- 0018 decoder output delay headroom
- 0021 encoder GOP size

It is incremental to those patches and does not duplicate them. If the release
project has advanced, compare its Codec2 base and patch series before rebasing.

The candidate adds native HEVC Main encoding, VPS/SPS/PPS handling, color input
conversion and metadata/registration support, plus the scoped Iris tier-control
compatibility path and host source checks. The final retained Fedora source
snapshot contained 134 source files; its archive SHA-256 is
`adbb8ea696f8122ee529a0c35209856e0b7dad7107e445275331bb73fe0c87fc`.

## Source and runtime evidence

The final source export's file hashes were verified. The source patch was checked
against a reconstruction of the pinned source subset. Host checks passed for
the missing-tier gate, geometry-specific frame-rate scope and HEVC header
boundaries/lifecycle under ASan/UBSan. These checks do not replace an Android
build or establish build-to-installed-binary provenance.

The development transcript reports the coherent four-library build, extended
HEVC raw/Surface/control validation, AVC regressions, decoder/HDR metadata checks
and promotion to a normal persistent HEVC boot. The complete matching final
build/install receipts are not included here, so those transcript results must
remain distinct from independently authenticated source provenance. The final
manual HEVC cold-boot verification receipt was not received.

Separate retained reports qualify a 7,200-frame VP9 byte-buffer pipeline, a
10,800-frame offscreen Surface/GPU pipeline, 540 functional resolution-change
frames and 120 flush/timestamp-reset frames. Ordinary application playback has
also worked, but intermittent loading/transition failures remain.

## Required integration review

The missing-tier path requires both
`ro.vendor.v4l2_codec2.encoder.supported.hevc` and
`ro.vendor.v4l2_codec2.hevc.iris_main_tier`, plus the exact reviewed Iris identity
and loaded-module build ID. It fails closed for other drivers. Vendor XML,
properties and final build receipts require their own integration review; a
Codec2 library patch alone is not a complete release image.

Rebuilding Iris changes its module build ID. Applying a kernel fix therefore
requires requalifying the driver and deliberately updating the compatibility
pin rather than bypassing the identity gate.

## Known failures

- A current-boot capture records an Iris timestamp fallback reading index 64
  outside a 64-entry metadata array, followed by a codec-HAL SIGSYS restart.
  The same boundary bug has an upstream fix proposal:
  https://lists.openwall.net/linux-kernel/2026/10/17/217 . That remedy is upstream
  work, has not been installed/validated on this Q6A, and is not included as a
  claimed local fix. It is not proven to cause every other failure.
- Another capture records 44 LMKD process kills in roughly 2.7 seconds,
  including foreground YouTube and the package installer. The allocation source
  remains unknown. A later 180-second watch held 9.14–9.84 GiB available RAM and
  reproduced no low-memory kill, but did record STREAMON/Surface failures while
  loading. Its global DMA inventory interfaces were unavailable.
- A temporary VP9 4K60 performance-point correction disappeared on reboot;
  permanent capability advertisement remains separate work.
- Framework thermal HAL integration and SystemUI HEVC profile/tier negotiation
  remain incomplete. Kernel thermal sensors/cooling operate; actual HDR display
  output is unqualified.

No raw device logs, user data, account material, proprietary firmware, APKs or
device images are part of this draft. No new board test is required merely to
preserve and review this source work.
