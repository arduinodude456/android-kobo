# Läuft in alpine:3.x (x86_64) mit --network host. Erwartet: out/zImage, $SYS_URL
set -eu
apk add --no-cache qemu-system-arm qemu-hw-display-virtio-gpu qemu-img android-tools socat curl unzip cpio gzip file e2fsprogs e2fsprogs-extra coreutils
O=$PWD/out/android; mkdir -p $O work; cd work
curl -fL "$SYS_URL" -o sys.zip && unzip -oq sys.zip
D=$(dirname "$(find . -name system.img | head -1)")
file "$D/system.img" | grep -qiE 'ext[234]' || { echo "system.img ist kein ext4 (yaffs2?) - vorher konvertieren"; exit 1; }
cp "$D/system.img" $O/system.img
cp ../out/zImage $O/zImage
cp ../device/qemu-args.sh ../device/android-start.sh $O/
if command -v debugfs >/dev/null 2>&1; then
    echo "system.img root:"; debugfs -R 'ls -l /' "$O/system.img" 2>&1 || true
    echo "system.img /system:"; debugfs -R 'ls -l /system' "$O/system.img" 2>&1 || true
else
    echo "debugfs nicht verfuegbar - Diagnoseausgabe uebersprungen (nicht kritisch)"
fi

# Ramdisk patchen: eigene init.goldfish.rc (vda=/system, vdb=/data, adbd per TCP)
mkdir rd && (cd rd && gzip -dc "../$D/ramdisk.img" | cpio -id --quiet && cp ../../ci/init.goldfish.rc . \
    && { [ -f default.prop ] || touch default.prop; \
         sed -i -E '/^(ro\.secure|ro\.adb\.secure|ro\.debuggable)=/d' default.prop; \
         printf 'ro.secure=0\nro.adb.secure=0\nro.debuggable=1\n' >> default.prop; echo "default.prop:"; cat default.prop; } \
    && find . | cpio -o -H newc --quiet | gzip -9 > $O/ramdisk.img)

truncate -s 1G data.raw && mke2fs -q -t ext4 data.raw
qemu-img convert -O qcow2 data.raw $O/data.qcow2

export AND=$O QEMU_CMD=qemu-system-arm NETOPT=",hostfwd=tcp:127.0.0.1:5555-:5555"
mkdir -p $O/run; . $O/qemu-args.sh
$QEMU_CMD -device help 2>&1 | grep -q 'virtio-gpu-device' || { echo "QEMU kennt virtio-gpu-device nicht (Modul-Paket fehlt)"; exit 1; }
run_qemu -no-reboot -monitor unix:/tmp/mon,server,nowait > qemu.log 2>&1 &
QP=$!
mon() { echo "$1" | socat -t "${2:-5}" - UNIX-CONNECT:/tmp/mon; }

echo "warte auf adb ..."
# ADB-Server vorab starten, ohne dass der Daemon unsere Pipes/stdout festhaelt
timeout -s KILL 30 adb start-server </dev/null >/dev/null 2>&1 || true
adb_deadline=$(( $(date +%s) + 420 ))
last_log=0
adb_ready=false
PS4='+ [$(date +%T)] '
set -x
while [ "$(date +%s)" -lt "$adb_deadline" ]; do
    if ! kill -0 "$QP" 2>/dev/null; then
        echo "QEMU wurde beendet, bevor ADB erreichbar war"
        tail -20 qemu.log || true
        echo "=== Userspace-Teil der Konsole (ab Kernel-Ende) ==="
        sed -n '/Freeing unused kernel memory/,$p' "$O/run/console.log" | head -150 || true
        exit 1
    fi
    if grep -qE 'Kernel panic|end Kernel panic' "$O/run/console.log" 2>/dev/null; then
        echo "Kernel Panic erkannt"; tail -100 "$O/run/console.log"; exit 1
    fi
    now=$(date +%s)
    if [ $(( now - last_log )) -ge 30 ]; then
        last_log=$now
        echo "  ... console.log: $(cat "$O/run/console.log" 2>/dev/null | wc -l) Zeilen, letzte: $(tail -n1 "$O/run/console.log" 2>/dev/null | cut -c1-120)"
        echo "  ... adb: $(timeout -s KILL 10 adb devices </dev/null 2>&1 | tr '\n' ' ')"
    fi
    # "adb connect" ist noetig, damit der Server den Gast findet. Er taucht dann als
    # "emulator-5554" (device) auf, daneben evtl. 127.0.0.1:5555 (offline) -> nur "device" nutzen.
    echo "  [$(date +%T)] adb connect ..."
    timeout -s KILL 10 adb connect 127.0.0.1:5555 </dev/null >/dev/null 2>&1 || true
    SER=$(timeout -s KILL 10 adb devices </dev/null 2>/dev/null | awk '$2=="device"{print $1; exit}')
    if [ -n "$SER" ] && timeout -s KILL 15 adb -s "$SER" shell true </dev/null >/dev/null 2>&1; then
        adb_ready=true
        break
    fi
    sleep 5
done
set +x
[ "$adb_ready" = true ] || {
    echo "ADB nach 420 Sekunden nicht erreichbar"
    echo "=== haeufigste Konsolenzeilen (Boot-Loop-Erkennung) ==="
    sed 's/^\[[ 0-9.]*\] //' "$O/run/console.log" | sort | uniq -c | sort -rn | head -15 || true
    echo "=== Konsole: Zeilen 150-330 ==="
    sed -n '150,330p' "$O/run/console.log" || true
    tail -100 qemu.log || true
    tail -100 "$O/run/console.log" || true
    exit 1
}
A="timeout -s KILL 20 adb -s $SER"
# URSACHE (fuenfter Lauf): Unter TCG ist der Erststart (dexopt) sehr langsam; der Watchdog schiesst system_server
# einmal ab, zygote startet neu und erholt sich nach ~2 min. Der fruehe Abbruch bei EINEM 'restarting' war zu streng.
# Jetzt: bis 30 min warten, Abbruch nur bei wiederholtem Neustart-Loop (>=6 Beobachtungen).
restarts=0
for i in $(seq 1 360); do
    [ "$($A shell getprop sys.boot_completed | tr -d '\r')" = 1 ] && break
    if [ $(( i % 12 )) -eq 0 ]; then
        echo "  ... Boot-Wartezeit $(( i * 5 ))s: zygote=$($A shell getprop init.svc.zygote | tr -d '\r') sf=$($A shell getprop init.svc.surfaceflinger | tr -d '\r') bootanim=$($A shell getprop init.svc.bootanim | tr -d '\r') dev.bootcomplete=$($A shell getprop dev.bootcomplete | tr -d '\r')"
        $A shell logcat -d -v time 2>&1 | tr -d '\r' | grep -v 'I/ServiceManager' | tail -25 | cut -c1-220 || true
        # Bootloop erst nach wiederholtem Neustart abbrechen
        if [ "$($A shell getprop init.svc.zygote | tr -d '\r')" = restarting ]; then restarts=$((restarts+1)); fi
        if [ "$restarts" -ge 6 ]; then
            echo "zygote im Neustart-Loop - breche Warten ab"; break
        fi
    fi
    sleep 5
done
[ "$($A shell getprop sys.boot_completed | tr -d '\r')" = 1 ] || {
    echo "Boot nicht abgeschlossen"
    $A shell logcat -d -v time > logcat.txt 2>&1 || true
    $A shell ps > ps.txt 2>&1 || true
    echo "=== init.svc.* (Dienststatus) ==="; $A shell getprop | grep -E 'init\.svc|sys\.boot|vold|crypto|dev\.bootcomplete' || true
    echo "=== ps ==="; $A shell ps 2>&1 | head -60 || true
    echo "=== logcat (ohne ServiceManager-Rauschen, Anfang) ==="; $A shell logcat -d -v time 2>&1 | tr -d '\r' | grep -v 'I/ServiceManager' | head -150 | cut -c1-240 || true
    echo "=== logcat Fehler/Abstuerze ==="; $A shell logcat -d -v time 2>&1 | tr -d '\r' | grep -E 'F/|E/|DEBUG|AndroidRuntime|Fatal|signal|backtrace|SurfaceFlinger|Zygote' | head -120 | cut -c1-240 || true
    echo "=== tombstones ==="; $A shell 'ls -l /data/tombstones; for f in /data/tombstones/*; do echo "--- $f"; head -40 $f; done' 2>&1 | head -120 || true
    echo "=== dmesg ==="; $A shell dmesg 2>&1 | tail -60 || true
    echo "=== /dev/graphics, binder, ashmem ==="; $A shell ls -l /dev/graphics /dev/binder /dev/ashmem /dev/alarm 2>&1 || true
    tail -50 $O/run/console.log; exit 1
}
$A shell settings put global window_animation_scale 0
$A shell settings put global transition_animation_scale 0
$A shell settings put global animator_duration_scale 0
$A shell settings put system screen_off_timeout 2147483647
$A shell input keyevent KEYCODE_MENU
sleep 2
$A shell input keyevent KEYCODE_HOME
sleep 30
for i in $(seq 1 12); do
    $A shell dumpsys window | grep -q 'mCurrentFocus.*Launcher' && break; sleep 5
done
$A shell dumpsys window | grep 'mCurrentFocus.*Launcher' || {
    echo "Launcher nicht im Vordergrund"
    $A shell dumpsys window | grep -E 'mCurrentFocus|mFocusedApp' || true
    $A shell logcat -d -v time > logcat.txt 2>&1 || true
    exit 1
}
$A disconnect >/dev/null 2>&1 || true

mon "savevm homescreen" 600
mon "info snapshots" | grep -q homescreen || { echo "savevm fehlgeschlagen"; exit 1; }
mon quit; wait $QP || true
mv $O/data.qcow2 $O/data.base.qcow2
rm -rf $O/run; echo "Snapshot ok"
