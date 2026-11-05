#!/system/bin/sh
# Diagnose: wo verbringt surfaceflinger seine Zeit?  (Aufruf: sh /sf-prof.sh [crash])
#
# WICHTIG: Die KitKat-Toolbox kennt KEIN cut/sed/head/basename/awk (erster Diagnoselauf: "not found",
# dadurch waren alle Messwerte leer). Dieses Skript nutzt deshalb nur mksh-Builtins (read, ${x##*/},
# $((..)), eval) plus cat/ls/grep/debuggerd. Kuerzen und Filtern passiert auf dem Host (make-snapshot.sh).
#
# Ausgabe: je Thread die verbrauchten CPU-Ticks in 3 s (-> welcher Thread rennt?), Kontextwechsel
# (voluntary = blockiert er, nonvoluntary = laeuft er durch?), wchan/syscall, offene fds, geladene
# Grafik-Bibliotheken und drei Backtraces von debuggerd.
# "crash": zusaetzlich SIGSEGV an surfaceflinger (Tombstone mit Backtrace; init startet den Dienst neu).

p=
for d in /proc/[0-9]*; do
    [ -r "$d/comm" ] || continue
    read -r c < "$d/comm" 2>/dev/null
    if [ "$c" = surfaceflinger ]; then p=${d#/proc/}; break; fi
done
echo "sf pid=$p"
[ -n "$p" ] || { echo "surfaceflinger laeuft nicht:"; ps; exit 1; }

sample() {  # $1 = Phase; legt tk_<Phase>_<tid> = utime+stime ab
    ph=$1
    for t in /proc/$p/task/*; do
        tid=${t##*/}
        read -r line < "$t/stat" 2>/dev/null || continue
        rest=${line##*) }       # alles nach "(comm) ": Feld 3 = state ... utime = Feld 14 = $12, stime = $13
        set -- $rest
        eval "tk_${ph}_$tid=\$(( ${12} + ${13} ))"
    done
}

read -r up1 < /proc/uptime
sample a; sleep 3; sample b
read -r up2 < /proc/uptime
echo "== uptime: $up1 -> $up2  (zweite Zahl = Idle-Sekunden; ~0 heisst: die einzige vCPU ist voll ausgelastet)"
echo "== Threads von surfaceflinger: CPU-Ticks in ca. 3 s (bei HZ=100 sind 300 = eine volle CPU)"
for t in /proc/$p/task/*; do
    tid=${t##*/}
    eval "a=\$tk_a_$tid; b=\$tk_b_$tid"
    [ -n "$a" ] && [ -n "$b" ] || continue
    read -r name < "$t/comm" 2>/dev/null
    read -r wch < "$t/wchan" 2>/dev/null
    sc=$(cat "$t/syscall" 2>&1)
    echo "tid=$tid name=$name ticks=$((b - a)) wchan=${wch:-?} syscall=${sc:-?}"
done

echo "== Kontextwechsel je Thread (viele nonvoluntary + kaum voluntary = Thread rechnet durch)"
for t in /proc/$p/task/*; do
    echo "-- tid ${t##*/}"
    grep -E 'Name|State|ctxt_switches' "$t/status" 2>&1
done

echo "== stat des Hauptthreads"; cat /proc/$p/stat 2>&1
echo "== /proc/stat (cpu)";      grep '^cpu ' /proc/stat 2>&1
echo "== fds";                   ls -l /proc/$p/fd 2>&1
echo "== maps (Grafik/Framebuffer)"
grep -E 'fb|graphics|drm|hwcomposer|gralloc|GLES|libagl|egl|libui|libgui' /proc/$p/maps 2>&1
echo "== sysprops"
getprop | grep -E 'debug\.|sf\.|qemu|hwui|egl|init\.svc'

echo "== Backtraces (debuggerd -b), 3 Stueck"
for n in 1 2 3; do
    echo "-- Backtrace $n"
    debuggerd -b $p 2>&1
    sleep 1
done

if [ "$1" = crash ]; then
    echo "== SIGSEGV an surfaceflinger -> Tombstone (surfaceflinger wird danach neu gestartet)"
    kill -11 $p
    sleep 10
    ls -l /data/tombstones 2>&1
    for f in /data/tombstones/*; do
        [ -f "$f" ] || continue
        echo "-- $f"; cat "$f"
    done
fi
exit 0
