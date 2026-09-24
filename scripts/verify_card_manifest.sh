#!/bin/bash
#
# verify_card_manifest.sh — sprawdza, czy zawartosc karty ZMIENILA SIE OD ZAPISU.
#
# Rozni sie od verify_card.sh tym, ze porownuje z MANIFESTEM (sumy zapisane w chwili
# wgrywania), a nie z biezacymi plikami zrodlowymi. Zrodla sa przebudowywane, wiec
# porownanie z nimi daje falszywe alarmy - to wlasnie zmylilo pierwszy sprawdzian.
#
# Odpowiada na pytanie: czy nosnik jest USZKODZONY (tresc sie rozjechala po zapisie),
# czy tylko nieaktualny (zrodla poszly do przodu).
#
# Uzycie: sudo ~/q6a/verify_card_manifest.sh [/dev/sdX]
set -uo pipefail

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  for d in /dev/sd?; do
    [ -b "$d" ] || continue
    # Dyski systemowe odsiewamy po TYM CZYM SA, nie po literze: litera /dev/sdX zalezy od
    # kolejnosci podpinania i sie zmienia (2026-09-19: karta wyszla jako /dev/sde, czyli
    # dokladnie na dawnej czarnej liscie -> wszystkie te skrypty mowily "nie znalazlem karty").
    [ "$(lsblk -dno RM "$d" 2>/dev/null | tr -d '[:space:]')" = "1" ] || continue
    [ "$(lsblk -dno TRAN "$d" 2>/dev/null | tr -d '[:space:]')" = "usb" ] || continue
    GB=$(( $(lsblk -bdno SIZE "$d" 2>/dev/null || echo 0) / 1024/1024/1024 ))
    if [ "$GB" -ge 200 ] && [ "$GB" -le 300 ]; then TARGET="$d"; break; fi
  done
fi
[ -n "$TARGET" ] || { echo "STOP: nie znalazlem karty."; exit 1; }

# Klucz manifestu: GUID tablicy partycji, NIE litera /dev/sdX - litera zalezy od kolejnosci
# podpinania (2026-09-19 karta przeszla z sdf na sde i manifest .sdf sie osierocil, przez co
# verify_card_manifest.sh nie mial z czym porownywac). Dla obrazu w pliku zostaje nazwa pliku.
if [ -b "$TARGET" ]; then
  CARD_ID=$(sgdisk -p "$TARGET" 2>/dev/null | awk -F'): ' '/Disk identifier \(GUID/{print $2}' | tr -d ' ')
  [ -n "$CARD_ID" ] || CARD_ID=$(basename "$TARGET")
else
  CARD_ID=$(basename "$TARGET")
fi
MAN="$HOME/q6a/.a17_sd_manifest.$CARD_ID"
# jednorazowa migracja starego klucza po literze, zeby nie zgubic policzonych hashy
if [ ! -f "$MAN" ] && [ -b "$TARGET" ]; then
  for legacy in $HOME/q6a/.a17_sd_manifest.sd?; do
    [ -f "$legacy" ] || continue
    mv "$legacy" "$MAN"
    echo "=== manifest przeniesiony: $(basename "$legacy") -> $(basename "$MAN") ==="
    break
  done
fi
[ -s "$MAN" ] || { echo "STOP: brak manifestu $MAN"; exit 1; }

OFF=$(sgdisk -i 1 "$TARGET" 2>/dev/null | awk '/First sector/{print $3}')
SPEC="${TARGET}@@$((OFF*512))"
echo "=== nosnik: $TARGET   manifest: $MAN ==="
echo "=== porownanie: KARTA vs TO, CO NA NIA ZAPISANO ==="
echo

BAD=0
while read -r NAME SUM; do
  [ -n "$NAME" ] || continue
  printf "  %-38s " "$NAME"
  TMP=$(mktemp -u)
  if ! mcopy -i "$SPEC" "::/Android/$NAME" "$TMP" 2>/dev/null; then
    echo "NIE DA SIE ODCZYTAC"; BAD=1; continue
  fi
  GOT=$(sha256sum "$TMP" | cut -d' ' -f1); rm -f "$TMP"
  if [ "$GOT" = "$SUM" ]; then echo "OK (nietkniete od zapisu)"
  else echo "ZMIENILO SIE PO ZAPISIE -> USZKODZENIE"; BAD=1; fi
done < "$MAN"

echo
if [ "$BAD" = "0" ]; then
  echo "=== WYNIK: KARTA NIEUSZKODZONA ==="
  echo "    Wszystko, co zapisalismy, lezy na niej nietkniete."
  echo "    Rozbieznosci w verify_card.sh brały się z przebudowanych zrodel, nie z nosnika."
else
  echo "=== WYNIK: NOSNIK USZKODZONY - tresc rozjechala sie po zapisie ==="
fi
