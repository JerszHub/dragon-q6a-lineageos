#!/bin/bash
# mk_a17_diag.sh — turns a release image into a diagnostic one that records the whole boot
#                  log on the card, for boards that reset before anything can be read.
#
# The only changes against the release image:
#   - a generic_init built with the boot log recorder (StartBootLog in first_stage_init.cpp,
#     patches/experimental/generic_init-q6a-bootlog.patch) is appended to the ramdisk as an
#     extra cpio archive; the kernel unpacks archives in order, so it replaces the original
#   - the default entry `a17` gets androidboot.q6a_bootlog=1
# Kernel, DTB, system, vendor and the boot entry's other parameters stay byte-identical.
#
# The log lands on the ESP in q6a-bootlog/boot-0.log (latest boot), boot-1.log, boot-2.log.
#
# Usage: mk_a17_diag.sh <release.img> <generic_init> <output.img>
set -euo pipefail
SRC=$1; GI=$2; OUT=$3
OFF=$(( $(sgdisk -i 1 "$SRC" | awk '/First sector/{print $3}') * 512 ))
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

cp --sparse=always "$SRC" "$OUT"
SPEC="$OUT@@$OFF"

echo "=== ramdisk"
mcopy -i "$SPEC" ::/Android/ramdisk-all-combined.img "$TMP/ramdisk.img"
python3 - "$GI" "$TMP/extra.cpio" <<'EOF'
import sys
data = open(sys.argv[1], 'rb').read()
def entry(name, mode, body):
    name = name.encode() + b'\0'
    hdr = b'070701' + b''.join(b'%08X' % v for v in
          (0, mode, 0, 0, 1, 0, len(body), 0, 0, 0, 0, len(name), 0))
    out = hdr + name
    out += b'\0' * (-len(out) % 4) + body
    return out + b'\0' * (-len(out) % 4)
arc = entry('system/bin/generic_init', 0o100755, data) + entry('TRAILER!!!', 0, b'')
arc += b'\0' * (-len(arc) % 512)
open(sys.argv[2], 'wb').write(arc)
EOF
lz4 -l -9 -q "$TMP/extra.cpio" "$TMP/extra.cpio.lz4"
cat "$TMP/ramdisk.img" "$TMP/extra.cpio.lz4" > "$TMP/ramdisk-diag.img"
mcopy -o -i "$SPEC" "$TMP/ramdisk-diag.img" ::/Android/ramdisk-all-combined.img
echo "    $(stat -c %s "$TMP/ramdisk.img") -> $(stat -c %s "$TMP/ramdisk-diag.img") bytes"

echo "=== boot entry"
mtype -i "$SPEC" ::/loader/entries/a17.conf > "$TMP/a17.conf"
grep -q "q6a_bootlog" "$TMP/a17.conf" || sed -i '/^options/ s/$/ androidboot.q6a_bootlog=1/' "$TMP/a17.conf"
sed -i 's/^title .*/title      LineageOS 24 (diagnostic boot log)/' "$TMP/a17.conf"
bad=$(awk '($1=="linux"||$1=="initrd"||$1=="devicetree") && NF!=2' "$TMP/a17.conf")
[ -z "$bad" ] || { echo "STOP: malformed entry: $bad"; exit 1; }
mcopy -o -i "$SPEC" "$TMP/a17.conf" ::/loader/entries/a17.conf
grep -o "androidboot.q6a_bootlog=1" "$TMP/a17.conf" | sed 's/^/    /'

echo "=== log directory"
mmd -i "$SPEC" ::/q6a-bootlog 2>/dev/null || true
cat > "$TMP/README.txt" <<'EOF'
Boot logs of this diagnostic image. boot-0.log is the latest boot, boot-1.log and
boot-2.log the two before it. Each is the kernel log (/dev/kmsg) from power-on until the
board reset or was switched off. Send all three files.
EOF
mcopy -o -i "$SPEC" "$TMP/README.txt" ::/q6a-bootlog/README.txt
echo "done: $OUT"
