#!/bin/bash
# build_progress.sh — zywy licznik postepu builda AOSP/LineageOS.
# Czyta najnowszy ~/q6a/lineage/build_*.log i odswieza sie w miejscu.
# Uzycie: ~/q6a/build_progress.sh [plik.log]        (Ctrl+C konczy)
#
# Pokazuje: pasek, procent, cele, tempo (celi/s), czas trwania i szacowany czas do konca.
# ETA liczona z tempa z ostatnich ~60 s, nie ze sredniej od startu - inaczej po dlugiej
# fazie analizy Soong (gdzie ninja stoi) prognoza jest bez sensu.
set -u
LOG="${1:-}"
[ -z "$LOG" ] && LOG=$(ls -t ${LINEAGE_TREE:-$HOME/q6a/lineage}/build_*.log 2>/dev/null | head -1)
[ -n "$LOG" ] && [ -f "$LOG" ] || { echo "nie znalazlem logu builda"; exit 1; }
echo "log: $LOG"
echo

# Czas liczymy od STARTU BUILDA (pierwsza linia logu), nie od uruchomienia licznika -
# inaczej przy podlaczeniu sie do trwajacego builda pokazuje absurdalnie male wartosci.
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
    # Postep czytamy TYLKO po "Starting ninja". Soong i kati uzywaja tego samego formatu
    # [NN% x/y], wiec bez tego licznik pokazuje np. "100% 47/47" w fazie kati - co wyglada
    # jak skonczony build, a jest dopiero rozgrzewka. (Zaobserwowane 2026-09-21.)
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
        # Tempo liczymy w oknie 120 s. Krotsze okno (probowalem 20 s) daje przy starcie
        # ninji absurdy w stylu "zostalo 11h" - w pierwszych sekundach leca tanie cele,
        # a potem wchodzi ciezki clang++ i tempo zupelnie sie zmienia.
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
            ETAS="licze..."
        fi
        FILL=$((PCT/2)); BAR=$(printf "%${FILL}s" | tr ' ' '#'); PAD=$(printf "%$((50-FILL))s")
        printf "\r[%s%s] %3s%%  %s/%s  %s cel/s  trwa %dm%02ds  zostalo ~%s   " \
               "$BAR" "$PAD" "$PCT" "$CUR" "$TOT" "${RATE:-0}" $((EL/60)) $((EL%60)) "$ETAS"
    else
        FAZA=$(grep -aoE "Running product configuration|analyzing Android.bp|finishing Make packaging|bootstrap blueprint|Starting ninja" "$LOG" | tail -1)
        printf "\r  (ninja jeszcze nie ruszyla) %-40s trwa %dm%02ds   " "${FAZA:-faza wstepna}" $((EL/60)) $((EL%60))
    fi
    sleep 5
done
