#!/bin/bash
# build_progress.sh — live progress counter for an AOSP/LineageOS build.
# Reads the newest build_*.log and refreshes in place.
# Usage: build_progress.sh [file.log]        (Ctrl+C to stop)
#
# Shows: a bar, percentage, targets, rate (targets/s), elapsed time and estimated time left.
# The ETA uses the rate over the last ~120 s, not the average since the start — otherwise
# the long Soong analysis phase (during which ninja is idle) makes it meaningless.
set -u
LOG="${1:-}"
[ -z "$LOG" ] && LOG=$(ls -t ${LINEAGE_TREE:-$HOME/q6a/lineage}/build_*.log 2>/dev/null | head -1)
[ -n "$LOG" ] && [ -f "$LOG" ] || { echo "no build log found"; exit 1; }
echo "log: $LOG"
echo

# Elapsed time is measured from the BUILD START (the log's first line), not from when
# this counter was started — otherwise attaching to a running build shows absurd values.
START=$(date -d "$(head -1 "$LOG" | sed 's/=== start //')" +%s 2>/dev/null)
[ -z "$START" ] && START=$(stat -c%Y "$LOG" 2>/dev/null) || true
[ -z "$START" ] && START=$(date +%s)
LAST_T=0; LAST_N=0; RATE=0
while true; do
    if grep -aq BUILD_EXIT "$LOG" 2>/dev/null; then
        EX=$(grep -a BUILD_EXIT "$LOG" | tail -1)
        printf "\r%-100s\n" " "
        if echo "$EX" | grep -q "BUILD_EXIT=0"; then echo "✅ $EX"; else echo "❌ $EX"; fi
        grep -an "^FAILED:\|^error:" "$LOG" | grep -av "kernel modules" | head -3
        exit 0
    fi
    # Progress is read ONLY after "Starting ninja". Soong and kati use the same
    # [NN% x/y] format, so without this the counter shows e.g. "100% 47/47" during kati,
    # which looks like a finished build but is only the warm-up. (Seen 2026-09-21.)
    NL=$(grep -an "Starting ninja" "$LOG" 2>/dev/null | tail -1 | cut -d: -f1)
    if [ -n "$NL" ]; then
        P=$(tail -n +"$NL" "$LOG" | grep -aoE '\[ *[0-9]+% [0-9]+/[0-9]+\]' | tail -1)
    else
        P=""
    fi
    NOW=$(date +%s); EL=$((NOW-START))
    if [ -n "$P" ]; then
        PCT=$(echo "$P" | grep -oE '[0-9]+%' | tr -d '%')
        CUR=$(echo "$P" | grep -oE '[0-9]+/' | tr -d '/')
        TOT=$(echo "$P" | grep -oE '/[0-9]+' | tr -d '/')
        # The rate uses a 120 s window. A shorter one (20 s was tried) swings wildly: cheap
        # targets go first and give optimistic figures, then the heavy clang++ work changes
        # the pace and the estimate jumps to absurd values like "11h left".
        if [ "$LAST_T" -eq 0 ]; then
            LAST_T=$NOW; LAST_N=$CUR
        elif [ $((NOW-LAST_T)) -ge 120 ] && [ "$CUR" -gt "$LAST_N" ]; then
            RATE=$(( (CUR-LAST_N) / (NOW-LAST_T) ))
            [ "$RATE" -lt 1 ] && RATE=1
            LAST_T=$NOW; LAST_N=$CUR
        fi
        if [ "${RATE:-0}" -gt 0 ] && [ "$TOT" -gt "$CUR" ]; then
            ETA=$(( (TOT-CUR) / RATE ))
            ETAS=$(printf "%dh%02dm" $((ETA/3600)) $(((ETA%3600)/60)))
        else
            ETAS="estimating..."
        fi
        FILL=$((PCT/2)); BAR=$(printf "%${FILL}s" | tr ' ' '#'); PAD=$(printf "%$((50-FILL))s")
        printf "\r[%s%s] %3s%%  %s/%s  %s targets/s  elapsed %dm%02ds  left ~%s   " \
               "$BAR" "$PAD" "$PCT" "$CUR" "$TOT" "${RATE:-0}" $((EL/60)) $((EL%60)) "$ETAS"
    else
        PHASE=$(grep -aoE "Running product configuration|analyzing Android.bp|finishing Make packaging|bootstrap blueprint|Starting ninja" "$LOG" | tail -1)
        printf "\r  (ninja has not started yet) %-40s running %dm%02ds   " "${PHASE:-early phase}" $((EL/60)) $((EL%60))
    fi
    sleep 5
done
