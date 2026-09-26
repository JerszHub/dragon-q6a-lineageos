#!/bin/bash
#
# update_a17_sd.sh — refreshes the Android 17 images on a medium's ESP (a card or a .img).
#
# WHY A MANIFEST RATHER THAN COMPARING AGAINST THE MEDIUM (changed 2026-09-13):
#   The previous version read every file back from the medium first, to compare
#   checksums. For system.img that is 991 MB read BEFORE writing and as much again after
#   — about 3 GB of traffic per file. Over usbipd USB passthrough that backfired:
#   the adapter reset itself halfway through a read (dmesg: "urb->status -104",
#   "reset high-speed USB device"), a mcopy zawisl w stanie D na martwym uchwycie.
#   Now the checksums of the files last WRITTEN are kept locally and the medium is read
#   ONLY to verify after writing. Traffic drops from ~3 GB per file to ~2 GB, and on a
#   repeat run with nothing changed, to zero.
#
# Usage: sudo update_a17_sd.sh [/dev/sdX | image.img]
#         FORCE=1 sudo ~/q6a/update_a17_sd.sh    # zignoruj manifest, wgraj wszystko
set -uo pipefail

OUT=${LINEAGE_TREE:-$HOME/q6a/lineage}/out/target/product/Generic_arm64
KOBJ=$OUT/obj/KERNEL_OBJ/arch/arm64/boot
TARGET="${1:-}"
FORCE="${FORCE:-0}"

declare -a FILES=(
  "$KOBJ/Image|Image"
  "$KOBJ/dts/qcom/qcs6490-radxa-dragon-q6a.dtb|qcs6490-radxa-dragon-q6a.dtb"
  "$OUT/ramdisk-all-combined.img|ramdisk-all-combined.img"
  "$OUT/system.img|system.img"
  "$OUT/vendor.img|vendor.img"
  "$OUT/vendor_dlkm.img|vendor_dlkm.img"
)

if [ -z "$TARGET" ]; then
  # Medium detection: shared library (no hardcoded size window).
  source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/q6a_find_media.sh"
  TARGET=$(q6a_find_media) || exit 1
fi
[ -n "$TARGET" ] || { echo "STOP: no medium found."; lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL; exit 1; }

OFF=$(sgdisk -i 1 "$TARGET" 2>/dev/null | awk '/First sector/{print $3}')
[ -n "$OFF" ] || { echo "STOP: cannot read the GPT from $TARGET"; exit 1; }
SPEC="${TARGET}@@$((OFF*512))"

# per-medium manifest: the key is the target name (device or file)
# Manifest key: the partition table GUID, NOT the /dev/sdX letter — the letter depends on
# attach order (2026-09-19 the card moved from sdf to sde and the .sdf manifest was orphaned,
# leaving verify_card_manifest.sh nothing to compare against). For a file image the name is kept.
if [ -b "$TARGET" ]; then
  CARD_ID=$(sgdisk -p "$TARGET" 2>/dev/null | awk -F'): ' '/Disk identifier \(GUID/{print $2}' | tr -d ' ')
  [ -n "$CARD_ID" ] || CARD_ID=$(basename "$TARGET")
else
  CARD_ID=$(basename "$TARGET")
fi
MAN="$HOME/q6a/.a17_sd_manifest.$CARD_ID"
# one-off migration of the old letter-based key, so the computed hashes are not lost
if [ ! -f "$MAN" ] && [ -b "$TARGET" ]; then
  for legacy in $HOME/q6a/.a17_sd_manifest.sd?; do
    [ -f "$legacy" ] || continue
    mv "$legacy" "$MAN"
    echo "=== manifest przeniesiony: $(basename "$legacy") -> $(basename "$MAN") ==="
    break
  done
fi
touch "$MAN" 2>/dev/null || true

echo "=== cel: $TARGET   ESP: $SPEC ==="
echo "=== manifest: $MAN ==="
[ "$FORCE" = "1" ] && echo "=== FORCE=1: manifest ignorowany ==="
echo

CHANGED=0
for entry in "${FILES[@]}"; do
  SRC="${entry%%|*}"; NAME="${entry##*|}"
  [ -f "$SRC" ] || { echo "STOP: $SRC not found"; exit 1; }
  SRC_SUM=$(sha256sum "$SRC" | cut -d' ' -f1)
  MB=$(( $(stat -c%s "$SRC") / 1024 / 1024 ))

  if [ "$FORCE" != "1" ] && grep -qx "$NAME $SRC_SUM" "$MAN" 2>/dev/null; then
    printf "  %-38s unchanged\n" "$NAME"
    continue
  fi

  printf "  %-38s wgrywam (%s MB)... " "$NAME" "$MB"
  if ! mcopy -o -i "$SPEC" "$SRC" "::/Android/$NAME"; then
    echo "WRITE FAILED"
    echo "     -> check 'dmesg | tail' — over usbipd the adapter can reset itself."
    echo "     -> if mcopy is stuck in state D: sudo pkill -9 mcopy, then re-attach the medium."
    exit 1
  fi
  sync

  printf "weryfikuje... "
  TMP=$(mktemp -u)
  if ! mcopy -i "$SPEC" "::/Android/$NAME" "$TMP" 2>/dev/null; then
    echo "VERIFY READ FAILED"; rm -f "$TMP"; exit 1
  fi
  GOT=$(sha256sum "$TMP" | cut -d' ' -f1); rm -f "$TMP"
  if [ "$GOT" != "$SRC_SUM" ]; then
    echo "NIEZGODNY!"
    sed -i "/^$NAME /d" "$MAN" 2>/dev/null
    exit 1
  fi
  echo "OK"
  sed -i "/^$NAME /d" "$MAN" 2>/dev/null
  echo "$NAME $SRC_SUM" >> "$MAN"
  CHANGED=$((CHANGED+1))
done

echo
echo "=== wgranych plikow: $CHANGED ==="
mdir -i "$SPEC" ::/Android
echo "DONE."
