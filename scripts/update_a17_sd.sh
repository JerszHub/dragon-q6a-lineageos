#!/bin/bash
#
# update_a17_sd.sh — aktualizuje obrazy A17 na ESP nosnika (karta lub plik .img).
#
# DLACZEGO MANIFEST, A NIE PORONWANIE Z NOSNIKIEM (zmiana 2026-09-13):
#   Poprzednia wersja dla KAZDEGO pliku najpierw odczytywala jego kopie z karty, zeby
#   porownac sumy. Przy system.img to 991 MB odczytu PRZED zapisem i drugie tyle po nim
#   - okolo 3 GB ruchu na jeden plik. Przy przekazywaniu USB przez usbipd to sie zemscilo:
#   adapter zresetowal sie w polowie odczytu (dmesg: "urb->status -104",
#   "reset high-speed USB device"), a mcopy zawisl w stanie D na martwym uchwycie.
#   Teraz pamietamy sumy ostatnio WGRANYCH plikow lokalnie i nosnik czytamy TYLKO
#   do weryfikacji po zapisie. Ruch spada z ~3 GB na plik do ~2 GB, a przy powtornym
#   uruchomieniu bez zmian - do zera.
#
# Uzycie: sudo ~/q6a/update_a17_sd.sh [/dev/sdX | plik.img]
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
[ -n "$TARGET" ] || { echo "STOP: nie znalazlem karty SD 200-300 GB."; lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL; exit 1; }

OFF=$(sgdisk -i 1 "$TARGET" 2>/dev/null | awk '/First sector/{print $3}')
[ -n "$OFF" ] || { echo "STOP: nie czytam GPT z $TARGET"; exit 1; }
SPEC="${TARGET}@@$((OFF*512))"

# manifest per-nosnik: klucz = nazwa celu (urzadzenie albo plik)
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
touch "$MAN" 2>/dev/null || true

echo "=== cel: $TARGET   ESP: $SPEC ==="
echo "=== manifest: $MAN ==="
[ "$FORCE" = "1" ] && echo "=== FORCE=1: manifest ignorowany ==="
echo

CHANGED=0
for entry in "${FILES[@]}"; do
  SRC="${entry%%|*}"; NAME="${entry##*|}"
  [ -f "$SRC" ] || { echo "STOP: brak $SRC"; exit 1; }
  SRC_SUM=$(sha256sum "$SRC" | cut -d' ' -f1)
  MB=$(( $(stat -c%s "$SRC") / 1024 / 1024 ))

  if [ "$FORCE" != "1" ] && grep -qx "$NAME $SRC_SUM" "$MAN" 2>/dev/null; then
    printf "  %-38s bez zmian\n" "$NAME"
    continue
  fi

  printf "  %-38s wgrywam (%s MB)... " "$NAME" "$MB"
  if ! mcopy -o -i "$SPEC" "$SRC" "::/Android/$NAME"; then
    echo "BLAD ZAPISU"
    echo "     -> sprawdz 'dmesg | tail' - przy usbipd adapter potrafi sie zresetowac."
    echo "     -> jesli mcopy zawisl w stanie D: sudo pkill -9 mcopy, odepnij/podepnij nosnik."
    exit 1
  fi
  sync

  printf "weryfikuje... "
  TMP=$(mktemp -u)
  if ! mcopy -i "$SPEC" "::/Android/$NAME" "$TMP" 2>/dev/null; then
    echo "BLAD ODCZYTU KONTROLNEGO"; rm -f "$TMP"; exit 1
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
echo "GOTOWE."
