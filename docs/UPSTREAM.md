# Upstream checklist

Last updated: 2026-10-06.

Two different bars apply, and most of this list only matters for the second one:

- **Contributions to existing repositories** (AOSP, Mesa, Linux, LineageOS Gerrit) can go at any
  time. They follow each project's review rules, plus the LineageOS AI policy for Gerrit
  (see [Submission format](#submission-format)).
- **Official LineageOS support for the Dragon Q6A** has to meet the
  [Device Support Requirements](https://github.com/LineageOS/charter/blob/main/device-support-requirements.md)
  (LDSR). Every gap below refers to a section of that document.

The closest precedent is the `nx*` exemption (2026-04-16): a device without an Android-based
stock OS. Like the Q6A, whose stock OS is RadxaOS (Debian), it cannot meet requirements written
around "what the stock OS supported".

## 1. LDSR requirements not met

| LDSR section | Current state | Work needed |
|---|---|---|
| SELinux status | Permissive, set on the kernel command line | Policy for the whole port; dedicated domains for the `q6a_*` init services |
| Encryption | `ro.crypto.state=unsupported` | File-based encryption: metadata encryption, fstab flags, KeyMint |
| LineageOS Recovery, Updater | `device/mainline/generic` has no recovery support at all | Recovery boot entry and ramdisk; an OTA path for a layout where system and vendor are image files on the ESP. Devices without a traditional recovery may document another way to install LineageOS zips |
| Addon packages | GApps go through our own `q6a_install_gapps` service | Depends on recovery: MindTheGapps has to install from Lineage Recovery |
| USB (MTP) | No USB device mode: `/sys/class/udc` is empty, both DWC3 controllers are `dr_mode = "host"` | Radxa's own device tree sets the same, so the stock OS has no device mode either: document it as a hardware deviation. Without device mode, `adb sideload` over USB is impossible, so recovery has to take zips from storage or the network |
| Device tree structure | Builds as `lineage_Generic_arm64` | Own codename and device tree with `lineage_<codename>.mk` |
| Device tree structure | `lineage.dependencies` would need `radxa-pkg/aic8800` | Wi-Fi/Bluetooth driver source must live in a repository LineageOS can host |
| Proprietary files extraction | ADSP firmware, GPU zap shader, audio topology and AIC8800 firmware are copied by hand | Upstream linux-firmware already carries Radxa's Q6A files (`qcom/qcs6490/radxa/dragon-q6a/`: ADSP, CDSP, topology), the GPU zap shader (`qcom/qcm6490/a660_zap.mbn`), the video firmware and the QUP firmware, all redistributable. Take them from there by updating `external/linux-firmware-mainline`; only the AIC8800 firmware still needs a source with documented rights |
| Kernel (clocks) | The tree carries an experimental GPU OPP table with 840/900 MHz points | Must match the SoC vendor's binning. Kept aside as an experimental patch, not shipped |

## 2. Debug and tuning features in the default image

- `q6a_debug_net` enables adb over TCP with fixed addresses. It is the only adb channel this
  board has (no USB device mode), so it is now included only when the build sets
  `Q6A_DEBUG_NET=true`. `scripts/build_q6a_a17.sh` does that by default for development; build
  releases with `Q6A_DEBUG_NET=false`. Releases up to `lineage24-v2` still include it.
- `q6a_tuning` pins CPU and GPU clocks at their maximum at every boot. Kept on purpose for now
  (maintainer's decision). Before an official submission it has to become opt-in.

## 3. To verify

| Item | Requirement | Known state |
|---|---|---|
| Audio, 3.5 mm jack | MUST (stock supports it) | Worked on 2026-09-26; recheck |
| Audio over HDMI | MUST if stock supports it | Declared in the DT, never verified |
| Bluetooth audio (A2DP) | MUST | Untested |
| Wi-Fi hotspot | MUST (the driver offers AP and P2P-GO) | An access point starts and broadcasts from the framework (`cmd wifi start-softap`); a client getting internet through it is untested |
| Wi-Fi and Bluetooth MAC addresses | MUST match stock | Read from the chip (`addr_assign_type=0`), so almost certainly identical to RadxaOS; not compared directly |
| microSD slot | MUST | Both SDHCI hosts probe; no card was inserted. `/data` lived on a microSD card during bring-up, so the slot works; recheck with a card |
| Hardware video codecs | MUST if the stock OS supports them | Work: H.264, HEVC and VP9 decoding and H.264 encoding through iris and the V4L2 Codec2 HAL. Upstream work left: the HAL should report `C2PortActualDelayTuning` from the driver's minimum buffer count instead of the fixed output delay of 20 (0018), and frames iris returns with `V4L2_BUF_FLAG_ERROR` and timestamp 0 leave their work items uncompleted |
| Camera | MUST if the stock OS supports it | CCI is disabled in the DT and no sensor is attached. Needs agreement with the Directors, given the non-Android stock OS |
| MIPI-DSI | SHOULD | Not started |
| USB/Bluetooth tethering, GSI boot | SHOULD | Untested |

## 4. Workarounds that will block review

- `pd_ignore_unused clk_ignore_unused` on the command line hides a probe-order problem between
  `genpd` and MDSS.
- The DP lane fix in the DT forces the QMP PHY into DP-only mode, which costs USB3 SuperSpeed.
  The port needs a second endpoint for USB3.
- The Wi-Fi/Bluetooth modules are loaded by an init service instead of `modules.load` and
  `modules.alias`.
- Local patches: the `.blobs` directory suffix in `MultifileBlobCache` (Genshin Impact deletes
  the stock `.multifile` directory on every start) and `mesa.force.gl.renderer`.
- glthread is on by default in our Mesa tree (`patches/experimental/`). Either measure it
  against a build without it and submit it with the numbers, or drop it.
- EGL cache limits (4 GiB, 262,144 entries) and `vm.max_map_count=1048576` in
  `device/mainline/generic` are sized for one game. Measured 2026-10-11 on Genshin Impact: the
  shader warm-up writes about 70,000 entries and 550 MiB, and the process passes 89,000
  mappings in play. The byte limit is parsed as `uint32_t`, so 4294967295 is the largest
  value AOSP accepts; a reviewer may ask for smaller defaults.

## 5. Ready to submit

| Target | Change |
|---|---|
| AOSP `frameworks/native` | `MultifileBlobCache::get()`: compare the stored header with the stored value size, not with the caller's buffer size; every oversized lookup (Mesa always passes 64 KiB) was a miss |
| Mesa (freedreno a6xx) | Reverse index from seqno to texture states, so deleting a sampler view no longer walks the whole texture cache; about 16% of a game's CPU time |
| Mesa (driconf) | Per-application GL renderer override for Genshin Impact instead of the vendor property |
| LineageOS Gerrit | Missing `LineageSettingsProvider` dependency; `generic_init` canonical mount point (0007); `generic_init` vfat `umask`, without which `vendor.prop` in the android dir is never loaded (0019); the `device/mainline/generic` patches in `patches/`. Dropped after checking upstream: 0002 (`lineage-sdk` builds unpatched on the current tree, verified 2026-10-11) and 0003 (`libzstd` visibility; upstream guards the dependency in `generic_init` instead, change 505913) |
| AOSP `external/v4l2_codec2` | Decoder input dmabuf cache sync (0017); encoder plane length (0011), decoder 0x0 input size (0013), key frame fallback (0014) |
| Linux (iris) | The gen2 encoder never subscribes to the picture type, so no encoded buffer carries `V4L2_BUF_FLAG_KEYFRAME` (0020). To report: `rmmod qcom_iris` deadlocks, as `iris_core_deinit()` holds `core->lock` across `disable_irq()` while the threaded handler waits for that lock |
| Linux | Dragon Q6A device tree; `orientation-switch` on a QMP PHY with no USB-C connector; the `genpd` ordering; the SMMU SError on a failed DP link |

### Submission format

- Gerrit changes need `Assisted-by: LLM`.
- Comments explain non-obvious logic only. Several comments written during bring-up are long
  and narrative, and must be cut down before submission.
- Commit messages stay short.
- Original files carry "(C) 2026 The LineageOS Project", added to existing copyright headers,
  never replacing them. Kernel changes are GPLv2, Android changes Apache 2.0.

## 6. Project and community

- Wiki page: installation instructions, hardware deviations, software deviations.
- A GitLab account for the maintainer, and regular triage of bug reports.
- An exemption request as a change to the `charter` repository, approved by at least three
  Project Directors.

## Order of work

1. Clean the image of debug features and experimental clocks (sections 1 and 2).
2. Send the changes from section 5.
3. SELinux Enforcing.
4. Encryption.
5. Recovery, OTA and GApps, after a design decision on the boot layout and USB device mode.
6. Device tree, extraction script, hardware verification, Wiki and the exemption request.
