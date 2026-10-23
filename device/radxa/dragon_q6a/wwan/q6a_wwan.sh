#!/system/bin/sh
# SPDX-FileCopyrightText: 2026 The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#
# q6a_wwan.sh - bring up a USB cellular modem as an Android Ethernet network.
#
# Supported: Fibocom FM350-GL (MediaTek T700) in its USB RNDIS compositions, 0e8d:7126
# (AT+GTUSBMODE=40, AT port on interface 4) and 0e8d:7127 (=41, the default, interface 6).
# The kernel binds rndis_host to interface 0 and option to the serial ports.
#
# The modem runs no DHCP server: the host has to use the address of the PDP context. This
# script reads it over the AT port and hands it to EthernetService as a static
# configuration (WwanConfig), which then brings the network up like any Ethernet.
#
# Only the AT port is opened. The modem's other serial ports (logging, diagnostics) are
# reported to crash its firmware when touched.

TAG=q6a_wwan
OUT=/dev/q6a_wwan.at
CONFIG="/system/bin/app_process -Djava.class.path=${Q6A_WWAN_JAR:-/system_ext/framework/q6a-wwan.jar} /system/bin org.lineageos.wwan.WwanConfig"
# Lenovo's FCC unlock key. Modules taken from Lenovo laptops keep the radio off at every
# power-up until the host answers AT+GTFCCLOCKGEN, as ModemManager's fcc-unlock does.
FCC_KEY=$(getprop persist.q6a.wwan.fcc_key)
FCC_KEY=${FCC_KEY:-3df8c719}

log() { /system/bin/log -t $TAG "$*"; }

# note <state>: log the state the loop is waiting in, once per change.
note() {
    [ "$1" = "$NOTE" ] && return
    NOTE=$1
    log "$1"
}

# Print "<usb device path> <AT interface number>" of the first supported modem.
find_modem() {
    for d in /sys/bus/usb/devices/*; do
        [ -f "$d/idVendor" ] || continue
        case "$(cat $d/idVendor):$(cat $d/idProduct)" in
            0e8d:7126) echo "$d 4"; return ;;
            0e8d:7127) echo "$d 6"; return ;;
        esac
    done
}

# One reader keeps the AT port open for the whole session: the option driver drops what
# the modem sends while nobody has the port open, so a reader started per command loses
# answers that arrive before it opens the port.
start_reader() {
    [ -n "$READER" ] && kill -0 $READER 2>/dev/null && [ "$READER_TTY" = "$TTY" ] && return
    stop_reader
    : > $OUT
    cat $TTY >> $OUT 2>/dev/null &
    READER=$!
    READER_TTY=$TTY
}

stop_reader() {
    [ -n "$READER" ] && kill $READER 2>/dev/null && wait $READER 2>/dev/null
    READER=
}

# at <command> [timeout in s]: send one command, print the response without the echo.
at() {
    local start n=0 limit=$(( ${2:-5} * 10 ))
    start=$(( $(stat -c %s $OUT) + 1 ))
    printf '%s\r' "$1" > $TTY
    while [ $n -lt $limit ] &&
            ! tail -c +$start $OUT | grep -qE '^(OK|ERROR|\+CME ERROR)'; do
        sleep 0.1
        n=$((n + 1))
    done
    tail -c +$start $OUT | tr -d '\r' | grep -v -e '^$' -e "^$1\$"
}

fcc_unlock() {
    at AT+GTFCCEFFSTATUS? | grep -qE 'GTFCCEFFSTATUS: [0-9]+,0' || return 0
    local challenge hash
    challenge=$(at AT+GTFCCLOCKGEN | grep -oE '0x[0-9a-fA-F]+')
    [ -n "$challenge" ] || return 1
    hash=$(printf "%08x$FCC_KEY" $challenge | xxd -r -p | sha256sum | cut -c1-8)
    at "AT+GTFCCLOCKVER=$(printf %d 0x$hash)" | grep -q 'GTFCCLOCKVER: 1' || return 1
    log "FCC lock released"
}

registered() {
    at "AT+CEREG?" | grep -qE 'CEREG: [0-9]+,[15]' && return 0
    at "AT+C5GREG?" | grep -qE 'C5GREG: [0-9]+,[15]' && return 0
    at "AT+CGREG?" | grep -qE 'CGREG: [0-9]+,[15]'
}

# The APN: a user override, else the one the network assigned to the default bearer at
# attach (context 0, e.g. "internet.mnc002.mcc260.gprs" -> "internet"), else "internet".
# This covers most operators without an APN database.
pick_apn() {
    local apn
    apn=$(getprop persist.q6a.wwan.apn)
    if [ -z "$apn" ]; then
        apn=$(at AT+CGCONTRDP=0 | sed -n 's/^+CGCONTRDP: 0,[0-9]*,"\([^"]*\)".*/\1/p' | head -n 1)
        apn=${apn%%.mnc*}
        case "$apn" in ims|sos|"") apn=internet ;; esac
    fi
    echo "$apn"
}

connect() {
    local apn current
    apn=$(pick_apn)
    if at "AT+CGACT?" | grep -q 'CGACT: 1,1'; then
        current=$(at AT+CGCONTRDP=1 | sed -n 's/^+CGCONTRDP: 1,[0-9]*,"\([^"]*\)".*/\1/p' | head -n 1)
        [ "${current%%.mnc*}" = "$apn" ] && return 0
        at "AT+CGACT=0,1" 30 > /dev/null
    fi
    log "connecting, APN $apn"
    at "AT+CGDCONT=1,\"IP\",\"$apn\"" > /dev/null
    at "AT+CGACT=1,1" 60 | grep -q '^OK'
}

# EthernetService stores the static configuration under the interface name and keeps it
# across reboots, so it has to be undone when the modem goes away, or the next Ethernet
# adapter to get this name would inherit the modem's address.
release() {
    [ -n "$CUR_IF" ] || return
    $CONFIG $CUR_IF --dhcp > /dev/null 2>&1
    setprop persist.q6a.wwan.iface ""
    log "$CUR_IF released"
    CUR_IF=
    CUR_IP=
}

CUR_IF=$(getprop persist.q6a.wwan.iface)
CUR_IP=
READER=
while true; do
    set -- $(find_modem)
    if [ -z "$1" ]; then
        note "no modem"
        stop_reader
        release
        sleep 5
        continue
    fi
    TTY=/dev/$(ls $1:1.$2 2>/dev/null | grep -m 1 '^ttyUSB')
    IF=$(ls $1:1.0/net 2>/dev/null)
    if [ ! -c "$TTY" ] || [ -z "$IF" ]; then
        note "modem $1: waiting for the AT port and the network interface"
        sleep 2
        continue
    fi
    start_reader
    [ $(stat -c %s $OUT) -gt 65536 ] && : > $OUT
    if ! at AT | grep -q '^OK'; then
        note "modem $1: no answer on $TTY"
        sleep 2
        continue
    fi

    if ! fcc_unlock; then
        note "FCC unlock failed"
        sleep 10
        continue
    fi
    if ! registered; then
        note "not registered"
        sleep 5
        continue
    fi
    if ! connect; then
        note "data connection failed"
        sleep 5
        continue
    fi

    IP=$(at AT+CGPADDR=1 | grep -oE '([0-9]+\.){3}[0-9]+' | head -n 1)
    if [ -n "$IP" ] && [ "$IF $IP" != "$CUR_IF $CUR_IP" ]; then
        # The modem answers ARP for the .1 of the /24 (verified with Windows and Linux hosts),
        # so it serves as the gateway; .254 when the address itself ends in .1.
        GW=${IP%.*}.1
        [ "$GW" = "$IP" ] && GW=${IP%.*}.254
        DNS=$(at AT+CGCONTRDP=1 | awk -F'"' '/^\+CGCONTRDP: 1,/ { print $8, $10; exit }')
        if R=$($CONFIG $IF $IP/24 $GW ${DNS:-8.8.8.8} 2>&1); then
            note "$IF up: $IP gateway $GW DNS $DNS"
            setprop persist.q6a.wwan.iface $IF
            CUR_IF=$IF
            CUR_IP=$IP
        else
            note "EthernetService refused $IF: $(echo $R | tail -c 200)"
        fi
    elif [ -z "$IP" ]; then
        note "connected, but no address"
    fi
    sleep 10
done
