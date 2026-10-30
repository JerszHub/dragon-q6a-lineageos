#!/system/bin/sh
# q6a_perf.sh — pin the Radxa Dragon Q6A at its maximum sustained clocks.
#
# WHAT THIS IS NOT: an overclock. The CPU frequency ceiling on QCS6490 lives in the EPSS/OSM
# lookup table, programmed by signed firmware, and qcom-cpufreq-hw only enables the device
# tree OPPs that the hardware table also contains. The table on this silicon ends at
# 1958400 / 2400000 / 2707200 kHz and carries no turbo rows, so /sys/.../cpufreq/boost
# refuses to turn on. Everything here works within those clocks.
#
# Usage: q6a_perf.sh max | stock | status
set -e
CPUFREQ=/sys/devices/system/cpu/cpufreq
GPU=/sys/class/devfreq/3d00000.gpu

cpu_apply() {
    for p in $CPUFREQ/policy*; do
        echo "$1" > "$p/scaling_governor"
    done
}

# Android creates these groups but this device leaves every one of them spanning all eight
# cores, so background work competes with the foreground for the A78s. Give the small
# cores to everything that is not user-visible and leave top-app the whole machine.
cpuset_apply() {
    [ -d /dev/cpuset ] || return 0
    for g in background system-background; do
        [ -d "/dev/cpuset/$g" ] && echo "$1" > "/dev/cpuset/$g/cpus"
    done
}

case "${1:-status}" in
max)
    cpu_apply performance
    # min = max pins the GPU; unlike on the vendor kernel this survives idle, so the
    # userspace governor is not needed.
    cat "$GPU/max_freq" > "$GPU/min_freq"
    cpuset_apply 0-3
    echo "performance mode on"
    ;;
stock)
    cpu_apply schedutil
    cat "$GPU/available_frequencies" | tr ' ' '\n' | grep -v '^$' | sort -n | head -1 > "$GPU/min_freq"
    cpuset_apply 0-7
    echo "back to stock behaviour"
    ;;
status)
    for p in $CPUFREQ/policy*; do
        printf '%-8s %-12s cur=%-9s min=%-9s max=%s\n' \
            "$(basename "$p")" "$(cat "$p/scaling_governor")" \
            "$(cat "$p/scaling_cur_freq")" "$(cat "$p/scaling_min_freq")" "$(cat "$p/scaling_max_freq")"
    done
    printf 'gpu      %-12s cur=%-9s min=%-9s max=%s\n' \
        "$(cat "$GPU/governor")" "$(cat "$GPU/cur_freq")" "$(cat "$GPU/min_freq")" "$(cat "$GPU/max_freq")"
    printf 'boost    %s\n' "$(cat "$CPUFREQ/boost" 2>/dev/null || echo 'n/a')"
    [ -d /dev/cpuset ] && for g in top-app foreground background system-background; do
        [ -d "/dev/cpuset/$g" ] && printf 'cpuset   %-17s %s\n' "$g" "$(cat "/dev/cpuset/$g/cpus")"
    done
    hot=0
    for z in /sys/class/thermal/thermal_zone*; do
        t=$(cat "$z/temp" 2>/dev/null) || continue
        [ "${t:-0}" -gt "$hot" ] && hot=$t
    done
    printf 'thermal  hottest zone %s C\n' "$((hot/1000))"
    thr=
    for c in /sys/class/thermal/cooling_device*; do
        s=$(cat "$c/cur_state" 2>/dev/null) || continue
        [ "${s:-0}" != "0" ] && thr="$thr $(cat "$c/type"):$s"
    done
    printf 'throttle %s\n' "${thr:-none}"
    ;;
*)
    echo "usage: $0 max | stock | status" >&2; exit 1 ;;
esac
