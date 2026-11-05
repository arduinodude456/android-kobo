#!/system/bin/sh
# Drosselt den surfaceflinger-Hauptthread (nice 10).
# URSACHE (Lauf 7): Auf der einzigen emulierten vCPU (TCG) verbrauchte surfaceflinger ~92 % der CPU-Zeit
# (sum-exec 1084 s von 1185 s; system_server nur 13 s). system_server/zygote verhungern, der Watchdog
# schiesst system_server ab (Neustart-Schleife), sys.boot_completed wird nie 1. SF setzt sich selbst auf
# nice -8; hier auf +10 zuruecksetzen, damit system_server/Launcher zuerst Rechenzeit bekommen.
PRIO=${1:-10}
say() { echo "<6>sf-throttle: $*" > /dev/kmsg 2>/dev/null; }
sleep 3   # SF setzt seine eigene Prioritaet beim Start; danach ueberschreiben
n=0
pid=
while [ $n -lt 20 ]; do
    pid=$(ps | while read u p rest; do case "$rest" in */surfaceflinger) echo $p; break;; esac; done)
    [ -n "$pid" ] && break
    n=$((n+1)); sleep 1
done
[ -n "$pid" ] || { say "surfaceflinger nicht gefunden"; exit 1; }
renice $PRIO $pid >/dev/null 2>&1 || say "renice fehlgeschlagen/nicht vorhanden"
line=$(cat /proc/$pid/stat 2>/dev/null)
set -- ${line#*) }
# nach ")" : Feld3=state ... nice ist Feld 19 der Gesamtzeile -> hier das 17. Wort
shift 16
say "surfaceflinger pid=$pid nice=$1 (Ziel $PRIO)"
exit 0
