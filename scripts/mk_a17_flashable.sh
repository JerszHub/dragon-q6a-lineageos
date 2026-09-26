#!/bin/bash
# mk_a17_flashable.sh — builds a COMPLETE release image: write it with Balena Etcher (or
#                       dd) and boot. No partitioning step, no scripts, no Linux required.
#
# WHY THIS REPLACES THE OLD TWO-STEP RELEASE:
# The previous image carried only the ESP, so every user had to run a partitioning script
# afterwards to create metadata and userdata. That step needed Linux, and it produced two
# support requests in one day — one about a hardcoded card-size window, one about a boot
# entry that only exists on a development card. Neither user did anything wrong.
#
# WHAT IS IN THE IMAGE:
#   p1 ESP       4 GB    system/vendor images, kernel, DTB, firmware, boot entries
#   p2 metadata  32 MB   required by androidboot.mount_userdata=std_parts
#   p3 userdata  512 MB  deliberately small — the board grows it on first boot
#
# The board expands userdata to fill the medium by itself, through the
# q6a_expand_userdata service: it moves the backup GPT to the real end of the disk,
# recreates the partition at full size, reboots once so the kernel re-reads the table,
# then grows the filesystem online with resize2fs. That is why the image can stay small
# enough to download and still use a 512 GB card fully.
#
# ⚠️ Do NOT format userdata with the ext4 quota/project features: CONFIG_QFMT_V2=m means
#    the quota format is a module, absent during first-stage boot, and mounting /data then
#    fails fatally — a boot loop. Confirmed on hardware.
#
# Usage: ~/q6a/mk_a17_flashable.sh [version]        (default: v2)
set -euo pipefail
HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
VER="${1:-v2}"
OUT_DIR=${LINEAGE_TREE:-${LINEAGE_TREE:-$HOME/q6a/lineage}}/out/target/product/Generic_arm64
KOBJ=$OUT_DIR/obj/KERNEL_OBJ/arch/arm64/boot
V7=$HOME/q6a/dragon_q6a_universal-v7.img
IMG=$HOME/q6a/dragon_q6a_lineage24_${VER}.img
ENTRIES=${RELEASE_ENTRIES:-/tmp/rel/entries}

ESP_MB=4096; META_MB=32; DATA_MB=512
ESP_START=2048
ESP_END=$(( ESP_START + ESP_MB*2048 - 1 ))
META_START=$(( ESP_END + 1 ));  META_END=$(( META_START + META_MB*2048 - 1 ))
DATA_START=$(( META_END + 1 )); DATA_END=$(( DATA_START + DATA_MB*2048 - 1 ))
TOTAL_SECT=$(( DATA_END + 34 + 1 ))

echo "=== 1/7 creating image ($(( TOTAL_SECT*512/1024/1024 )) MB)"
rm -f "$IMG"; truncate -s $(( TOTAL_SECT*512 )) "$IMG"
sgdisk -og "$IMG" >/dev/null
sgdisk -n "1:${ESP_START}:${ESP_END}"   -t 1:EF00 -c 1:"ESP"      "$IMG" >/dev/null
sgdisk -n "2:${META_START}:${META_END}" -t 2:8300 -c 2:"metadata" "$IMG" >/dev/null
sgdisk -n "3:${DATA_START}:${DATA_END}" -t 3:8300 -c 3:"userdata" "$IMG" >/dev/null
sgdisk -p "$IMG" | tail -5 | sed 's/^/    /'

echo "=== 2/7 formatting the ESP"
# The size must be given explicitly with -T: mformat otherwise measures to the end of the
# FILE, which overruns the partition by the 33 sectors GPT reserves for the backup table.
# Files landing at the tail then fall outside the partition and the kernel refuses to read
# them — that is how a vendor.img became unreadable once and SurfaceFlinger looped.
ESP_SECT=$(( ESP_END - ESP_START + 1 ))
mformat -i "$IMG"@@$((ESP_START*512)) -F -T "$ESP_SECT" -v A17 ::
FATSECT=$(minfo -i "$IMG"@@$((ESP_START*512)) | awk '/big size/{print $3}')
[ "$FATSECT" -le "$ESP_SECT" ] || { echo "STOP: FAT ($FATSECT) larger than partition ($ESP_SECT)"; exit 1; }
echo "    partition $ESP_SECT sectors, FAT $FATSECT sectors"

echo "=== 3/7 bootloader"
SPEC="$IMG@@$((ESP_START*512))"
mmd -i "$SPEC" ::/EFI ::/EFI/BOOT ::/loader ::/loader/entries ::/Android
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mcopy -i "$V7"@@1048576 ::/EFI/BOOT/BOOTAA64.EFI "$TMP/BOOTAA64.EFI"
mcopy -i "$SPEC" "$TMP/BOOTAA64.EFI" ::/EFI/BOOT/BOOTAA64.EFI

echo "=== 4/7 system images"
for f in "$KOBJ/Image|Image" \
         "$KOBJ/dts/qcom/qcs6490-radxa-dragon-q6a.dtb|qcs6490-radxa-dragon-q6a.dtb" \
         "$OUT_DIR/ramdisk-all-combined.img|ramdisk-all-combined.img" \
         "$OUT_DIR/system.img|system.img" \
         "$OUT_DIR/vendor.img|vendor.img" \
         "$OUT_DIR/vendor_dlkm.img|vendor_dlkm.img"; do
  src=${f%%|*}; dst=${f##*|}
  [ -f "$src" ] || { echo "STOP: missing $src"; exit 1; }
  mcopy -o -i "$SPEC" "$src" "::/Android/$dst"
  printf "    %-34s %8.1f MB\n" "$dst" "$(stat -c%s "$src" | awk '{print $1/1024/1024}')"
done

echo "=== 5/7 firmware and boot entries"
"$HERE/add_a17_firmware.sh" "$IMG" 2>&1 | grep -E "audio:|regulatory:|WARNING|UWAGA" | sed 's/^/    /' || true
for e in a17 a17-udbg a17-quiet; do
  [ -f "$ENTRIES/$e.conf" ] || { echo "STOP: missing $ENTRIES/$e.conf"; exit 1; }
  bad=$(awk '($1=="linux"||$1=="initrd"||$1=="devicetree") && NF!=2' "$ENTRIES/$e.conf")
  [ -z "$bad" ] || { echo "STOP: malformed entry $e: $bad"; exit 1; }
  mcopy -o -i "$SPEC" "$ENTRIES/$e.conf" ::/loader/entries/$e.conf
  echo "    $e.conf"
done
printf 'timeout 0\ndefault a17\n' > "$TMP/loader.conf"
mcopy -o -i "$SPEC" "$TMP/loader.conf" ::/loader/loader.conf

echo "=== 6/7 metadata and userdata filesystems"
mke2fs -q -F -t ext4 -b 4096 -L metadata -m 0 "$TMP/metadata.img" $(( META_MB*256 ))
mke2fs -q -F -t ext4 -b 4096 -L userdata -M /data -m 0 "$TMP/userdata.img" $(( DATA_MB*256 ))
for x in "metadata|$META_START" "userdata|$DATA_START"; do
  n=${x%%|*}; off=${x##*|}
  dd if="$TMP/$n.img" of="$IMG" bs=512 seek="$off" conv=notrunc status=none
  echo "    $n at sector $off"
done
# neither may carry the quota feature
for n in metadata userdata; do
  tune2fs -l "$TMP/$n.img" | grep -i "filesystem features" | grep -qw quota \
    && { echo "STOP: $n has the quota feature"; exit 1; }
done
echo "    OK - no quota feature"

echo "=== 7/7 verification"
for f in ::/Android/Image ::/Android/qcs6490-radxa-dragon-q6a.dtb ::/Android/system.img \
         ::/Android/vendor.img ::/Android/vendor_dlkm.img ::/Android/ramdisk-all-combined.img \
         ::/Android/firmware/regulatory.db \
         ::/Android/firmware/qcom/qcs6490/QCS6490-Radxa-Dragon-Q6A-tplg.bin \
         ::/Android/firmware/qcom/qcs6490/radxa/dragon-q6a/adsp.mbn \
         ::/loader/loader.conf ::/loader/entries/a17.conf ::/EFI/BOOT/BOOTAA64.EFI; do
  mtype -i "$SPEC" "$f" >/dev/null 2>&1 && echo "    OK  $f" || { echo "    MISSING $f"; exit 1; }
done
for n in 2 3; do
  nm=$(sgdisk -i $n "$IMG" | sed -n "s/^Partition name: *'\(.*\)'$/\1/p")
  echo "    p$n GPT name: '$nm'"
done
ls -l "$IMG" | awk '{printf "\n    %s  %.2f GB\n", $NF, $5/1024/1024/1024}'
echo "    compress for release:  xz -T0 -6 -k $IMG"
