#!/bin/bash
# fix_userdata_layout.sh — dokłada brakującą partycję "metadata" wymaganą przez std_parts.
#
# PRZYCZYNA (znaleziona w zrodlach, nie zgadywana):
#   vendor/mainline/services/generic_init/dynamic_mount_handler.cpp:123
#     const std::list<std::string> android_userdata_partitions = {"cache","userdata","metadata"};
#   ...:701
#     for (const auto& [part, bdev] : android_userdata_part_to_bdev_map) {
#         if (part == "cache" && !need_mount_cache) continue;   // cache MA wyjatek
#         if (bdev == nullptr) return false;                    // metadata NIE MA
#     }
# Czyli androidboot.mount_userdata=std_parts wymaga partycji o nazwach GPT
# "userdata" ORAZ "metadata". Stworzylismy tylko userdata, wiec generic_init czekal
# w nieskonczonosc na brakujace urzadzenie blokowe -> boot nigdy nie dochodzil do
# post-fs-data, czyli do sieci i adb. Stad cisza na UART i brak ARP.
#
# "cache" jest zbedny: need_mount_cache wlacza sie tylko gdy w zamontowanym systemie
# istnieje katalog /cache (:528), a nasz system.img go NIE MA (sprawdzone).
#
# UKLAD: p1 ESP zostaje NIETKNIETY. p2 metadata 32 MB, p3 userdata reszta.
# Partycja userdata jest odtwarzana od zera - nie ma na niej nic wartosciowego
# (vold zdazyl utworzyc puste katalogi mediow, nic wiecej).
#
# Uzycie: sudo ~/q6a/fix_userdata_layout.sh [/dev/sdX]          <- sam plan
#         sudo ~/q6a/fix_userdata_layout.sh [/dev/sdX] --apply
set -euo pipefail
APPLY=0; TARGET=""
for a in "$@"; do case "$a" in --apply) APPLY=1;; /dev/*) TARGET="$a";; *) echo "nieznany argument: $a"; exit 1;; esac; done
if [ -z "$TARGET" ]; then
  # Wykrywanie nosnika: wspolna biblioteka (bez zaszytego okna rozmiaru).
  source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/q6a_find_media.sh"
  TARGET=$(q6a_find_media) || exit 1
fi
[ -n "$TARGET" ] || { echo "STOP: nie znalazlem karty."; exit 1; }

P1END=$(sgdisk -i 1 "$TARGET" | awk '/Last sector/{print $3}')
P1NAME=$(sgdisk -i 1 "$TARGET" | sed -n "s/^Partition name: *'\(.*\)'$/\1/p")
DEVSZ=$(blockdev --getsz "$TARGET")
MD_START=$(( ((P1END + 1 + 2047) / 2048) * 2048 ))
MD_END=$(( MD_START + 65536 - 1 ))              # 32 MB
UD_START=$(( MD_END + 1 ))
UD_END=$(( DEVSZ - 34 ))

echo "=== cel: $TARGET ==="
echo "  p1 $P1NAME (NIETKNIETA): ... $P1END"
echo "  p2 metadata : $MD_START .. $MD_END   (32 MB)"
echo "  p3 userdata : $UD_START .. $UD_END   (~$(( (UD_END-UD_START)*512/1024/1024/1024 )) GB)"
[ "$P1NAME" = "ESP" ] || { echo "STOP: partycja 1 to nie ESP - przerywam."; exit 1; }

if [ "$APPLY" != "1" ]; then echo; echo "To byl tylko plan. Zeby wykonac: sudo $0 $TARGET --apply"; exit 0; fi
if lsblk -no MOUNTPOINT "$TARGET" | grep -q .; then echo "STOP: cos z $TARGET jest zamontowane."; exit 1; fi

echo; echo "=== WYKONUJE ==="
sgdisk -d 2 "$TARGET" >/dev/null 2>&1 || true
sgdisk -d 3 "$TARGET" >/dev/null 2>&1 || true
sgdisk -n "2:${MD_START}:${MD_END}" -t 2:8300 -c 2:"metadata" "$TARGET" >/dev/null
sgdisk -n "3:${UD_START}:${UD_END}" -t 3:8300 -c 3:"userdata" "$TARGET" >/dev/null
partprobe "$TARGET" 2>/dev/null || true; sleep 2
for n in 2 3; do [ -b "${TARGET}${n}" ] || { echo "STOP: ${TARGET}${n} nie powstal"; exit 1; }; done
mkfs.ext4 -q -L metadata -m 0 "${TARGET}2"
mkfs.ext4 -q -L userdata -m 0 "${TARGET}3"

echo; echo "=== PO ZMIANIE ==="
sgdisk -p "$TARGET" | tail -4 | sed 's/^/  /'
for n in 2 3; do
  echo "  ${TARGET}${n}: $(lsblk -dno SIZE ${TARGET}${n})  $(blkid -s LABEL -o value ${TARGET}${n} 2>/dev/null)"
done
echo
echo "GOTOWE. Ustaw wpis: sudo ~/q6a/set_default_entry.sh a17"
echo "Powrot na tmpfs gdyby padlo: sudo ~/q6a/set_default_entry.sh a17-pdclk"
