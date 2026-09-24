#!/bin/bash
# build_aic8800.sh — buduje sterowniki AIC8800D80 (USB) pod NASZE jadro 7.1.0.
#
# Uklad: AIC8800D80 na USB za wbudowanym hubem (a69c:8d80, DTS: wifi@4).
# W v7 uzywalismy modulow PREBUILT z RadxaOS (vermagic 6.18.2-4-qcom) - na jadrze
# 7.1.0 sie nie zaladuja (inna wersja + my mamy CONFIG_MODVERSIONS, one nie).
#
# Zrodla: github.com/radxa-pkg/aic8800 (oficjalne pakowanie Radxy, to samo, z czego
# pochodzily moduly v7). Surowy kod AICSemi NIE kompiluje sie pod 7.1 - Radxa niesie
# latke debianowa `fix-linux-7.1-build.patch`. Cala seria (27 latek) jest nalozona.
#
# ⚠️ CONFIG_PLATFORM_UBUNTU: Radxa domyslnie ustawia "y", co daje sciezke firmware
# /lib/firmware. My budujemy dla Androida, wiec wymuszamy "n" -> zrodla wybieraja
# wtedy /vendor/etc/firmware (aicbluetooth.c:147-151, aic_btusb.c:2846-2850).
# Dlatego TEZ nie nakladamy `fix-usb-firmware-path.patch` - jest debianowa.
#
# ⚠️ KCFLAGS=-Wno-error: Radxa buduje ten sterownik GCC (pakiet debianowy), my klangiem
# 22 z AOSP, ktory ma znacznie wiecej ostrzeżen - a jadro Androida dodaje -Werror.
# Makefile producenta wycisza juz -Wno-implicit-fallthrough i -Wno-unused-variable,
# ale klang zglasza dodatkowo -Wmisleading-indentation, -Wsometimes-uninitialized itd.
# Lapanie ich po jednym to niekonczaca sie petla, wiec zdejmujemy -Werror, ZOSTAWIAJAC
# ostrzezenia widoczne w logu. Bledy kompilacji nadal zatrzymuja build.
#
# NIE zamaskowalismy przy tym trzech REALNYCH usterek, ktore znalazly te ostrzezenia -
# sa poprawione w zrodle, nie wyciszone:
#   aic_btusb.c:3364   ret_val bez wartosci (uzywane w printk)
#   rwnx_tx.c:1442     msgbuf przekazywany niezainicjalizowany do intf_tcp_alloc_msg
#   aic_priv_cmd.c:279 lvl_mod bez wartosci dla mode 1, 3 i >=6, trafia do buf[1]
#
# (stary komentarz) jadro Androida buduje z -Werror, a kod producenta ma dwa rodzaje
# niechlujstwa, ktore to wywalaja: niezaanotowane fall-through w switchu
# (rwnx_msg_tx.c:623,636) i mylace wciecie (rwnx_msg_tx.c:4257). Obie sa czysto
# kosmetyczne, wiec wyciszamy TE DWIE KLASY, nie -Werror w calosci.
# Trzeci blad - "ret_val is uninitialized" w aic_btusb.c:3387 - NIE jest wyciszony,
# tylko naprawiony w zrodle (zmienna sluzyla wylacznie do printk, funkcja i tak
# zwracala -1). Wyciszanie -Wuninitialized zamaskowaloby przyszle prawdziwe bledy.
#
# ⚠️ CONFIG_USE_FW_REQUEST = n (domyslnie): sterownik czyta pliki BEZPOSREDNIO przez
# filp_open, nie przez request_firmware. Firmware musi realnie lezec pod ta sciezka.
set -u
SRC=$HOME/q6a/aic8800_src/src/USB/driver_fw/drivers
KSRC=${LINEAGE_TREE:-$HOME/q6a/lineage}/kernel/mainline/android-mainline
KOBJ=${LINEAGE_TREE:-$HOME/q6a/lineage}/out/target/product/Generic_arm64/obj/KERNEL_OBJ
CLANG=${LINEAGE_TREE:-$HOME/q6a/lineage}/prebuilts/clang/host/linux-x86/clang-r596125/bin
# pahole jest potrzebne do BTF (jadro ma CONFIG_DEBUG_INFO_BTF_MODULES). Bez niego
# moduly linkuja sie poprawnie, ale gen-btf.sh konczy build bledem 127 i KASUJE .ko.
KBTOOLS=${LINEAGE_TREE:-$HOME/q6a/lineage}/prebuilts/kernel-build-tools/linux-x86/bin
OUT=$HOME/q6a/aic8800_build
LOG=$HOME/q6a/aic8800_build.log

[ -d "$KOBJ" ] || { echo "STOP: brak $KOBJ"; exit 1; }
[ -x "$CLANG/clang" ] || { echo "STOP: brak klanga w $CLANG"; exit 1; }
export PATH="$CLANG:$KBTOOLS:$PATH"

mkdir -p "$OUT"
: > "$LOG"
echo "=== jadro: $(cat $KOBJ/include/config/kernel.release 2>/dev/null) ==="
echo "=== klang: $($CLANG/clang --version | head -1) ==="

build_one() {
  local dir="$1" name="$2"
  echo "--- buduje $name" | tee -a "$LOG"
  make -C "$KSRC" O="$KOBJ" M="$dir" \
       ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE=aarch64-linux-gnu- \
       KCFLAGS="-Wno-error" \
       CONFIG_PLATFORM_UBUNTU=n CONFIG_PLATFORM_ROCKCHIP=n \
       CONFIG_PLATFORM_ALLWINNER=n CONFIG_PLATFORM_AMLOGIC=n CONFIG_PLATFORM_HI=n \
       modules >> "$LOG" 2>&1
  local rc=$?
  if [ $rc -eq 0 ]; then
    find "$dir" -name "*.ko" -exec cp {} "$OUT/" \; 2>/dev/null
    echo "    OK" | tee -a "$LOG"
  else
    echo "    BLAD (rc=$rc) - szczegoly w $LOG" | tee -a "$LOG"
  fi
  return $rc
}

build_one "$SRC/aic8800" "aic_load_fw + aic8800_fdrv"
build_one "$SRC/aic_btusb" "aic_btusb"

echo
echo "=== zbudowane moduly ==="
ls -la "$OUT"/*.ko 2>/dev/null | awk '{printf "  %8.1f KB  %s\n",$5/1024,$9}' || echo "  ZADNYCH"
for m in "$OUT"/*.ko; do
  [ -f "$m" ] && echo "  $(basename $m): vermagic=$(modinfo "$m" 2>/dev/null | awk '/^vermagic/{$1="";print}' | xargs)"
done
