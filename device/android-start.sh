#!/bin/sh
# Aufruf: sh android-start.sh check|start|stop|reset
AND=/mnt/onboard/.adds/android
cd "$AND" || exit 1
mkdir -p run
Q="$AND/qemu"
QEMU_CMD="$Q/lib/ld-musl-armhf.so.1 --library-path $Q/lib:$Q/usr/lib $Q/usr/bin/qemu-system-arm"
. "$AND/qemu-args.sh"

case "$1" in
check)
    avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
    [ -z "$avail" ] && avail=$(awk '/^(MemFree|Cached):/{s+=$2} END{print s}' /proc/meminfo)
    [ "${avail:-0}" -ge 650000 ] || { echo "Zu wenig freier RAM: ${avail} kB (min. 650000)"; exit 2; }
    [ -f data.qcow2 ] || cp data.base.qcow2 data.qcow2 || { echo "data.qcow2 fehlt"; exit 3; }
    exit 0 ;;
stop)
    [ -f run/qemu.pid ] && kill "$(cat run/qemu.pid)" 2>/dev/null
    sleep 1; [ -f run/qemu.pid ] && kill -9 "$(cat run/qemu.pid)" 2>/dev/null
    rm -f run/qemu.pid; exit 0 ;;
reset)
    cp -f data.base.qcow2 data.qcow2; exit $? ;;
start)
    t0=$(date +%s)
    echo "== loadvm homescreen =="
    run_qemu -pidfile run/qemu.pid -loadvm homescreen
    rc=$?
    if [ $rc -ne 0 ] && [ $(( $(date +%s) - t0 )) -lt 40 ]; then
        echo "== loadvm fehlgeschlagen (rc=$rc), Kaltstart =="
        cp -f data.base.qcow2 data.qcow2   # Snapshot-Stand sicherstellen
        run_qemu -pidfile run/qemu.pid
    fi ;;
esac
