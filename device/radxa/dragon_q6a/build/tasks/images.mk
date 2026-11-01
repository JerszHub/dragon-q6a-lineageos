#
# SPDX-FileCopyrightText: The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#
# Images outside super and the boot images: the EFI system partition with GRUB, the persist
# partition with GRUB's environment and A/B state, and the firmware partition.
# Modelled on device/virt/virt-common (build/tasks) and device/xiaomi/mi7150-mainline
# (build/tasks/espimage.mk), which take the GRUB EFI binary from device/virt/virtio_arm64.

ifeq ($(USES_DEVICE_RADXA_DRAGON_Q6A),true)

DRAGON_Q6A_BOOTMGR_SHARED_LIBS_DIR := prebuilts/bootmgr/lib64
DRAGON_Q6A_BOOTMGR_EXEC_ENV := LD_LIBRARY_PATH=$(DRAGON_Q6A_BOOTMGR_SHARED_LIBS_DIR) $(DRAGON_Q6A_BOOTMGR_SHARED_LIBS_DIR)/ld-linux-x86-64.so.2
DRAGON_Q6A_BOOTMGR_TOOLS_BIN_DIR := prebuilts/bootmgr/tools/$(HOST_PREBUILT_TAG)/bin

DRAGON_Q6A_GRUB_ARCH := arm64-efi
DRAGON_Q6A_GRUB_PREBUILT_DIR := prebuilts/bootmgr/grub/linux-arm64/$(DRAGON_Q6A_GRUB_ARCH)
DRAGON_Q6A_GRUB_EFI_PREBUILT := device/virt/virtio_arm64/bootmgr/grub/prebuilt/boot/BOOTAA64.EFI
DRAGON_Q6A_GRUB_CONFIG := $(DEVICE_PATH)/bootmgr/grub/grub-boot.cfg

DRAGON_Q6A_DTB := qcom/qcs6490-radxa-dragon-q6a.dtb
DRAGON_Q6A_DTB_SRC := $(TARGET_OUT_INTERMEDIATES)/KERNEL_OBJ/arch/arm64/boot/dts/$(DRAGON_Q6A_DTB)

ifneq ($(LINEAGE_BUILD),)
DRAGON_Q6A_DISTRIBUTION_NAME := LineageOS $(PRODUCT_VERSION_MAJOR).$(PRODUCT_VERSION_MINOR)
else
DRAGON_Q6A_DISTRIBUTION_NAME := Android $(PLATFORM_VERSION_LAST_STABLE)
endif

# $(1): output file
# $(2): list of contents to include
# $(3): volume label
# $(4): image size in MiB
define dragon-q6a-create-fat32image
	rm -f $(1)
	/bin/dd if=/dev/zero of=$(1) bs=1M count=$(4) status=none
	$(DRAGON_Q6A_BOOTMGR_EXEC_ENV) $(DRAGON_Q6A_BOOTMGR_TOOLS_BIN_DIR)/mformat -F -i $(1) -v "$(3)" ::
	$(foreach content,$(2),$(DRAGON_Q6A_BOOTMGR_EXEC_ENV) $(DRAGON_Q6A_BOOTMGR_TOOLS_BIN_DIR)/mcopy -i $(1) -s $(content) :: &&)true
endef

##### EFI system partition #####

# The files are also kept in a directory, so that they can be copied onto an existing EFI
# system partition next to another boot manager.
DRAGON_Q6A_ESP_DIR := $(TARGET_OUT_INTERMEDIATES)/DRAGON_Q6A_ESP
INSTALLED_DRAGON_Q6A_ESPIMAGE_TARGET := $(PRODUCT_OUT)/EFI.img

$(INSTALLED_DRAGON_Q6A_ESPIMAGE_TARGET): $(DRAGON_Q6A_GRUB_EFI_PREBUILT) $(DRAGON_Q6A_GRUB_CONFIG) $(INSTALLED_KERNEL_TARGET)
	$(call pretty,"Target EFI System Partition image: $@")
	rm -rf $(DRAGON_Q6A_ESP_DIR)
	mkdir -p $(DRAGON_Q6A_ESP_DIR)/EFI/BOOT $(DRAGON_Q6A_ESP_DIR)/boot/grub/fonts $(dir $(DRAGON_Q6A_ESP_DIR)/dtb/$(DRAGON_Q6A_DTB))
	cp $(DRAGON_Q6A_GRUB_EFI_PREBUILT) $(DRAGON_Q6A_ESP_DIR)/EFI/BOOT/BOOTAA64.EFI
	cp -r $(DRAGON_Q6A_GRUB_PREBUILT_DIR)/lib/grub/$(DRAGON_Q6A_GRUB_ARCH) $(DRAGON_Q6A_ESP_DIR)/boot/grub/
	cp $(DRAGON_Q6A_GRUB_PREBUILT_DIR)/share/grub/unicode.pf2 $(DRAGON_Q6A_ESP_DIR)/boot/grub/fonts/unicode.pf2
	touch $(DRAGON_Q6A_ESP_DIR)/boot/grub/.is_esp_part_on_android_boot_device
	cp $(DRAGON_Q6A_GRUB_CONFIG) $(DRAGON_Q6A_ESP_DIR)/boot/grub/grub.cfg
	sed -i -e "s|@AB_OTA_UPDATER@|$(AB_OTA_UPDATER)|g" \
	    -e "s|@BOOTMGR_ANDROID_DISTRIBUTION_NAME@|$(DRAGON_Q6A_DISTRIBUTION_NAME)|g" \
	    -e "s|@DTB@|$(DRAGON_Q6A_DTB)|g" $(DRAGON_Q6A_ESP_DIR)/boot/grub/grub.cfg
	cp $(DRAGON_Q6A_DTB_SRC) $(DRAGON_Q6A_ESP_DIR)/dtb/$(DRAGON_Q6A_DTB)
	$(call dragon-q6a-create-fat32image,$@,$(DRAGON_Q6A_ESP_DIR)/EFI $(DRAGON_Q6A_ESP_DIR)/boot $(DRAGON_Q6A_ESP_DIR)/dtb,EFI,64)

.PHONY: espimage
espimage: $(INSTALLED_DRAGON_Q6A_ESPIMAGE_TARGET)

##### persist #####

DRAGON_Q6A_PERSIST_DIR := $(TARGET_OUT_INTERMEDIATES)/DRAGON_Q6A_PERSIST
DRAGON_Q6A_GRUB_EDITENV_EXEC := $(HOST_OUT_EXECUTABLES)/grub-editenv
DRAGON_Q6A_GRUB_BOOT_CONTROL_EXEC := $(HOST_OUT_EXECUTABLES)/grub_boot_control
DRAGON_Q6A_GRUBENV_DEFAULTS := android_selinux_permissive=0 grub_android_default=0 grub_timeout=5 quiet=0
INSTALLED_DRAGON_Q6A_PERSISTIMAGE_TARGET := $(PRODUCT_OUT)/persist.img

$(INSTALLED_DRAGON_Q6A_PERSISTIMAGE_TARGET): $(DRAGON_Q6A_GRUB_EDITENV_EXEC) $(DRAGON_Q6A_GRUB_BOOT_CONTROL_EXEC)
	$(call pretty,"Target persist image: $@")
	rm -rf $(DRAGON_Q6A_PERSIST_DIR)
	mkdir -p $(DRAGON_Q6A_PERSIST_DIR)
	$(DRAGON_Q6A_GRUB_EDITENV_EXEC) $(DRAGON_Q6A_PERSIST_DIR)/grubenv create
	$(DRAGON_Q6A_GRUB_EDITENV_EXEC) $(DRAGON_Q6A_PERSIST_DIR)/grubenv set $(DRAGON_Q6A_GRUBENV_DEFAULTS)
	$(DRAGON_Q6A_GRUB_BOOT_CONTROL_EXEC) $(DRAGON_Q6A_PERSIST_DIR)/grubenv_abootctrl
	$(call dragon-q6a-create-fat32image,$@,$(DRAGON_Q6A_PERSIST_DIR)/grubenv $(DRAGON_Q6A_PERSIST_DIR)/grubenv_abootctrl,PERSIST,16)

.PHONY: persistimage
persistimage: $(INSTALLED_DRAGON_Q6A_PERSISTIMAGE_TARGET)

##### firmware #####

# Qualcomm firmware from linux-firmware, in its layout (scripts/fetch_firmware.sh of the port's
# repository downloads and checks it). The board's device tree names a few files differently.
DRAGON_Q6A_FIRMWARE_SRC ?= vendor/radxa/dragon_q6a/firmware
DRAGON_Q6A_FIRMWARE_DIR := $(TARGET_OUT_INTERMEDIATES)/DRAGON_Q6A_FIRMWARE
INSTALLED_DRAGON_Q6A_FIRMWAREIMAGE_TARGET := $(PRODUCT_OUT)/firmware.img

DRAGON_Q6A_FIRMWARE_FILES := \
    qcom/a660_gmu.bin:qcom/a660_gmu.bin \
    qcom/a660_sqe.fw:qcom/a660_sqe.fw \
    qcom/qcm6490/a660_zap.mbn:qcom/qcs6490/a660_zap.mbn \
    qcom/qcm6490/qupv3fw.elf:qcom/qcm6490/qupv3fw.elf \
    qcom/qcs6490/radxa/dragon-q6a/adsp.mbn:qcom/qcs6490/radxa/dragon-q6a/adsp.mbn \
    qcom/qcs6490/radxa/dragon-q6a/QCS6490-Radxa-Dragon-Q6A-tplg.bin:qcom/qcs6490/QCS6490-Radxa-Dragon-Q6A-tplg.bin \
    qcom/vpu/vpu20_p1.mbn:qcom/vpu/vpu20_p1.mbn \
    qcom/vpu/vpu20_p1_gen2_s6.mbn:qcom/vpu/vpu20_p1_gen2_s6.mbn

$(INSTALLED_DRAGON_Q6A_FIRMWAREIMAGE_TARGET): $(foreach f,$(DRAGON_Q6A_FIRMWARE_FILES),$(DRAGON_Q6A_FIRMWARE_SRC)/$(call word-colon,1,$(f)))
	$(call pretty,"Target firmware image: $@")
	rm -rf $(DRAGON_Q6A_FIRMWARE_DIR)
	$(foreach f,$(DRAGON_Q6A_FIRMWARE_FILES), \
	    mkdir -p $(dir $(DRAGON_Q6A_FIRMWARE_DIR)/$(call word-colon,2,$(f))) && \
	    cp $(DRAGON_Q6A_FIRMWARE_SRC)/$(call word-colon,1,$(f)) $(DRAGON_Q6A_FIRMWARE_DIR)/$(call word-colon,2,$(f)) &&) true
	$(call dragon-q6a-create-fat32image,$@,$(DRAGON_Q6A_FIRMWARE_DIR)/qcom,FIRMWARE,64)

.PHONY: firmwareimage
firmwareimage: $(INSTALLED_DRAGON_Q6A_FIRMWAREIMAGE_TARGET)

INSTALLED_RADIOIMAGE_TARGET += \
    $(INSTALLED_DRAGON_Q6A_ESPIMAGE_TARGET) \
    $(INSTALLED_DRAGON_Q6A_PERSISTIMAGE_TARGET) \
    $(INSTALLED_DRAGON_Q6A_FIRMWAREIMAGE_TARGET)

endif # USES_DEVICE_RADXA_DRAGON_Q6A
