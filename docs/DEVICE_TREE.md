# Regular device tree (device/radxa/dragon_q6a)

The shipped builds use `device/mainline/generic` with `generic_init`, which loads the system
images from files on the EFI system partition. LineageOS will not take such a tree as an
official device: it has no recovery and no OTA by design. This tree replaces it with a regular
one. Asked on the LineageOS Discord (October 2026), the answers were that the boot path is ours
to choose (GBL, U-Boot and GRUB are all in use) and that a board whose stock OS is Linux can be
official; Banana Pi M5 is one.

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
| 4 | persist | 16 MiB | ext4 labelled PERSIST: `grubenv`, `grubenv_abootctrl` |
| 5 | metadata | 32 MiB | metadata encryption keys, OTA snapshots |
| 6 | firmware | 128 MiB | Qualcomm firmware |
| 7, 8 | vendor_boot_a/b | 100 MiB | vendor ramdisk, recovery ramdisk, kernel modules |
| 9, 10 | boot_a/b | 96 MiB | kernel, generic ramdisk |
| 12 | userdata | rest of the disk | |

## Kernel

android-mainline with the board's patches, as before. `kernel/dragon_q6a.config` is, for now,
the complete configuration the shipped builds produce from `device/mainline/generic`'s
Debian-derived fragments; it has to be reduced to what differs from `gki_defconfig`.
`kernel/dragon_q6a-boot.config` builds in the drivers first stage init needs to mount the boot
disk (NVMe, its PCIe PHY and regulators, SD card, vfat) and efivarfs.

## Status

The skeleton: product, BoardConfig, fstab, init files, SELinux types for persist and firmware,
the Q6A services that carry over (Wi-Fi/Bluetooth loading, tuning, the USB modem), properties,
GRUB additions and the partition script. `lunch lineage_dragon_q6a cp2a userdebug` works and
the current product, `lineage_Generic_arm64`, is untouched.

## Still to do

1. Image tasks: the EFI system partition (GRUB, configuration, DTB), persist (ext4, PERSIST,
   initial grubenv) and firmware images, and a disk or installer image. The virt trees have all
   of these in `build/tasks`, guarded by `USES_DEVICE_VIRT_VIRT_COMMON`; the open question for
   LineageOS is whether hardware devices should share them (for example from
   `device/mainline/common`) rather than copy them.
2. fastbootd: a fastboot HAL for recovery (the virt trees have
   `android.hardware.fastboot-service.virt_recovery`).
3. Kernel modules: the vendor_dlkm module list and load order, which `generic_init` and
   `q6a_load_wifi_bt` handle today.
4. SELinux: the Q6A services still run as `su`, which only exists in userdebug builds.
5. Hardware HALs carried by `device/mainline/generic` today: health, sensors, Wi-Fi overlays,
   input configuration, USB gadget (device mode works on the USB 3.1 port, see UPSTREAM.md).
6. Verified boot: vbmeta and AVB, once the boot chain works.
7. Build, flash to an SD card, boot, then move the NVMe installation over (it wipes the disk).
