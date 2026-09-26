#!/bin/bash
# mk_a17_release.sh — builds a RELEASE image for the Dragon Q6A (LineageOS 24).
#
# Difference from mk_a17_sdimg.sh: that one builds a BRING-UP image (userdata=tmpfs,
# mount_firmware=disable, konsola na UART, timeout 5, wpisy diagnostyczne).
# This one builds an image meant to simply work:
#   - `a17` as the default entry: mount_userdata=std_parts, mount_firmware=only_android_dir,
#     pd_ignore_unused clk_ignore_unused, console=tty0 (NO UART — see below), timeout 0
#   - firmware na ESP: GPU (a660*), regulatory.db (-27 s bootu), adsp.mbn + topologia LPASS (audio)
#   - wpisy diagnostyczne a17-udbg (std_parts + logi UART) i a17-quiet (quiet loglevel=3)
#
# ⚠️ Do NOT remove `console=tty0`. With no `console=` at all the kernel enables ttyMSM0
#    (the UART), which is blocking at ~11 KB/s, and boot grows from ~10 s to ~53 s. Measured.
# ⚠️ The board has ONLY a touchscreen, so the boot menu is unusable — hence timeout 0
#    and entry selection through set_default_entry.sh.
#
# Usage: mk_a17_release.sh [version]      (default: v1)
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VER="${1:-v1}"
IMG_SRC=$HERE/dragon_q6a_a17_test.img
OUT=$HERE/dragon_q6a_lineage24_${VER}.img
ENTRIES=${RELEASE_ENTRIES:-/tmp/rel/entries}

echo "=== 1/5 building the base image"
"$HERE/mk_a17_sdimg.sh" >/dev/null
[ -f "$IMG_SRC" ] || { echo "STOP: $IMG_SRC not found"; exit 1; }
cp "$IMG_SRC" "$OUT"
SPEC="$OUT@@1048576"

echo "=== 2/5 staging firmware (GPU + regulatory + audio)"
"$HERE/add_a17_firmware.sh" "$OUT" 2>&1 | grep -E "audio:|regulatory:|UWAGA" | sed 's/^/    /' || true

echo "=== 3/5 installing the release boot entries"
for e in a17 a17-udbg a17-quiet; do
  [ -f "$ENTRIES/$e.conf" ] || { echo "STOP: $ENTRIES/$e.conf not found"; exit 1; }
  # kontrola: sciezki musza miec po 2 pola (patrz wpadka z 2026-09-24)
  bad=$(awk '($1=="linux"||$1=="initrd"||$1=="devicetree") && NF!=2' "$ENTRIES/$e.conf")
  [ -z "$bad" ] || { echo "STOP: malformed entry $e: $bad"; exit 1; }
  mcopy -o -i "$SPEC" "$ENTRIES/$e.conf" ::/loader/entries/$e.conf
  echo "    $e.conf"
done
# drop the old bring-up entries
for e in a17-dbg a17-drm a17-fb; do mdel -i "$SPEC" ::/loader/entries/$e.conf 2>/dev/null || true; done
printf 'timeout 0\ndefault a17\n' > /tmp/loader.conf
mcopy -o -i "$SPEC" /tmp/loader.conf ::/loader/loader.conf

echo "=== 4/5 verifying"
PSTART=$(sgdisk -i 1 "$OUT" | awk '/First sector/{print $3}')
PEND=$(sgdisk -i 1 "$OUT" | awk '/Last sector/{print $3}')
PSECT=$(( PEND - PSTART + 1 ))
FATSECT=$(minfo -i "$SPEC" | awk '/big size/{print $3}')
echo "    partition $PSECT sectors, FAT $FATSECT sectors"
[ "$FATSECT" -le "$PSECT" ] || { echo "STOP: FAT is larger than the partition"; exit 1; }
for f in ::/Android/Image ::/Android/qcs6490-radxa-dragon-q6a.dtb ::/Android/system.img \
         ::/Android/vendor.img ::/Android/vendor_dlkm.img ::/Android/ramdisk-all-combined.img \
         ::/Android/firmware/regulatory.db \
         ::/Android/firmware/qcom/qcs6490/QCS6490-Radxa-Dragon-Q6A-tplg.bin \
         ::/Android/firmware/qcom/qcs6490/radxa/dragon-q6a/adsp.mbn \
         ::/loader/loader.conf ::/loader/entries/a17.conf ::/EFI/BOOT/BOOTAA64.EFI; do
  mtype -i "$SPEC" "$f" >/dev/null 2>&1 && echo "    OK  $f" || { echo "    MISSING $f"; exit 1; }
done
mtype -i "$SPEC" ::/loader/loader.conf | sed 's/^/    /'

echo "=== 5/5 done"
ls -l "$OUT" | awk '{printf "    %s  %.2f GB\n", $NF, $5/1024/1024/1024}'
echo "    compress with: zstd -19 -T0 $OUT"
