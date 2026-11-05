#!/bin/sh
# Aufruf: sh android-start.sh check|start|stop|reset
AND=/mnt/onboard/.adds/android
cd "$AND" || exit 1
mkdir -p run
Q="$AND/qemu"
PIDF=/tmp/android-qemu.pid   # tmpfs: Dateisperren funktionieren auf FAT32 (/mnt/onboard) nicht zuverlaessig
# Alle laufenden QEMU-Instanzen beenden (auch verwaiste ohne PID-Datei)
kill_qemu() {
    [ -f "$PIDF" ] && kill "$(cat "$PIDF")" 2>/dev/null
    for d in /proc/[0-9]*; do
        grep -q 'qemu-system-ar[m]' "$d/cmdline" 2>/dev/null && kill "${d#/proc/}" 2>/dev/null
    done
    sleep 1
    for d in /proc/[0-9]*; do
        grep -q 'qemu-system-ar[m]' "$d/cmdline" 2>/dev/null && kill -9 "${d#/proc/}" 2>/dev/null
    done
    rm -f "$PIDF" "$AND/run/qemu.pid"
}
# Modulpfad explizit setzen: Wegen des musl-Loaders zeigt /proc/self/exe auf den Loader, QEMU findet die
# Module (virtio-gpu!) sonst nicht -> Geraet fehlt -> loadvm: "Unknown savevm section ... virtio-gpu".
export QEMU_MODULE_DIR="$Q/usr/lib/qemu"
QEMU_CMD="$Q/lib/ld-musl-armhf.so.1 --library-path $Q/lib:$Q/usr/lib $Q/usr/bin/qemu-system-arm -L $Q/usr/share/qemu"
# Datenverzeichnis (VNC-Keymaps) ebenfalls explizit (-L), aus demselben Grund wie QEMU_MODULE_DIR.
[ -f "$Q/usr/share/qemu/keymaps/en-us" ] || echo "WARNUNG: $Q/usr/share/qemu/keymaps/en-us fehlt im Bundle"
. "$AND/qemu-args.sh"

# Loopback muss oben sein (bei ausgeschaltetem WLAN ist lo auf dem Kobo down -> "Network is unreachable" fuer
# 127.0.0.1, KOReader erreicht dann den VNC-Server von QEMU nicht).
up_lo() {
    ifconfig lo 127.0.0.1 netmask 255.0.0.0 up 2>/dev/null || ip link set lo up 2>/dev/null || true
}
# utime+stime je QEMU-Thread (kumulativ, 1/100 s). comm kann Leerzeichen enthalten -> an ") " trennen.
cpu_threads() {
    for t in /proc/$1/task/[0-9]*; do cat "$t/stat" 2>/dev/null; done | awk '{ l=$0; sub(/^[0-9]+ \(/,"",l); sub(/\) .*/,"",l); gsub(/ /,"_",l); r=$0; sub(/^.*\) /,"",r); split(r,f," "); printf "%s=%d ", l, f[12]+f[13] }'
}
# KOReader schaltet auf Kobo-Geraeten teils Kerne ab bzw. nutzt einen sparsamen CPU-Governor. Fuer die Emulation
# (TCG ist rein CPU-gebunden) alle Kerne online und Governor "performance"; Originalwerte werden gemerkt und
# beim Beenden wiederhergestellt.
CPUD=/sys/devices/system/cpu
cpu_boost() {
    : > run/cpu_saved
    for c in $CPUD/cpu[0-9]*; do
        [ -f "$c/online" ] || continue
        echo "$c/online $(cat "$c/online")" >> run/cpu_saved
        echo 1 > "$c/online" 2>/dev/null
    done
    for g in $CPUD/cpu[0-9]*/cpufreq/scaling_governor $CPUD/cpufreq/policy*/scaling_governor; do
        [ -f "$g" ] || continue
        echo "$g $(cat "$g")" >> run/cpu_saved
        echo performance > "$g" 2>/dev/null
    done
}
cpu_restore() {
    [ -f run/cpu_saved ] || return 0
    while read f v; do echo "$v" > "$f" 2>/dev/null; done < run/cpu_saved
    rm -f run/cpu_saved
}
cpu_state() { echo "online=$(cat $CPUD/online 2>/dev/null) gov=$(cat $CPUD/cpu0/cpufreq/scaling_governor 2>/dev/null) freq=$(cat $CPUD/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)"; }
case "$1" in
check)
    up_lo
    # Seitencache freigeben, dann messen. Schwelle per Datei run/min_ram_kb anpassbar (Standard 400000 kB).
    sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    MIN=$(cat run/min_ram_kb 2>/dev/null); MIN=${MIN:-400000}
    avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
    [ -z "$avail" ] && avail=$(awk '/^(MemFree|Cached):/{s+=$2} END{print s}' /proc/meminfo)
    [ "${avail:-0}" -ge "$MIN" ] || { echo "Zu wenig freier RAM: ${avail} kB (min. ${MIN}; anpassbar in run/min_ram_kb)"; exit 2; }
    [ -f data.qcow2 ] || cp data.base.qcow2 data.qcow2 || { echo "data.qcow2 fehlt"; exit 3; }
    exit 0 ;;
stop)
    kill_qemu; cpu_restore; exit 0 ;;
reset)
    cp -f data.base.qcow2 data.qcow2; exit $? ;;
start)
    up_lo
    kill_qemu
    cpu_restore; cpu_boost
    # TCG-Modus per Datei umschaltbar (run/tcg_thread = multi|single), ohne Snapshot-Neubau.
    TCG_THREAD=$(cat run/tcg_thread 2>/dev/null)
    case "$TCG_THREAD" in single|multi) ;; *) TCG_THREAD=multi ;; esac
    export TCG_THREAD
    # Diagnose nur auf ausdrücklichen Wunsch aktivieren: Die frühere Dauerschleife
    # hat auf dem Kobo zusätzlich CPU- und I/O-Zeit verbraucht und die Touch-Latenz erhöht.
    if [ -f "$AND/run/diagnostics" ]; then
      ( echo "$(date +%T) host: cores=$(grep -c '^processor' /proc/cpuinfo) tcg=$TCG_THREAD"
        while sleep 30; do
          pid=$(cat $PIDF 2>/dev/null); [ -n "$pid" ] || continue
          kill -0 "$pid" 2>/dev/null || break
          echo "$(date +%T) $(grep -E 'VmRSS' /proc/$pid/status | tr -s '\t\n ' ' ') $(cpu_state) ticks: $(cpu_threads $pid)"
        done ) > "$AND/run/progress.log" 2>&1 &
    fi
    t0=$(date +%s)
    echo "== loadvm homescreen =="
    run_qemu -pidfile $PIDF -loadvm homescreen
    rc=$?
    [ $rc -eq 4 ] && exit 4   # GPU-Modul fehlt: Kaltstart waere ebenfalls ohne Display
    if [ $rc -ne 0 ] && [ $(( $(date +%s) - t0 )) -lt 40 ]; then
        echo "== loadvm fehlgeschlagen (rc=$rc), Kaltstart =="
        cp -f data.base.qcow2 data.qcow2   # Snapshot-Stand sicherstellen
        run_qemu -pidfile $PIDF
    fi
    cpu_restore ;;
esac
