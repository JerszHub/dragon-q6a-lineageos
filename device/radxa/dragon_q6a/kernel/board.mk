#
# SPDX-FileCopyrightText: The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#

# Kernel build configuration for Radxa Dragon Q6A (Qualcomm QCS6490).
#
# Selected via MAINLINE_GENERIC_KERNEL_BOARDCONFIG_MK, see
# device/mainline/generic/docs/porting.md.
#
# This reproduces the stock Generic_arm64 configuration chain and appends a
# single board specific fragment at the end. The stock chain is kept because
# the generic device tree relies on a modular kernel: the ramdisk is assembled
# from individual modules by configs/kernel/boot_kernel_modules_finder.sh and
# the remainder is installed into vendor_dlkm. Replacing the Debian derived
# configuration with the upstream arm64 defconfig builds most of those drivers
# into the image instead, and the ramdisk assembly then fails with
# "Module <name> not found" for every module it expects to find.

DRAGON_Q6A_KERNEL_PATH := device/radxa/dragon_q6a/kernel

BOARD_KERNEL_IMAGE_NAME := Image

# device/mainline/generic/BoardConfig.mk only sets these in the branch taken when
# no board configuration is provided, so a board configuration has to set them
# itself. Both existing examples under Generic_arm64/kernels/ do the same.
TARGET_KERNEL_SOURCE ?= kernel/mainline/android-mainline
TARGET_KERNEL_CONFIG := gki_defconfig

TARGET_KERNEL_CONFIG_EXT := \
    $(TARGET_DEVICE_PATH)/configs/kernel/pre-debian.config \
    $(PRODUCT_OUT)/obj/KCONFIG_OBJ/debian-filtered.config \
    $(DEVICE_PATH)/configs/kernel/fix-build.config \
    kernel/mainline/configs/fragments/y/fbcon.config \
    $(DEVICE_PATH)/configs/kernel/customizations.config \
    $(DRAGON_Q6A_KERNEL_PATH)/qcs6490.config
