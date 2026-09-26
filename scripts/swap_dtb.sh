#!/bin/bash
#
# swap_dtb.sh — podmienia DTB na karcie miedzy wariantem Z wyswietlaczem i BEZ, bez przebudowy.
#
# Warianty do bisekcji. Kazdy rozni sie od "display" DOKLADNIE JEDNA wlasciwoscia status,
# zrobione przez dtc round-trip z dtb-display.dtb (zweryfikowane diffem - patrz nizej).
#
#   display    mdss okay   dp okay   gpu okay    <- D: wiesza sie tuz po "bound 3d00000.gpu" (6/6)
#   nodisplay  mdss disab. dp disab. gpu okay    <- A: wstaje, ale bez system_server
#   dpoff      mdss okay   dp DISAB. gpu okay    <- B: czy winne DP, czy sam DPU?
#   gpuoff     mdss okay   dp okay   gpu DISAB.  <- C: czy winno GPU? (msm_drv.c:1026 pomija
#                                                    niedostepny wezel, agregat sklada sie bez GPU)
#   lanes      jak display, ale w phy@88e8000: USUNIETE "orientation-switch"
#                                              + DODANE data-lanes = <0 1> w port@0/endpoint
#              <- E: orientacja linii DP. phy-qcom-qmp-combo.c:4896 czyta data-lanes TYLKO
#                 w galezi else - z "orientation-switch" sterownik rejestruje przelacznik
#                 Type-C i czeka na orientacje, ktorej na tej plycie nikt nie poda, wiec
#                 zostaje domyslny NORMAL = DP na liniach {3,2}. Plyta ma je na {0,1}
#                 (potwierdzone w obu dzialajacych DTB z v7). Stad: AUX czyta EDID,
#                 ale glowne lacze nie trenuje (max v_level reached).
#              SKUTEK UBOCZNY: usb3_orientation = NONE -> QMPPHY_MODE_DP_ONLY,
#                 czyli USB3 SuperSpeed na tym PHY znika. USB2 bez zmian.
#
# Uzycie: sudo ~/q6a/swap_dtb.sh display|nodisplay|dpoff|gpuoff|lanes [/dev/sdX | plik.img]
set -euo pipefail

VAR="${1:-}"
case "$VAR" in display|nodisplay|dpoff|gpuoff|lanes) ;; *) echo "Uzycie: $0 display|nodisplay|dpoff|gpuoff|lanes [cel]"; exit 1;; esac
SRC="$HOME/q6a/dtb-${VAR}.dtb"
[ -f "$SRC" ] || { echo "STOP: brak $SRC"; exit 1; }

TARGET="${2:-}"
if [ -z "$TARGET" ]; then
  # Wykrywanie nosnika: wspolna biblioteka (bez zaszytego okna rozmiaru).
  source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/q6a_find_media.sh"
  TARGET=$(q6a_find_media) || exit 1
fi
[ -n "$TARGET" ] || { echo "STOP: nie znalazlem karty."; exit 1; }

OFF=$(sgdisk -i 1 "$TARGET" 2>/dev/null | awk '/First sector/{print $3}')
SPEC="${TARGET}@@$((OFF*512))"
NAME=qcs6490-radxa-dragon-q6a.dtb

echo "=== cel: $TARGET ==="
echo "=== wgrywam wariant: $VAR ($(stat -c%s "$SRC") B) ==="
mcopy -o -i "$SPEC" "$SRC" "::/Android/$NAME"
sync

TMP=$(mktemp -u); trap 'rm -f "$TMP"' EXIT
mcopy -i "$SPEC" "::/Android/$NAME" "$TMP"
if [ "$(sha256sum "$TMP" | cut -d' ' -f1)" = "$(sha256sum "$SRC" | cut -d' ' -f1)" ]; then
  echo "=== OK (bajt w bajt) ==="
else
  echo "=== NIEZGODNY! ==="; exit 1
fi

# manifest moze byc teraz nieaktualny dla DTB - usun wpis, zeby nie klamal
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
[ -f "$MAN" ] && sed -i "/^$NAME /d" "$MAN"
echo "GOTOWE. Na karcie jest teraz DTB: $VAR"
