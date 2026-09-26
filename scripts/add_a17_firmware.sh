#!/bin/bash
#
# add_a17_firmware.sh — dokłada firmware GPU na ESP nosnika A17 i przelacza
# androidboot.mount_firmware na "only_android_dir" we wpisie a17-fix.
#
# PO CO (ustalone z logu UART 2026-09-12, boot a17-display):
#   Po wlaczeniu wyswietlacza agregat msm DRM sklada sie i wiaze GPU:
#     msm_dpu ae01000.display-controller: bound 3d00000.gpu (ops a3xx_ops)
#   ...po czym plyta robi TWARDY RESET (PM: Reset by PSHOLD / Warm Reset) bez zadnego sladu.
#   Przyczyna: &gpu_zap_shader ma firmware-name = "qcom/qcs6490/a660_zap.mbn", a przy
#   mount_firmware=disable katalog /mnt/vendor/firmware NIE ISTNIEJE, wiec zap-shader sie
#   nie laduje. Bez niego GPU zostaje w trybie bezpiecznym i pierwszy dostep do jego
#   rejestrow konczy sie resetem sprzetowym. (Dodatkowo: "supply vdd/vddcx not found".)
#   Ta sama sciezka firmware jest w DZIALAJACYM DTB v7 - plik pasuje 1:1.
#
# UKLAD KATALOGOW (rozny dla zap i reszty!):
#   qcom/qcs6490/a660_zap.mbn   <- dokladnie to, co mowi firmware-name w DT
#   qcom/a660_sqe.fw            <- adreno_request_fw prefiksuje "qcom/"
#   qcom/a660_gmu.bin           <- j.w.
#
# Uzycie: sudo ~/q6a/add_a17_firmware.sh [/dev/sdX | plik.img]
set -euo pipefail

FW_SRC=$HOME/q6a/glodroid/device/glodroid/dragon_q6a/firmware
TARGET="${1:-}"

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

for f in a660_gmu.bin a660_sqe.fw a660_zap.mbn; do
  [ -f "$FW_SRC/$f" ] || { echo "STOP: brak $FW_SRC/$f"; exit 1; }
done

echo "==> tworze katalogi firmware"
for d in ::/Android/firmware ::/Android/firmware/qcom ::/Android/firmware/qcom/qcs6490; do
  mmd -i "$SPEC" "$d" 2>/dev/null || true
done

echo "==> kopiuje bloby"
mcopy -o -i "$SPEC" "$FW_SRC/a660_sqe.fw"  ::/Android/firmware/qcom/a660_sqe.fw
mcopy -o -i "$SPEC" "$FW_SRC/a660_gmu.bin" ::/Android/firmware/qcom/a660_gmu.bin
mcopy -o -i "$SPEC" "$FW_SRC/a660_zap.mbn" ::/Android/firmware/qcom/qcs6490/a660_zap.mbn

# regulatory.db — DUZY ZYSK NA CZASIE BOOTU (zmierzone 2026-09-24: -27 s)
# cfg80211.ko laduje sie w ~2,4 s, czyli ZANIM zamontowany zostanie /vendor. Szuka
# regulatory.db pod firmware_class.path=/mnt/vendor/firmware/ i dostaje -2 (ENOENT),
# mimo ze plik JEST w obrazie w /vendor/firmware/. Po nieudanym ladowaniu cfg80211
# wysyla zdarzenia uevent na /devices/faux/regulatory CO 3,33 s bez konca.
# Skutek: generic_init w drugim przebiegu ueventd wola Poll(..., 5s, true), czyli czeka
# na 5 s CISZY - a cisza nigdy nie nastepuje. Warunek "until there's no new uevents"
# (first_stage_init.cpp:641) jest nie do spelnienia, wiec petla wisi az do twardego
# limitu 30 s z Gerrita #501523.
# Pomiar: apexd-bootstrap 36,64 s -> 9,64 s, adbd 41,62 -> 14,50, bootanim 42,13 -> 15,03.
# AUDIO: firmware ADSP + topologia LPASS (zweryfikowane na sprzecie 2026-09-25)
# Bez adsp.mbn `remoteproc0` (nazwa "adsp") zostaje `offline`, wiec q6apm/GPR nigdy nie
# wstaja i karta ALSA NIE ISTNIEJE (/proc/asound/cards puste).
# Bez topologii komponent APM nie przechodzi probe'a:
#   qcom-apm gprsvc:service:2:1: tplg firmware loading .../QCS6490-Radxa-Dragon-Q6A-tplg.bin failed -2
#   snd-sc8280xp sound: ASoC: failed to instantiate card -2
# UWAGA NA SCIEZKI - SA ROZNE:
#   adsp.mbn -> qcom/qcs6490/radxa/dragon-q6a/   (z wezla remoteproc `firmware-name`)
#   tplg.bin -> qcom/qcs6490/                    (nazwa z `model` karty, BEZ podkatalogu)
AUD_SRC=${AUDIO_FW_SRC:-$HOME/q6a/glodroid/device/glodroid/dragon_q6a/firmware/qcom/qcs6490/radxa/dragon-q6a}
for d in ::/Android/firmware/qcom/qcs6490/radxa ::/Android/firmware/qcom/qcs6490/radxa/dragon-q6a; do
  mmd -i "$SPEC" "$d" 2>/dev/null || true
done
if [ -f "$AUD_SRC/adsp.mbn" ]; then
  mcopy -o -i "$SPEC" "$AUD_SRC/adsp.mbn" ::/Android/firmware/qcom/qcs6490/radxa/dragon-q6a/adsp.mbn
  echo "    audio: adsp.mbn"
else
  echo "    UWAGA: brak $AUD_SRC/adsp.mbn - NIE BEDZIE DZWIEKU"
fi
if [ -f "$AUD_SRC/QCS6490-Radxa-Dragon-Q6A-tplg.bin" ]; then
  mcopy -o -i "$SPEC" "$AUD_SRC/QCS6490-Radxa-Dragon-Q6A-tplg.bin" ::/Android/firmware/qcom/qcs6490/QCS6490-Radxa-Dragon-Q6A-tplg.bin
  echo "    audio: QCS6490-Radxa-Dragon-Q6A-tplg.bin"
else
  echo "    UWAGA: brak topologii - karta ALSA sie nie zainstancjonuje"
fi

REG_SRC=${LINEAGE_OUT:-${LINEAGE_TREE:-$HOME/q6a/lineage}/out/target/product/Generic_arm64}/vendor/firmware
for f in regulatory.db regulatory.db.p7s; do
  if [ -f "$REG_SRC/$f" ]; then
    mcopy -o -i "$SPEC" "$REG_SRC/$f" ::/Android/firmware/$f
    echo "    regulatory: $f"
  else
    echo "    UWAGA: brak $REG_SRC/$f - boot bedzie o ~27 s dluzszy"
  fi
done

echo "==> przelaczam mount_firmware w a17-fix"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mtype -i "$SPEC" ::/loader/entries/a17-fix.conf > "$TMP/a17-fix.conf"
sed -i 's/androidboot\.mount_firmware=disable/androidboot.mount_firmware=only_android_dir/' "$TMP/a17-fix.conf"
grep -q "mount_firmware=only_android_dir" "$TMP/a17-fix.conf" || { echo "STOP: podmiana mount_firmware sie nie udala"; exit 1; }
mcopy -o -i "$SPEC" "$TMP/a17-fix.conf" ::/loader/entries/a17-fix.conf
sync

echo
echo "=== weryfikacja ==="
echo "-- firmware/ --";     mdir -i "$SPEC" ::/Android/firmware | grep -Ei "regulatory|tplg|bytes"
echo "-- audio adsp --";    mdir -i "$SPEC" ::/Android/firmware/qcom/qcs6490/radxa/dragon-q6a 2>/dev/null | grep -Ei "adsp|bytes"
echo "-- qcom/ --";          mdir -i "$SPEC" ::/Android/firmware/qcom | grep -E "a660|bytes"
echo "-- qcom/qcs6490/ --";  mdir -i "$SPEC" ::/Android/firmware/qcom/qcs6490 | grep -E "a660|bytes"
echo "-- wpis a17-fix --"
mtype -i "$SPEC" ::/loader/entries/a17-fix.conf | grep -oE "mount_firmware=[a-z_]*|firmware_class\.path=[^ ]*"
echo
echo "GOTOWE."
