#!/bin/bash
# q6a_find_media.sh — wspolne wykrywanie nosnika Dragon Q6A. Do dolaczenia przez `source`.
#
# DLACZEGO POWSTALO (zgloszenie ze spolecznosci Radxa, 2026-09-26):
#   "I get an error message when trying to run the make_userdata script. It can't find
#    the card. Does the SD card have to be over a certain size?"
# Tak — i to byl nasz blad. Skrypty mialy ZASZYTE OKNO `GB >= 200 && GB <= 300`, bo
# powstaly pod jedna konkretna karte 256 GB. Kazdy z karta 64/128 GB albo 1 TB dostawal
# "nie znalazlem karty". Do tego wymagalismy RM=1 i TRAN=usb, wiec NVMe w obudowie
# (RM=0) tez nie przechodzil.
#
# JAK JEST TERAZ: nosnik rozpoznajemy PO ZAWARTOSCI — dysk z tablica GPT, ktorej
# ktoras partycja nazywa sie "ESP". To dziala niezaleznie od rozmiaru, od tego czy
# nosnik jest wymienny, i od szyny (USB/SD/NVMe). Nie wymaga roota (PARTLABEL czyta
# sie z /sys). Gdy pasuje wiecej niz jeden nosnik, NIE zgadujemy — wypisujemy liste
# i kazemy podac urzadzenie jawnie.

# q6a_find_media [min_GB]  -> wypisuje sciezke urzadzenia na stdout, 0/1 jako kod wyjscia
q6a_find_media() {
  local min_gb="${1:-0}" d cands=() gb
  for d in /dev/sd? /dev/nvme?n? /dev/mmcblk?; do
    [ -b "$d" ] || continue
    # tylko dyski, nie partycje
    [ "$(lsblk -dno TYPE "$d" 2>/dev/null | tr -d '[:space:]')" = "disk" ] || continue
    # pomin nosniki tylko do odczytu (obrazy systemowe WSL)
    [ "$(lsblk -dno RO "$d" 2>/dev/null | tr -d '[:space:]')" = "1" ] && continue
    # SYGNATURA: ktoras partycja ma nazwe GPT "ESP"
    # UWAGA: nazwa bywa "ESP" (nasze obrazy A17) albo "esp" (uklad v7/Android 13),
    # wiec porownujemy BEZ rozroznienia wielkosci liter. Zlapane wlasnym testem 2026-09-26.
    lsblk -no PARTLABEL "$d" 2>/dev/null | tr -d ' ' | grep -qix "esp" || continue
    gb=$(( $(lsblk -bdno SIZE "$d" 2>/dev/null || echo 0) / 1024/1024/1024 ))
    [ "$gb" -lt "$min_gb" ] && continue
    cands+=("$d")
  done
  if [ "${#cands[@]}" -eq 1 ]; then
    # Ostrzezenie, gdy nosnik ma uklad v7/Android 13 (partycja `super`), a skrypt
    # nalezy do A17 - zeby nikt nie nadpisal dzialajacej instalacji przez pomylke.
    if lsblk -no PARTLABEL "${cands[0]}" 2>/dev/null | tr -d ' ' | grep -qix "super"; then
      echo "UWAGA: ${cands[0]} ma uklad Androida 13 (partycja 'super'), nie A17." >&2
    fi
    echo "${cands[0]}"; return 0
  fi
  if [ "${#cands[@]}" -eq 0 ]; then
    {
      echo "STOP: nie znalazlem nosnika Dragon Q6A."
      echo "Szukam dysku, ktorego tablica GPT ma partycje o nazwie 'ESP' (dowolny rozmiar,"
      echo "dowolna szyna: SD, USB, NVMe). Widoczne dyski:"
      lsblk -o NAME,SIZE,TYPE,TRAN,RM,RO,FSTYPE,PARTLABEL,MODEL
      echo
      echo "Jesli nosnik jest na liscie, podaj go jawnie, np.:  sudo $0 /dev/sdX"
      echo "Jesli go nie ma - nie zostal jeszcze podpiety albo nie ma na nim naszego obrazu."
    } >&2
    return 1
  fi
  {
    echo "STOP: pasuje ${#cands[@]} nosnikow - nie zgaduje, ktory:"
    for d in "${cands[@]}"; do
      printf "  %-16s %s  %s\n" "$d" "$(lsblk -dno SIZE $d)" "$(lsblk -dno MODEL $d 2>/dev/null)"
    done
    echo "Podaj urzadzenie jawnie, np.:  sudo $0 ${cands[0]}"
  } >&2
  return 1
}
