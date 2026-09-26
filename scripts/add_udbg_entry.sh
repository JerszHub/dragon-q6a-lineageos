#!/bin/bash
# add_udbg_entry.sh — the "a17-udbg" entry: the new /data (std_parts) plus UART LOGS.
#
# After switching to androidboot.mount_userdata=std_parts the board stopped booting,
# and because the same entry removed the serial console we cannot see why. There is no adb
# q6a_debug_net only starts at post-fs-data, that is AFTER /data is prepared.
#
# This entry combines the new configuration with diagnostics: it takes the options from
# console=ttyMSM0 plus earlycon and loglevel back, so the mount stage becomes visible.
#
# Usage: sudo add_udbg_entry.sh [/dev/sdX]
set -euo pipefail
TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  # Medium detection: shared library (no hardcoded size window).
  source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/q6a_find_media.sh"
  TARGET=$(q6a_find_media) || exit 1
fi
[ -n "$TARGET" ] || { echo "STOP: no card found."; exit 1; }
OFF=$(sgdisk -i 1 "$TARGET" | awk '/First sector/{print $3}')
SPEC="${TARGET}@@$((OFF*512))"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mtype -i "$SPEC" ::/loader/entries/a17.conf > "$TMP/base.conf"
sed -e 's/^title .*/title      LineageOS 24 - DIAG: nowe \/data + UART/' \
    -e 's|^options \(.*\)$|options \1 androidboot.seriallogging=ttyMSM0 earlycon console=ttyMSM0,115200n8 ignore_loglevel loglevel=8|' \
    "$TMP/base.conf" > "$TMP/a17-udbg.conf"
grep -q "console=ttyMSM0" "$TMP/a17-udbg.conf" || { echo "STOP: the console was not appended"; exit 1; }
grep -q "mount_userdata=std_parts" "$TMP/a17-udbg.conf" || { echo "STOP: std_parts missing"; exit 1; }
mcopy -o -i "$SPEC" "$TMP/a17-udbg.conf" ::/loader/entries/a17-udbg.conf
printf 'timeout 0\ndefault a17-udbg\n' > "$TMP/loader.conf"
mcopy -o -i "$SPEC" "$TMP/loader.conf" ::/loader/loader.conf
sync
echo "=== a17-udbg ==="
mtype -i "$SPEC" ::/loader/entries/a17-udbg.conf | tr ' ' '\n' | grep -E "mount_userdata|console=|earlycon|ignore_unused" | sed 's/^/  /'
echo "=== loader.conf ==="; mtype -i "$SPEC" ::/loader/loader.conf | sed 's/^/  /'
echo
echo "DONE. Boot the board, then watch the UART."
echo "Back to the known-good configuration (tmpfs): sudo set_default_entry.sh a17-pdclk"
