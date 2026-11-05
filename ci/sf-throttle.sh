#!/system/bin/sh
# Drosselt surfaceflinger (ALLE Threads) auf nice $1 (Standard 10).  Aufruf: init-Service "sf-throttle".
# URSACHE (Lauf 7 + Diagnoselauf): Auf der einzigen emulierten vCPU (TCG) verbraucht surfaceflinger ~92 % der
# CPU-Zeit (sum-exec 1084 s von 1185 s; system_server nur 13 s, Gast-Idle ~0 s). system_server/zygote
# verhungern, der Watchdog schiesst system_server ab (Neustart-Schleife), sys.boot_completed wird nie 1.
# surfaceflinger setzt sich selbst auf nice -8 (und seine Threads auf -8/-9). Frueher wurde nur der
# Hauptthread per "renice" gesetzt - setpriority(PRIO_PROCESS) wirkt unter Linux aber nur auf EINEN Thread
# (die tid), die uebrigen SF-Threads liefen mit -8 weiter. Hier daher jeden Thread einzeln, und wiederholt,
# weil SF Threads spaeter startet (EventThread, Binder-Threads) und seine Prioritaeten selbst zuruecksetzt.
#
# Nur mksh-Builtins + renice (Toolbox): kein ps|cut/sed/head/basename.
PRIO=${1:-10}
say() { echo "<6>sf-throttle: $*" > /dev/kmsg 2>/dev/null; }

find_sf() {
    pid=
    for d in /proc/[0-9]*; do
        read -r c < "$d/comm" 2>/dev/null || continue
        if [ "$c" = surfaceflinger ]; then pid=${d#/proc/}; return 0; fi
    done
    return 1
}

last=
n=0
# ~10 Minuten lang alle 3 s nachziehen (Erststart); danach bleibt der Zustand im Snapshot erhalten.
while [ $n -lt 200 ]; do
    if find_sf; then
        tids=
        for t in /proc/$pid/task/*; do tids="$tids ${t##*/}"; done
        renice $PRIO $tids >/dev/null 2>&1 || say "renice fehlgeschlagen"
        if [ "$tids" != "$last" ]; then
            last=$tids
            read -r line < /proc/$pid/stat 2>/dev/null
            set -- ${line#*) }
            shift 16   # Feld 19 (nice) des Hauptthreads
            say "surfaceflinger pid=$pid threads:$tids nice(main)=$1 (Ziel $PRIO)"
        fi
    fi
    n=$((n + 1))
    sleep 3
done
exit 0
