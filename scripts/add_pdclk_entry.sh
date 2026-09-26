#!/bin/bash
#
# add_pdclk_entry.sh — boot entry 'a17-pdclk': stops unused power domains and clocks from
#
# PODSTAWA (log uart_dpoff_1723.log):
#   [ 3.001749] PM: genpd: Disabling unused power domains
#               clk: Disabling unused clocks
#   [51.717267] generic_init: Loading module /vendor_dlkm/lib/modules/msm.ko
#   [52.481372] msm_dpu ae01000.display-controller: bound 3d00000.gpu
#   [52.510398] Console: switching to colour dummy device 80x25   <- last line, then PSHOLD
#
# So the kernel powers down the MDSS domain and its clocks three seconds in, while the msm
# 48 SECONDS LATER. Nothing holds a reference in between, because simpledrm is disabled
# driver arrives much later. If bringing the GDSC up in pm_runtime_get_sync() does not reach
# through, the first DPU register read happens with no clock -> watchdog -> PSHOLD, no panic.
# This also explains the non-determinism: whether the domain is powered down depends on
# whether anything holds a reference at the 3 s mark, which varies with module load order.
#
# Oba parametry sa w NASZYM jadrze: pd_ignore_unused (drivers/pmdomain/core.c:1367),
# clk_ignore_unused (drivers/clk/clk.c:1512).
#
# NOTE: the DTB stays on dpoff so that EXACTLY ONE thing changes against the previous boot.
#
# Usage: sudo add_pdclk_entry.sh [/dev/sdX | image.img]
set -euo pipefail

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  # Medium detection: shared library (no hardcoded size window).
  source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/q6a_find_media.sh"
  TARGET=$(q6a_find_media) || exit 1
fi
[ -n "$TARGET" ] || { echo "STOP: no card found."; exit 1; }

OFF=$(sgdisk -i 1 "$TARGET" 2>/dev/null | awk '/First sector/{print $3}')
SPEC="${TARGET}@@$((OFF*512))"
echo "=== target: $TARGET ==="

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mtype -i "$SPEC" ::/loader/entries/a17-fix.conf > "$TMP/base.conf"

sed -e 's/^title .*/title      Android 17 (LOS24) - DIAG: pd_ignore_unused + clk_ignore_unused/' \
    -e 's/^\(options .*\)$/\1 pd_ignore_unused clk_ignore_unused/' \
    "$TMP/base.conf" > "$TMP/a17-pdclk.conf"

grep -q "pd_ignore_unused clk_ignore_unused" "$TMP/a17-pdclk.conf" || { echo "STOP: the parameters were not appended"; exit 1; }
[ "$(grep -c '^options ' "$TMP/a17-pdclk.conf")" = "1" ] || { echo "STOP: not exactly one options line"; exit 1; }

mcopy -o -i "$SPEC" "$TMP/a17-pdclk.conf" ::/loader/entries/a17-pdclk.conf
printf 'timeout 10\ndefault a17-pdclk\n' > "$TMP/loader.conf"
mcopy -o -i "$SPEC" "$TMP/loader.conf" ::/loader/loader.conf
sync

echo "=== a17-pdclk: dopisane parametry ==="
mtype -i "$SPEC" ::/loader/entries/a17-pdclk.conf | tr ' ' '\n' | grep -E "ignore_unused|console=|blacklist" | sed 's/^/  /'
echo "=== loader.conf ==="; mtype -i "$SPEC" ::/loader/loader.conf | sed 's/^/  /'
echo
echo "DONE. The DTB stays on dpoff. Boot, then watch the UART."
