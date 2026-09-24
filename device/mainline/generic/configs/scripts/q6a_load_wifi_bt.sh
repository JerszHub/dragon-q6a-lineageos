#!/system/bin/sh
# Q6A: jawne ladowanie sterownikow AIC8800D80 (WiFi + Bluetooth).
#
# DLACZEGO NIE PRZEZ ALIASY: generic_init laduje moduly z modules.load w RAMDYSKU,
# a potem ueventd dobiera je po polu MODALIAS z uevent-ow (docs/booting-process.md:53).
# Nasze moduly maja poprawne aliasy wkompilowane:
#   alias: usb:vA69Cp8D80d*...   alias: usb:vA69Cp8D81d*...
# ale /vendor_dlkm/lib/modules/modules.alias ICH NIE ZAWIERA - build policzyl aliasy
# do zestawu "VENDOR" (depmod_VENDOR_intermediates, 14 wpisow A69C), a pliki .ko
# trafily do vendor_dlkm, ktorego modules.alias pochodzi z innego zrodla.
# Objaw: "ueventd: LoadWithAliases was unable to load usb:vA69Cp8D80...".
# BOARD_VENDOR_KERNEL_MODULES_LOAD tez nie pomaga - nic w obrazie nie czyta modules.load.
#
# KOLEJNOSC JEST ISTOTNA: aic_load_fw wgrywa firmware do ukladu, co powoduje jego
# przeenumerowanie 8d80 -> 8d81. aic8800_fdrv wystarczy wtedy ZAREJESTROWAC - USB core
# sam go zwiaze, gdy urzadzenie pojawi sie w nowym trybie. Dlatego bez sleepow.
#
# Firmware: /vendor/etc/firmware (plasko, bez podkatalogu) - aicbluetooth.c:149 + :333.
set -x
M=/vendor_dlkm/lib/modules
/system/bin/insmod $M/aic_load_fw.ko
/system/bin/insmod $M/aic8800_fdrv.ko
# BLUETOOTH: NIE ladujemy aic_btusb - i to jest celowe.
# Interfejsy BT tego ukladu sa STANDARDOWEJ KLASY USB 0xE0 (Wireless Controller):
#   1-1.4:1.0 class=e0    1-1.4:1.1 class=e0    1-1.4:1.2 class=ff (WiFi, aic8800_fdrv)
# Obsluguje je GENERYCZNY btusb z jadra - sprawdzone na sprzecie: zwiazanie
# 1-1.4:1.0 z /sys/bus/usb/drivers/btusb/bind tworzy hci0.
# aic_btusb nie tylko jest zbedny, ale SZKODZI: przejmuje oba interfejsy klasy e0
# i wystawia wlasne /dev/aicbt_dev, ktorego stockowy HAL Androida nie umie uzyc.
# Objaw: hci0 nie powstaje, a stos BT wisi w BLE_TURNING_ON i po timeoucie wpada w OFF.
