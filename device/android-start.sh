#!/bin/sh
# Aufruf: sh android-start.sh check|start|stop|reset
AND=/mnt/onboard/.adds/android
cd "$AND" || exit 1
mkdir -p run
Q="$AND/qemu"
PIDF=/tmp/android-qemu.pid   # tmpfs: Dateisperren funktionieren auf FAT32 (/mnt/onboard) nicht zuverlaessig

# Nur die eigene Instanz beenden, nicht alle QEMU-Prozesse des Hosts. Ein
# wiederverwendetes PID-File allein ist kein hinreichender Identitaetsnachweis.
our_qemu() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ -r "/proc/$1/cmdline" ] && grep -Fq "$Q/usr/bin/qemu-system-arm" "/proc/$1/cmdline" 2>/dev/null
}
kill_qemu() {
    p=$(cat "$PIDF" 2>/dev/null)
    if our_qemu "$p"; then
        kill "$p" 2>/dev/null || true
        i=0
        while our_qemu "$p" && [ "$i" -lt 5 ]; do
            sleep 1
            i=$((i + 1))
        done
        if our_qemu "$p"; then
            echo "WARNUNG: QEMU beendet sich nicht rechtzeitig; SIGKILL"
            kill -9 "$p" 2>/dev/null || true
            sleep 1
        fi
        if our_qemu "$p"; then
            echo "FEHLER: QEMU laeuft noch; Datentraeger nicht erneut oeffnen"
            return 1
        fi
    fi
    rm -f "$PIDF" "$AND/run/qemu.pid"
    return 0
}
# Ein verwaister Prozess ohne PID-Datei darf nicht versehentlich dasselbe
# FAT-Dateiimage parallel oeffnen. Nicht fremde QEMU-Instanzen beenden.
ensure_no_orphan() {
    for d in /proc/[0-9]*; do
        p=${d#/proc/}
        if our_qemu "$p" && grep -Fq "file=$AND/data.qcow2" "$d/cmdline" 2>/dev/null; then
            echo "FEHLER: QEMU-Prozess $p benutzt dieses Android-Image noch"
            return 1
        fi
    done
    return 0
}
# Modulpfad explizit setzen: Wegen des musl-Loaders zeigt /proc/self/exe auf den Loader, QEMU findet die
# Module (virtio-gpu!) sonst nicht -> Geraet fehlt -> loadvm: "Unknown savevm section ... virtio-gpu".
export QEMU_MODULE_DIR="$Q/usr/lib/qemu"
QEMU_CMD="$Q/lib/ld-musl-armhf.so.1 --library-path $Q/lib:$Q/usr/lib $Q/usr/bin/qemu-system-arm -L $Q/usr/share/qemu"
# Datenverzeichnis (VNC-Keymaps) ebenfalls explizit (-L), aus demselben Grund wie QEMU_MODULE_DIR.
[ -f "$Q/usr/share/qemu/keymaps/en-us" ] || echo "WARNUNG: $Q/usr/share/qemu/keymaps/en-us fehlt im Bundle"
. "$AND/qemu-args.sh"

# Fuer Upgrades: einen von einer frueheren Version hinterlassenen Governor
# wiederherstellen. Neue Starts veraendern den Host-Governor nicht mehr.
GOVF=/tmp/android-gov.save
restore_gov() {
    [ -f "$GOVF" ] || return 0
    while read -r f v; do [ -n "$v" ] && echo "$v" > "$f" 2>/dev/null; done < "$GOVF"
    rm -f "$GOVF"
}

# Fehlender, veralteter oder unvollstaendiger Buildstatus ist kein Beweis
# fuer einen kompatiblen Snapshot. Ohne Nachweis sicher kalt starten.
snapshot_status() {
    [ -f build-status.txt ] || { echo "Kein Buildstatus: Kaltstart"; return 1; }
    grep -qx 'status=SNAPSHOT' build-status.txt && grep -qx 'snapshot=homescreen' build-status.txt || {
        echo "Build ohne nachgewiesenen Snapshot: Kaltstart"; return 1;
    }
    return 0
}
snapshot_ready() {
    snapshot_status || return 1
    command -v sha256sum >/dev/null 2>&1 || { echo "sha256sum fehlt: Kaltstart"; return 1; }
    for file in qemu-args.sh data.base.qcow2; do
        expected=$(awk -v f="$file" '{ n=$2; sub(/^.*\//,"",n); if (n == f) { print $1; exit } }' build-status.txt)
        actual=$(sha256sum "$file" 2>/dev/null | awk '{print $1}')
        [ -n "$expected" ] && [ "$expected" = "$actual" ] || {
            echo "Snapshot-Zuordnung fuer $file fehlt oder stimmt nicht: Kaltstart"; return 1;
        }
    done
    return 0
}

# Nur ein vollstaendig kopiertes Basisimage als Arbeitsimage einsetzen. Ein
# Reset darf explizit ersetzen; beim ersten Check darf nichts ueberschrieben
# werden. Die Verzeichnissperre koordiniert parallel laufende eigene Skripte.
copy_base() {
    mode=$1
    mkdir run/data-copy.lock 2>/dev/null || { echo "FEHLER: Datenkopie bereits aktiv (run/data-copy.lock)"; return 1; }
    tmp="data.qcow2.tmp.$$"
    rm -f run/fresh-snapshot "$tmp"
    if [ ! -f data.base.qcow2 ] || ! cp data.base.qcow2 "$tmp"; then
        echo "FEHLER: data.base.qcow2 fehlt oder Kopie fehlgeschlagen"
        rm -f "$tmp"; rmdir run/data-copy.lock; return 1
    fi
    if [ "$mode" = initial ] && [ -e data.qcow2 ]; then
        echo "FEHLER: data.qcow2 wurde zwischenzeitlich angelegt; nicht ueberschrieben"
        rm -f "$tmp"; rmdir run/data-copy.lock; return 1
    fi
    if ! mv -f "$tmp" data.qcow2; then
        echo "FEHLER: Datenkopie konnte nicht eingesetzt werden"
        rm -f "$tmp"; rmdir run/data-copy.lock; return 1
    fi
    # Nur ein als Snapshot-Build markiertes Image kommt fuer loadvm in Frage;
    # start prueft danach noch die Hashes und die Arbeitskopie mit cmp.
    if snapshot_status; then : > run/fresh-snapshot; fi
    rmdir run/data-copy.lock
}

# Loopback muss oben sein (bei ausgeschaltetem WLAN ist lo auf dem Kobo down -> "Network is unreachable" fuer
# 127.0.0.1, KOReader erreicht dann den VNC-Server von QEMU nicht).
up_lo() {
    ifconfig lo 127.0.0.1 netmask 255.0.0.0 up 2>/dev/null || ip link set lo up 2>/dev/null || true
}
case "$1" in
check)
    up_lo
    # MemAvailable beruecksichtigt wiederverwendbaren Cache. Globales
    # drop_caches wuerde den naechsten Start und andere Programme ausbremsen.
    MIN=$(cat run/min_ram_kb 2>/dev/null); MIN=${MIN:-400000}
    avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
    [ -z "$avail" ] && avail=$(awk '/^(MemFree|Cached):/{s+=$2} END{print s}' /proc/meminfo)
    [ "${avail:-0}" -ge "$MIN" ] || { echo "Zu wenig freier RAM: ${avail} kB (min. ${MIN}; anpassbar in run/min_ram_kb)"; exit 2; }
    [ -f data.qcow2 ] || copy_base initial || exit 3
    exit 0 ;;
stop)
    kill_qemu; rc=$?
    restore_gov
    exit "$rc" ;;
reset)
    # Reset ist die explizit bestaetigte Ausnahme: vorhandene Daten werden ersetzt.
    p=$(cat "$PIDF" 2>/dev/null)
    if our_qemu "$p"; then echo "FEHLER: vor Reset Android stoppen"; exit 1; fi
    ensure_no_orphan || exit 1
    copy_base reset
    exit $? ;;
start)
    up_lo
    kill_qemu || exit 1
    ensure_no_orphan || exit 1
    restore_gov
    [ -f data.qcow2 ] || { echo "FEHLER: data.qcow2 fehlt; zuerst check ausfuehren"; exit 3; }
    fresh=0
    if [ -f run/fresh-snapshot ]; then
        if snapshot_ready && cmp -s data.qcow2 data.base.qcow2; then
            fresh=1
        else
            echo "Snapshot nicht nachgewiesen oder Arbeitsimage geaendert: kein Rollback"
        fi
        # Vor QEMU-Start entfernen: auch nach Absturz wird kein spaeterer
        # Start versehentlich auf einen alten Gast-Datentraeger zurueckgesetzt.
        rm -f run/fresh-snapshot
    fi
    # Erst jetzt darf das Plugin nach VNC suchen: vorher koennte noch eine alte
    # QEMU-Instanz laufen, waehrend die Datenkopie/Hashpruefung im Hintergrund laeuft.
    : > run/launch-ready
    if [ "$fresh" = 1 ]; then
        echo "== einmaliger loadvm homescreen auf unveraenderter Erstkopie =="
        run_qemu -pidfile "$PIDF" -loadvm homescreen
        rc=$?
        # Kein automatischer Neustart: stop kann QEMU absichtlich beenden;
        # ein sofortiger Fallback wuerde die VM dann unbemerkt neu starten.
        # Der Marker ist entfernt; der naechste Start bootet kalt und behielt
        # das vorhandene Arbeitsimage unveraendert bei.
        [ "$rc" -eq 0 ] || echo "QEMU beendet (rc=$rc); beim naechsten Start Kaltstart ohne Reset"
    else
        # loadvm setzt auch den Inhalt beschreibbarer Gastplatten zurueck.
        echo "== Kaltstart: vorhandene Android-Daten bleiben erhalten =="
        run_qemu -pidfile "$PIDF"
        rc=$?
    fi
    exit "$rc" ;;
*)
    echo "Aufruf: $0 check|start|stop|reset"; exit 1 ;;
esac
