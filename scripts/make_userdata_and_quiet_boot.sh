#!/bin/bash
# make_userdata_and_quiet_boot.sh — trwale /data + cichy boot bez UART i bez menu.
#
# ROBI TRZY RZECZY:
#
# 1. TRWALE /data. Dotad cmdline mial androidboot.mount_userdata=tmpfs, czyli /data
#    w RAM-ie, kasowane przy kazdym restarcie. Skutek: kreator wstepnej konfiguracji
#    przy KAZDYM boocie i brak trwalych tombstone'ow. Tworzymy partycje GPT o nazwie
#    "userdata" w wolnym miejscu karty (~235 GB za 3-gigabajtowym ESP) i przelaczamy
#    na androidboot.mount_userdata=std_parts, ktore mapuje partycje PO NAZWIE
#    (docs/boot-parameters.md:56, docs/installation.md:30).
#
# 2. CICHY WPIS ROZRUCHOWY "a17" bez konsoli szeregowej. Usuwa console=ttyMSM0,
#    earlycon, androidboot.seriallogging, ignore_loglevel, loglevel=8, keep_bootcon.
#    ZOSTAJA: pd_ignore_unused clk_ignore_unused (bez nich wyswietlacz sie nie podnosi)
#    oraz androidboot.insecure_adb=true (bez tego nie ma adb po TCP).
#
# 3. timeout 0 w loader.conf. Plyta ma tylko panel dotykowy, wiec menu i tak jest
#    nieobslugiwalne. Stare wpisy ZOSTAJA na karcie - da sie do nich wrocic przez
#    ~/q6a/set_default_entry.sh <nazwa>.
#
# Uzycie: sudo ~/q6a/make_userdata_and_quiet_boot.sh [/dev/sdX]          <- sam plan
#         sudo ~/q6a/make_userdata_and_quiet_boot.sh [/dev/sdX] --apply
set -euo pipefail
APPLY=0; TARGET=""
for a in "$@"; do case "$a" in --apply) APPLY=1;; /dev/*) TARGET="$a";; *) echo "nieznany argument: $a"; exit 1;; esac; done
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

OFF=$(sgdisk -i 1 "$TARGET" | awk '/First sector/{print $3}')
SPEC="${TARGET}@@$((OFF*512))"
P1END=$(sgdisk -i 1 "$TARGET" | awk '/Last sector/{print $3}')
DEVSZ=$(blockdev --getsz "$TARGET")
# WYMOG std_parts (znaleziony w zrodlach 2026-09-24):
#   vendor/mainline/services/generic_init/dynamic_mount_handler.cpp:123
#     android_userdata_partitions = {"cache","userdata","metadata"};
#   ...:701  petla sprawdzajaca gotowosc ma wyjatek TYLKO dla "cache"
#     (if (part == "cache" && !need_mount_cache) continue;), a dla kazdej innej
#     brakujacej partycji robi "return false" -> generic_init czeka w nieskonczonosc.
# Dlatego OPROCZ "userdata" trzeba utworzyc "metadata". "cache" jest zbedny:
# need_mount_cache wlacza sie tylko gdy w systemie istnieje katalog /cache (:528),
# a nasz system.img go nie ma. Dopasowanie idzie po NAZWIE GPT (uevent PARTNAME),
# typ GUID nie ma znaczenia. metadata montuje sie w /metadata (:779).
MD_START=$(( ((P1END + 1 + 2047) / 2048) * 2048 ))
MD_END=$(( MD_START + 65536 - 1 ))          # 32 MB
UD_START=$(( MD_END + 1 ))
UD_END=$(( DEVSZ - 34 ))
UD_GB=$(( (UD_END - UD_START) * 512 / 1024/1024/1024 ))

echo "=== cel: $TARGET ==="
echo "  ESP (part 1): $OFF .. $P1END"
echo "  metadata (part 2): $MD_START .. $MD_END  (32 MB)"
echo "  userdata (part 3): $UD_START .. $UD_END  (~${UD_GB} GB)"
EXIST=$(sgdisk -p "$TARGET" 2>/dev/null | awk '$1==2{print $1}')
[ -n "$EXIST" ] && { echo "  UWAGA: partycja 2 JUZ ISTNIEJE - przerywam, sprawdz recznie."; exit 1; }

BASE=$(mtype -i "$SPEC" ::/loader/entries/a17-pdclk.conf 2>/dev/null | grep "^options" || true)
[ -n "$BASE" ] || { echo "STOP: nie znalazlem wpisu a17-pdclk.conf"; exit 1; }
NEW=$(echo "$BASE" \
  | sed -E 's/ (console=ttyMSM0[^ ]*|earlycon|androidboot\.seriallogging=[^ ]*|ignore_loglevel|loglevel=[0-9]+|keep_bootcon|nokaslr|initcall_debug)//g' \
  | sed -E 's/androidboot\.mount_userdata=[a-z_]+/androidboot.mount_userdata=std_parts/')
echo
echo "=== nowy wpis 'a17' (cichy) ==="
echo "$NEW" | tr ' ' '\n' | grep -E "mount_userdata|console|ignore_unused|insecure_adb|seriallogging|earlycon" | sed 's/^/  /'
echo "  (brak linii console=/earlycon/seriallogging = usuniete poprawnie)"

if [ "$APPLY" != "1" ]; then echo; echo "To byl tylko plan. Zeby wykonac: sudo $0 $TARGET --apply"; exit 0; fi

echo; echo "=== WYKONUJE ==="
sgdisk -n "2:${MD_START}:${MD_END}" -t 2:8300 -c 2:"metadata" "$TARGET" >/dev/null
sgdisk -n "3:${UD_START}:${UD_END}" -t 3:8300 -c 3:"userdata" "$TARGET" >/dev/null
partprobe "$TARGET" 2>/dev/null || true; sleep 2
MD_DEV="${TARGET}2"; UD_DEV="${TARGET}3"
for d in "$MD_DEV" "$UD_DEV"; do [ -b "$d" ] || { echo "STOP: $d nie powstal"; exit 1; }; done
mkfs.ext4 -q -L metadata -m 0 "$MD_DEV"
# UWAGA (2026-09-24): NIE wlaczac cechy ext4 "quota"/"project" na /data.
# To jadro ma CONFIG_QFMT_V2=m i CONFIG_QUOTA_TREE=m (moduly). Ext4 z cecha quota
# wola przy montowaniu ext4_enable_quotas() -> dquot_load_quota_inode(), ktore wymaga
# ZAREJESTROWANEGO formatu QFMT_VFS_V1. W pierwszym etapie bootu (generic_init) zaden
# modul quot nie jest zaladowany -> ext4_fill_super() zawodzi -> mount /data pada.
# A /data ma no_fail=false (dynamic_mount_handler.cpp:780), wiec init uznaje to za blad
# krytyczny -> androidboot.init_fatal_reboot_target=recovery -> brak recovery -> PETLA BOOTOW.
# Sprawdzone na sprzecie 2026-09-24. generic_init i tak nie prosi o quota:
# jego wpis fstab ma wylacznie fs_type (ext4/f2fs), zero flag quota.
mkfs.ext4 -q -L userdata -M /data -m 0 "$UD_DEV"
echo "  partycja metadata: $(lsblk -dno SIZE $MD_DEV) ext4"
echo "  partycja userdata: $(lsblk -dno SIZE $UD_DEV) ext4 (bez quota - patrz komentarz)"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mtype -i "$SPEC" ::/loader/entries/a17-pdclk.conf | sed -e 's/^title .*/title      LineageOS 24 (Android 17)/' -e "s|^options .*|$NEW|" > "$TMP/a17.conf"
mcopy -o -i "$SPEC" "$TMP/a17.conf" ::/loader/entries/a17.conf
printf 'timeout 0\ndefault a17\n' > "$TMP/loader.conf"
mcopy -o -i "$SPEC" "$TMP/loader.conf" ::/loader/loader.conf
sync
echo; echo "=== PO ZMIANIE ==="
sgdisk -p "$TARGET" | tail -4 | sed 's/^/  /'
mtype -i "$SPEC" ::/loader/loader.conf | sed 's/^/  /'
echo "GOTOWE. Stare wpisy zostaly - powrot przez ~/q6a/set_default_entry.sh <nazwa>."
