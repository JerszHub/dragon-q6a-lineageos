#!/bin/bash
# fix_data_quota.sh — naprawia petle bootow po wlaczeniu /data na std_parts.
#
# CO SIE STALO (2026-09-24): sformatowalem userdata przez
#   mke2fs -O quota,project -E quotatype=usrquota:grpquota:prjquota
# To bylo zbedne (generic_init buduje wpis fstab wylacznie z fs_type, zero flag quota)
# i okazalo sie zgubne: jadro ma CONFIG_QFMT_V2=m oraz CONFIG_QUOTA_TREE=m, wiec format
# quot jest MODULEM. Ext4 z cecha "quota" przy montowaniu wola ext4_enable_quotas() ->
# dquot_load_quota_inode(), a to wymaga zarejestrowanego QFMT_VFS_V1. W pierwszym etapie
# bootu zaden modul quot nie jest zaladowany -> ext4_fill_super() zawodzi -> mount /data pada.
# /data ma no_fail=false (dynamic_mount_handler.cpp:780) -> init uznaje blad krytyczny ->
# androidboot.init_fatal_reboot_target=recovery -> recovery nie istnieje -> PETLA BOOTOW.
#
# CO ROBI: formatuje partycje 3 (userdata) na czysty ext4 bez quot i ustawia wpis
# rozruchowy a17-udbg = std_parts + pelne logi (console=tty0 -> widoczne na ekranie
# dotykowym). Wzgledem dzialajacego a17-pdclk zmienia sie DOKLADNIE JEDNA rzecz:
# androidboot.mount_userdata tmpfs -> std_parts.
#
# Uzycie: sudo ~/q6a/fix_data_quota.sh            <- sam plan
#         sudo ~/q6a/fix_data_quota.sh --apply
set -euo pipefail
# Pod sudo "~" rozwija sie do /root, nie $HOME - odwolujemy sie
# do katalogu tego skryptu (blad zlapany na sprzecie 2026-09-24).
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
APPLY=0; TARGET=""
for a in "$@"; do case "$a" in --apply) APPLY=1;; /dev/*) TARGET="$a";; *) echo "nieznany argument: $a"; exit 1;; esac; done
if [ -z "$TARGET" ]; then
  # Wykrywanie nosnika: wspolna biblioteka (bez zaszytego okna rozmiaru).
  source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/q6a_find_media.sh"
  TARGET=$(q6a_find_media) || exit 1
fi
[ -n "$TARGET" ] || { echo "STOP: nie znalazlem karty."; lsblk -o NAME,SIZE,TYPE,TRAN,RM,LABEL; exit 1; }

echo "=== cel: $TARGET ==="
sgdisk -p "$TARGET" | tail -5 | sed 's/^/  /'
UD="${TARGET}3"; MD="${TARGET}2"
[ -b "$UD" ] || { echo "STOP: brak $UD"; exit 1; }
N2=$(sgdisk -i 2 "$TARGET" | sed -n "s/^Partition name: *'\(.*\)'$/\1/p")
N3=$(sgdisk -i 3 "$TARGET" | sed -n "s/^Partition name: *'\(.*\)'$/\1/p")
echo "  part2 nazwa GPT = '$N2'   part3 nazwa GPT = '$N3'"
[ "$N2" = "metadata" ] && [ "$N3" = "userdata" ] || { echo "STOP: nieoczekiwane nazwy partycji."; exit 1; }
echo
echo "  cechy OBECNEGO userdata:"
tune2fs -l "$UD" 2>/dev/null | grep -i "filesystem features" | sed 's/^/    /' || echo "    (nie czytam)"

if [ "$APPLY" != "1" ]; then
  echo; echo "PLAN: mkfs.ext4 bez quot na $UD  +  wpis rozruchowy a17-udbg"
  echo "Zeby wykonac: sudo $0 --apply"; exit 0
fi
if lsblk -no MOUNTPOINT "$TARGET" | grep -q .; then echo "STOP: cos z $TARGET jest zamontowane."; exit 1; fi

echo; echo "=== WYKONUJE ==="
mkfs.ext4 -q -F -L userdata -M /data -m 0 "$UD"
echo "  nowe cechy userdata:"
tune2fs -l "$UD" | grep -i "filesystem features" | sed 's/^/    /'
if tune2fs -l "$UD" | grep -i "filesystem features" | grep -qw "quota"; then
  echo "STOP: cecha quota WCIAZ obecna - przerywam."; exit 1
fi
echo "  OK - brak cechy quota"

"$HERE/set_default_entry.sh" a17-udbg "$TARGET" 0

echo
echo "GOTOWE. Wloz karte do Q6a i wlacz."
echo "Logi jadra pojda na ekran dotykowy (console=tty0 + loglevel=8)."
echo "Jesli wstanie - odezwie sie adb i reszte dokoncze zdalnie."
