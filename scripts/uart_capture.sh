#!/bin/bash
# uart_capture.sh — captures the board's serial console into a file this session can read.
#
# WHY: on this board nothing else shows the early boot. console=tty0 stays blank until the
# msm DRM driver binds (long after generic_init has died), CONFIG_DRM_SIMPLEDRM is not set,
# earlycon=efifb produces nothing because the firmware does not hand a framebuffer to the
# kernel, and pstore_blk registers at late_initcall — after the NVMe has been probed.
# The UART is the only channel left.
#
# BEFORE RUNNING: the CP210x adapter must be passed through to WSL, otherwise it is not
# visible here (WSL2 does not map COM ports to /dev/ttyS*; those nodes are dummies).
# In a Windows terminal:
#     usbipd list
#     usbipd bind   --busid <BUSID of the CP210x>      (once, needs admin)
#     usbipd attach --wsl --busid <BUSID>
# The adapter then shows up here as /dev/ttyUSB0.
#
# WIRING: the board's UART is 1.8 V. RX on the adapter goes to the board's TX. Ground is
# shared. Only the receive direction is needed for capturing.
#
# Usage: sudo uart_capture.sh [output-file] [seconds]
#        Default: ~/q6a/uart_<date>.log, runs until Ctrl+C.
set -uo pipefail
HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
OUT=""; SECS=0
for a in "$@"; do case "$a" in ''|*[!0-9]*) OUT="$a";; *) SECS="$a";; esac; done
OUT="${OUT:-$HERE/uart_$(date +%m%d_%H%M).log}"

PORT=""
for p in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyACM0; do [ -e "$p" ] && { PORT="$p"; break; }; done
if [ -z "$PORT" ]; then
  echo "STOP: no /dev/ttyUSB* found — the adapter is not passed through to WSL."
  echo
  echo "In a Windows terminal run:"
  echo "    usbipd list"
  echo "    usbipd bind   --busid <BUSID of the CP210x>     (once, as administrator)"
  echo "    usbipd attach --wsl --busid <BUSID>"
  echo
  echo "Visible serial devices right now:"
  ls -l /dev/ttyUSB* /dev/ttyACM* 2>/dev/null | sed 's/^/    /' || echo "    (none)"
  exit 1
fi
echo "=== port: $PORT   ->   $OUT ==="
stty -F "$PORT" 115200 cs8 -cstopb -parenb -echo -icrnl -ixon -crtscts raw 2>/dev/null \
  || { echo "STOP: could not configure $PORT (run with sudo?)"; exit 1; }
echo "    115200 8N1, no flow control"
echo "    Power the board on now. Ctrl+C when the log stops moving."
[ "$SECS" -gt 0 ] && echo "    (stopping automatically after ${SECS}s)"
echo

: > "$OUT"
if [ "$SECS" -gt 0 ]; then
  timeout "$SECS" cat "$PORT" | tee -a "$OUT"
else
  cat "$PORT" | tee -a "$OUT"
fi
echo
echo "=== captured $(wc -l < "$OUT") lines into $OUT ==="
