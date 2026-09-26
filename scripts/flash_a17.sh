#!/bin/bash
# flash_a17.sh — wgrywa obraz wydaniowy LineageOS 24 na DOWOLNY nosnik (SD, USB, NVMe)
#                i dopasowuje uklad partycji do jego RZECZYWISTEGO rozmiaru.
#
# DLACZEGO nie wystarczy samo `dd`:
#   Obraz ma 3 GB, wiec zapasowa tablica GPT siedzi na koncu TEGO OBRAZU. Po zapisaniu
#   na nosnik 476 GB zostaje w 3. gigabajcie, a reszta dysku jest dla GPT niewidoczna.
#   Trzeba ja przeniesc na faktyczny koniec (`sgdisk -e`), dopiero potem dopisac partycje.
#
# CO ROBI:
#   1. dd obrazu           2. sgdisk -e (zapasowy GPT na koniec)
#   3. metadata 32 MB      4. userdata = CALA reszta nosnika
#   5. mkfs.ext4 (BEZ quot - patrz nizej)  6. weryfikacja
#
# ⚠️ NIE formatowac userdata z cecha ext4 `quota`/`project`: to jadro ma CONFIG_QFMT_V2=m,
#    wiec format quot jest modulem i w pierwszym etapie bootu go nie ma -> mount /data pada
#    -> init reboot do recovery, ktorego nie ma -> PETLA BOOTOW. Sprawdzone na sprzecie.
#
# Uzycie: sudo ~/q6a/flash_a17.sh [/dev/sdX] [obraz.img]      <- plan
#         sudo ~/q6a/flash_a17.sh [/dev/sdX] [obraz.img] --apply
set -euo pipefail
HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
APPLY=0; TARGET=""; IMG=""
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1;;
    /dev/*)  TARGET="$a";;
    *.img)   IMG="$a";;
    *) echo "nieznany argument: $a"; exit 1;;
  esac
done
IMG="${IMG:-$HERE/dragon_q6a_lineage24_v1.img}"
[ -f "$IMG" ] || { echo "STOP: brak obrazu $IMG"; exit 1; }
if [ -z "$TARGET" ]; then
  source "$HERE/q6a_find_media.sh"
  TARGET=$(q6a_find_media) || exit 1
fi
[ -b "$TARGET" ] || { echo "STOP: $TARGET nie jest urzadzeniem blokowym"; exit 1; }

DEVSZ=$(blockdev --getsz "$TARGET")
DEVGB=$(( DEVSZ * 512 / 1024/1024/1024 ))
IMGSZ=$(stat -c%s "$IMG")
echo "=== CEL: $TARGET  ($DEVGB GB, $(lsblk -dno MODEL $TARGET 2>/dev/null)) ==="
echo "=== OBRAZ: $IMG ($(( IMGSZ/1024/1024 )) MB) ==="
[ "$DEVSZ" -gt $(( IMGSZ/512 )) ] || { echo "STOP: nosnik mniejszy niz obraz"; exit 1; }
echo
echo "--- ZOSTANIE BEZPOWROTNIE SKASOWANE:"
lsblk -o NAME,SIZE,FSTYPE,PARTLABEL,LABEL "$TARGET" | sed 's/^/    /'
echo
# Koniec ESP CZYTAMY Z OBRAZU, nie zaszywamy. (Blad zlapany 2026-09-26: mialem tu
# 6291455, a faktyczny koniec to 6291422 - GPT rezerwuje 33 sektory na zapasowa tablice
# na koncu PLIKU. Dzialalo przypadkiem, bo metadata i tak zaczynala sie dalej.)
ESP_END=$(sgdisk -i 1 "$IMG" 2>/dev/null | awk '/Last sector/{print $3}')
[ -n "$ESP_END" ] || { echo "STOP: nie odczytalem konca partycji ESP z $IMG"; exit 1; }
MD_START=$(( ((ESP_END + 1 + 2047) / 2048) * 2048 ))
MD_END=$(( MD_START + 65536 - 1 ))    # metadata 32 MB
UD_START=$(( MD_END + 1 ))
UD_END=$(( DEVSZ - 34 ))
echo "--- UKLAD PO ZAPISIE (dopasowany do $DEVGB GB):"
printf "    p1 ESP       2048 .. %-12s  3.0 GB\n" "$ESP_END"
printf "    p2 metadata  %-12s .. %-12s  32 MB\n" "$MD_START" "$MD_END"
printf "    p3 userdata  %-12s .. %-12s  ~%s GB\n" "$UD_START" "$UD_END" "$(( (UD_END-UD_START)*512/1024/1024/1024 ))"

if [ "$APPLY" != 1 ]; then
  echo; echo "To byl tylko plan. Zeby wykonac:  sudo $0 $TARGET --apply"; exit 0
fi
if lsblk -no MOUNTPOINT "$TARGET" | grep -q .; then
  echo "STOP: cos z $TARGET jest zamontowane - odmontuj najpierw."; exit 1
fi

echo; echo "=== 1/5 zapis obrazu"
# UWAGA: `dd status=progress` pokazuje predkosc przyjmowania danych do PAMIECI PODRECZNEJ,
# nie zapisu na nosnik. Przy conv=fsync licznik potrafi pokazac 1,2 GB/s, a potem ZAMRZEC
# na minuty, bo trwa zrzut. (2026-09-26: tak wygladal zapis, ktory realnie szedl 20 MB/s.)
# Dlatego czytamy sektory zapisane z /sys/block/<dev>/stat - to prawdziwy ruch.
DEVNAME=$(basename "$(readlink -f "$TARGET")")
STAT=/sys/block/$DEVNAME/stat
sec0=$(awk '{print $7}' "$STAT" 2>/dev/null || echo 0)
t0=$(date +%s)
dd if="$IMG" of="$TARGET" bs=4M conv=fsync status=none &
DDPID=$!
while kill -0 "$DDPID" 2>/dev/null; do
  sleep 2
  sec=$(awk '{print $7}' "$STAT" 2>/dev/null || echo "$sec0")
  mb=$(( (sec - sec0) * 512 / 1024 / 1024 ))
  el=$(( $(date +%s) - t0 )); [ "$el" -lt 1 ] && el=1
  pct=$(( mb * 100 / (IMGSZ/1024/1024) )); [ "$pct" -gt 100 ] && pct=100
  printf "\r    %4s MB / %s MB  (%3s%%)  %s MB/s  " "$mb" "$((IMGSZ/1024/1024))" "$pct" "$(( mb / el ))"
done
RC=0; wait "$DDPID" || RC=$?    # jawnie, bo `set -e` przerwaloby skrypt na `wait`
printf "\n"
[ "$RC" = 0 ] || { echo "STOP: dd zakonczylo sie bledem $RC"; exit 1; }
sync
echo "=== 2/5 przenosze zapasowy GPT na koniec nosnika"
sgdisk -e "$TARGET" >/dev/null
partprobe "$TARGET" 2>/dev/null || true; sleep 2
echo "=== 3/5 tworze metadata + userdata"
sgdisk -n "2:${MD_START}:${MD_END}" -t 2:8300 -c 2:"metadata" "$TARGET" >/dev/null
sgdisk -n "3:${UD_START}:${UD_END}" -t 3:8300 -c 3:"userdata" "$TARGET" >/dev/null
partprobe "$TARGET" 2>/dev/null || true; sleep 3
P() { case "$TARGET" in *nvme*|*mmcblk*) echo "${TARGET}p$1";; *) echo "${TARGET}$1";; esac; }
for n in 1 2 3; do [ -b "$(P $n)" ] || { echo "STOP: $(P $n) nie powstal"; exit 1; }; done
echo "=== 4/5 formatuje"
mkfs.ext4 -q -F -L metadata -m 0 "$(P 2)"
mkfs.ext4 -q -F -L userdata -M /data -m 0 "$(P 3)"      # BEZ quot!
sync
echo "=== 5/5 weryfikacja"
sgdisk -p "$TARGET" | tail -5 | sed 's/^/    /'
for n in 2 3; do
  feats=$(tune2fs -l "$(P $n)" 2>/dev/null | grep -i "filesystem features" | sed 's/.*: *//')
  echo "    $(P $n): $(lsblk -dno SIZE $(P $n))"
  echo "$feats" | grep -qw quota && { echo "    STOP: cecha quota obecna na $(P $n)"; exit 1; }
done
echo "    OK - brak cechy quota"
MNT=$(mktemp -d); mount -o ro "$(P 1)" "$MNT" 2>/dev/null && {
  for f in Android/Image Android/qcs6490-radxa-dragon-q6a.dtb Android/system.img \
           Android/firmware/regulatory.db loader/loader.conf loader/entries/a17.conf \
           EFI/BOOT/BOOTAA64.EFI; do
    [ -f "$MNT/$f" ] && echo "    OK  $f" || { echo "    BRAK $f"; umount "$MNT"; exit 1; }
  done
  echo "    loader.conf: $(tr -d '\r' < "$MNT/loader/loader.conf" | tr '\n' ' ')"
  umount "$MNT"
}; rmdir "$MNT"
echo
echo "GOTOWE. Nosnik $TARGET ma LineageOS 24 i $(( (UD_END-UD_START)*512/1024/1024/1024 )) GB na /data."
