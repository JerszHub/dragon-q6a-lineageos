#!/bin/bash
# read_pstore.sh — reads the kernel log that pstore_blk wrote to the `pstore` partition.
#
# Run it after the board failed to boot, with the card/SSD back in this machine.
# pstore_blk stores records raw, each with a small header; this extracts the readable text.
#
# Usage: sudo read_pstore.sh [/dev/sdX] [output-file]
set -euo pipefail
HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
TARGET=""; OUT=""
for a in "$@"; do case "$a" in /dev/*) TARGET="$a";; *) OUT="$a";; esac; done
if [ -z "$TARGET" ]; then source "$HERE/q6a_find_media.sh"; TARGET=$(q6a_find_media) || exit 1; fi
P() { case "$TARGET" in *nvme*|*mmcblk*) echo "${TARGET}p$1";; *) echo "${TARGET}$1";; esac; }

IDX=""
for n in 4 5 3 2; do
  nm=$(sgdisk -i $n "$TARGET" 2>/dev/null | sed -n "s/^Partition name: *'\(.*\)'$/\1/p")
  [ "$nm" = "pstore" ] && { IDX=$n; break; }
done
[ -n "$IDX" ] || { echo "STOP: no partition named 'pstore' on $TARGET"; exit 1; }
DEV=$(P $IDX)
OUT="${OUT:-$HERE/pstore_$(date +%m%d_%H%M).log}"
SZ=$(blockdev --getsize64 "$DEV")
echo "=== pstore: $DEV  ($(( SZ/1024/1024 )) MB) ==="

RAW=$(mktemp); trap 'rm -f "$RAW"' EXIT
dd if="$DEV" of="$RAW" bs=1M count=$(( SZ/1024/1024 )) status=none

# Is there anything there at all?
if ! grep -qa "[[:print:]]\{40,\}" "$RAW"; then
  echo "  The partition is empty — the kernel wrote nothing."
  echo "  Check that the boot entry carries pstore_blk.blkdev=... and that the medium"
  echo "  is probed before late_initcall (fs/pstore/blk.c:346)."
  exit 1
fi
# Pull out printable runs; kernel console lines carry timestamps like "[    1.234567]".
strings -n 8 "$RAW" > "$OUT"
LINES=$(wc -l < "$OUT")
KERN=$(grep -c "^\[ *[0-9]\+\.[0-9]\+\]" "$OUT" || true)
echo "  written to: $OUT   ($LINES lines, $KERN with kernel timestamps)"
echo
echo "=== last 30 lines with a kernel timestamp ==="
grep "^\[ *[0-9]\+\.[0-9]\+\]" "$OUT" | tail -30 | sed 's/^/  /'
echo
echo "=== anything that looks like the cause ==="
grep -iE "panic|FATAL|Failed to mount|Failed to setup loop|cannot|unable|BUG:|Oops" "$OUT" | tail -20 | sed 's/^/  /' || echo "  (nothing matched)"
