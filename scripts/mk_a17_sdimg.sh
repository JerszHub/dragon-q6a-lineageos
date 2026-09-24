#!/bin/bash
# Sklada testowy obraz SD z Androidem 17 (LineageOS 24 / mainline_generic) dla Dragon Q6A.
# Metoda: JEDNA partycja ESP (FAT32) + obrazy systemu w katalogu /Android ("android dir"),
# userdata w tmpfs. Najprostszy mozliwy uklad pod PIERWSZY boot - zero partycjonowania
# systemu, wszystko podmienia sie zwyklym kopiowaniem plikow.
set -e
OUT=${LINEAGE_TREE:-$HOME/q6a/lineage}/out/target/product/Generic_arm64
KOBJ=$OUT/obj/KERNEL_OBJ/arch/arm64/boot
IMG=$HOME/q6a/dragon_q6a_a17_test.img
V7=$HOME/q6a/dragon_q6a_universal-v7.img
SIZE_MB=3072
OFF=1048576          # 2048 sektorow * 512

echo "=== 1/6 tworze obraz ${SIZE_MB} MB"
rm -f "$IMG"; truncate -s ${SIZE_MB}M "$IMG"

echo "=== 2/6 tablica GPT (jedna partycja ESP)"
sgdisk -og "$IMG" >/dev/null
sgdisk -n 1:2048:0 -t 1:EF00 -c 1:"ESP" "$IMG" >/dev/null
sgdisk -p "$IMG" | tail -3

echo "=== 3/6 formatuje FAT32"
# UWAGA, BLAD NAPRAWIONY 2026-09-19: samo "mformat -i plik@@OFFSET" NIE ZNA rozmiaru partycji.
# mtools liczy wtedy system plikow jako (rozmiar_pliku - offset)/512, czyli do konca PLIKU -
# a GPT rezerwuje na koncu 33 sektory na zapasowa tablice. FAT wychodzil o 33 sektory (16,5 kB)
# WIEKSZY niz partycja: partycja 6289375 sektorow, FAT 6289408.
# Skutek na sprzecie: pliki lezace na koncu FAT wychodza poza partycje i jadro odmawia odczytu
#   mmcblk1p1: attempt to access beyond end of device, sector=6289390 limit=6289375
#   erofs (device loop0): read error  -> vendor.img nieczytelny -> SurfaceFlinger w petli.
# Dlatego rozmiar podajemy jawnie przez -T, licząc go z tablicy partycji.
PSTART=$(sgdisk -i 1 "$IMG" | awk '/First sector/{print $3}')
PEND=$(sgdisk -i 1 "$IMG" | awk '/Last sector/{print $3}')
PSECT=$(( PEND - PSTART + 1 ))
echo "    partycja: $PSTART..$PEND = $PSECT sektorow"
mformat -i "$IMG"@@$((PSTART*512)) -F -T "$PSECT" -v A17TEST ::
# kontrola: FAT nie moze byc wiekszy niz partycja
FATSECT=$(minfo -i "$IMG"@@$((PSTART*512)) | awk '/big size/{print $3}')
echo "    FAT: $FATSECT sektorow"
[ "$FATSECT" -le "$PSECT" ] || { echo "STOP: FAT ($FATSECT) wiekszy niz partycja ($PSECT)"; exit 1; }

echo "=== 4/6 bootloader z v7 (embloader 0.4 + BCB, sprawdzony na tej plycie)"
mmd -i "$IMG"@@$OFF ::/EFI ::/EFI/BOOT ::/loader ::/loader/entries ::/Android
mcopy -i "$V7"@@$OFF ::/EFI/BOOT/BOOTAA64.EFI /tmp/BOOTAA64.EFI
mcopy -i "$IMG"@@$OFF /tmp/BOOTAA64.EFI ::/EFI/BOOT/BOOTAA64.EFI
rm -f /tmp/BOOTAA64.EFI

echo "=== 5/6 kopiuje kernel, DTB, ramdisk i obrazy systemu"
mcopy -i "$IMG"@@$OFF "$KOBJ/Image" ::/Android/Image
mcopy -i "$IMG"@@$OFF "$KOBJ/dts/qcom/qcs6490-radxa-dragon-q6a.dtb" ::/Android/qcs6490-radxa-dragon-q6a.dtb
mcopy -i "$IMG"@@$OFF "$OUT/ramdisk-all-combined.img" ::/Android/ramdisk-all-combined.img
for i in system vendor vendor_dlkm; do
  echo "    $i.img"
  mcopy -i "$IMG"@@$OFF "$OUT/$i.img" ::/Android/$i.img
done

echo "=== 6/6 wpisy rozruchowe"
BASE='androidboot.init_fatal_reboot_target=recovery binder.impl=rust log_buf_len=4M loop.max_part=7 printk.devkmsg=on rw vt.global_cursor_default=0 androidboot.addon_fstab_suffix=basic androidboot.console=tty0 androidboot.hardware=generic androidboot.hypervisor.version=1 androidboot.hypervisor.vm.supported=1 androidboot.hypervisor.protected_vm.supported=0 androidboot.init_fatal_pause=true androidboot.selinux=permissive androidboot.verifiedbootstate=orange audit=0 console=tty0 firmware_class.path=/mnt/vendor/firmware/ mitigations=off rdinit=/system/bin/generic_init sysctl.kernel.firmware_config.force_sysfs_fallback=1 sysctl.kernel.modprobe=/vendor/bin/modprobe_kernel'
INST='androidboot.android_dir=Android androidboot.mount_system=imgs androidboot.mount_userdata=tmpfs androidboot.mount_firmware=disable'
# earlycon BEZ argumentow: sterownik qcom_geni ma tylko OF_EARLYCON_DECLARE, wiec forma
# "earlycon=qcom_geni,0xADRES" jest ignorowana. Bez argumentow jadro bierze port z DTB
# (chosen/stdout-path = serial0 -> serial@994000). panic=0 = zawieszenie zamiast restartu.
DBG='androidboot.insecure_adb=true androidboot.seriallogging=ttyMSM0 earlycon console=ttyMSM0,115200n8 keep_bootcon ignore_loglevel loglevel=8 panic=0'

TMP=$(mktemp -d)
cat > $TMP/loader.conf <<EOF
timeout 5
default a17-dbg
EOF
cat > $TMP/a17-dbg.conf <<EOF
title      Android 17 (LOS24) - DEBUG (earlycon + initcall_debug)
linux      /Android/Image
initrd     /Android/ramdisk-all-combined.img
devicetree /Android/qcs6490-radxa-dragon-q6a.dtb
options    $BASE $INST androidboot.insecure_adb=true earlycon console=ttyMSM0,115200n8 keep_bootcon ignore_loglevel loglevel=8 panic=0 nokaslr initcall_debug
EOF
cat > $TMP/a17-drm.conf <<EOF
title      Android 17 (LOS24) - DRM / msm
linux      /Android/Image
initrd     /Android/ramdisk-all-combined.img
devicetree /Android/qcs6490-radxa-dragon-q6a.dtb
options    $BASE $INST $DBG initcall_blacklist=simpledrm_platform_driver_init video=HDMI-A-1:e
EOF
cat > $TMP/a17-fb.conf <<EOF
title      Android 17 (LOS24) - framebuffer (awaryjny)
linux      /Android/Image
initrd     /Android/ramdisk-all-combined.img
devicetree /Android/qcs6490-radxa-dragon-q6a.dtb
options    $BASE $INST $DBG androidboot.use_fb_display=true video=HDMI-A-1:e
EOF
mcopy -i "$IMG"@@$OFF $TMP/loader.conf ::/loader/loader.conf
for c in a17-dbg a17-drm a17-fb; do mcopy -i "$IMG"@@$OFF $TMP/$c.conf ::/loader/entries/$c.conf; done
rm -rf $TMP

echo
echo "=== GOTOWE: $IMG"
ls -la "$IMG" | awk '{printf "    rozmiar: %.2f GB\n",$5/1073741824}'
echo "=== zawartosc ESP:"
mdir -i "$IMG"@@$OFF ::/Android
mdir -i "$IMG"@@$OFF ::/loader/entries
