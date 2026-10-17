#!/bin/bash
# Builds a test SD image with Android 17 (LineageOS 24 / mainline_generic) for the Dragon Q6A.
# Method: ONE ESP partition (FAT32) + system images in the /Android directory ("android dir"),
# userdata on tmpfs. The simplest possible layout for a FIRST boot — no partitioning
# of the system; everything is replaced by plain file copies.
set -e
OUT=${LINEAGE_TREE:-$HOME/q6a/lineage}/out/target/product/Generic_arm64
KOBJ=$OUT/obj/KERNEL_OBJ/arch/arm64/boot
IMG=$HOME/q6a/dragon_q6a_a17_test.img
EFI=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)/prebuilt/embloader/BOOTAA64.EFI
SIZE_MB=3072
OFF=1048576          # 2048 sectors * 512

echo "=== 1/6 creating a ${SIZE_MB} MB image"
rm -f "$IMG"; truncate -s ${SIZE_MB}M "$IMG"

echo "=== 2/6 GPT (one ESP partition)"
sgdisk -og "$IMG" >/dev/null
sgdisk -n 1:2048:0 -t 1:EF00 -c 1:"ESP" "$IMG" >/dev/null
sgdisk -p "$IMG" | tail -3

echo "=== 3/6 formatting FAT32"
# NOTE, BUG FIXED 2026-09-19: "mformat -i file@@OFFSET" alone does NOT know the partition size.
# mtools then computes the filesystem as (file size - offset)/512, i.e. to the end of the FILE —
# but GPT reserves 33 sectors at the end for the backup table. The FAT came out 33 sectors (16.5 kB)
# LARGER than the partition: partition 6289375 sectors, FAT 6289408.
# Effect on hardware: files at the end of the FAT fall outside the partition and the kernel says
#   mmcblk1p1: attempt to access beyond end of device, sector=6289390 limit=6289375
#   erofs (device loop0): read error  -> vendor.img unreadable -> SurfaceFlinger loops.
# So the size is passed explicitly with -T, computed from the partition table.
PSTART=$(sgdisk -i 1 "$IMG" | awk '/First sector/{print $3}')
PEND=$(sgdisk -i 1 "$IMG" | awk '/Last sector/{print $3}')
PSECT=$(( PEND - PSTART + 1 ))
echo "    partition: $PSTART..$PEND = $PSECT sectors"
mformat -i "$IMG"@@$((PSTART*512)) -F -T "$PSECT" -v A17TEST ::
# check: the FAT must not be larger than the partition
FATSECT=$(minfo -i "$IMG"@@$((PSTART*512)) | awk '/big size/{print $3}')
echo "    FAT: $FATSECT sectors"
[ "$FATSECT" -le "$PSECT" ] || { echo "STOP: FAT ($FATSECT) larger than the partition ($PSECT)"; exit 1; }

echo "=== 4/6 bootloader (embloader 0.4 + BCB, see prebuilt/embloader/README.md)"
mmd -i "$IMG"@@$OFF ::/EFI ::/EFI/BOOT ::/loader ::/loader/entries ::/Android
mcopy -i "$IMG"@@$OFF "$EFI" ::/EFI/BOOT/BOOTAA64.EFI

echo "=== 5/6 copying kernel, DTB, ramdisk and system images"
mcopy -i "$IMG"@@$OFF "$KOBJ/Image" ::/Android/Image
mcopy -i "$IMG"@@$OFF "$KOBJ/dts/qcom/qcs6490-radxa-dragon-q6a.dtb" ::/Android/qcs6490-radxa-dragon-q6a.dtb
mcopy -i "$IMG"@@$OFF "$OUT/ramdisk-all-combined.img" ::/Android/ramdisk-all-combined.img
for i in system vendor vendor_dlkm; do
  echo "    $i.img"
  mcopy -i "$IMG"@@$OFF "$OUT/$i.img" ::/Android/$i.img
done

echo "=== 6/6 boot entries"
BASE='androidboot.init_fatal_reboot_target=recovery binder.impl=rust log_buf_len=4M loop.max_part=7 printk.devkmsg=on rw vt.global_cursor_default=0 androidboot.addon_fstab_suffix=basic androidboot.console=tty0 androidboot.hardware=generic androidboot.hypervisor.version=1 androidboot.hypervisor.vm.supported=1 androidboot.hypervisor.protected_vm.supported=0 androidboot.init_fatal_pause=true androidboot.selinux=permissive androidboot.verifiedbootstate=orange audit=0 console=tty0 firmware_class.path=/mnt/vendor/firmware/ mitigations=off rdinit=/system/bin/generic_init sysctl.kernel.firmware_config.force_sysfs_fallback=1 sysctl.kernel.modprobe=/vendor/bin/modprobe_kernel'
INST='androidboot.android_dir=Android androidboot.mount_system=imgs androidboot.mount_userdata=tmpfs androidboot.mount_firmware=disable'
# earlycon with NO arguments: the qcom_geni driver only has OF_EARLYCON_DECLARE, so the
# "earlycon=qcom_geni,0xADDRESS" form is ignored. With no arguments the kernel takes the port from the DTB
# (chosen/stdout-path = serial0 -> serial@994000). panic=0 = hang instead of reboot.
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
title      Android 17 (LOS24) - framebuffer (fallback)
linux      /Android/Image
initrd     /Android/ramdisk-all-combined.img
devicetree /Android/qcs6490-radxa-dragon-q6a.dtb
options    $BASE $INST $DBG androidboot.use_fb_display=true video=HDMI-A-1:e
EOF
mcopy -i "$IMG"@@$OFF $TMP/loader.conf ::/loader/loader.conf
for c in a17-dbg a17-drm a17-fb; do mcopy -i "$IMG"@@$OFF $TMP/$c.conf ::/loader/entries/$c.conf; done
rm -rf $TMP

echo
echo "=== DONE: $IMG"
ls -la "$IMG" | awk '{printf "    size: %.2f GB\n",$5/1073741824}'
echo "=== ESP contents:"
mdir -i "$IMG"@@$OFF ::/Android
mdir -i "$IMG"@@$OFF ::/loader/entries
