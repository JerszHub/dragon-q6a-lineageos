#!/system/bin/sh
# LOCAL DEBUG AID for the Radxa Dragon Q6A bring up. NOT upstream material.
#
# The procedure is the one in device/mainline/generic/docs/debugging.md, section
# "Gathering ADB access via ethernet ... when system services encounters crash loop".
# It needs androidboot.insecure_adb=true, which the board's boot entries already carry.
#
# WHY setprop service.adb.tcp.port: verified on hardware, nothing in the image sets this
# property. An earlier assumption that product.prop did was simply wrong. Without it adbd
# listens on USB only and a TCP connection times out despite correct ARP.
#
# Addresses: 192.168.137.50 (host side = Windows ICS on 192.168.137.1) and 192.168.1.100.
# Then: adb connect 192.168.137.50:5555
#
# Remove this once the framework comes up reliably on its own.
set -x

# "stop" USED TO BE THE FIRST COMMAND HERE, AND REMOVING IT WAS THE FIX.
# It was needed while SurfaceFlinger was looping, because netd restarted endlessly and
# wiped the manual eth0 configuration. Once DisplayPort link training started working,
# SurfaceFlinger became healthy and "stop" did nothing but harm: the script also does
# "stop adbd; start adbd", which toggles init.svc.adbd, which re-triggers this very
# service through the trigger in q6a_debug_net.rc, which runs "stop" again. Android then
# reached the logo and died, over and over (observed: 24 service starts in one boot).
# Setting the address stays; the loop at the bottom defends it against netd.

/system/bin/ip link set eth0 up
/system/bin/ip address add 192.168.137.50/24 dev eth0
/system/bin/ip address add 192.168.1.100/24 dev eth0
/system/bin/ip rule add from all lookup main

# Restart adbd ONLY when the port is not set yet. Without this guard the script feeds
# itself: "stop adbd" changes init.svc.adbd, the trigger in q6a_debug_net.rc restarts this
# script, which stops adbd again, and so on (24 service starts in a single boot).
if [ "$(/system/bin/getprop service.adb.tcp.port)" != "5555" ]; then
    /system/bin/setprop service.adb.tcp.port 5555
    /system/bin/stop adbd
    /system/bin/start adbd
fi

# netd is running now (there is no "stop" any more), so it will manage the interfaces.
# Keep our fixed address and the IPv6 link-local address alive for as long as the system
# runs: every 3 s for the first four and a half minutes, then every 10 s. EthernetService
# tears the eth0 network down whenever a better network becomes the default (a USB modem
# with internet, while this cable has none); IpClient then removes the addresses, sets
# disable_ipv6 and netd drops the eth0 routing table, which held the link-local route.
# That cuts adb off until the cable is replugged.
i=0
while true; do
    [ $i -lt 90 ] && /system/bin/sleep 3 || /system/bin/sleep 10
    [ "$(cat /proc/sys/net/ipv6/conf/eth0/disable_ipv6)" = "1" ] &&
        echo 0 > /proc/sys/net/ipv6/conf/eth0/disable_ipv6
    /system/bin/ip address show eth0 | /system/bin/grep -q "192.168.137.50" || {
        /system/bin/ip link set eth0 up
        /system/bin/ip address add 192.168.137.50/24 dev eth0
        /system/bin/ip address add 192.168.1.100/24 dev eth0
    }
    # Android puts the link-local prefix route in the per-interface table, not in main, and
    # its IPv6 rules never consult main. adb runs over the IPv6 link-local address, so both
    # the route and an IPv6 rule are needed once netd has dropped the eth0 table.
    /system/bin/ip -6 route show table main | /system/bin/grep -q "^fe80::/64 dev eth0" ||
        /system/bin/ip -6 route add fe80::/64 dev eth0 table main
    /system/bin/ip rule show | /system/bin/grep -q "from all lookup main" ||
        /system/bin/ip rule add from all lookup main
    /system/bin/ip -6 rule show | /system/bin/grep -q "from all lookup main" ||
        /system/bin/ip -6 rule add from all lookup main
    i=$((i + 1))
done
