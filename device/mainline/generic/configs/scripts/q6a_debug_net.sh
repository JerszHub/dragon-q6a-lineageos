#!/system/bin/sh
# LOCAL DEBUG AID for the Radxa Dragon Q6A bring up. NOT upstream material.
#
# Procedura 1:1 z device/mainline/generic/docs/debugging.md, sekcja
# "Gathering ADB access via ethernet ... when system services encounters crash loop".
# Wymaga androidboot.insecure_adb=true (mamy w cmdline wpisu a17-pdclk).
#
# DLACZEGO "stop" JEST PIERWSZY: framework na tej plycie kreci sie w petli
# (SurfaceFlinger nie wstaje, bo DP nie trenuje lacza), a kazdy restart netd
# i system_server czysci reczna konfiguracje eth0. "stop" zatrzymuje klase main,
# adbd przezywa (class core). Przy okazji konczy petle SurfaceFlingera, czyli
# daje nam STABILNY system do diagnozy zamiast wiecznie restartujacego sie.
#
# DLACZEGO setprop service.adb.tcp.port: SPRAWDZONE 2026-09-19 - nic w obrazie
# tej wlasciwosci NIE USTAWIA (wczesniej zalozylem, ze robi to product.prop - blednie).
# Bez niej adbd sluchа wylacznie po USB i polaczenie TCP wygasa mimo poprawnego ARP.
#
# Adresy: 192.168.137.50 (host = Windows ICS, 192.168.137.1) oraz 192.168.1.100.
# Potem: adb connect 192.168.137.50:5555
#
# Usunac, gdy wyswietlacz zacznie dzialac i framework bedzie wstawal sam.
set -x

# 2026-09-19, PO NAPRAWIE ORIENTACJI LINII DP: "stop" USUNIETY.
# Byl potrzebny, gdy SurfaceFlinger krecil sie w petli (DP nie trenowal lacza) - wtedy
# netd restartowal sie bez konca i czyscil reczna konfiguracje eth0. Po poprawce
# data-lanes/orientation-switch lacze trenuje sie na HBR2 i SF jest zdrowy, wiec "stop"
# tylko PRZESZKADZA: skrypt robi "stop adbd; start adbd", to przelacza init.svc.adbd,
# co przez wyzwalacz w q6a_debug_net.rc restartuje ten skrypt, ktory znowu robi "stop"
# -> Android wstaje do logo i ginie, w kolko (zaobserwowane: 24 starty uslugi w jednym boocie).
# Sama konfiguracja adresu zostaje - petla nizej pilnuje go przed netd.

/system/bin/ip link set eth0 up
/system/bin/ip address add 192.168.137.50/24 dev eth0
/system/bin/ip address add 192.168.1.100/24 dev eth0
/system/bin/ip rule add from all lookup main

# Restart adbd TYLKO gdy port nie jest jeszcze ustawiony. Bez tej blokady skrypt karmi
# sam siebie: "stop adbd" -> init.svc.adbd sie zmienia -> wyzwalacz w q6a_debug_net.rc
# restartuje ten skrypt -> znowu "stop adbd" -> ... (24 starty uslugi w jednym boocie).
if [ "$(/system/bin/getprop service.adb.tcp.port)" != "5555" ]; then
    /system/bin/setprop service.adb.tcp.port 5555
    /system/bin/stop adbd
    /system/bin/start adbd
fi

# netd teraz DZIALA (nie ma juz "stop"), wiec bedzie zarzadzal interfejsami.
# Przez ~4,5 minuty pilnujemy, zeby nasz staly adres przetrwal jego konfiguracje.
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
