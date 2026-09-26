#!/bin/bash
#
# build_q6a_a17.sh — THE canonical build script for Android 17 on the Dragon Q6A.
# Usage: ./build_q6a_a17.sh [target]      (default: all_images)
#
# ⚠️⚠️ NAJWAZNIEJSZE: MAINLINE_GENERIC_KERNEL_BOARDCONFIG_MK
# Our board.mk lives in device/radxa/dragon_q6a/kernel/, which is NOT the default path
# (device/mainline/generic/Generic_arm64/kernels/<nazwa>/board.mk). device/mainline/generic/
# BoardConfig.mk picks it up ONLY through this variable; without it the "else" branch
# with a bare gki_defconfig is taken and our ENTIRE qcs6490.config fragment is SKIPPED.
# Objawy takiego builda (sprawdzone 2026-09-12): ARM64_VA_BITS=39 zamiast 48,
# ARM64_BTI_KERNEL=y, SHADOW_CALL_STACK=y, NLS_CODEPAGE_437=m zamiast y.
# Such a kernel DIES after ExitBootServices — exactly the blocker we hit in August.
#
# ⚠️ Do NOT run "make" on the kernel by hand: oldconfig prompts interactively for new symbols
# (e.g. MEMFD_ASHMEM_SHIM) and truncates .config at EOF (about 25 options lost).
set -u
cd ${LINEAGE_TREE:-$HOME/q6a/lineage} || exit 1

export MAINLINE_GENERIC_KERNEL_BOARDCONFIG_MK=device/radxa/dragon_q6a/kernel/board.mk

source build/envsetup.sh > /dev/null 2>&1
# 2026-09-20: PRZEJSCIE NA PELNY PRODUKT LineageOS.
# aosp_Generic_arm64 inherits only lineage_sdk_common.mk (the SDK alone), so the image
# had the AOSP UI, the default AOSP boot animation and NO LineageSettingsProvider — services
# from org.lineageos.platform killed system_server without it.
# lineage_Generic_arm64 dziedziczy vendor/lineage/config/common_full_tablet_wifionly.mk,
# that is the full product: Lineage boot animation, apps, LineageSettingsProvider.
# Poprzedni wariant: build_q6a_a17.sh.bak-aosp-0920
lunch lineage_Generic_arm64-cp2a-userdebug > /dev/null 2>&1
export LINEAGE_BUILD=Generic_arm64          # BoardConfigLineage.mk is only included when this is set
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

# -j8 (2026-09-20). History: -j12 caused OOM kills in kotlinc/r8, so we dropped to -j6.
# Maszyna ma 16 rdzeni i 26 GB dla WSL (32 GB fizycznie). Faza analizy Soong potrafi
# reach 21 GB, but it is ONE process bounded by GOMEMLIMIT, not by -j. Only ninja
# odpala rownolegle kompilatory, a te sa duzo lzejsze. -j8 to kompromis: +33% wzgledem
# -j6, a nadal spory zapas na kotlinc/r8 w koncowej fazie budowania aplikacji.
m "$TARGET_GOAL" -j8 >> "$LOG" 2>&1
echo "BUILD_EXIT=$? $(date)" >> "$LOG"
tail -4 "$LOG"
