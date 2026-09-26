#!/bin/bash
#
# add_a17_firmware.sh — stages firmware on the ESP of an Android 17 medium and switches
# androidboot.mount_firmware na "only_android_dir" we wpisie a17-fix.
#
# PO CO (ustalone z logu UART 2026-09-12, boot a17-display):
#   With the display enabled the msm DRM aggregate forms and binds the GPU:
#     msm_dpu ae01000.display-controller: bound 3d00000.gpu (ops a3xx_ops)
#   ...after which the board HARD RESETS (PM: Reset by PSHOLD / Warm Reset) leaving no trace.
#   Cause: &gpu_zap_shader has firmware-name = "qcom/qcs6490/a660_zap.mbn", and with
#   with mount_firmware=disable the /mnt/vendor/firmware directory DOES NOT EXIST, so the
#   zap shader never loads. Without it the GPU stays in secure mode and the first access
#   to its registers ends in a hardware reset. (Also: "supply vdd/vddcx not found".)
#   The same firmware path is in the WORKING v7 DTB — the file matches exactly.
#
# DIRECTORY LAYOUT (different for zap than for the rest!):
#   qcom/qcs6490/a660_zap.mbn   <- dokladnie to, co mowi firmware-name w DT
#   qcom/a660_sqe.fw            <- adreno_request_fw prefiksuje "qcom/"
#   qcom/a660_gmu.bin           <- j.w.
#
# Usage: sudo add_a17_firmware.sh [/dev/sdX | image.img]
set -euo pipefail

FW_SRC=$HOME/q6a/glodroid/device/glodroid/dragon_q6a/firmware
TARGET="${1:-}"

if [ -z "$TARGET" ]; then
  # Medium detection: shared library (no hardcoded size window).
  source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/q6a_find_media.sh"
  TARGET=$(q6a_find_media) || exit 1
fi
[ -n "$TARGET" ] || { echo "STOP: no medium found."; lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL; exit 1; }

OFF=$(sgdisk -i 1 "$TARGET" 2>/dev/null | awk '/First sector/{print $3}')
[ -n "$OFF" ] || { echo "STOP: cannot read the GPT from $TARGET"; exit 1; }
SPEC="${TARGET}@@$((OFF*512))"
echo "=== cel: $TARGET   ESP: $SPEC ==="

for f in a660_gmu.bin a660_sqe.fw a660_zap.mbn; do
  [ -f "$FW_SRC/$f" ] || { echo "STOP: missing $FW_SRC/$f"; exit 1; }
done

echo "==> creating firmware directories"
for d in ::/Android/firmware ::/Android/firmware/qcom ::/Android/firmware/qcom/qcs6490; do
  mmd -i "$SPEC" "$d" 2>/dev/null || true
done

echo "==> copying blobs"
mcopy -o -i "$SPEC" "$FW_SRC/a660_sqe.fw"  ::/Android/firmware/qcom/a660_sqe.fw
mcopy -o -i "$SPEC" "$FW_SRC/a660_gmu.bin" ::/Android/firmware/qcom/a660_gmu.bin
mcopy -o -i "$SPEC" "$FW_SRC/a660_zap.mbn" ::/Android/firmware/qcom/qcs6490/a660_zap.mbn

# regulatory.db — A LARGE BOOT-TIME SAVING (measured 2026-09-24: 27 seconds)
# cfg80211.ko loads at about 2.4 s, that is BEFORE /vendor is mounted. It looks for
# regulatory.db pod firmware_class.path=/mnt/vendor/firmware/ i dostaje -2 (ENOENT),
# even though the file IS in the image at /vendor/firmware/. Having failed, cfg80211
# emits a uevent on /devices/faux/regulatory EVERY 3.33 s, indefinitely.
# Effect: generic_init's second ueventd pass calls Poll(..., 5s, true), waiting for five
# seconds of SILENCE that never comes. The "until there's no new uevents" condition
# (first_stage_init.cpp:641) cannot be satisfied, so the loop runs until the hard
# limitu 30 s z Gerrita #501523.
# Pomiar: apexd-bootstrap 36,64 s -> 9,64 s, adbd 41,62 -> 14,50, bootanim 42,13 -> 15,03.
# AUDIO: firmware ADSP + topologia LPASS (zweryfikowane na sprzecie 2026-09-25)
# Without adsp.mbn, `remoteproc0` (named "adsp") stays `offline`, so q6apm and GPR never
# come up and there is NO ALSA card at all (/proc/asound/cards is empty).
# Without the topology the APM component fails to probe:
#   qcom-apm gprsvc:service:2:1: tplg firmware loading .../QCS6490-Radxa-Dragon-Q6A-tplg.bin failed -2
#   snd-sc8280xp sound: ASoC: failed to instantiate card -2
# UWAGA NA SCIEZKI - SA ROZNE:
#   adsp.mbn -> qcom/qcs6490/radxa/dragon-q6a/   (z wezla remoteproc `firmware-name`)
#   tplg.bin -> qcom/qcs6490/                    (named after the card's `model`, NO subdirectory)
AUD_SRC=${AUDIO_FW_SRC:-$HOME/q6a/glodroid/device/glodroid/dragon_q6a/firmware/qcom/qcs6490/radxa/dragon-q6a}
for d in ::/Android/firmware/qcom/qcs6490/radxa ::/Android/firmware/qcom/qcs6490/radxa/dragon-q6a; do
  mmd -i "$SPEC" "$d" 2>/dev/null || true
done
if [ -f "$AUD_SRC/adsp.mbn" ]; then
  mcopy -o -i "$SPEC" "$AUD_SRC/adsp.mbn" ::/Android/firmware/qcom/qcs6490/radxa/dragon-q6a/adsp.mbn
  echo "    audio: adsp.mbn"
else
  echo "    WARNING: $AUD_SRC/adsp.mbn missing — THERE WILL BE NO SOUND"
fi
if [ -f "$AUD_SRC/QCS6490-Radxa-Dragon-Q6A-tplg.bin" ]; then
  mcopy -o -i "$SPEC" "$AUD_SRC/QCS6490-Radxa-Dragon-Q6A-tplg.bin" ::/Android/firmware/qcom/qcs6490/QCS6490-Radxa-Dragon-Q6A-tplg.bin
  echo "    audio: QCS6490-Radxa-Dragon-Q6A-tplg.bin"
else
  echo "    WARNING: topology missing — the ALSA card will not instantiate"
fi

REG_SRC=${LINEAGE_OUT:-${LINEAGE_TREE:-$HOME/q6a/lineage}/out/target/product/Generic_arm64}/vendor/firmware
for f in regulatory.db regulatory.db.p7s; do
  if [ -f "$REG_SRC/$f" ]; then
    mcopy -o -i "$SPEC" "$REG_SRC/$f" ::/Android/firmware/$f
    echo "    regulatory: $f"
  else
    echo "    WARNING: $REG_SRC/$f missing — boot will be about 27 s slower"
  fi
done

echo "==> przelaczam mount_firmware w a17-fix"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mtype -i "$SPEC" ::/loader/entries/a17-fix.conf > "$TMP/a17-fix.conf"
sed -i 's/androidboot\.mount_firmware=disable/androidboot.mount_firmware=only_android_dir/' "$TMP/a17-fix.conf"
grep -q "mount_firmware=only_android_dir" "$TMP/a17-fix.conf" || { echo "STOP: the mount_firmware substitution failed"; exit 1; }
mcopy -o -i "$SPEC" "$TMP/a17-fix.conf" ::/loader/entries/a17-fix.conf
sync

echo
echo "=== weryfikacja ==="
echo "-- firmware/ --";     mdir -i "$SPEC" ::/Android/firmware | grep -Ei "regulatory|tplg|bytes"
echo "-- audio adsp --";    mdir -i "$SPEC" ::/Android/firmware/qcom/qcs6490/radxa/dragon-q6a 2>/dev/null | grep -Ei "adsp|bytes"
echo "-- qcom/ --";          mdir -i "$SPEC" ::/Android/firmware/qcom | grep -E "a660|bytes"
echo "-- qcom/qcs6490/ --";  mdir -i "$SPEC" ::/Android/firmware/qcom/qcs6490 | grep -E "a660|bytes"
echo "-- entry a17-fix --"
mtype -i "$SPEC" ::/loader/entries/a17-fix.conf | grep -oE "mount_firmware=[a-z_]*|firmware_class\.path=[^ ]*"
echo
echo "DONE."
