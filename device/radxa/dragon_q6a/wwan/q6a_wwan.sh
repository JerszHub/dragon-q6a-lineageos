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
#
# A SIM card with a PIN is unlocked with the PIN stored in $PIN_FILE (root only, unlike a
# system property, which apps can read).

TAG=q6a_wwan
OUT=/dev/q6a_wwan.at
PIN_FILE=/data/misc/q6a_wwan/pin
JAVA="/system/bin/app_process -Djava.class.path=${Q6A_WWAN_JAR:-/system_ext/framework/q6a-wwan.jar} /system/bin"
CONFIG="$JAVA org.lineageos.wwan.WwanConfig"
APNS="$JAVA org.lineageos.wwan.ApnLookup"
# Lenovo's FCC unlock key. Modules taken from Lenovo laptops keep the radio off at every
# power-up until the host answers AT+GTFCCLOCKGEN, as ModemManager's fcc-unlock does.
FCC_KEY=$(getprop persist.q6a.wwan.fcc_key)
FCC_KEY=${FCC_KEY:-3df8c719}

log() { /system/bin/log -t $TAG "$*"; }

# note <message> [state]: log the state the loop is waiting in, once per change, and
# publish it for WwanStatus as q6a.wwan.state.
note() {
    [ -n "$2" ] && state $2
    [ "$1" = "$NOTE" ] && return
    NOTE=$1
    log "$1"
}

state() {
    [ "$1" = "$STATE" ] && return
    STATE=$1
    setprop q6a.wwan.state $1
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
    chmod 600 $OUT
    cat $TTY >> $OUT 2>/dev/null &
    READER=$!
    READER_TTY=$TTY
    # The port opens in canonical mode with echo on: the tty would send everything the
    # modem says back to it, including the echo of each command, which the modem then runs
    # a second time.
    stty -F $TTY raw -echo
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

# Unlock the SIM card if it asks for a PIN. A rejected PIN is deleted straight away, so a
# wrong one costs a single attempt and can never use up the SIM's attempts and lock it
# behind the PUK.
sim_ready() {
    local out state
    out=$(at AT+CPIN?)
    state=$(echo "$out" | sed -n 's/^+CPIN: //p')
    case "$state" in
        READY)
            return 0 ;;
        "SIM PIN")
            if [ ! -s $PIN_FILE ]; then
                note "the SIM card needs a PIN, write it to $PIN_FILE" sim_pin
                return 1
            fi
            if at "AT+CPIN=\"$(cat $PIN_FILE)\"" 10 | grep -q '^OK'; then
                log "SIM card unlocked"
                return 0
            fi
            rm -f $PIN_FILE
            log "the SIM card rejected the PIN; $PIN_FILE deleted"
            state sim_pin
            ;;
        "")
            case "$out" in
                *"CME ERROR: 10"*) note "no SIM card" no_sim ;;
                *) note "SIM card not ready" starting ;;
            esac ;;
        *)
            note "SIM card locked: $state" sim_locked ;;
    esac
    return 1
}

registered() {
    at "AT+CEREG?" | grep -qE 'CEREG: [0-9]+,[15]' && return 0
    at "AT+C5GREG?" | grep -qE 'C5GREG: [0-9]+,[15]' && return 0
    at "AT+CGREG?" | grep -qE 'CGREG: [0-9]+,[15]'
}

# crsm <file id> <length>: read a transparent elementary file of the SIM card, as hex.
crsm() {
    at "AT+CRSM=176,$1,0,0,$2" |
        sed -n 's/^+CRSM: *144, *0, *"\{0,1\}\([0-9A-Fa-f]*\).*/\1/p' | sed 's/\(FF\)*$//'
}

# The APNs to try, one "apn|auth|user|password" per line. A user override alone; else the
# APN the network assigned to the default bearer at attach (context 0, e.g.
# "internet.mnc002.mcc260.gprs" -> "internet"), then the SIM card's entries in the APN
# database, matched by its IMSI, GID1 (EF 6F3E) and service provider name (EF 6F46), and
# "internet" last. The identifiers go to ApnLookup on stdin and are never logged.
apn_candidates() {
    local apn imsi gid1 spn
    apn=$(getprop persist.q6a.wwan.apn)
    if [ -n "$apn" ]; then
        echo "$apn|0||"
        return
    fi
    apn=$(at AT+CGCONTRDP=0 | sed -n 's/^+CGCONTRDP: 0,[0-9]*,"\([^"]*\)".*/\1/p' | head -n 1)
    apn=${apn%%.mnc*}
    case "$apn" in ims|sos|"") ;; *) echo "$apn|0||" ;; esac
    imsi=$(at AT+CIMI | grep -m 1 -E '^[0-9]{6,15}$')
    if [ -n "$imsi" ]; then
        gid1=$(crsm 28478 0)
        spn=$(crsm 28486 17)
        echo "$imsi ${gid1:--} ${spn:--}" | $APNS 2> /dev/null
    fi
    echo "internet|0||"
}

# connect <apn|auth|user|password>: make context 1 an active data session on this APN.
connect() {
    local apn auth user pass rest current
    # The "|" is quoted: mksh reads a bare one in a pattern as an alternative.
    apn=${1%%"|"*}
    rest=${1#*"|"}
    auth=${rest%%"|"*}
    rest=${rest#*"|"}
    user=${rest%%"|"*}
    pass=${rest#*"|"}
    if at "AT+CGACT?" | grep -q 'CGACT: 1,1'; then
        current=$(at AT+CGCONTRDP=1 | sed -n 's/^+CGCONTRDP: 1,[0-9]*,"\([^"]*\)".*/\1/p' | head -n 1)
        [ "${current%%.mnc*}" = "$apn" ] && return 0
        at "AT+CGACT=0,1" 30 > /dev/null
    fi
    log "connecting, APN $apn"
    at "AT+CGDCONT=1,\"IP\",\"$apn\"" > /dev/null
    if [ "$auth" = 0 ]; then
        at "AT+CGAUTH=1,0" > /dev/null
    else
        at "AT+CGAUTH=1,$auth,\"$user\",\"$pass\"" > /dev/null
    fi
    at "AT+CGACT=1,1" 60 | grep -q '^OK'
}

# cell: publish the serving cell for WwanStatus as q6a.wwan.cell,
# "operator|technology|band|RSRP dBm|RSRQ dB|SINR dB". The signal comes from MediaTek's
# AT+ECSQ, in quarter dB: on the LTE line (RAT 4096) field 6 is RSRQ, 7 RSRP, 9 SINR and
# 10 the band; AT+GTCCINFO reports the same values in whole dB.
cell() {
    local cops op act tech signal
    cops=$(at AT+COPS? | grep -m 1 '^+COPS:')
    op=$(echo "$cops" | sed -n 's/^+COPS: *[0-9]*,[0-9]*,"\([^"|]*\)".*/\1/p')
    case "$op" in
        *[!0-9]*|"") ;;
        *) at "AT+COPS=3,0" > /dev/null ;;   # numeric; ask for names from the next round
    esac
    act=$(echo "$cops" | sed -n 's/^+COPS: *[0-9]*,[0-9]*,"[^"]*",\([0-9]*\).*/\1/p')
    case "$act" in
        0|1|3) tech=2G ;;
        2|4|5|6) tech=3G ;;
        7) tech=LTE ;;
        13) tech=LTE+5G ;;
        10|11|12) tech=5G ;;
        *) tech= ;;
    esac
    signal=$(at AT+ECSQ | awk -F'[:,]' '/^\+ECSQ:/ && $9 + 0 == 4096 && $8 + 0 != 0 {
        printf "%d|%.0f|%.1f|%.0f", $11, $8 / 4, $7 / 4, $10 / 4; exit }')
    [ -n "$signal" ] || signal="|||"
    setprop q6a.wwan.cell "$op|$tech|$signal"
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
CANDS=
STATE=
while true; do
    set -- $(find_modem)
    if [ -z "$1" ]; then
        note "no modem" no_modem
        setprop q6a.wwan.cell ""
        CANDS=
        stop_reader
        release
        sleep 5
        continue
    fi
    TTY=/dev/$(ls $1:1.$2 2>/dev/null | grep -m 1 '^ttyUSB')
    IF=$(ls $1:1.0/net 2>/dev/null)
    if [ ! -c "$TTY" ] || [ -z "$IF" ]; then
        note "modem $1: waiting for the AT port and the network interface" starting
        sleep 2
        continue
    fi
    start_reader
    [ $(stat -c %s $OUT) -gt 65536 ] && : > $OUT
    if ! at AT | grep -q '^OK'; then
        note "modem $1: no answer on $TTY" starting
        sleep 2
        continue
    fi

    if ! fcc_unlock; then
        note "FCC unlock failed" fcc_failed
        sleep 10
        continue
    fi
    cell
    if ! sim_ready; then
        CANDS=
        sleep 5
        continue
    fi
    if ! registered; then
        note "not registered" searching
        sleep 5
        continue
    fi
    if [ -z "$CANDS" ]; then
        CANDS=$(apn_candidates | awk '!seen[$0]++')
        CAND_N=1
    fi
    CAND=$(echo "$CANDS" | sed -n "${CAND_N}p")
    if ! connect "$CAND"; then
        note "APN ${CAND%%"|"*} refused" connecting
        CAND_N=$((CAND_N + 1))
        if [ $CAND_N -gt $(echo "$CANDS" | wc -l) ]; then
            note "data connection failed with every APN" no_apn
            CANDS=
            sleep 30
        fi
        sleep 2
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
            note "$IF up: $IP gateway $GW DNS $DNS" connected
            setprop persist.q6a.wwan.iface $IF
            CUR_IF=$IF
            CUR_IP=$IP
        else
            note "EthernetService refused $IF: $(echo $R | tail -c 200)" no_apn
        fi
    elif [ -z "$IP" ]; then
        note "connected, but no address" connecting
    fi
    [ -n "$IP" ] && [ "$IF $IP" = "$CUR_IF $CUR_IP" ] && state connected
    sleep 5
done
