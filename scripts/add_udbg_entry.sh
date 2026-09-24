#!/bin/bash
# add_udbg_entry.sh — wpis "a17-udbg": nowe /data (std_parts) + LOGI UART.
#
# Po przelaczeniu na androidboot.mount_userdata=std_parts plyta przestala sie bootowac,
# a poniewaz ten sam wpis usunal konsole szeregowa, nie widzimy powodu. Brak tez adb -
# q6a_debug_net startuje dopiero na post-fs-data, czyli PO przygotowaniu /data.
#
# Ten wpis laczy nowa konfiguracje z diagnostyka: bierze options z 'a17' i dokłada
# z powrotem console=ttyMSM0 + earlycon + loglevel, zeby zobaczyc etap montowania.
#
# Uzycie: sudo ~/q6a/add_udbg_entry.sh [/dev/sdX]
set -euo pipefail
TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  for d in /dev/sd?; do
    [ -b "$d" ] || continue
    [ "$(lsblk -dno RM "$d" 2>/dev/null | tr -d '[:space:]')" = "1" ] || continue
    [ "$(lsblk -dno TRAN "$d" 2>/dev/null | tr -d '[:space:]')" = "usb" ] || continue
    GB=$(( $(lsblk -bdno SIZE "$d" 2>/dev/null || echo 0) / 1024/1024/1024 ))
    if [ "$GB" -ge 200 ] && [ "$GB" -le 300 ]; then TARGET="$d"; break; fi
  done
fi
[ -n "$TARGET" ] || { echo "STOP: nie znalazlem karty."; exit 1; }
OFF=$(sgdisk -i 1 "$TARGET" | awk '/First sector/{print $3}')
SPEC="${TARGET}@@$((OFF*512))"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mtype -i "$SPEC" ::/loader/entries/a17.conf > "$TMP/base.conf"
sed -e 's/^title .*/title      LineageOS 24 - DIAG: nowe \/data + UART/' \
    -e 's|^options \(.*\)$|options \1 androidboot.seriallogging=ttyMSM0 earlycon console=ttyMSM0,115200n8 ignore_loglevel loglevel=8|' \
    "$TMP/base.conf" > "$TMP/a17-udbg.conf"
grep -q "console=ttyMSM0" "$TMP/a17-udbg.conf" || { echo "STOP: nie dopisalem konsoli"; exit 1; }
grep -q "mount_userdata=std_parts" "$TMP/a17-udbg.conf" || { echo "STOP: brak std_parts"; exit 1; }
mcopy -o -i "$SPEC" "$TMP/a17-udbg.conf" ::/loader/entries/a17-udbg.conf
printf 'timeout 0\ndefault a17-udbg\n' > "$TMP/loader.conf"
mcopy -o -i "$SPEC" "$TMP/loader.conf" ::/loader/loader.conf
sync
echo "=== a17-udbg ==="
mtype -i "$SPEC" ::/loader/entries/a17-udbg.conf | tr ' ' '\n' | grep -E "mount_userdata|console=|earlycon|ignore_unused" | sed 's/^/  /'
echo "=== loader.conf ==="; mtype -i "$SPEC" ::/loader/loader.conf | sed 's/^/  /'
echo
echo "GOTOWE. Boot + sudo ~/q6a/uart_listen.sh udata"
echo "Powrot do dzialajacej konfiguracji (tmpfs): sudo ~/q6a/set_default_entry.sh a17-pdclk"
