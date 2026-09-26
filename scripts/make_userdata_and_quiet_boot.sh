#!/bin/bash
# make_userdata_and_quiet_boot.sh — persistent /data plus a quiet boot: no UART, no menu.
#
# IT DOES THREE THINGS:
#
# 1. PERSISTENT /data. Until now the command line carried
#    androidboot.mount_userdata=tmpfs, so /data lived in RAM and was wiped on every
#    restart. The visible effect was the setup wizard on EVERY boot and no lasting
#    tombstones. This creates a GPT partition named "userdata" in the free space behind
#    the 3 GB ESP and switches to androidboot.mount_userdata=std_parts, which maps
#    partitions BY NAME (docs/boot-parameters.md:56, docs/installation.md:30).
#
# 2. A QUIET BOOT ENTRY "a17" with no serial console. Removes console=ttyMSM0,
#    earlycon, androidboot.seriallogging, ignore_loglevel, loglevel=8, keep_bootcon.
#    KEPT: pd_ignore_unused clk_ignore_unused (without them the display does not come
#    up) and androidboot.insecure_adb=true (without it there is no adb over TCP).
#
# 3. timeout 0 in loader.conf. The board has only a touchscreen, so the boot menu
#    cannot be operated anyway. The older entries STAY on the medium — you can return
#    to them with set_default_entry.sh <name>.
#
# Usage: sudo make_userdata_and_quiet_boot.sh [/dev/sdX]          <- plan only
#         sudo make_userdata_and_quiet_boot.sh [/dev/sdX] --apply
set -euo pipefail
APPLY=0; TARGET=""
for a in "$@"; do case "$a" in --apply) APPLY=1;; /dev/*) TARGET="$a";; *) echo "unknown argument: $a"; exit 1;; esac; done
if [ -z "$TARGET" ]; then
  # Medium detection: shared library (no hardcoded size window).
  source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/q6a_find_media.sh"
  TARGET=$(q6a_find_media) || exit 1
fi
[ -n "$TARGET" ] || { echo "STOP: no medium found."; exit 1; }

OFF=$(sgdisk -i 1 "$TARGET" | awk '/First sector/{print $3}')
SPEC="${TARGET}@@$((OFF*512))"
P1END=$(sgdisk -i 1 "$TARGET" | awk '/Last sector/{print $3}')
DEVSZ=$(blockdev --getsz "$TARGET")
# WHAT std_parts REQUIRES (found in the sources, not guessed, 2026-09-24):
#   vendor/mainline/services/generic_init/dynamic_mount_handler.cpp:123
#     android_userdata_partitions = {"cache","userdata","metadata"};
#   ...:701  the readiness loop has an exception ONLY for "cache"
#     (if (part == "cache" && !need_mount_cache) continue;); for any other missing
#     partition it returns false, so generic_init keeps waiting.
# So "metadata" must be created ALONGSIDE "userdata". "cache" is genuinely unnecessary:
# need_mount_cache is only set when the mounted system contains a /cache directory
# (:528), and ours does not. Matching is by GPT NAME (uevent PARTNAME); the type GUID
# is irrelevant. metadata mounts at /metadata (:779).
MD_START=$(( ((P1END + 1 + 2047) / 2048) * 2048 ))
MD_END=$(( MD_START + 65536 - 1 ))          # 32 MB
UD_START=$(( MD_END + 1 ))
UD_END=$(( DEVSZ - 34 ))
UD_GB=$(( (UD_END - UD_START) * 512 / 1024/1024/1024 ))

echo "=== target: $TARGET ==="
echo "  ESP (part 1): $OFF .. $P1END"
echo "  metadata (part 2): $MD_START .. $MD_END  (32 MB)"
echo "  userdata (part 3): $UD_START .. $UD_END  (~${UD_GB} GB)"
EXIST=$(sgdisk -p "$TARGET" 2>/dev/null | awk '$1==2{print $1}')
[ -n "$EXIST" ] && { echo "  WARNING: partition 2 ALREADY EXISTS — stopping, check by hand."; exit 1; }

BASE=$(mtype -i "$SPEC" ::/loader/entries/a17-pdclk.conf 2>/dev/null | grep "^options" || true)
[ -n "$BASE" ] || { echo "STOP: boot entry a17-pdclk.conf not found"; exit 1; }
NEW=$(echo "$BASE" \
  | sed -E 's/ (console=ttyMSM0[^ ]*|earlycon|androidboot\.seriallogging=[^ ]*|ignore_loglevel|loglevel=[0-9]+|keep_bootcon|nokaslr|initcall_debug)//g' \
  | sed -E 's/androidboot\.mount_userdata=[a-z_]+/androidboot.mount_userdata=std_parts/')
echo
echo "=== new 'a17' entry (quiet) ==="
echo "$NEW" | tr ' ' '\n' | grep -E "mount_userdata|console|ignore_unused|insecure_adb|seriallogging|earlycon" | sed 's/^/  /'
echo "  (no console=/earlycon/seriallogging lines means they were removed correctly)"

if [ "$APPLY" != "1" ]; then echo; echo "That was the plan only. To apply: sudo $0 $TARGET --apply"; exit 0; fi

echo; echo "=== APPLYING ==="
sgdisk -n "2:${MD_START}:${MD_END}" -t 2:8300 -c 2:"metadata" "$TARGET" >/dev/null
sgdisk -n "3:${UD_START}:${UD_END}" -t 3:8300 -c 3:"userdata" "$TARGET" >/dev/null
partprobe "$TARGET" 2>/dev/null || true; sleep 2
MD_DEV="${TARGET}2"; UD_DEV="${TARGET}3"
for d in "$MD_DEV" "$UD_DEV"; do [ -b "$d" ] || { echo "STOP: $d was not created"; exit 1; }; done
mkfs.ext4 -q -L metadata -m 0 "$MD_DEV"
# NOTE (2026-09-24): do NOT enable the ext4 "quota"/"project" features on /data.
# This kernel has CONFIG_QFMT_V2=m and CONFIG_QUOTA_TREE=m, so the quota format is a
# module. An ext4 filesystem carrying the quota feature calls ext4_enable_quotas() at
# mount time, which needs a REGISTERED QFMT_VFS_V1 format. During first-stage boot
# (generic_init) no quota module is loaded, so ext4_fill_super() fails and mounting
# /data fails. Because /data is no_fail=false (dynamic_mount_handler.cpp:780) init
# treats that as fatal -> androidboot.init_fatal_reboot_target=recovery -> there is no
# recovery -> BOOT LOOP. Confirmed on hardware 2026-09-24. generic_init never asks for
# quota anyway: the fstab entry it builds carries only fs_type (ext4/f2fs).
mkfs.ext4 -q -L userdata -M /data -m 0 "$UD_DEV"
echo "  metadata partition: $(lsblk -dno SIZE $MD_DEV) ext4"
echo "  userdata partition: $(lsblk -dno SIZE $UD_DEV) ext4 (no quota — see the comment)"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mtype -i "$SPEC" ::/loader/entries/a17-pdclk.conf | sed -e 's/^title .*/title      LineageOS 24 (Android 17)/' -e "s|^options .*|$NEW|" > "$TMP/a17.conf"
mcopy -o -i "$SPEC" "$TMP/a17.conf" ::/loader/entries/a17.conf
printf 'timeout 0\ndefault a17\n' > "$TMP/loader.conf"
mcopy -o -i "$SPEC" "$TMP/loader.conf" ::/loader/loader.conf
sync
echo; echo "=== AFTER ==="
sgdisk -p "$TARGET" | tail -4 | sed 's/^/  /'
mtype -i "$SPEC" ::/loader/loader.conf | sed 's/^/  /'
echo "DONE. The older entries are still there — return with set_default_entry.sh <name>."
