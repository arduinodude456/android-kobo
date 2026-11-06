#!/system/bin/sh
# Drosselt surfaceflinger NUR WAEHREND DES BOOTS (alle Threads auf nice $1, Standard 10) und setzt ihn nach
# sys.boot_completed=1 auf nice $2 (Standard 0) zurueck.  Aufruf: init-Service "sf-throttle".
#
# Hintergrund: Waehrend des Erststarts verbraucht surfaceflinger auf der einzigen emulierten vCPU (TCG) fast die
# ganze CPU-Zeit (Software-Komposition), system_server verhungert. Darum wird er beim Boot gedrosselt.
# FRUEHERER FEHLER: Die Drosselung blieb im Snapshot erhalten (nice 10 = nur ~10 % Gewicht gegen nice-0-Prozesse).
# Im Betrieb wartet dann jede App auf surfaceflinger (BufferQueue), der kaum CPU bekommt -> Touch/Bild
# reagieren extrem traege. Deshalb nach dem Boot zurueck auf normale Prioritaet.
#
# Nur mksh-Builtins + renice + getprop (Toolbox): kein ps|cut/sed/head/basename.
PRIO=${1:-10}
AFTER=${2:-0}
say() { echo "<6>sf-throttle: $*" > /dev/kmsg 2>/dev/null; }

find_sf() {
    pid=
    for d in /proc/[0-9]*; do
        read -r c < "$d/comm" 2>/dev/null || continue
        if [ "$c" = surfaceflinger ]; then pid=${d#/proc/}; return 0; fi
    done
    return 1
}
set_prio() {  # $1 = nice fuer alle Threads
    tids=
    for t in /proc/$pid/task/*; do tids="$tids ${t##*/}"; done
    renice $1 $tids >/dev/null 2>&1 || say "renice fehlgeschlagen"
}
ticks() {
    read -r line < /proc/$pid/stat 2>/dev/null || { echo 0; return; }
    set -- ${line#*) }
    echo $(( ${12} + ${13} ))
}

n=0
# Bis zum Bootende alle 3 s nachziehen (SF startet Threads spaeter und setzt Prioritaeten selbst zurueck).
while [ $n -lt 3000 ]; do
    [ "$(getprop sys.boot_completed)" = 1 ] && break
    find_sf && set_prio $PRIO
    n=$((n + 1)); sleep 3
done

# Nach dem Boot: normale Prioritaet, ein paar Mal wiederholen (spaet gestartete SF-Threads).
for i in 1 2 3 4 5 6 7 8 9 10; do
    if find_sf; then set_prio $AFTER; fi
    sleep 3
done
# Diagnose: SF-Last im Leerlauf (500 Ticks = 1 volle vCPU bei HZ=100) -> steht in console.log/dmesg
if find_sf; then
    a=$(ticks); sleep 5; b=$(ticks)
    say "nach Boot: surfaceflinger nice=$AFTER, CPU-Ticks in 5 s: $((b - a)) (500 = voll ausgelastet)"
fi
exit 0
