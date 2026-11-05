#!/system/bin/sh
# q6a_ws_brightness.sh — brightness of the WaveShare 7" HDMI LCD (C) from Android's slider.
#
# The panel takes brightness over USB HID (0eef:0005 "WaveShare WS170120", vendor collection,
# report ID 4), not through a backlight driver, so Android cannot drive it by itself.
# Protocol, from WaveShare's own tool: one write() of exactly 38 bytes,
#     04 AA 01 00 00 00 <BB> 00 ... 00
# with BB the brightness. The panel saturates at about 100, so BB runs from MIN to 100.
# BB = 0 switches off the backlight AND the touch controller (they share a supply), which leaves
# the panel unusable from its own screen, so nothing below MIN is ever sent.
#
#   q6a_ws_brightness.sh            follow the slider (the init service)
#   q6a_ws_brightness.sh set <N>    one-shot, N = MIN..MAX
MIN=8
MAX=100
POLL=0.05
PKT=/data/vendor/q6a_ws_brightness

find_dev() {
    for h in /sys/class/hidraw/hidraw*; do
        grep -q '^HID_ID=0003:00000EEF:00000005$' "$h/device/uevent" 2>/dev/null || continue
        # The vendor collection with report ID 4 (85 04), apart from touch (report ID 1).
        od -An -tx1 -v "$h/device/report_descriptor" | tr -d '\n' | grep -q '85 04' || continue
        echo "/dev/${h##*/}"
        return 0
    done
    return 1
}

# Every packet is built once and checked, so the loop only copies a file.
build_packets() {
    mkdir -p "$PKT" || return 1
    bb=$MIN
    while [ "$bb" -le "$MAX" ]; do
        f=$PKT/$bb
        {
            printf '\004\252\001'
            head -c 3 /dev/zero
            printf "\\$(printf %03o "$bb")"
            head -c 31 /dev/zero
        } > "$f"
        [ "$(wc -c < "$f" | tr -d ' ')" = 38 ] || { echo "packet $bb is not 38 bytes"; return 1; }
        [ "$(od -An -tx1 -N7 "$f" | tr -d ' \n')" = "04aa01000000$(printf %02x "$bb")" ] ||
            { echo "packet $bb has wrong bytes"; return 1; }
        bb=$((bb + 1))
    done
}

# DisplayPowerController's current brightness (0..1). It includes the temporary value while the
# slider is dragged; the brightness setting only changes when the finger lifts.
level() {
    dumpsys display 2>/dev/null | awk -F= -v lo=$MIN -v hi=$MAX \
        '/Display Brightness=/ { v = int(lo + $2 * (hi - lo) + 0.5); if (v < lo) v = lo; if (v > hi) v = hi; print v; exit }'
}

build_packets || exit 1

if [ "$1" = set ]; then
    [ "$2" -ge "$MIN" ] && [ "$2" -le "$MAX" ] || { echo "usage: $0 set <$MIN..$MAX>"; exit 1; }
    dev=$(find_dev) || { echo "panel not found"; exit 1; }
    cat "$PKT/$2" > "$dev"
    exit
fi

while :; do
    dev=$(find_dev) || { sleep 5; continue; }
    log -t q6a_ws_brightness "panel on $dev"
    last=
    while :; do
        v=$(level)
        if [ -n "$v" ] && [ "$v" != "$last" ]; then
            # A failed write means the panel went away: look for it again.
            cat "$PKT/$v" > "$dev" 2>/dev/null || break
            last=$v
        fi
        sleep $POLL
    done
    log -t q6a_ws_brightness "panel gone"
done
