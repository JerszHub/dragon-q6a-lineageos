#!/bin/bash
# fix_quiet_entry.sh — repairs a malformed a17-quiet entry and restores bootability.
#
# WHAT HAPPENED (2026-09-24): a17-quiet.conf was generated with
#   sed 's/$/ quiet loglevel=3/' a17.conf > a17-quiet.conf
# which appends the text to EVERY line of the file, not just to "options":
#   linux      /Android/Image quiet loglevel=3          <-- that path does not exist
#   initrd     /Android/ramdisk-all-combined.img quiet loglevel=3
#   devicetree /Android/qcs6490-radxa-dragon-q6a.dtb quiet loglevel=3
# systemd-boot cannot find the kernel, and timeout 0 with no keyboard leaves the board stuck.
#
# WHAT IT DOES: restores the default entry to the known-good "a17", deletes the broken
# file and recreates a17-quiet CORRECTLY (only the "options" line is modified).
#
# Usage: sudo fix_quiet_entry.sh            <- plan
#         sudo fix_quiet_entry.sh --apply
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
APPLY=0; TARGET=""
for a in "$@"; do case "$a" in --apply) APPLY=1;; /dev/*) TARGET="$a";; *) echo "unknown argument: $a"; exit 1;; esac; done
if [ -z "$TARGET" ]; then
  # Medium detection: shared library (no hardcoded size window).
  source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/q6a_find_media.sh"
  TARGET=$(q6a_find_media) || exit 1
fi
[ -n "$TARGET" ] || { echo "STOP: no medium found."; lsblk -o NAME,SIZE,TRAN,RM; exit 1; }
OFF=$(sgdisk -i 1 "$TARGET" | awk '/First sector/{print $3}')
SPEC="${TARGET}@@$((OFF*512))"
echo "=== cel: $TARGET  ESP: $SPEC ==="
echo "--- current loader.conf:"; mtype -i "$SPEC" ::/loader/loader.conf 2>/dev/null | sed 's/^/    /'
echo "--- malformed a17-quiet.conf (first lines):"
mtype -i "$SPEC" ::/loader/entries/a17-quiet.conf 2>/dev/null | head -4 | sed 's/^/    /' || echo "    (file not present)"
if [ "$APPLY" != 1 ]; then echo; echo "PLAN: default -> a17, delete a17-quiet, recreate it correctly."; echo "Run: sudo $0 --apply"; exit 0; fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo; echo "=== APPLYING ==="
mdel -i "$SPEC" ::/loader/entries/a17-quiet.conf 2>/dev/null && echo "  removed the malformed entry" || echo "  (nothing to remove)"
mtype -i "$SPEC" ::/loader/entries/a17.conf > "$TMP/a17.conf"
# CORRECTLY: only the line starting with "options"
awk '/^options/ { print $0 " quiet loglevel=3"; next } /^title/ { print "title      LineageOS 24 (Android 17) - cichy"; next } { print }' \
    "$TMP/a17.conf" > "$TMP/a17-quiet.conf"
echo "  --- check before writing:"
grep -E "^(title|linux|initrd|devicetree)" "$TMP/a17-quiet.conf" | sed 's/^/    /'
for k in linux initrd devicetree; do
  ref=$(grep "^$k" "$TMP/a17.conf"       | awk '{print $2}')
  new=$(grep "^$k" "$TMP/a17-quiet.conf" | awk '{print $2}')
  [ "$ref" = "$new" ] || { echo "  STOP: line '$k' was changed ($ref -> $new)"; exit 1; }
  nf=$(grep "^$k" "$TMP/a17-quiet.conf" | wc -w)
  [ "$nf" -eq 2 ] || { echo "  STOP: line '$k' has $nf fields instead of 2"; exit 1; }
done
echo "  OK — paths untouched"
mcopy -o -i "$SPEC" "$TMP/a17-quiet.conf" ::/loader/entries/a17-quiet.conf
"$HERE/set_default_entry.sh" a17 "$TARGET" 0
echo
echo "DONE. The board will boot the known-good 'a17' entry."
echo "The 'a17-quiet' entry is now correct — test it over adb, no need to remove the card."
