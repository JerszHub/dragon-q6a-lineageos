#
# SPDX-FileCopyrightText: The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#

DEVICE_PATH := device/radxa/dragon_q6a

USES_DEVICE_RADXA_DRAGON_Q6A := true

# Inherit from mainline/qcom-common
include device/mainline/qcom-common/BoardConfigMainlineQcomCommon.mk

# Testing: DRAGON_Q6A_GENERIC_CPU=true builds for the CPU variant of mainline_generic's
# Generic_arm64, so that a tree which has built that product reuses its native outputs instead
# of compiling everything again for cortex-a76.
ifeq ($(DRAGON_Q6A_GENERIC_CPU),true)
TARGET_ARCH_VARIANT := armv8-a
TARGET_CPU_VARIANT := generic
TARGET_CPU_VARIANT_RUNTIME :=
endif

# A/B
# The board boots from GPT on NVMe or SD through its UEFI firmware and GRUB; GRUB keeps the
# slot state in grubenv on the persist partition and hardware/mainline/common's
# grub_boot_control serves it to Android, as in LineageOS' virt devices. Unlike there, the EFI
# system partition is not slotted: the firmware always starts GRUB from the same one.
AB_OTA_UPDATER := true

# Bootconfig
BOARD_BOOTCONFIG := \
    $(MAINLINE_COMMON_ANDROIDBOOT_PARAMS) \
    $(MAINLINE_QCOM_SOC_ANDROIDBOOT_PARAMS) \
    androidboot.boot_devices=any \
    androidboot.hardware=dragon_q6a

# Bootloader
BOARD_BOOT_HEADER_VERSION := 4
BOARD_MKBOOTIMG_ARGS += --header_version $(BOARD_BOOT_HEADER_VERSION)
TARGET_BOOTLOADER_BOARD_NAME := dragon_q6a
TARGET_NO_BOOTLOADER := true

# Filesystem
TARGET_USERIMAGES_USE_EXT4 := true
TARGET_USERIMAGES_USE_F2FS := true

# Kernel
BOARD_KERNEL_IMAGE_NAME := Image
BOARD_INCLUDE_DTB_IN_BOOTIMG := true
TARGET_KERNEL_DTB := qcom/qcs6490-radxa-dragon-q6a.dtb
TARGET_DTB_LIST_WILDCARD := qcom/qcs6490-radxa-dragon-q6a
TARGET_KERNEL_SOURCE := kernel/mainline/android-mainline
TARGET_KERNEL_CONFIG := gki_defconfig
# android-mainline is an Android common kernel, so gki_defconfig is the base; the official
# mainline phones start from defconfig because their kernels are not. qcs6490.config is shared
# with the generic_init build.
TARGET_KERNEL_CONFIG_EXT := \
    kernel/mainline/configs/fragments/common.config \
    kernel/mainline/configs/fragments/y/fbcon.config \
    $(DEVICE_PATH)/kernel/dragon_q6a.config \
    $(DEVICE_PATH)/kernel/qcs6490.config \
    $(DEVICE_PATH)/kernel/dragon_q6a-boot.config
# android-mainline dropped its empty Kconfig.ext placeholder; needs LineageOS Gerrit 489817.
TARGET_KERNEL_KCONFIG_EXT_PREFIX := $(DEVICE_PATH)/kernel/kconfig-ext

BOARD_KERNEL_CMDLINE := \
    $(MAINLINE_COMMON_KERNEL_PARAMS) \
    $(MAINLINE_QCOM_KERNEL_PARAMS) \
    clk_ignore_unused \
    console=tty0 \
    initcall_blacklist=simpledrm_platform_driver_init \
    panic=0 \
    pd_ignore_unused \
    video=HDMI-A-1:e

# Kernel modules
# AIC8800D80 Wi-Fi and Bluetooth, built from source against this kernel. They are loaded by
# init.dragon_q6a.rc, see configs/scripts/q6a_load_wifi_bt.sh.
BOARD_VENDOR_KERNEL_MODULES += \
    $(DEVICE_PATH)/kernel/modules/aic_load_fw.ko \
    $(DEVICE_PATH)/kernel/modules/aic8800_fdrv.ko
BOARD_KERNEL_MODULES_LOAD_ALLOW_MISSING := true
TARGET_AUTO_COLLECT_KERNEL_MODULE_DEPS := true

# Partitions
BOARD_FLASH_BLOCK_SIZE := 4096
BOARD_BOOTIMAGE_PARTITION_SIZE := 100663296 # 96 MiB
BOARD_VENDOR_BOOTIMAGE_PARTITION_SIZE := 104857600 # 100 MiB
BOARD_USES_METADATA_PARTITION := true

DLKM_PARTITIONS := system_dlkm vendor_dlkm
SSI_PARTITIONS := product system system_ext
TREBLE_PARTITIONS := odm vendor
ALL_PARTITIONS := $(DLKM_PARTITIONS) $(SSI_PARTITIONS) $(TREBLE_PARTITIONS)

$(foreach p, $(DLKM_PARTITIONS), \
    $(eval BOARD_USES_$(call to-upper, $(p))IMAGE := true))

BOARD_SYSTEMIMAGE_EXTFS_INODE_COUNT := 8192
BOARD_PRODUCTIMAGE_EXTFS_INODE_COUNT := 6144
BOARD_SYSTEM_EXTIMAGE_EXTFS_INODE_COUNT := 4096
BOARD_VENDORIMAGE_EXTFS_INODE_COUNT := 2048
BOARD_ODMIMAGE_EXTFS_INODE_COUNT := 1024
$(foreach p, $(call to-upper, $(SSI_PARTITIONS) $(TREBLE_PARTITIONS)), \
    $(eval BOARD_$(p)IMAGE_PARTITION_RESERVED_SIZE := 134217728)) # 128 MiB

# Virtual A/B keeps one copy of each partition in super; updates go through snapshots.
BOARD_SUPER_PARTITION_SIZE := 12884901888 # 12 GiB
BOARD_SUPER_PARTITION_GROUPS := dragon_q6a_dynamic_partitions
BOARD_DRAGON_Q6A_DYNAMIC_PARTITIONS_PARTITION_LIST := $(ALL_PARTITIONS)
BOARD_DRAGON_Q6A_DYNAMIC_PARTITIONS_SIZE := $(shell expr $(BOARD_SUPER_PARTITION_SIZE) - 4194304)

$(foreach p, $(call to-upper, $(ALL_PARTITIONS)), \
    $(eval BOARD_$(p)IMAGE_FILE_SYSTEM_TYPE := ext4) \
    $(eval TARGET_COPY_OUT_$(p) := $(call to-lower, $(p))))

AB_OTA_PARTITIONS := \
    $(ALL_PARTITIONS) \
    boot \
    vendor_boot

# Properties
TARGET_VENDOR_PROP += $(DEVICE_PATH)/configs/properties/vendor.prop

# Ramdisk
BOARD_RAMDISK_USE_LZ4 := true

# Recovery
BOARD_INCLUDE_RECOVERY_RAMDISK_IN_VENDOR_BOOT := true
BOARD_MOVE_RECOVERY_RESOURCES_TO_VENDOR_BOOT := true
TARGET_NO_RECOVERY := true
TARGET_RECOVERY_FSTAB := $(DEVICE_PATH)/configs/fstab/fstab.dragon_q6a
ifeq ($(DRAGON_Q6A_DUAL_BOOT),true)
TARGET_RECOVERY_FSTAB := $(DEVICE_PATH)/configs/fstab/fstab.dragon_q6a.dual_boot
endif

# SELinux
BOARD_VENDOR_SEPOLICY_DIRS += $(DEVICE_PATH)/sepolicy/vendor
