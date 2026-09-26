#!/bin/bash
#
# set_default_entry.sh — sets the default boot entry in loader.conf on the ESP.
#
# WHY: the systemd-boot menu needs a KEYBOARD, and the board has only a touchscreen.
# Jedyny sposob wyboru wpisu to ustawienie go jako domyslnego przed bootem.
#
# Usage: sudo set_default_entry.sh <entry-name> [/dev/sdX | image.img] [timeout]
#   np.   sudo ~/q6a/set_default_entry.sh a17-fix
set -euo pipefail

ENTRY="${1:-}"
[ -n "$ENTRY" ] || { echo "Usage: $0 <entry-name> [/dev/sdX|image.img] [timeout]"; exit 1; }
ENTRY="${ENTRY%.conf}"
TARGET="${2:-}"
TMOUT="${3:-10}"

if [ -z "$TARGET" ]; then
  # Medium detection: shared library (no hardcoded size window).
  source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/q6a_find_media.sh"
  TARGET=$(q6a_find_media) || exit 1
fi
[ -n "$TARGET" ] || { echo "STOP: no medium found."; lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL; exit 1; }

OFF=$(sgdisk -i 1 "$TARGET" 2>/dev/null | awk '/First sector/{print $3}')
[ -n "$OFF" ] || { echo "STOP: cannot read the GPT from $TARGET"; exit 1; }
SPEC="${TARGET}@@$((OFF*512))"

echo "=== target: $TARGET   ESP: $SPEC ==="
echo "=== available entries ==="
AVAIL=$(mdir -b -i "$SPEC" ::/loader/entries 2>/dev/null | sed 's#::/loader/entries/##; s#\.conf$##')
echo "$AVAIL" | sed 's/^/  /'
echo "$AVAIL" | grep -qx "$ENTRY" || { echo; echo "STOP: no entry named '$ENTRY' on the medium"; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
printf 'timeout %s\ndefault %s\n' "$TMOUT" "$ENTRY" > "$TMP/loader.conf"
mcopy -o -i "$SPEC" "$TMP/loader.conf" ::/loader/loader.conf
sync

echo
echo "=== loader.conf na nosniku ==="
mtype -i "$SPEC" ::/loader/loader.conf | sed 's/^/  /'
echo "DONE — the board will boot '$ENTRY' with no keyboard involved."
