#
# SPDX-FileCopyrightText: The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#

# Inherit from those products. Most specific first.
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit_only.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/full_base.mk)

# Inherit some common Lineage stuff.
$(call inherit-product, vendor/lineage/config/common_full_tablet_wifionly.mk)

# Inherit from device
$(call inherit-product, device/radxa/dragon_q6a/device.mk)

PRODUCT_NAME := lineage_dragon_q6a
PRODUCT_DEVICE := dragon_q6a
PRODUCT_BRAND := Radxa
PRODUCT_MANUFACTURER := Radxa
PRODUCT_MODEL := Dragon Q6A
