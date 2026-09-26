#!/bin/bash
# add_halt_entry.sh — boot entry "a17-halt": stop on a fatal error instead of looping.
#
# WHY: when generic_init hits LOG(FATAL) it goes through InitAborter (util.cpp:644) ->
# InitFatalReboot(SIGABRT) -> RebootSystem, so the board reboots and loops, and whatever
# was on screen is gone before it can be read.
#
# androidboot.init_fatal_pause=true, which the normal entries already carry, does NOT help
# here: it is only consulted in the SIGNAL handler (reboot_utils.cpp:210), not on the
# LOG(FATAL) path.
#
# androidboot.init_fatal_panic=true does help: InitFatalReboot writes "c" to
# /proc/sysrq-trigger (reboot_utils.cpp:186) which panics the kernel. Combined with the
# panic=0 already on our command line, the kernel then HALTS instead of rebooting, and the
# error stays on screen long enough to read or photograph.
#
# Images are untouched. Only a boot entry is added; the existing entries stay.
#
# Usage: sudo add_halt_entry.sh [/dev/sdX]           <- plan only
#        sudo add_halt_entry.sh [/dev/sdX] --apply
set -euo pipefail
HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
APPLY=0; TARGET=""; BASE_ENTRY=a17
for a in "$@"; do case "$a" in --apply) APPLY=1;; /dev/*) TARGET="$a";; *) BASE_ENTRY="$a";; esac; done
if [ -z "$TARGET" ]; then source "$HERE/q6a_find_media.sh"; TARGET=$(q6a_find_media) || exit 1; fi
OFF=$(sgdisk -i 1 "$TARGET" | awk '/First sector/{print $3}')
SPEC="${TARGET}@@$((OFF*512))"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mtype -i "$SPEC" "::/loader/entries/${BASE_ENTRY}.conf" > "$TMP/base.conf" 2>/dev/null \
  || { echo "STOP: entry ${BASE_ENTRY}.conf not found on the medium"; exit 1; }

# Only the options line is touched — the linux/initrd/devicetree paths must stay intact.
awk '
  /^title/   { print "title      LineageOS 24 - DIAG: halt on fatal error, serial console"; next }
  /^options/ { line=$0
               gsub(/ androidboot\.init_fatal_reboot_target=[^ ]*/, "", line)
               # Drop the simpledrm blacklist. NOTE: this parameter was always a no-op —
               # CONFIG_DRM_SIMPLEDRM is not set in this kernel, so the initcall it names
               # does not exist. Removing it changes nothing; it is dropped only so the
               # entry stops implying the board has an early framebuffer from simpledrm.
               gsub(/ initcall_blacklist=simpledrm_platform_driver_init/, "", line)
               # Serial console as well: the screen stays black because generic_init dies
               # before the msm DRM driver binds, and pstore_blk did not register either.
               # UART is the only output that exists this early. It is slow (~11 KB/s,
               # blocking) so the boot takes far longer — acceptable for diagnosis.
               gsub(/ console=ttyMSM0[^ ]*/, "", line)
               gsub(/ earlycon/, "", line)
               # Output goes to the SERIAL console. Everything else was tried and does
               # not work on this board:
               #   console=tty0    - nothing until the msm DRM driver binds, and
               #                     generic_init dies long before that
               #   simpledrm       - CONFIG_DRM_SIMPLEDRM is not set; the initcall the
               #                     blacklist named never existed
               #   earlycon=efifb  - black screen, so the firmware does not hand a
               #                     framebuffer to the kernel through the EFI stub
               # Plain `earlycon` with no argument is correct here: the qcom_geni driver
               # only has OF_EARLYCON_DECLARE, so earlycon=qcom_geni,0xADDR is ignored and
               # the kernel takes the port from the device tree instead.
               # keep_bootcon stops the kernel dropping earlycon once ttyMSM0 comes up.
               gsub(/ keep_bootcon/, "", line)
               gsub(/ console=ttyMSM0[^ ]*/, "", line)
               gsub(/ earlycon[^ ]*/, "", line)
               print line " androidboot.init_fatal_panic=true loglevel=8" \
                          " earlycon console=ttyMSM0,115200n8 keep_bootcon ignore_loglevel"; next }
             { print }
' "$TMP/base.conf" > "$TMP/a17-halt.conf"

echo "=== target: $TARGET ==="
echo "--- generated entry:"
awk '{ if ($1=="linux"||$1=="initrd"||$1=="devicetree") printf "    %-11s fields=%d  %s\n",$1,NF,$2;
       else if ($1=="title") printf "    %-11s %s\n",$1,substr($0,12) }' "$TMP/a17-halt.conf"
# Print the WHOLE options line, wrapped. Cherry-picking patterns with grep -o hid a
# missing keep_bootcon and turned "earlycon=efifb" into a bare "earlycon" three times
# in a row (2026-09-26), each costing a boot cycle. Show everything instead.
echo "    --- full options line:"
grep "^options" "$TMP/a17-halt.conf" | fold -s -w 96 | sed 's/^/      /'
bad=$(awk '($1=="linux"||$1=="initrd"||$1=="devicetree") && NF!=2' "$TMP/a17-halt.conf")
[ -z "$bad" ] || { echo "STOP: malformed entry: $bad"; exit 1; }
for k in linux initrd devicetree; do
  [ "$(grep "^$k" "$TMP/base.conf" | awk '{print $2}')" = "$(grep "^$k" "$TMP/a17-halt.conf" | awk '{print $2}')" ] \
    || { echo "STOP: line '$k' changed"; exit 1; }
done
echo "    OK - paths untouched"

if [ "$APPLY" != 1 ]; then echo; echo "Plan only. To apply: sudo $0 $TARGET --apply"; exit 0; fi
mcopy -o -i "$SPEC" "$TMP/a17-halt.conf" ::/loader/entries/a17-halt.conf
"$HERE/set_default_entry.sh" a17-halt "$TARGET" 0
echo
echo "DONE. The board will now HALT on a fatal error instead of rebooting,"
echo "leaving the message on screen. Photograph it."
echo "Back to normal: sudo $HERE/set_default_entry.sh a17 $TARGET 0"
