#!/bin/bash
# fetch_firmware.sh — downloads the Qualcomm firmware the board needs from upstream
# linux-firmware, at a pinned commit, and checks each file against firmware/SHA256SUMS.
#
# Every file here is redistributable (LICENSE.qcom in linux-firmware) and byte-identical to
# what the released images ship. The directory layout matches linux-firmware, so
# add_a17_firmware.sh can take the files from their upstream paths.
#
# The AIC8800 Wi-Fi/Bluetooth firmware is not in linux-firmware; it is shipped in
# device/radxa/dragon_q6a/firmware/aic8800/ and installed by the build.
#
# Usage: fetch_firmware.sh [destination]     (default: $LINUX_FW_SRC or ~/q6a/linux-firmware-q6a)
set -euo pipefail
REPO_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
DEST=${1:-${LINUX_FW_SRC:-$HOME/q6a/linux-firmware-q6a}}
# linux-firmware main of 2026-10-17.
LFW_COMMIT=12dfe670ce7c5987a60fab36d974c4a7d2a6eeeb
BASE=https://gitlab.com/kernel-firmware/linux-firmware/-/raw/$LFW_COMMIT

mkdir -p "$DEST"
while read -r sum path; do
  [ -n "$path" ] || continue
  f=$DEST/$path
  if [ -f "$f" ] && [ "$(sha256sum < "$f" | cut -d' ' -f1)" = "$sum" ]; then
    echo "    ok      $path"
    continue
  fi
  mkdir -p "$(dirname "$f")"
  curl -fsSL -o "$f.part" "$BASE/$path" || { echo "STOP: download failed: $path"; exit 1; }
  got=$(sha256sum < "$f.part" | cut -d' ' -f1)
  [ "$got" = "$sum" ] || { rm -f "$f.part"; echo "STOP: checksum mismatch: $path"; exit 1; }
  mv "$f.part" "$f"
  echo "    fetched $path"
done < "$REPO_DIR/firmware/SHA256SUMS"
echo "firmware ready in $DEST"
