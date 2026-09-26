#!/bin/bash
# fix_quiet_entry.sh — naprawia uszkodzony wpis a17-quiet i przywraca bootowalnosc.
#
# CO SIE STALO (2026-09-24): wpis a17-quiet.conf wygenerowalem przez
#   sed 's/$/ quiet loglevel=3/' a17.conf > a17-quiet.conf
# a to dopisuje tekst do KAZDEJ linii pliku, nie tylko do "options":
#   linux      /Android/Image quiet loglevel=3          <-- sciezka nie istnieje
#   initrd     /Android/ramdisk-all-combined.img quiet loglevel=3
#   devicetree /Android/qcs6490-radxa-dragon-q6a.dtb quiet loglevel=3
# systemd-boot nie znajduje jadra, a timeout 0 + brak klawiatury = plyta stoi.
#
# CO ROBI: przywraca domyslny wpis na sprawdzony "a17", kasuje uszkodzony plik
# i tworzy a17-quiet POPRAWNIE (zmieniana jest wylacznie linia "options").
#
# Uzycie: sudo ~/q6a/fix_quiet_entry.sh            <- plan
#         sudo ~/q6a/fix_quiet_entry.sh --apply
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
APPLY=0; TARGET=""
for a in "$@"; do case "$a" in --apply) APPLY=1;; /dev/*) TARGET="$a";; *) echo "nieznany: $a"; exit 1;; esac; done
if [ -z "$TARGET" ]; then
  # Wykrywanie nosnika: wspolna biblioteka (bez zaszytego okna rozmiaru).
  source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/q6a_find_media.sh"
  TARGET=$(q6a_find_media) || exit 1
fi
[ -n "$TARGET" ] || { echo "STOP: nie znalazlem karty."; lsblk -o NAME,SIZE,TRAN,RM; exit 1; }
OFF=$(sgdisk -i 1 "$TARGET" | awk '/First sector/{print $3}')
SPEC="${TARGET}@@$((OFF*512))"
echo "=== cel: $TARGET  ESP: $SPEC ==="
echo "--- obecny loader.conf:"; mtype -i "$SPEC" ::/loader/loader.conf 2>/dev/null | sed 's/^/    /'
echo "--- uszkodzony a17-quiet.conf (pierwsze linie):"
mtype -i "$SPEC" ::/loader/entries/a17-quiet.conf 2>/dev/null | head -4 | sed 's/^/    /' || echo "    (brak pliku)"
if [ "$APPLY" != 1 ]; then echo; echo "PLAN: default -> a17, skasowac a17-quiet, utworzyc go poprawnie."; echo "Wykonaj: sudo $0 --apply"; exit 0; fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo; echo "=== WYKONUJE ==="
mdel -i "$SPEC" ::/loader/entries/a17-quiet.conf 2>/dev/null && echo "  skasowany uszkodzony wpis" || echo "  (nie bylo czego kasowac)"
mtype -i "$SPEC" ::/loader/entries/a17.conf > "$TMP/a17.conf"
# POPRAWNIE: tylko linia zaczynajaca sie od "options"
awk '/^options/ { print $0 " quiet loglevel=3"; next } /^title/ { print "title      LineageOS 24 (Android 17) - cichy"; next } { print }' \
    "$TMP/a17.conf" > "$TMP/a17-quiet.conf"
echo "  --- kontrola przed wgraniem:"
grep -E "^(title|linux|initrd|devicetree)" "$TMP/a17-quiet.conf" | sed 's/^/    /'
for k in linux initrd devicetree; do
  ref=$(grep "^$k" "$TMP/a17.conf"       | awk '{print $2}')
  new=$(grep "^$k" "$TMP/a17-quiet.conf" | awk '{print $2}')
  [ "$ref" = "$new" ] || { echo "  STOP: linia '$k' zmieniona ($ref -> $new)"; exit 1; }
  nf=$(grep "^$k" "$TMP/a17-quiet.conf" | wc -w)
  [ "$nf" -eq 2 ] || { echo "  STOP: linia '$k' ma $nf pol zamiast 2"; exit 1; }
done
echo "  OK - sciezki nietkniete"
mcopy -o -i "$SPEC" "$TMP/a17-quiet.conf" ::/loader/entries/a17-quiet.conf
"$HERE/set_default_entry.sh" a17 "$TARGET" 0
echo
echo "GOTOWE. Plyta wystartuje sprawdzony wpis 'a17'."
echo "Wpis 'a17-quiet' jest teraz poprawny - do przetestowania przez adb, bez wyjmowania karty."
