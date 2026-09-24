#!/bin/bash
#
# add_pdclk_entry.sh — wpis 'a17-pdclk': blokuje gaszenie nieuzywanych domen i zegarow.
#
# PODSTAWA (log uart_dpoff_1723.log):
#   [ 3.001749] PM: genpd: Disabling unused power domains
#               clk: Disabling unused clocks
#   [51.717267] generic_init: Loading module /vendor_dlkm/lib/modules/msm.ko
#   [52.481372] msm_dpu ae01000.display-controller: bound 3d00000.gpu
#   [52.510398] Console: switching to colour dummy device 80x25   <- ostatnia linia, potem PSHOLD
#
# Czyli jadro gasi domene zasilania i zegary MDSS w 3. sekundzie, a sterownik msm zjawia sie
# 48 SEKUND POZNIEJ. Nikt w miedzyczasie nie trzyma referencji, bo simpledrm jest wylaczony
# przez initcall_blacklist. Jesli podniesienie GDSC w pm_runtime_get_sync() nie dochodzi do
# skutku, pierwszy odczyt rejestru DPU leci bez zegara -> watchdog -> PSHOLD bez paniki.
# To tlumaczy tez niedeterminizm: czy domena zostanie zgaszona, zalezy od tego, czy w 3. s
# cokolwiek trzyma referencje, a to zmienia sie z kolejnoscia ladowania modulow.
#
# Oba parametry sa w NASZYM jadrze: pd_ignore_unused (drivers/pmdomain/core.c:1367),
# clk_ignore_unused (drivers/clk/clk.c:1512).
#
# UWAGA: DTB zostawiamy na dpoff, zeby zmienic DOKLADNIE JEDNA rzecz wzgledem ostatniego bootu.
#
# Uzycie: sudo ~/q6a/add_pdclk_entry.sh [/dev/sdX | plik.img]
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

OFF=$(sgdisk -i 1 "$TARGET" 2>/dev/null | awk '/First sector/{print $3}')
SPEC="${TARGET}@@$((OFF*512))"
echo "=== cel: $TARGET ==="

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mtype -i "$SPEC" ::/loader/entries/a17-fix.conf > "$TMP/base.conf"

sed -e 's/^title .*/title      Android 17 (LOS24) - DIAG: pd_ignore_unused + clk_ignore_unused/' \
    -e 's/^\(options .*\)$/\1 pd_ignore_unused clk_ignore_unused/' \
    "$TMP/base.conf" > "$TMP/a17-pdclk.conf"

grep -q "pd_ignore_unused clk_ignore_unused" "$TMP/a17-pdclk.conf" || { echo "STOP: nie dopisalem parametrow"; exit 1; }
[ "$(grep -c '^options ' "$TMP/a17-pdclk.conf")" = "1" ] || { echo "STOP: nie jedna linia options"; exit 1; }

mcopy -o -i "$SPEC" "$TMP/a17-pdclk.conf" ::/loader/entries/a17-pdclk.conf
printf 'timeout 10\ndefault a17-pdclk\n' > "$TMP/loader.conf"
mcopy -o -i "$SPEC" "$TMP/loader.conf" ::/loader/loader.conf
sync

echo "=== a17-pdclk: dopisane parametry ==="
mtype -i "$SPEC" ::/loader/entries/a17-pdclk.conf | tr ' ' '\n' | grep -E "ignore_unused|console=|blacklist" | sed 's/^/  /'
echo "=== loader.conf ==="; mtype -i "$SPEC" ::/loader/loader.conf | sed 's/^/  /'
echo
echo "GOTOWE. DTB zostaje dpoff. Boot + sudo ~/q6a/uart_listen.sh pdclk"
