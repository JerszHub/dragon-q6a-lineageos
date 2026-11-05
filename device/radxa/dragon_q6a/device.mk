#
# SPDX-FileCopyrightText: The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#

DEVICE_PATH := device/radxa/dragon_q6a

# Inherit from mainline/qcom-common
$(call inherit-product, device/mainline/qcom-common/mainline_qcom-common.mk)

# A/B
AB_OTA_POSTINSTALL_CONFIG += \
    FILESYSTEM_TYPE_system=ext4

# GRUB's A/B state lives on persist, so qcom-common leaves persist writable.
TARGET_BOOT_HAL := grub

$(call inherit-product, $(SRC_TARGET_DIR)/product/virtual_ab_ota/launch_with_vendor_ramdisk.mk)

PRODUCT_PACKAGES += \
    grub-editenv \
    grub-editenv.recovery \
    grub_boot_control \
    grub_boot_control.recovery \
    sgdisk.recovery

PRODUCT_HOST_PACKAGES += \
    grub-editenv \
    grub_boot_control

# APEX
OVERRIDE_PRODUCT_COMPRESSED_APEX := false

# Bootanimation
TARGET_SCREEN_WIDTH := 1024
TARGET_SCREEN_HEIGHT := 600

# Camera
TARGET_EXTERNAL_CAMERA_PROVIDER_HAL := default-aidl

# Dalvik heap
$(call inherit-product, frameworks/native/build/tablet-10in-xhdpi-2048-dalvik-heap.mk)

# Dynamic partitions
PRODUCT_BUILD_SUPER_PARTITION := true
PRODUCT_USE_DYNAMIC_PARTITIONS := true
PRODUCT_USE_DYNAMIC_PARTITION_SIZE := true

# Firmware
# linux_firmware_r8168: PHY parameters for the RTL8111H Ethernet controller (rtl8168h-2.fw).
PRODUCT_PACKAGES += \
    dragon_q6a_firmware_qcom_symlink \
    linux_firmware_r8168

# First stage init
# DRAGON_Q6A_DUAL_BOOT=true builds for a disk shared with a generic_init installation (testing).
ifeq ($(DRAGON_Q6A_DUAL_BOOT),true)
$(call soong_config_set,dragon_q6a,fstab_variant,dual_boot)
endif

PRODUCT_PACKAGES += \
    fstab.dragon_q6a \
    fstab.dragon_q6a.vendor_ramdisk \
    linker.vendor_ramdisk \
    resize2fs.vendor_ramdisk \
    shell_and_utilities_vendor_ramdisk \
    tune2fs.vendor_ramdisk

# Graphics (Mesa)
TARGET_GRAPHICS := mesa
TARGET_MESA_DO_NOT_SET_AS_DEFAULT := true
# lavapipe does not build in this tree (an unstripped 241 MB library strips to nothing);
# the software Vulkan fallback comes from the SwiftShader APEX instead.
TARGET_MESA_ENABLE_SOFTWARE_RENDERER := false

# Graphics allocator
TARGET_MINIGBM_UPSTREAM_ENABLE_GBM_MESA_DRIVER := true

PRODUCT_PACKAGES += \
    dri_gbm \
    libgbm_mesa

# Graphics composer
TARGET_GRAPHICS_COMPOSER_HAL := drm_hwcomposer

# Graphics (Vulkan)
PRODUCT_PACKAGES += \
    org.lineageos.device.graphics.vulkan.swiftshader

# Init
PRODUCT_PACKAGES += \
    init.dragon_q6a.rc \
    ueventd.dragon_q6a.rc

# Kernel
PRODUCT_OTA_ENFORCE_VINTF_KERNEL_REQUIREMENTS := false

# Media
# The V4L2 stateful Codec2 HAL, on top of the iris driver.
TARGET_MEDIA_C2_HAL := v4l2_codec2

# Permissions
# A board used with touch panels, not a PC: pc_core_hardware.xml declares android.hardware.type.pc
# and no touchscreen, and Google Play hides games such as Genshin Impact from that profile.
PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/tablet_core_hardware.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/tablet_core_hardware.xml \
    frameworks/native/data/etc/android.hardware.touchscreen.multitouch.jazzhand.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.touchscreen.multitouch.jazzhand.xml

# Scoped Storage
$(call inherit-product, $(SRC_TARGET_DIR)/product/emulated_storage.mk)

# SoC
TARGET_QCOM_SOC := qcs6490

# Shipping API level
TARGET_FOLLOWS_LATEST_SHIPPING_API_LEVEL := true

# Soong namespaces
PRODUCT_SOONG_NAMESPACES += \
    $(DEVICE_PATH)/configs

# Tuning
PRODUCT_PACKAGES += \
    q6a_perf.sh \
    q6a_tuning.rc

# USB modem (Fibocom FM350-GL) as an Ethernet network, see wwan/.
PRODUCT_PACKAGES += \
    q6a_wwan

# VINTF
TARGET_FOLLOWS_LATEST_VINTF_TARGET_LEVEL := true

# Wi-Fi and Bluetooth (AIC8800D80 on USB)
# The driver reads its firmware directly from /vendor/etc/firmware, without request_firmware.
PRODUCT_COPY_FILES += $(foreach f,$(wildcard $(DEVICE_PATH)/firmware/aic8800/*), \
    $(f):$(TARGET_COPY_OUT_VENDOR)/etc/firmware/$(notdir $(f)))

PRODUCT_PACKAGES += \
    q6a_load_wifi_bt.rc \
    q6a_load_wifi_bt.sh

TARGET_HOSTAPD_AND_WPA_SUPPLICANT_FORM := legacy
