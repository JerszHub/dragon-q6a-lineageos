#!/bin/bash
# build_aic8800.sh — builds the AIC8800D80 (USB) drivers against OUR 7.1.0 kernel.
#
# Topology: AIC8800D80 on USB behind the on-board hub (a69c:8d80, DTS: wifi@4).
# W v7 uzywalismy modulow PREBUILT z RadxaOS (vermagic 6.18.2-4-qcom) - na jadrze
# 7.1.0 they will not load (different version, and we have CONFIG_MODVERSIONS while they
#
# Zrodla: github.com/radxa-pkg/aic8800 (oficjalne pakowanie Radxy, to samo, z czego
# do not). Raw AICSemi code does NOT compile against 7.1 — Radxa carries a Debian patch
# `fix-linux-7.1-build.patch`. The whole series (27 patches) is applied.
#
# ⚠️ CONFIG_PLATFORM_UBUNTU: Radxa defaults it to "y", which puts the firmware path at
# /lib/firmware. We build for Android, so we force "n" and the sources pick the
# wtedy /vendor/etc/firmware (aicbluetooth.c:147-151, aic_btusb.c:2846-2850).
# For the same reason we do NOT apply `fix-usb-firmware-path.patch`, which is Debian-specific.
#
# ⚠️ KCFLAGS=-Wno-error: Radxa buduje ten sterownik GCC (pakiet debianowy), my klangiem
# 22 from AOSP, which warns about far more — and the Android kernel adds -Werror.
# The vendor Makefile already silences -Wno-implicit-fallthrough and -Wno-unused-variable,
# ale klang zglasza dodatkowo -Wmisleading-indentation, -Wsometimes-uninitialized itd.
# chasing them one by one is endless, so we drop -Werror while KEEPING the warnings
# ostrzezenia widoczne w logu. Bledy kompilacji nadal zatrzymuja build.
#
# This did NOT mask the three REAL defects those warnings found — they are
# fixed in the source, not silenced:
#   aic_btusb.c:3364   ret_val used uninitialised (it feeds a printk)
#   rwnx_tx.c:1442     msgbuf przekazywany niezainicjalizowany do intf_tcp_alloc_msg
#   aic_priv_cmd.c:279 lvl_mod uninitialised for modes 1, 3 and >=6, and reaches buf[1]
#
# (older note) the Android kernel builds with -Werror, and the vendor code has two kinds
# niechlujstwa, ktore to wywalaja: niezaanotowane fall-through w switchu
# (rwnx_msg_tx.c:623,636) i mylace wciecie (rwnx_msg_tx.c:4257). Obie sa czysto
# cosmetic, so we silence THOSE TWO CLASSES rather than -Werror as a whole.
# The third one — "ret_val is uninitialized" at aic_btusb.c:3387 — is NOT silenced but
# fixed in the source (the variable only fed a printk; the function returns void anyway).
# zwracala -1). Wyciszanie -Wuninitialized zamaskowaloby przyszle prawdziwe bledy.
#
# ⚠️ CONFIG_USE_FW_REQUEST = n (the default): the driver reads files DIRECTLY through
# filp_open, not through request_firmware. The firmware must really sit at that path.
set -u
SRC=$HOME/q6a/aic8800_src/src/USB/driver_fw/drivers
KSRC=${LINEAGE_TREE:-$HOME/q6a/lineage}/kernel/mainline/android-mainline
KOBJ=${LINEAGE_TREE:-$HOME/q6a/lineage}/out/target/product/Generic_arm64/obj/KERNEL_OBJ
CLANG=${LINEAGE_TREE:-$HOME/q6a/lineage}/prebuilts/clang/host/linux-x86/clang-r596125/bin
# pahole is needed for BTF (the kernel has CONFIG_DEBUG_INFO_BTF_MODULES). Without it
# the modules link fine, but gen-btf.sh fails the build with status 127 and DELETES the .ko.
KBTOOLS=${LINEAGE_TREE:-$HOME/q6a/lineage}/prebuilts/kernel-build-tools/linux-x86/bin
OUT=$HOME/q6a/aic8800_build
LOG=$HOME/q6a/aic8800_build.log

[ -d "$KOBJ" ] || { echo "STOP: $KOBJ not found"; exit 1; }
[ -x "$CLANG/clang" ] || { echo "STOP: no clang in $CLANG"; exit 1; }
export PATH="$CLANG:$KBTOOLS:$PATH"

mkdir -p "$OUT"
: > "$LOG"
echo "=== kernel: $(cat $KOBJ/include/config/kernel.release 2>/dev/null) ==="
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
    echo "    FAILED (rc=$rc) — details in $LOG" | tee -a "$LOG"
  fi
  return $rc
}

build_one "$SRC/aic8800" "aic_load_fw + aic8800_fdrv"
build_one "$SRC/aic_btusb" "aic_btusb"

echo
echo "=== modules built ==="
ls -la "$OUT"/*.ko 2>/dev/null | awk '{printf "  %8.1f KB  %s\n",$5/1024,$9}' || echo "  ZADNYCH"
for m in "$OUT"/*.ko; do
  [ -f "$m" ] && echo "  $(basename $m): vermagic=$(modinfo "$m" 2>/dev/null | awk '/^vermagic/{$1="";print}' | xargs)"
done
