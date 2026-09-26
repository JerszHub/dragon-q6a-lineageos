#!/system/bin/sh
# Q6A: explicit loading of the AIC8800D80 drivers (Wi-Fi + Bluetooth).
#
# WHY NOT THROUGH ALIASES: generic_init loads modules from modules.load in the RAMDISK,
# and ueventd then picks them up from the MODALIAS field of uevents
# (docs/booting-process.md:53). Our modules do carry the right aliases built in:
#   alias: usb:vA69Cp8D80d*...   alias: usb:vA69Cp8D81d*...
# but /vendor_dlkm/lib/modules/modules.alias DOES NOT CONTAIN THEM — the build computed
# aliases for the "VENDOR" set (depmod_VENDOR_intermediates, 14 A69C entries) while the
# .ko files landed in vendor_dlkm, whose modules.alias comes from a different source.
# The symptom is "ueventd: LoadWithAliases was unable to load usb:vA69Cp8D80...".
# BOARD_VENDOR_KERNEL_MODULES_LOAD does not help either — nothing in this image reads
# modules.load.
#
# ORDER MATTERS: aic_load_fw uploads firmware to the chip, which makes it re-enumerate
# from 8d80 to 8d81. aic8800_fdrv then only needs to be REGISTERED — USB core binds it
# by itself once the device reappears in the new mode. Hence no sleeps.
set -x
M=/vendor_dlkm/lib/modules
/system/bin/insmod $M/aic_load_fw.ko
/system/bin/insmod $M/aic8800_fdrv.ko
# aic_btusb is deliberately NOT loaded. The Bluetooth interfaces are standard USB class
# 0xE0 and the kernel's generic btusb handles them; the Bluetooth firmware is part of the
# payload aic_load_fw uploads. aic_btusb races btusb for the interface and, when it wins,
# exposes /dev/aicbt_dev, which the stock Android HAL cannot use — Bluetooth then hangs
# in BLE_TURNING_ON. Confirmed on hardware 2026-09-22.
