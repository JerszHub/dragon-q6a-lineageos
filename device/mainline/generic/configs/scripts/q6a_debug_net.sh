#!/system/bin/sh
# LOCAL DEBUG AID for the Radxa Dragon Q6A bring up. NOT upstream material.
#
# Follows device/mainline/generic/docs/debugging.md, section
# "Gathering ADB access via ethernet ... when system services encounters crash loop".
# Requires androidboot.insecure_adb=true (present in the a17 command line).
#
# WHY setprop service.adb.tcp.port: VERIFIED 2026-09-19 — nothing in the image sets this
# property (an earlier assumption that product.prop did was simply wrong). Without it adbd
# listens on USB only and the TCP connection times out despite correct ARP.
#
# Addresses below are from the development setup: 192.168.137.50 (host = Windows ICS at
# 192.168.137.1) and 192.168.1.100. Adjust them for your network, or drop this file.
# Then: adb connect 192.168.137.50:5555
#
# Remove once the display works and the framework comes up on its own.
set -x

# 2026-09-19, AFTER FIXING THE DP LANE ORIENTATION: "stop" was REMOVED from this script.
# It was needed while SurfaceFlinger was looping (DP never trained), because netd then
# restarted endlessly and wiped the manual eth0 configuration. With the
# data-lanes/orientation-switch fix the link trains at HBR2 and SF is healthy, so "stop"
# only got in the way: the script did "stop adbd; start adbd", which flips init.svc.adbd,
# which through the trigger in q6a_debug_net.rc restarts this script, which runs "stop"
# again — Android reached the logo and died, over and over (24 service starts in a single
# boot were observed). The address configuration stays; the loop below defends it from netd.

/system/bin/ip link set eth0 up
/system/bin/ip address add 192.168.137.50/24 dev eth0
/system/bin/ip address add 192.168.1.100/24 dev eth0
/system/bin/ip rule add from all lookup main

# Restart adbd ONLY when the port is not set yet. Without this guard the script feeds
# itself: "stop adbd" -> init.svc.adbd changes -> the trigger in q6a_debug_net.rc restarts
# this script -> "stop adbd" again -> ... (24 service starts in a single boot).
if [ "$(/system/bin/getprop service.adb.tcp.port)" != "5555" ]; then
    /system/bin/setprop service.adb.tcp.port 5555
    /system/bin/stop adbd
    /system/bin/start adbd
fi

# netd is running now (there is no "stop" any more), so it will manage the interfaces.
# For about four and a half minutes we make sure our static address survives its work.
i=0
while [ $i -lt 90 ]; do
    /system/bin/sleep 3
    /system/bin/ip address show eth0 | /system/bin/grep -q "192.168.137.50" || {
        /system/bin/ip address add 192.168.137.50/24 dev eth0
        /system/bin/ip address add 192.168.1.100/24 dev eth0
        /system/bin/ip rule add from all lookup main
    }
    i=$((i + 1))
done

/system/bin/ip address show eth0
/system/bin/ip rule show
