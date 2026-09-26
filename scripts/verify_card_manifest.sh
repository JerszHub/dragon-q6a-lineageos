#!/bin/bash
#
# verify_card_manifest.sh — checks whether the medium's content CHANGED SINCE IT WAS WRITTEN.
#
# Unlike verify_card.sh, this compares against the MANIFEST (checksums recorded at the
# moment of writing) rather than against the current source files. Sources get rebuilt,
# porownanie z nimi daje falszywe alarmy - to wlasnie zmylilo pierwszy sprawdzian.
#
# It answers one question: is the medium CORRUPTED (content drifted after writing),
# or merely out of date (the sources moved on).
#
# Usage: sudo verify_card_manifest.sh [/dev/sdX]
set -uo pipefail

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  # Medium detection: shared library (no hardcoded size window).
  source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/q6a_find_media.sh"
  TARGET=$(q6a_find_media) || exit 1
fi
[ -n "$TARGET" ] || { echo "STOP: no medium found."; exit 1; }

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
[ -s "$MAN" ] || { echo "STOP: manifest $MAN not found"; exit 1; }

OFF=$(sgdisk -i 1 "$TARGET" 2>/dev/null | awk '/First sector/{print $3}')
SPEC="${TARGET}@@$((OFF*512))"
echo "=== medium: $TARGET   manifest: $MAN ==="
echo "=== comparing: THE MEDIUM vs WHAT WAS WRITTEN TO IT ==="
echo

BAD=0
while read -r NAME SUM; do
  [ -n "$NAME" ] || continue
  printf "  %-38s " "$NAME"
  TMP=$(mktemp -u)
  if ! mcopy -i "$SPEC" "::/Android/$NAME" "$TMP" 2>/dev/null; then
    echo "UNREADABLE"; BAD=1; continue
  fi
  GOT=$(sha256sum "$TMP" | cut -d' ' -f1); rm -f "$TMP"
  if [ "$GOT" = "$SUM" ]; then echo "OK (nietkniete od zapisu)"
  else echo "CHANGED SINCE WRITING -> CORRUPTION"; BAD=1; fi
done < "$MAN"

echo
if [ "$BAD" = "0" ]; then
  echo "=== RESULT: MEDIUM INTACT ==="
  echo "    Wszystko, co zapisalismy, lezy na niej nietkniete."
  echo "    Differences reported by verify_card.sh came from rebuilt sources, not the medium."
else
  echo "=== RESULT: MEDIUM CORRUPTED — content drifted after writing ==="
fi
