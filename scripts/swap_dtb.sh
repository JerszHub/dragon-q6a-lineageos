#!/bin/bash
#
# swap_dtb.sh — swaps the DTB on the medium between display and no-display variants,
#               without rebuilding anything.
#
# Variants for bisection. Each differs from "display" by EXACTLY ONE status property,
# produced by a dtc round-trip from dtb-display.dtb (verified by diff — see below).
#
#   display    mdss okay   dp okay   gpu okay    <- D: hangs right after "bound 3d00000.gpu" (6/6)
#   nodisplay  mdss disab. dp disab. gpu okay    <- A: boots, but without system_server
#   dpoff      mdss okay   dp DISAB. gpu okay    <- B: czy winne DP, czy sam DPU?
#   gpuoff     mdss okay   dp okay   gpu DISAB.  <- C: czy winno GPU? (msm_drv.c:1026 pomija
#                                                    node unavailable, the aggregate forms without the GPU)
#   lanes      jak display, ale w phy@88e8000: USUNIETE "orientation-switch"
#                                              + DODANE data-lanes = <0 1> w port@0/endpoint
#              <- E: DP lane orientation. phy-qcom-qmp-combo.c:4896 reads data-lanes ONLY
#                 w galezi else - z "orientation-switch" sterownik rejestruje przelacznik
#                 Type-C and waits for an orientation nothing on this board supplies, so
#                 the default NORMAL stands = DP on lanes {3,2}. This board wires {0,1}
#                 (potwierdzone w obu dzialajacych DTB z v7). Stad: AUX czyta EDID,
#                 but the main link never trains (max v_level reached).
#              SKUTEK UBOCZNY: usb3_orientation = NONE -> QMPPHY_MODE_DP_ONLY,
#                 so USB3 SuperSpeed on that PHY disappears. USB2 is unaffected.
#
# Usage: sudo swap_dtb.sh display|nodisplay|dpoff|gpuoff|lanes [/dev/sdX | image.img]
set -euo pipefail

VAR="${1:-}"
case "$VAR" in display|nodisplay|dpoff|gpuoff|lanes) ;; *) echo "Usage: $0 display|nodisplay|dpoff|gpuoff|lanes [target]"; exit 1;; esac
SRC="$HOME/q6a/dtb-${VAR}.dtb"
[ -f "$SRC" ] || { echo "STOP: $SRC not found"; exit 1; }

TARGET="${2:-}"
if [ -z "$TARGET" ]; then
  # Medium detection: shared library (no hardcoded size window).
  source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/q6a_find_media.sh"
  TARGET=$(q6a_find_media) || exit 1
fi
[ -n "$TARGET" ] || { echo "STOP: no medium found."; exit 1; }

OFF=$(sgdisk -i 1 "$TARGET" 2>/dev/null | awk '/First sector/{print $3}')
SPEC="${TARGET}@@$((OFF*512))"
NAME=qcs6490-radxa-dragon-q6a.dtb

echo "=== target: $TARGET ==="
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

# the manifest may now be stale for the DTB — drop the entry so it does not lie
# Manifest key: the partition table GUID, NOT the /dev/sdX letter — the letter depends on
# attach order (2026-09-19 the card moved from sdf to sde and the .sdf manifest was orphaned,
# leaving verify_card_manifest.sh nothing to compare against). For a file image the name is kept.
if [ -b "$TARGET" ]; then
  CARD_ID=$(sgdisk -p "$TARGET" 2>/dev/null | awk -F'): ' '/Disk identifier \(GUID/{print $2}' | tr -d ' ')
  [ -n "$CARD_ID" ] || CARD_ID=$(basename "$TARGET")
else
  CARD_ID=$(basename "$TARGET")
fi
MAN="$HOME/q6a/.a17_sd_manifest.$CARD_ID"
# one-off migration of the old letter-based key, so the computed hashes are not lost
if [ ! -f "$MAN" ] && [ -b "$TARGET" ]; then
  for legacy in $HOME/q6a/.a17_sd_manifest.sd?; do
    [ -f "$legacy" ] || continue
    mv "$legacy" "$MAN"
    echo "=== manifest przeniesiony: $(basename "$legacy") -> $(basename "$MAN") ==="
    break
  done
fi
[ -f "$MAN" ] && sed -i "/^$NAME /d" "$MAN"
echo "DONE. The medium now carries DTB variant: $VAR"
