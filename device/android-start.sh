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

# CPU-Governor auf "performance" (QEMU/TCG ist reine CPU-Last; ondemand/conservative taktet zu traege hoch).
# Urspruengliche Werte werden gemerkt und bei stop/Ende wiederhergestellt.
GOVF=/tmp/android-gov.save
set_perf() {
    [ -f "$GOVF" ] || {
        : > "$GOVF"
        for g in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
            [ -w "$g" ] || continue
            echo "$g $(cat "$g")" >> "$GOVF"
        done
    }
    for g in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        [ -w "$g" ] && echo performance > "$g" 2>/dev/null
    done
    return 0
}
restore_gov() {
    [ -f "$GOVF" ] || return 0
    while read -r f v; do [ -n "$v" ] && echo "$v" > "$f" 2>/dev/null; done < "$GOVF"
    rm -f "$GOVF"
}
# QEMU hoeher priorisieren als KOReader (wartet auf die PID-Datei, laeuft parallel zum Vordergrund-QEMU)
boost_qemu() {
    i=0
    while [ $i -lt 30 ]; do
        [ -s "$PIDF" ] && break
        i=$((i + 1)); sleep 1
    done
    p=$(cat "$PIDF" 2>/dev/null); [ -n "$p" ] || return 0
    renice -n -5 -p "$p" >/dev/null 2>&1 || renice -5 -p "$p" >/dev/null 2>&1 || true
}

# Loopback muss oben sein (bei ausgeschaltetem WLAN ist lo auf dem Kobo down -> "Network is unreachable" fuer
# 127.0.0.1, KOReader erreicht dann den VNC-Server von QEMU nicht).
up_lo() {
    ifconfig lo 127.0.0.1 netmask 255.0.0.0 up 2>/dev/null || ip link set lo up 2>/dev/null || true
}
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
    kill_qemu; restore_gov; exit 0 ;;
reset)
    cp -f data.base.qcow2 data.qcow2; exit $? ;;
start)
    up_lo
    kill_qemu
    # Diagnose: alle 10 s Speicher-/Lesefortschritt von QEMU protokollieren (zeigt, ob loadvm vorankommt)
    ( while sleep 10; do
        pid=$(cat $PIDF 2>/dev/null); [ -n "$pid" ] || continue
        kill -0 "$pid" 2>/dev/null || break
        echo "$(date +%T) $(grep -E 'VmRSS|State' /proc/$pid/status | tr -s '\t\n ' ' ') $(grep -E '^rchar|read_bytes' /proc/$pid/io | tr '\n' ' ') $(grep MemAvailable /proc/meminfo | tr -s ' ')"
      done ) > "$AND/run/progress.log" 2>&1 &
    set_perf
    boost_qemu &
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
    restore_gov ;;
esac
