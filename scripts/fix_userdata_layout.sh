#!/bin/bash
# fix_userdata_layout.sh — adds the missing "metadata" partition that std_parts requires.
#
# THE CAUSE (found in the sources, not guessed):
#   vendor/mainline/services/generic_init/dynamic_mount_handler.cpp:123
#     const std::list<std::string> android_userdata_partitions = {"cache","userdata","metadata"};
#   ...:701
#     for (const auto& [part, bdev] : android_userdata_part_to_bdev_map) {
#         if (part == "cache" && !need_mount_cache) continue;   // cache HAS an exception
#         if (bdev == nullptr) return false;                    // metadata does NOT
#     }
# So androidboot.mount_userdata=std_parts needs GPT partitions named both "userdata"
# AND "metadata". We had created only userdata, so generic_init waited for a block
# device that never appeared and boot never reached post-fs-data — hence no network and
# no adb, which is why the UART went silent and nothing answered ARP.
#
# "cache" is genuinely unnecessary: need_mount_cache is only set when the mounted system
# contains a /cache directory (:528), and our system.img does not (verified).
#
# LAYOUT: p1 ESP is left UNTOUCHED. p2 metadata 32 MB, p3 userdata takes the rest.
# The userdata partition is recreated from scratch — there is nothing of value on it
# (vold had created empty media directories, nothing more).
#
# Usage: sudo fix_userdata_layout.sh [/dev/sdX]          <- plan only
#         sudo fix_userdata_layout.sh [/dev/sdX] --apply
set -euo pipefail
APPLY=0; TARGET=""
for a in "$@"; do case "$a" in --apply) APPLY=1;; /dev/*) TARGET="$a";; *) echo "unknown argument: $a"; exit 1;; esac; done
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/q6a_find_media.sh"
if [ -z "$TARGET" ]; then
  # Medium detection: shared library (no hardcoded size window).
  source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/q6a_find_media.sh"
  TARGET=$(q6a_find_media) || exit 1
fi
[ -n "$TARGET" ] || { echo "STOP: no medium found."; exit 1; }

P1END=$(sgdisk -i 1 "$TARGET" | awk '/Last sector/{print $3}')
P1NAME=$(sgdisk -i 1 "$TARGET" | sed -n "s/^Partition name: *'\(.*\)'$/\1/p")
DEVSZ=$(blockdev --getsz "$TARGET")
MD_START=$(( ((P1END + 1 + 2047) / 2048) * 2048 ))
MD_END=$(( MD_START + 65536 - 1 ))              # 32 MB
UD_START=$(( MD_END + 1 ))
UD_END=$(( DEVSZ - 34 ))

echo "=== target: $TARGET ==="
echo "  p1 $P1NAME (UNTOUCHED): ... $P1END"
echo "  p2 metadata : $MD_START .. $MD_END   (32 MB)"
echo "  p3 userdata : $UD_START .. $UD_END   (~$(( (UD_END-UD_START)*512/1024/1024/1024 )) GB)"
[ "$P1NAME" = "ESP" ] || { echo "STOP: partition 1 is not ESP — aborting."; exit 1; }

if [ "$APPLY" != "1" ]; then echo; echo "That was the plan only. To apply: sudo $0 $TARGET --apply"; exit 0; fi
if lsblk -no MOUNTPOINT "$TARGET" | grep -q .; then echo "STOP: something on $TARGET is mounted."; exit 1; fi

echo; echo "=== APPLYING ==="
sgdisk -d 2 "$TARGET" >/dev/null 2>&1 || true
sgdisk -d 3 "$TARGET" >/dev/null 2>&1 || true
sgdisk -n "2:${MD_START}:${MD_END}" -t 2:8300 -c 2:"metadata" "$TARGET" >/dev/null
sgdisk -n "3:${UD_START}:${UD_END}" -t 3:8300 -c 3:"userdata" "$TARGET" >/dev/null
partprobe "$TARGET" 2>/dev/null || true; sleep 2
for n in 2 3; do [ -b "$(q6a_part "$TARGET" $n)" ] || { echo "STOP: $(q6a_part "$TARGET" $n) was not created"; exit 1; }; done
mkfs.ext4 -q -L metadata -m 0 "$(q6a_part "$TARGET" 2)"
mkfs.ext4 -q -L userdata -m 0 "$(q6a_part "$TARGET" 3)"

echo; echo "=== AFTER ==="
sgdisk -p "$TARGET" | tail -4 | sed 's/^/  /'
for n in 2 3; do
  D=$(q6a_part "$TARGET" $n); echo "  $D: $(lsblk -dno SIZE $D)  $(blkid -s LABEL -o value $D 2>/dev/null)"
done
echo
echo "DONE. Select the entry with: sudo set_default_entry.sh a17"
echo "Back to tmpfs if it fails: sudo set_default_entry.sh a17-pdclk"
