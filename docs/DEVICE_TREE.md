# Regular device tree (device/radxa/dragon_q6a)

The shipped builds use `device/mainline/generic` with `generic_init`, which loads the system
images from files on the EFI system partition. LineageOS will not take such a tree as an
official device: it has no recovery and no OTA by design. This tree replaces it with a regular
one. Asked on the LineageOS Discord (October 2026), the answers were that the boot path is ours
to choose (GBL, U-Boot and GRUB are all in use) and that a board whose stock OS is Linux can be
official; Banana Pi M5 is one.

## Common trees

The tree inherits `device/mainline/qcom-common`, like LineageOS' official mainline Qualcomm
phones (for example `device/xiaomi/mi7150-mainline`), with `TARGET_QCOM_SOC := qcs6490`.
qcom-common had no family for this SoC, so two changes to it are carried as patches:

- `patches/0024-qcom-common-persist-overlay-optional.patch`: qcom-common mounts a tmpfs overlay
  over `/mnt/vendor/persist`, which would throw away every write grub_boot_control makes to the
  slot state. The overlay becomes an option, off by default when `TARGET_BOOT_HAL` is `grub`.
- `patches/0025-qcom-common-soc-sc7280.patch`: the `sc7280` family (QCM6490, QCS6490, SC7280,
  SM7325), with only what all of them share: CPU architecture, cpusets, sysfs labels for the
  GPU, display, remoteprocs and USB, minigbm flags and the iris codecs. It is based on the
  abandoned Gerrit change 445799, without that change's phone-specific parts (UFS boot device,
  WCN6750, DSI backlight).

qcom-common brings `hardware/mainline/qcom` (rmtfs, pd-mapper, tqftpserv, pil-squasher) and
`hardware/sony/timekeep`; `.repo/local_manifests/q6a_qcom.xml` adds the three projects.

## Boot chain

    SPI NOR firmware (Qualcomm XBL + UEFI, Radxa)  ->  GRUB on the EFI system partition
        ->  boot_<slot> + vendor_boot_<slot> from the same disk  ->  Android

GRUB and its A/B handling come from LineageOS' virtual machine trees
(`device/virt/virt-common`, `lineage-24.0`): `android_bootimg_fs` reads Android boot images,
the slot state lives in `grubenv_abootctrl` on the persist partition, and
`hardware/mainline/common`'s `grub_boot_control` serves it to Android as the boot HAL.
Recovery is the ramdisk in `vendor_boot`; `misc` tells GRUB to start it.

What differs from a virtual machine:

- **Device tree.** A VM gets its description from the firmware. This board's firmware carries a
  device tree for Radxa's downstream kernel, so GRUB loads the mainline DTB with `devicetree`.
  `android_bootimg_fs` does not expose vendor_boot's DTB section, so for now the DTB is a file on
  the EFI system partition and is not updated together with the kernel. Exposing `dtb` in
  `android_bootimg_fs` would fix that.
- **Firmware partition.** The DSP, GPU and video firmware is board specific (Radxa's packages
  and linux-firmware) and is mounted from a `firmware` partition at `/vendor/firmware_mnt`.
- **The EFI system partition is not slotted**: the firmware always starts GRUB from it.

## Partitions

Numbers 1-10 match the virt devices, whose GRUB configuration addresses partitions by number.
See `configs/scripts/create_partition_table.sh`.

| # | Name | Size | Contents |
|---|---|---|---|
| 1 | EFI | 256 MiB | GRUB, its configuration and theme, the DTB |
| 2 | super | 12 GiB | system, system_ext, product, vendor, odm, system_dlkm, vendor_dlkm (virtual A/B) |
| 3 | misc | 1 MiB | bootloader messages |
| 4 | persist | 16 MiB | FAT labelled PERSIST (GRUB writes it): `grubenv`, `grubenv_abootctrl` |
| 5 | metadata | 32 MiB | metadata encryption keys, OTA snapshots |
| 6 | firmware | 128 MiB | Qualcomm firmware |
| 7, 8 | vendor_boot_a/b | 100 MiB | vendor ramdisk, recovery ramdisk, kernel modules |
| 9, 10 | boot_a/b | 96 MiB | kernel, generic ramdisk |
| 12 | userdata | rest of the disk | |

## Kernel

android-mainline with the board's patches, as before. The official mainline phones start from
the arm64 `defconfig`, but their kernels are not Android common kernels. Ours is, and on top of
`defconfig` it loses what the running system relies on: the Rust binder that `binder.impl=rust`
selects, vendor hooks, dm-default-key and the GKI options. So the chain is:

1. `gki_defconfig`
2. `kernel/mainline/configs/fragments/common.config` and `y/fbcon.config` (dma-buf heaps, zram,
   USB gadget functions, framebuffer console)
3. `kernel/dragon_q6a.config`: the Qualcomm drivers the board's device tree needs, found by
   matching the compatible of every enabled node to its driver, with the values of the
   configuration the board ships with (first stage init's drivers built in, the rest modules),
   plus the menus GKI turns off, and the devices on PCIe and USB (Ethernet, Bluetooth, the
   USB hub, USB modems)
4. `kernel/qcs6490.config`, shared with the generic_init build (48-bit VA, no BTI or shadow
   call stack, NLS built in, iris instead of venus)
5. `kernel/dragon_q6a-boot.config`: NVMe, its PCIe PHY, SD card and vfat built in

It replaces the 332 KB configuration the generic_init build produces from Debian's.

Modules are loaded by `init.dragon_q6a.rc` in `post-fs`, after the firmware partition is
mounted, and the remote processors are started after that, as on the phones.
## Status

The skeleton on top of qcom-common: product, BoardConfig, fstab, init files, SELinux types for
persist, the Q6A services that carry over (Wi-Fi/Bluetooth loading, tuning, the USB modem),
properties, GRUB additions, the partition script and the kernel configuration chain.
`lunch lineage_dragon_q6a cp2a userdebug` and an analysis build work, and the current product,
`lineage_Generic_arm64`, still builds unchanged.

## Still to do

1. Done: `build/tasks/images.mk` builds `EFI.img` (GRUB from device/virt/virtio_arm64 as
   mi7150 does, its modules, `bootmgr/grub/grub-boot.cfg`, the DTB), `persist.img` (FAT
   PERSIST, grubenv and grubenv_abootctrl) and `firmware.img` (from
   `vendor/radxa/dragon_q6a/firmware`, filled by `scripts/fetch_firmware.sh`). Still missing:
   a disk or installer image, and the open question for LineageOS whether hardware devices
   should share the virt trees' image tasks rather than copy them.
2. Firmware: done for the files the board uses (a symlink /vendor/firmware/qcom ->
   /vendor/firmware_mnt/qcom). The GPU (a660) and video (vpu-2.0) firmware is generic and could
   come from `external/linux-firmware-mainline`, which does not carry it yet.
3. fastbootd: a fastboot HAL for recovery (the virt trees have
   `android.hardware.fastboot-service.virt_recovery`).
4. Kernel modules: the vendor_dlkm module list and load order, which `generic_init` and
   `q6a_load_wifi_bt` handle today.
5. SELinux: the Q6A services still run as `su`, which only exists in userdebug builds.
6. Hardware HALs carried by `device/mainline/generic` today: health, sensors, Wi-Fi overlays,
   input configuration, USB gadget (device mode works on the USB 3.1 port, see UPSTREAM.md).
7. Verified boot: vbmeta and AVB, once the boot chain works.
8. Build, flash to an SD card, boot, then move the NVMe installation over (it wipes the disk).
