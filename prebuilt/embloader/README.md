# embloader

`BOOTAA64.EFI` is the UEFI boot loader on the ESP of every LineageOS image for this board.

- Source: [BigfootACA/embloader](https://github.com/BigfootACA/embloader), commit
  `9f8e74bd0c44384ad0f02f49e209a9835034c670` ("bump version to 0.4"), GPL-2.0.
- Local change: [`patches/embloader/0001-boot-recovery-from-bcb.patch`](../../patches/embloader/0001-boot-recovery-from-bcb.patch).
  It reads the Android bootloader message from a GPT partition named `misc` and, when it says
  `boot-recovery`, boots the `twrp` entry once. Media without a `misc` partition are not
  affected.
- sha256: `9b5a86d2f7bfefccc87d76f86dd55f982b7dddd15c02b7711647825254041231`

## Rebuilding

Ubuntu 22.04 or later, with `gcc-aarch64-linux-gnu`, `nasm`, `uuid-dev` and `acpica-tools`:

```bash
git clone --recursive https://github.com/BigfootACA/embloader
cd embloader
git checkout 9f8e74bd0c44384ad0f02f49e209a9835034c670
git submodule update --init --recursive
git apply <this repo>/patches/embloader/0001-boot-recovery-from-bcb.patch
export GCC5_AARCH64_PREFIX=aarch64-linux-gnu-
./build.sh
# result: build/Build/embloader/RELEASE_GCC5/AARCH64/embloader.efi
```

The AOSP prebuilt GCC 7.4 is too old for edk2; use the distribution cross compiler.
