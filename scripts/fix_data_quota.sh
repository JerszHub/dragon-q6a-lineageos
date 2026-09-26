#!/bin/bash
# fix_data_quota.sh — repairs the boot loop caused by enabling /data on std_parts.
#
# WHAT HAPPENED (2026-09-24): userdata was formatted with
#   mke2fs -O quota,project -E quotatype=usrquota:grpquota:prjquota
# That was unnecessary (generic_init builds its fstab entry from fs_type alone, with no
# quota flags) and it turned out to be fatal: this kernel has CONFIG_QFMT_V2=m and
# CONFIG_QUOTA_TREE=m, so the quota format is a MODULE. An ext4 filesystem carrying the
# "quota" feature calls ext4_enable_quotas() -> dquot_load_quota_inode() at mount time,
# which needs a registered QFMT_VFS_V1. During first-stage boot no quota module is
# loaded, ext4_fill_super() fails and mounting /data fails. /data is no_fail=false
# (dynamic_mount_handler.cpp:780), so init treats it as fatal ->
# androidboot.init_fatal_reboot_target=recovery -> no recovery exists -> BOOT LOOP.
#
# WHAT IT DOES: reformats partition 3 (userdata) as plain ext4 without quota and selects
# the a17-udbg boot entry = std_parts plus full logging (console=tty0, so it is visible
# on the touchscreen). Against the known-good a17-pdclk exactly ONE thing changes:
# androidboot.mount_userdata from tmpfs to std_parts.
#
# Usage: sudo fix_data_quota.sh            <- plan only
#         sudo fix_data_quota.sh --apply
set -euo pipefail
# Under sudo "~" expands to /root, not $HOME, so we resolve paths from this
# script's own directory (bug caught on hardware 2026-09-24).
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
APPLY=0; TARGET=""
for a in "$@"; do case "$a" in --apply) APPLY=1;; /dev/*) TARGET="$a";; *) echo "unknown argument: $a"; exit 1;; esac; done
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/q6a_find_media.sh"
if [ -z "$TARGET" ]; then
  # Medium detection: shared library (no hardcoded size window).
  source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/q6a_find_media.sh"
  TARGET=$(q6a_find_media) || exit 1
fi
[ -n "$TARGET" ] || { echo "STOP: no medium found."; lsblk -o NAME,SIZE,TYPE,TRAN,RM,LABEL; exit 1; }

echo "=== target: $TARGET ==="
sgdisk -p "$TARGET" | tail -5 | sed 's/^/  /'
UD=$(q6a_part "$TARGET" 3); MD=$(q6a_part "$TARGET" 2)
[ -b "$UD" ] || { echo "STOP: $UD not found"; exit 1; }
N2=$(sgdisk -i 2 "$TARGET" | sed -n "s/^Partition name: *'\(.*\)'$/\1/p")
N3=$(sgdisk -i 3 "$TARGET" | sed -n "s/^Partition name: *'\(.*\)'$/\1/p")
echo "  part2 nazwa GPT = '$N2'   part3 nazwa GPT = '$N3'"
[ "$N2" = "metadata" ] && [ "$N3" = "userdata" ] || { echo "STOP: unexpected partition names."; exit 1; }
echo
echo "  cechy OBECNEGO userdata:"
tune2fs -l "$UD" 2>/dev/null | grep -i "filesystem features" | sed 's/^/    /' || echo "    (cannot read)"

if [ "$APPLY" != "1" ]; then
  echo; echo "PLAN: mkfs.ext4 without quota on $UD, plus the a17-udbg boot entry"
  echo "To apply: sudo $0 --apply"; exit 0
fi
if lsblk -no MOUNTPOINT "$TARGET" | grep -q .; then echo "STOP: something on $TARGET is mounted."; exit 1; fi

echo; echo "=== APPLYING ==="
mkfs.ext4 -q -F -L userdata -M /data -m 0 "$UD"
echo "  nowe cechy userdata:"
tune2fs -l "$UD" | grep -i "filesystem features" | sed 's/^/    /'
if tune2fs -l "$UD" | grep -i "filesystem features" | grep -qw "quota"; then
  echo "STOP: the quota feature is STILL present — aborting."; exit 1
fi
echo "  OK — no quota feature"

"$HERE/set_default_entry.sh" a17-udbg "$TARGET" 0

echo
echo "DONE. Put the medium back in the Q6A and power it on."
echo "Kernel logs will go to the touchscreen (console=tty0 + loglevel=8)."
echo "If it comes up, adb will answer and the rest can be done remotely."
