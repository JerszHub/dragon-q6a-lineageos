#!/bin/bash
#
# build_q6a_a17.sh — KANONICZNY skrypt budowania Androida 17 dla Dragon Q6A.
# Uzycie: ./build_q6a_a17.sh [cel]      (domyslnie all_images)
#
# ⚠️⚠️ NAJWAZNIEJSZE: MAINLINE_GENERIC_KERNEL_BOARDCONFIG_MK
# Nasz board.mk lezy w device/radxa/dragon_q6a/kernel/, czyli NIE na sciezce domyslnej
# (device/mainline/generic/Generic_arm64/kernels/<nazwa>/board.mk). device/mainline/generic/
# BoardConfig.mk podpina go WYLACZNIE przez te zmienna; bez niej wchodzi galaz "else"
# z golym gki_defconfig i CALY nasz fragment qcs6490.config jest POMIJANY.
# Objawy takiego builda (sprawdzone 2026-09-12): ARM64_VA_BITS=39 zamiast 48,
# ARM64_BTI_KERNEL=y, SHADOW_CALL_STACK=y, NLS_CODEPAGE_437=m zamiast y.
# Takie jadro GINIE po ExitBootServices - dokladnie ta blokada co w sierpniu.
#
# ⚠️ NIE wywolywac "make" na jadrze recznie: oldconfig pyta interaktywnie o nowe symbole
# (np. MEMFD_ASHMEM_SHIM) i przy EOF URYWA .config w polowie (stracone ~25 opcji).
set -u
cd ${LINEAGE_TREE:-$HOME/q6a/lineage} || exit 1

export MAINLINE_GENERIC_KERNEL_BOARDCONFIG_MK=device/radxa/dragon_q6a/kernel/board.mk

source build/envsetup.sh > /dev/null 2>&1
# 2026-09-20: PRZEJSCIE NA PELNY PRODUKT LineageOS.
# aosp_Generic_arm64 dziedziczy tylko lineage_sdk_common.mk (samo SDK), przez co w obrazie
# bylo AOSP-owe UI, domyslna animacja bootu AOSP i BRAK LineageSettingsProvider - a uslugi
# z org.lineageos.platform bez niego zabijaly system_server.
# lineage_Generic_arm64 dziedziczy vendor/lineage/config/common_full_tablet_wifionly.mk,
# czyli pelny produkt: bootanimation Lineage, aplikacje, LineageSettingsProvider, Trebuchet.
# Poprzedni wariant: build_q6a_a17.sh.bak-aosp-0920
lunch lineage_Generic_arm64-cp2a-userdebug > /dev/null 2>&1
export LINEAGE_BUILD=Generic_arm64          # BoardConfigLineage.mk wchodzi tylko gdy ustawione
export SOONG_INCREMENTAL_ANALYSIS=false
export SOONG_BUILD_GOMEMLIMIT=20GiB         # nasza latka w build/soong/ui/build/soong.go
TARGET_GOAL="${1:-all_images}"
LOG=${LINEAGE_TREE:-$HOME/q6a/lineage}/build_$(date +%m%d_%H%M).log

{
  echo "=== start $(date)"
  echo "cel: $TARGET_GOAL"
  echo "MAINLINE_GENERIC_KERNEL_BOARDCONFIG_MK=$MAINLINE_GENERIC_KERNEL_BOARDCONFIG_MK"
} > "$LOG"
echo "log: $LOG"

# -j8 (2026-09-20). Historia: -j12 dawalo OOM-kill w kotlinc/r8, wiec zeszlismy na -j6.
# Maszyna ma 16 rdzeni i 26 GB dla WSL (32 GB fizycznie). Faza analizy Soong potrafi
# zjesc 21 GB, ale to JEDEN proces - ogranicza ja GOMEMLIMIT, nie -j. Dopiero ninja
# odpala rownolegle kompilatory, a te sa duzo lzejsze. -j8 to kompromis: +33% wzgledem
# -j6, a nadal spory zapas na kotlinc/r8 w koncowej fazie budowania aplikacji.
m "$TARGET_GOAL" -j8 >> "$LOG" 2>&1
echo "BUILD_EXIT=$? $(date)" >> "$LOG"
tail -4 "$LOG"
