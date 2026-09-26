#!/bin/bash
# flash_a17.sh — writes a LineageOS 24 release image to ANY medium (SD, USB, NVMe) and
#                sizes the partitions to what that medium ACTUALLY is.
#
# WHY PLAIN `dd` IS NOT ENOUGH:
#   The image is 3 GB, so its backup GPT sits at the end of the IMAGE. Written to a 476 GB
#   drive it stays three gigabytes in, and the rest of the disk is invisible to partitioning
#   until the backup table is moved to the real end (`sgdisk -e`).
#
# WHAT IT DOES:
#   1. dd the image        2. sgdisk -e (backup GPT to the real end)
#   3. metadata, 32 MB     4. userdata across ALL remaining space
#   5. mkfs.ext4 (NO quota — see below)   6. verify
#
# ⚠️ Do NOT format userdata with the ext4 `quota`/`project` features. This kernel has
#    CONFIG_QFMT_V2=m, so the quota format is a module and is not loaded during first-stage
#    boot; mounting /data then fails, and because /data is not no_fail, init reboots into a
#    recovery that does not exist — a boot loop. Confirmed on hardware.
#
# Usage: sudo flash_a17.sh [/dev/sdX] [image.img]           <- plan only
#        sudo flash_a17.sh [/dev/sdX] [image.img] --apply
set -euo pipefail
HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
APPLY=0; TARGET=""; IMG=""
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1;;
    /dev/*)  TARGET="$a";;
    *.img)   IMG="$a";;
    *) echo "unknown argument: $a"; exit 1;;
  esac
done
IMG="${IMG:-$HERE/dragon_q6a_lineage24_v1.img}"
[ -f "$IMG" ] || { echo "STOP: image not found: $IMG"; exit 1; }
if [ -z "$TARGET" ]; then
  source "$HERE/q6a_find_media.sh"
  TARGET=$(q6a_find_media) || exit 1
fi
[ -b "$TARGET" ] || { echo "STOP: $TARGET is not a block device"; exit 1; }

DEVSZ=$(blockdev --getsz "$TARGET")
DEVGB=$(( DEVSZ * 512 / 1024/1024/1024 ))
IMGSZ=$(stat -c%s "$IMG")
echo "=== TARGET: $TARGET  ($DEVGB GB, $(lsblk -dno MODEL $TARGET 2>/dev/null)) ==="
echo "=== IMAGE: $IMG ($(( IMGSZ/1024/1024 )) MB) ==="
[ "$DEVSZ" -gt $(( IMGSZ/512 )) ] || { echo "STOP: medium is smaller than the image"; exit 1; }
echo
echo "--- THIS WILL BE ERASED, PERMANENTLY:"
lsblk -o NAME,SIZE,FSTYPE,PARTLABEL,LABEL "$TARGET" | sed 's/^/    /'
echo
# The end of the ESP is READ FROM THE IMAGE, not hardcoded. (Bug caught 2026-09-26: this
# said 6291455 while the real end is 6291422 — GPT reserves 33 sectors for the backup table
# at the end of the FILE. It worked by accident, because metadata started past it anyway.)
ESP_END=$(sgdisk -i 1 "$IMG" 2>/dev/null | awk '/Last sector/{print $3}')
[ -n "$ESP_END" ] || { echo "STOP: could not read the end of the ESP from $IMG"; exit 1; }
MD_START=$(( ((ESP_END + 1 + 2047) / 2048) * 2048 ))
MD_END=$(( MD_START + 65536 - 1 ))    # metadata, 32 MB
UD_START=$(( MD_END + 1 ))
UD_END=$(( DEVSZ - 34 ))
echo "--- LAYOUT AFTER WRITING (sized to $DEVGB GB):"
printf "    p1 ESP       2048 .. %-12s  3.0 GB\n" "$ESP_END"
printf "    p2 metadata  %-12s .. %-12s  32 MB\n" "$MD_START" "$MD_END"
printf "    p3 userdata  %-12s .. %-12s  ~%s GB\n" "$UD_START" "$UD_END" "$(( (UD_END-UD_START)*512/1024/1024/1024 ))"

if [ "$APPLY" != 1 ]; then
  echo; echo "That was the plan only. To write:  sudo $0 $TARGET --apply"; exit 0
fi
if lsblk -no MOUNTPOINT "$TARGET" | grep -q .; then
  echo "STOP: something on $TARGET is mounted — unmount it first."; exit 1
fi

echo; echo "=== 1/5 writing the image"
# NOTE: `dd status=progress` reports how fast data is accepted into the PAGE CACHE, not
# how fast it reaches the medium. With conv=fsync the counter can read 1.2 GB/s and then sit
# frozen for minutes while the flush happens. (2026-09-26: that is exactly how a write that
# really ran at 20 MB/s looked.) So we read written sectors from /sys/block/<dev>/stat,
# which is the actual traffic.
DEVNAME=$(basename "$(readlink -f "$TARGET")")
STAT=/sys/block/$DEVNAME/stat
sec0=$(awk '{print $7}' "$STAT" 2>/dev/null || echo 0)
t0=$(date +%s)
dd if="$IMG" of="$TARGET" bs=4M conv=fsync status=none &
DDPID=$!
while kill -0 "$DDPID" 2>/dev/null; do
  sleep 2
  sec=$(awk '{print $7}' "$STAT" 2>/dev/null || echo "$sec0")
  mb=$(( (sec - sec0) * 512 / 1024 / 1024 ))
  el=$(( $(date +%s) - t0 )); [ "$el" -lt 1 ] && el=1
  pct=$(( mb * 100 / (IMGSZ/1024/1024) )); [ "$pct" -gt 100 ] && pct=100
  printf "\r    %4s MB / %s MB  (%3s%%)  %s MB/s  " "$mb" "$((IMGSZ/1024/1024))" "$pct" "$(( mb / el ))"
done
RC=0; wait "$DDPID" || RC=$?    # explicit, because `set -e` would abort the script on `wait`
printf "\n"
[ "$RC" = 0 ] || { echo "STOP: dd failed with status $RC"; exit 1; }
sync
echo "=== 2/5 moving the backup GPT to the real end of the medium"
sgdisk -e "$TARGET" >/dev/null
partprobe "$TARGET" 2>/dev/null || true; sleep 2
echo "=== 3/5 creating metadata and userdata"
sgdisk -n "2:${MD_START}:${MD_END}" -t 2:8300 -c 2:"metadata" "$TARGET" >/dev/null
sgdisk -n "3:${UD_START}:${UD_END}" -t 3:8300 -c 3:"userdata" "$TARGET" >/dev/null
partprobe "$TARGET" 2>/dev/null || true; sleep 3
P() { case "$TARGET" in *nvme*|*mmcblk*) echo "${TARGET}p$1";; *) echo "${TARGET}$1";; esac; }
for n in 1 2 3; do [ -b "$(P $n)" ] || { echo "STOP: $(P $n) was not created"; exit 1; }; done
echo "=== 4/5 formatting"
mkfs.ext4 -q -F -L metadata -m 0 "$(P 2)"
mkfs.ext4 -q -F -L userdata -M /data -m 0 "$(P 3)"      # NO quota!
sync
echo "=== 5/5 verifying"
sgdisk -p "$TARGET" | tail -5 | sed 's/^/    /'
for n in 2 3; do
  feats=$(tune2fs -l "$(P $n)" 2>/dev/null | grep -i "filesystem features" | sed 's/.*: *//')
  echo "    $(P $n): $(lsblk -dno SIZE $(P $n))"
  echo "$feats" | grep -qw quota && { echo "    STOP: the quota feature is present on $(P $n)"; exit 1; }
done
echo "    OK — no quota feature"
MNT=$(mktemp -d); mount -o ro "$(P 1)" "$MNT" 2>/dev/null && {
  for f in Android/Image Android/qcs6490-radxa-dragon-q6a.dtb Android/system.img \
           Android/firmware/regulatory.db loader/loader.conf loader/entries/a17.conf \
           EFI/BOOT/BOOTAA64.EFI; do
    [ -f "$MNT/$f" ] && echo "    OK  $f" || { echo "    MISSING $f"; umount "$MNT"; exit 1; }
  done
  echo "    loader.conf: $(tr -d '\r' < "$MNT/loader/loader.conf" | tr '\n' ' ')"
  umount "$MNT"
}; rmdir "$MNT"
echo
echo "DONE. $TARGET now carries LineageOS 24 with $(( (UD_END-UD_START)*512/1024/1024/1024 )) GB for /data."
