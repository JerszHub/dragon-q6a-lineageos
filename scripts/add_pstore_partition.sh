#!/bin/bash
# add_pstore_partition.sh — adds a `pstore` partition so the kernel writes its console log
#                           and panic dumps straight to the medium, readable afterwards
#                           by putting the card/SSD into a PC.
#
# WHY: when the board fails early, there is nothing to read. The screen shows nothing
# (generic_init dies before the msm DRM driver binds, so the console has no framebuffer),
# adb never comes up, and a reboot loop erases whatever was there. A pstore partition
# survives both a reboot and a power cut.
#
# HOW IT WORKS (verified in fs/pstore/blk.c):
#   - pstore_blk.blkdev= accepts PARTUUID=..., resolved by early_lookup_bdev, the same
#     mechanism used to find the root filesystem (blk.c:268)
#   - pstore_blk.best_effort=Y is required to write without storage-driver support (blk.c:289)
#   - console_size records the console CONTINUOUSLY, not only a dump at panic time,
#     which is what makes a full boot log available afterwards
#   - registration happens at late_initcall (blk.c:346), so the medium must already be probed
#
# ⚠️ pstore_blk writes RAW to the partition. It must not share space with anything else.
# ⚠️ userdata is RECREATED smaller. On a fresh install it is empty; if you have data on it,
#    do not run this.
#
# Usage: sudo add_pstore_partition.sh [/dev/sdX]           <- plan only
#        sudo add_pstore_partition.sh [/dev/sdX] --apply
set -euo pipefail
HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
APPLY=0; TARGET=""; PSTORE_MB=64
for a in "$@"; do case "$a" in --apply) APPLY=1;; /dev/*) TARGET="$a";; *) echo "unknown argument: $a"; exit 1;; esac; done
if [ -z "$TARGET" ]; then source "$HERE/q6a_find_media.sh"; TARGET=$(q6a_find_media) || exit 1; fi
P() { case "$TARGET" in *nvme*|*mmcblk*) echo "${TARGET}p$1";; *) echo "${TARGET}$1";; esac; }

DEVSZ=$(blockdev --getsz "$TARGET")
UD_START=$(sgdisk -i 3 "$TARGET" | awk '/First sector/{print $3}')
UD_END_OLD=$(sgdisk -i 3 "$TARGET" | awk '/Last sector/{print $3}')
N3=$(sgdisk -i 3 "$TARGET" | sed -n "s/^Partition name: *'\(.*\)'$/\1/p")
PS_SECT=$(( PSTORE_MB * 1024 * 1024 / 512 ))
PS_START=$(( ((DEVSZ - 34 - PS_SECT) / 2048) * 2048 ))
PS_END=$(( DEVSZ - 34 ))
UD_END_NEW=$(( PS_START - 1 ))

echo "=== target: $TARGET ==="
sgdisk -p "$TARGET" | tail -5 | sed 's/^/  /'
echo
[ "$N3" = "userdata" ] || { echo "STOP: partition 3 is '$N3', expected 'userdata'"; exit 1; }
echo "--- planned change:"
printf "    p3 userdata  %s .. %s  ->  %s .. %s   (%s GB, was %s GB)\n" \
  "$UD_START" "$UD_END_OLD" "$UD_START" "$UD_END_NEW" \
  "$(( (UD_END_NEW-UD_START)*512/1024/1024/1024 ))" "$(( (UD_END_OLD-UD_START)*512/1024/1024/1024 ))"
printf "    p4 pstore    %s .. %s   (%s MB, NEW)\n" "$PS_START" "$PS_END" "$PSTORE_MB"
echo
echo "--- is userdata empty? (it is recreated, so anything on it is lost)"
UD=$(P 3); MNT=$(mktemp -d)
if mount -o ro "$UD" "$MNT" 2>/dev/null; then
  N=$(find "$MNT" -mindepth 1 -maxdepth 2 ! -name 'lost+found' 2>/dev/null | wc -l)
  echo "    entries on userdata: $N"
  [ "$N" -gt 4 ] && echo "    ⚠️ THERE IS DATA HERE — check before continuing"
  umount "$MNT"
else
  echo "    (could not mount — unformatted or already in use)"
fi
rmdir "$MNT" 2>/dev/null || true

if [ "$APPLY" != 1 ]; then echo; echo "Plan only. To apply: sudo $0 $TARGET --apply"; exit 0; fi
if lsblk -no MOUNTPOINT "$TARGET" | grep -q .; then echo "STOP: something on $TARGET is mounted."; exit 1; fi

echo; echo "=== APPLYING ==="
sgdisk -d 3 "$TARGET" >/dev/null
sgdisk -n "3:${UD_START}:${UD_END_NEW}" -t 3:8300 -c 3:"userdata" "$TARGET" >/dev/null
sgdisk -n "4:${PS_START}:${PS_END}"     -t 4:8300 -c 4:"pstore"   "$TARGET" >/dev/null
partprobe "$TARGET" 2>/dev/null || true; sleep 3
for n in 3 4; do [ -b "$(P $n)" ] || { echo "STOP: $(P $n) was not created"; exit 1; }; done
mkfs.ext4 -q -F -L userdata -M /data -m 0 "$(P 3)"      # no quota, see flash_a17.sh
# pstore gets NO filesystem on purpose — the kernel writes to it raw.
dd if=/dev/zero of="$(P 4)" bs=1M count=$PSTORE_MB conv=fsync status=none
PS_UUID=$(sgdisk -i 4 "$TARGET" | awk '/Partition unique GUID/{print $4}')
echo "  pstore PARTUUID: $PS_UUID"

# Add the pstore parameters to the diagnostic entry.
OFF=$(sgdisk -i 1 "$TARGET" | awk '/First sector/{print $3}'); SPEC="${TARGET}@@$((OFF*512))"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mtype -i "$SPEC" ::/loader/entries/a17-halt.conf > "$TMP/in.conf" 2>/dev/null \
  || { echo "STOP: a17-halt.conf not found — run add_halt_entry.sh first"; exit 1; }
awk -v uuid="$PS_UUID" '
  /^options/ { line=$0
               gsub(/ pstore_blk\.[^ ]*/, "", line)
               print line " pstore_blk.blkdev=PARTUUID=" uuid \
                          " pstore_blk.best_effort=Y pstore_blk.console_size=8192" \
                          " pstore_blk.kmsg_size=2048"; next }
             { print }
' "$TMP/in.conf" > "$TMP/a17-halt.conf"
bad=$(awk '($1=="linux"||$1=="initrd"||$1=="devicetree") && NF!=2' "$TMP/a17-halt.conf")
[ -z "$bad" ] || { echo "STOP: malformed entry: $bad"; exit 1; }
mcopy -o -i "$SPEC" "$TMP/a17-halt.conf" ::/loader/entries/a17-halt.conf
sync

echo
echo "=== AFTER ==="
sgdisk -p "$TARGET" | tail -6 | sed 's/^/  /'
grep -o "pstore_blk\.[^ ]*" "$TMP/a17-halt.conf" | sed 's/^/  /'
echo
echo "DONE. Boot the board, let it fail, then bring the medium back and run:"
echo "  sudo $HERE/read_pstore.sh $TARGET"
