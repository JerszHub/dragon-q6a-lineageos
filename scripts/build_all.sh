#!/bin/bash
# build_all.sh — builds a flashable image from a tree prepared by setup_tree.sh.
#
#   1. Android and the kernel (build_q6a_a17.sh)
#   2. the AIC8800 Wi-Fi/Bluetooth modules against that kernel (build_aic8800.sh)
#   3. vendor_dlkm again, if the modules differ from the ones in the device tree
#   4. the image (mk_a17_flashable.sh), written to Q6A_IMAGE_DIR (default: ~/q6a)
#
# Step 3 exists because the AIC8800 driver is built outside the kernel tree and must match
# the kernel exactly (vermagic and symbol CRCs); the modules shipped in the device tree only
# match a kernel built from the same commit, config and compiler.
#
# Usage: scripts/build_all.sh [tree] [version]     (defaults: $LINEAGE_TREE or ~/q6a/lineage, "local")
set -euo pipefail
HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
export LINEAGE_TREE=${1:-${LINEAGE_TREE:-$HOME/q6a/lineage}}
VER=${2:-local}
MODS=$LINEAGE_TREE/device/radxa/dragon_q6a/kernel/modules
AIC_OUT=$HOME/q6a/aic8800_build

last_build_ok() {
  local log
  log=$(ls -t "$LINEAGE_TREE"/build_*.log | head -1)
  grep -q "^BUILD_EXIT=0 " "$log" || { echo "STOP: build failed, see $log"; exit 1; }
}

echo "=== 1/4 Android + kernel (several hours on a first build)"
"$HERE/build_q6a_a17.sh"
last_build_ok

echo "=== 2/4 AIC8800 modules"
"$HERE/build_aic8800.sh"

echo "=== 3/4 vendor_dlkm"
changed=0
for m in aic8800_fdrv aic_load_fw aic_btusb; do
  [ -f "$AIC_OUT/$m.ko" ] || { echo "STOP: $AIC_OUT/$m.ko was not built"; exit 1; }
  if ! cmp -s "$AIC_OUT/$m.ko" "$MODS/$m.ko"; then
    cp "$AIC_OUT/$m.ko" "$MODS/$m.ko"
    changed=1
  fi
done
if [ "$changed" = 1 ]; then
  echo "    modules rebuilt for this kernel, repacking vendor_dlkm"
  "$HERE/build_q6a_a17.sh" vendor_dlkmimage
  last_build_ok
else
  echo "    modules identical, nothing to do"
fi

echo "=== 4/4 image"
"$HERE/mk_a17_flashable.sh" "$VER"
