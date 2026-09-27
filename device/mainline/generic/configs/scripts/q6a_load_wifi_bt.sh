#!/system/bin/sh
# Q6A: explicitly load the AIC8800D80 drivers (WiFi + Bluetooth).
#
# WHY NOT BY ALIAS: generic_init loads the modules listed in the RAMDISK's modules.load,
# and ueventd then picks further ones up from the MODALIAS field of each uevent
# (docs/booting-process.md:53). Our modules carry the right aliases:
#   alias: usb:vA69Cp8D80d*...   alias: usb:vA69Cp8D81d*...
# but /vendor_dlkm/lib/modules/modules.alias does not contain them. The build computed the
# aliases for the module set added through BOARD_VENDOR_KERNEL_MODULES (14 A69C entries in
# depmod_VENDOR_intermediates), while the modules.alias that ends up in vendor_dlkm comes
# from a different depmod pass covering the other 3893 modules.
# Symptom: "ueventd: LoadWithAliases was unable to load usb:vA69Cp8D80...".
#
# Adding the names to BOARD_VENDOR_KERNEL_MODULES_LOAD does not help either, and it is
# actively harmful: dlkm_loader_mainline does read that list, cannot resolve the names
# through modules.dep for the same reason, and aborts on the CHECK in its main() - after
# loading everything else, so the only real loss is the vendor.dlkm.modules.ready property.
#
# ORDER MATTERS: aic_load_fw uploads the firmware to the chip, which makes it re-enumerate
# from 8d80 to 8d81. aic8800_fdrv then only has to be REGISTERED - the USB core binds it
# itself once the device reappears in the new mode. Hence no sleeps.
#
# Firmware: /vendor/etc/firmware (flat, no subdirectory) - aicbluetooth.c:149 and :333.
set -x
M=/vendor_dlkm/lib/modules
/system/bin/insmod $M/aic_load_fw.ko
/system/bin/insmod $M/aic8800_fdrv.ko
# BLUETOOTH: aic_btusb is deliberately NOT loaded, and is not even shipped.
# This chip's BT interfaces are of the standard USB class 0xE0 (Wireless Controller):
#   1-1.4:1.0 class=e0    1-1.4:1.1 class=e0    1-1.4:1.2 class=ff (WiFi, aic8800_fdrv)
# The kernel's generic btusb driver handles them - verified on hardware: binding
# 1-1.4:1.0 to /sys/bus/usb/drivers/btusb/bind creates hci0.
# aic_btusb is not merely redundant, it BREAKS Bluetooth: it claims both class 0xE0
# interfaces and exposes its own /dev/aicbt_dev, which Android's stock HAL cannot use.
# Symptom: hci0 never appears, the BT stack hangs in BLE_TURNING_ON and falls back to OFF.
