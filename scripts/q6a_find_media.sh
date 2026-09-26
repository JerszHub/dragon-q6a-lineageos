#!/bin/bash
# q6a_find_media.sh — shared medium detection for the Dragon Q6A. Meant to be sourced.
#
# WHY THIS EXISTS (community report, 2026-09-26):
#   "I get an error message when trying to run the make_userdata script. It can't find
#    the card. Does the SD card have to be over a certain size?"
# It did, and that was our bug. Every script carried a hardcoded `GB >= 200 && GB <= 300`
# window, written around the single 256 GB card this port was developed on. A 64 GB card,
# a 1 TB card — anything outside that window — failed with "card not found". The scripts
# also required RM=1 and TRAN=usb, so an NVMe drive in an enclosure (which reports RM=0)
# never matched either.
#
# HOW IT WORKS NOW: the medium is identified by what it *is* — a disk whose GPT contains a
# partition named "ESP". That holds regardless of size, removability or bus (USB, SD, NVMe),
# and needs no root, since PARTLABEL is readable from /sys. When more than one medium
# matches we do NOT guess: the candidates are listed and the caller must name one.

# q6a_find_media [min_GB]  -> prints the device path on stdout, returns 0 on success
q6a_find_media() {
  local min_gb="${1:-0}" d cands=() gb
  for d in /dev/sd? /dev/nvme?n? /dev/mmcblk?; do
    [ -b "$d" ] || continue
    # whole disks only, not partitions
    [ "$(lsblk -dno TYPE "$d" 2>/dev/null | tr -d '[:space:]')" = "disk" ] || continue
    # skip read-only media (WSL's own system images show up as these)
    [ "$(lsblk -dno RO "$d" 2>/dev/null | tr -d '[:space:]')" = "1" ] && continue
    # THE SIGNATURE: some partition carries the GPT name "ESP".
    # Case-insensitive on purpose: our Android 17 images name it "ESP", while the older
    # Android 13 images name it "esp". Caught by testing against a real Android 13 drive.
    lsblk -no PARTLABEL "$d" 2>/dev/null | tr -d ' ' | grep -qix "esp" || continue
    gb=$(( $(lsblk -bdno SIZE "$d" 2>/dev/null || echo 0) / 1024/1024/1024 ))
    [ "$gb" -lt "$min_gb" ] && continue
    cands+=("$d")
  done
  if [ "${#cands[@]}" -eq 1 ]; then
    # Warn when the medium carries the Android 13 layout (a `super` partition) so that a
    # working installation is not overwritten by accident.
    if lsblk -no PARTLABEL "${cands[0]}" 2>/dev/null | tr -d ' ' | grep -qix "super"; then
      echo "WARNING: ${cands[0]} has the Android 13 layout (a 'super' partition), not Android 17." >&2
    fi
    echo "${cands[0]}"; return 0
  fi
  if [ "${#cands[@]}" -eq 0 ]; then
    {
      echo "STOP: no Dragon Q6A medium found."
      echo "Looking for a disk whose GPT has a partition named 'ESP' (any size, any bus:"
      echo "SD, USB or NVMe). Visible disks:"
      lsblk -o NAME,SIZE,TYPE,TRAN,RM,RO,FSTYPE,PARTLABEL,MODEL
      echo
      echo "If the medium is listed, name it explicitly, e.g.:  sudo $0 /dev/sdX"
      echo "If it is not, it is either not attached yet or does not carry one of our images."
    } >&2
    return 1
  fi
  {
    echo "STOP: ${#cands[@]} media match — not guessing which one:"
    for d in "${cands[@]}"; do
      printf "  %-16s %s  %s\n" "$d" "$(lsblk -dno SIZE $d)" "$(lsblk -dno MODEL $d 2>/dev/null)"
    done
    echo "Name one explicitly, e.g.:  sudo $0 ${cands[0]}"
  } >&2
  return 1
}

# q6a_part <device> <n>  -> prints the Nth partition's device node
# /dev/sde -> /dev/sde2, but /dev/nvme0n1 -> /dev/nvme0n1p2 and /dev/mmcblk0 -> /dev/mmcblk0p2.
# Appending the number directly is correct only for sd*/vd*/hd*. This was latent until
# q6a_find_media started scanning nvme and mmcblk devices too (2026-09-26).
q6a_part() {
  case "$1" in
    *nvme*|*mmcblk*|*loop*) echo "${1}p${2}" ;;
    *)                      echo "${1}${2}"  ;;
  esac
}
