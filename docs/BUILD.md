# Building

## Host requirements

Built and tested on WSL2 (Ubuntu) with 16 cores and 26 GB of RAM allocated to WSL out of
32 GB physical. Roughly 400 GB of disk is needed for the source tree plus build output.

## Getting the source

```bash
repo init -u https://github.com/LineageOS/android.git -b lineage-24.0 --git-lfs
```

Copy the manifests from `local_manifests/` in this repository into
`.repo/local_manifests/`, then:

```bash
repo sync -c -j8
```

Why these manifests are needed:

- **`q6a_device.xml`** adds `device/mainline/generic`. LineageOS' `roomservice.py` in
  `depsonly` mode looks for the device tree by repository name and will not find it; the
  third-parameter workaround from `docs/build.md` does not exist, because Gerrit change
  492595 was abandoned on 2026-08-15.
- **`q6a_unbranched.xml`** declares `external/mesa`. That project is in neither
  `default.xml` nor `roomservice.xml`; only `lineage.dependencies` in
  `device/mainline/common` pulls it in, and without the entry Mesa disappears from the tree.
  It carries no `revision`, so it follows the manifest default (`lineage-24.0`).
- **`roomservice.xml`** lists dependencies that `roomservice` never fetched, notably
  `external/alsa-lib` and `external/alsa-ucm-conf`. These only surface with the full
  `lineage_Generic_arm64` product, which enables the mainline audio HAL:
  `android.hardware.audio.service-aidl.mainline` depends on `libasound`.

⚠️ **Sync `vendor/mainline` and `device/mainline/generic` together.** See the upstream
note at the end of [STATUS.md](STATUS.md).

## Applying the patches

```bash
cd <tree>
for p in <this repo>/patches/*.patch; do
    # each patch header names the repository it applies to
    ...
done
```

See [../patches/README.md](../patches/README.md) — it lists the target repository and the
reason for every patch.

Then copy the device tree and the generic-tree additions:

```bash
cp -r <this repo>/device/radxa/dragon_q6a       <tree>/device/radxa/
cp -r <this repo>/device/mainline/generic/*     <tree>/device/mainline/generic/
```

## Building

Use `scripts/build_q6a_a17.sh`. Do not call `lunch` and `m` by hand — two environment
settings are easy to miss and both fail in ways that are hard to diagnose.

```bash
cp <this repo>/scripts/build_q6a_a17.sh <tree>/
cd <tree> && ./build_q6a_a17.sh
```

### `MAINLINE_GENERIC_KERNEL_BOARDCONFIG_MK`

Our `board.mk` lives in `device/radxa/dragon_q6a/kernel/`, which is not the default
location (`device/mainline/generic/Generic_arm64/kernels/<name>/board.mk`).
`device/mainline/generic/BoardConfig.mk` picks it up **only** through this variable.
Without it the build takes the `else` branch with a bare `gki_defconfig` and the whole
`qcs6490.config` fragment is silently skipped. The result is a kernel with
`ARM64_VA_BITS=39` instead of 48, `ARM64_BTI_KERNEL=y`, `SHADOW_CALL_STACK=y` and
`NLS_CODEPAGE_437=m` instead of `y` — and such a kernel dies right after
`ExitBootServices`.

### `LINEAGE_BUILD`

`BoardConfigLineage.mk` is only included when `LINEAGE_BUILD` is set.

### Memory

`soong_build` is started with `env -i`, so Go runtime settings cannot be inherited from
the caller. Patch `0006-soong-gomemlimit.patch` adds a `SOONG_BUILD_GOMEMLIMIT`
passthrough; the build script sets it to `20GiB`. Without it the analysis phase grew to
about 25 GB resident and was OOM-killed.

`-j8` is a deliberate compromise. `-j12` caused OOM kills in `kotlinc` and `r8`; the Soong
analysis phase is a single process bounded by `GOMEMLIMIT`, not by `-j`, and only the
`ninja` phase actually runs compilers in parallel.

### Do not

- call `make` on the kernel by hand — `oldconfig` prompts interactively for new symbols
  and truncates `.config` at EOF
- read `.config` while the build is running — our fragment is applied last in the chain

`scripts/build_progress.sh` prints a live percentage; it only starts counting after
`Starting ninja` appears in the log.

## Mesa driver selection

Use assignment, not subtraction:

```makefile
BOARD_MESA3D_GALLIUM_DRIVERS := freedreno
BOARD_MESA3D_VULKAN_DRIVERS  := freedreno
```

Upstream filters out only `nouveau`. Removing drivers one at a time with `filter-out`
costs one full build per driver — we paid for `asahi`, `imagination`, `radeonsi`, `amd`
and `etnaviv` that way.

## Writing a card or an SSD

`scripts/flash_a17.sh` writes a release image to any medium — SD, USB or NVMe — and sizes
the partitions to whatever that medium actually is:

```bash
sudo scripts/flash_a17.sh                 # plan only, nothing is written
sudo scripts/flash_a17.sh --apply         # write
sudo scripts/flash_a17.sh /dev/sdX --apply
```

`dd` alone is not enough. The image is 3 GB, so its backup GPT sits at the end of the
*image*; on a larger medium the rest of the disk stays invisible to partitioning until the
backup table is moved to the real end (`sgdisk -e`). The script does that, then creates
`metadata` and `userdata` across the remaining space.

The medium is found by what it *is* — a disk whose GPT has a partition named `ESP` — not by
size, removability or bus. There is no minimum or maximum size. If more than one medium
matches, the script lists them and asks you to name one rather than guessing.

Other tooling:

```bash
sudo scripts/mk_a17_release.sh                    # build a release image
sudo scripts/update_a17_sd.sh                     # refresh an existing card
sudo scripts/set_default_entry.sh a17 /dev/sdX 0  # pick the boot entry
```

The board has a touchscreen and no keyboard, so the boot menu cannot be used
interactively — the entry must be selected by making it the default.

Card detection in these scripts is by `RM=1` and `TRAN=usb`, never by the `/dev/sdX`
letter: the letter depends on plug order and has changed between sessions.

## Script conventions

The scripts assume the source tree at `~/q6a/lineage`. Override it with:

```bash
export LINEAGE_TREE=/path/to/your/tree
```

`device/mainline/generic/configs/scripts/q6a_debug_net.sh` contains static IP addresses
from the development setup (`192.168.137.50` over Ethernet, `192.168.1.100` on the LAN).
Adjust them for your network, or drop the file — it exists only to bring up networking
and adb early for debugging.
