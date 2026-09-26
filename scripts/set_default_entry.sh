#!/bin/bash
#
# set_default_entry.sh — ustawia domyslny wpis rozruchowy w loader.conf na ESP.
#
# PO CO: menu systemd-boot wymaga KLAWIATURY, a plyta ma tylko ekran dotykowy.
# Jedyny sposob wyboru wpisu to ustawienie go jako domyslnego przed bootem.
#
# Uzycie: sudo ~/q6a/set_default_entry.sh <nazwa-wpisu> [/dev/sdX | plik.img] [timeout]
#   np.   sudo ~/q6a/set_default_entry.sh a17-fix
set -euo pipefail

ENTRY="${1:-}"
[ -n "$ENTRY" ] || { echo "Uzycie: $0 <nazwa-wpisu> [/dev/sdX|plik.img] [timeout]"; exit 1; }
ENTRY="${ENTRY%.conf}"
TARGET="${2:-}"
TMOUT="${3:-10}"

if [ -z "$TARGET" ]; then
  # Wykrywanie nosnika: wspolna biblioteka (bez zaszytego okna rozmiaru).
  source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/q6a_find_media.sh"
  TARGET=$(q6a_find_media) || exit 1
fi
[ -n "$TARGET" ] || { echo "STOP: nie znalazlem karty SD 200-300 GB."; lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL; exit 1; }

OFF=$(sgdisk -i 1 "$TARGET" 2>/dev/null | awk '/First sector/{print $3}')
[ -n "$OFF" ] || { echo "STOP: nie czytam GPT z $TARGET"; exit 1; }
SPEC="${TARGET}@@$((OFF*512))"

echo "=== cel: $TARGET   ESP: $SPEC ==="
echo "=== dostepne wpisy ==="
AVAIL=$(mdir -b -i "$SPEC" ::/loader/entries 2>/dev/null | sed 's#::/loader/entries/##; s#\.conf$##')
echo "$AVAIL" | sed 's/^/  /'
echo "$AVAIL" | grep -qx "$ENTRY" || { echo; echo "STOP: brak wpisu '$ENTRY' na nosniku"; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
printf 'timeout %s\ndefault %s\n' "$TMOUT" "$ENTRY" > "$TMP/loader.conf"
mcopy -o -i "$SPEC" "$TMP/loader.conf" ::/loader/loader.conf
sync

echo
echo "=== loader.conf na nosniku ==="
mtype -i "$SPEC" ::/loader/loader.conf | sed 's/^/  /'
echo "GOTOWE - plyta wystartuje '$ENTRY' bez udzialu klawiatury."
