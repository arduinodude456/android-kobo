# Android für KOReader auf dem Kobo – optimierte Fassung

Dieses Projekt führt Android 4.4.2 als 32-Bit-ARM-Gast in QEMU aus und zeigt das Bild über ein KOReader-Plugin an. Es ist ein experimenteller Ansatz, kein natives Android und keine Hardwarevirtualisierung. Das Quellarchiv allein enthält **nicht** die erzeugten QEMU-, Kernel- und Android-Abbilder; diese werden durch den Build erzeugt.

## Was geändert wurde

- **QEMU:** ein virtueller CPU-Kern mit 64 MiB TCG-Übersetzungscache. In einem nicht vollständig kontrollierten Kaltstartvergleich auf dem Testhost kam der 1-vCPU-Gast schneller voran als der 2-vCPU-Gast. Auf dem Zweikern-Kobo kann so zudem ein physischer Kern für KOReader frei bleiben. Der Vergleich belegt keine schnellere Reaktion auf dem Kobo und ist kein App-Benchmark. Der Gastkernel unterstützt auch SMP; QEMU nutzt weiterhin Softwareemulation, nicht KVM.
- **Grafik und SurfaceFlinger:** Der virtuelle Bildschirm ist auf 480 × 640 statt 632 × 840 Pixel eingestellt. Das sind rund 58 % der bisherigen Pixel und bedeutet weniger Detail. Die Software-Komposition hat dadurch weniger Pixel zu bearbeiten. Die pauschale Veränderung aller SurfaceFlinger-Threadprioritäten wurde entfernt. Das verhindert, dass unterschiedliche Originalprioritäten überschrieben werden; ein garantierter Geschwindigkeitsgewinn ist das nicht.
- **Android:** Die Vorgabe, die Dalvik-Verifikation und DEX-Optimierung abschaltete, wurde entfernt. Der Build deaktiviert die softwaregerenderte Bootanimation direkt in der Ramdisk; Android-Übergangsanimationen werden im Gast abgeschaltet. Bei Erfolg erstellt der Build einen vorbereiteten Homescreen-Snapshot. Diese Änderungen benötigen eine neue Ramdisk und einen neu erstellten Snapshot; ein alter Snapshot übernimmt sie nicht nachträglich.
- **KOReader und Touch:** RFB/VNC liest Bilddaten nicht mehr synchron bis zum vollständigen Rechteck, sondern stückweise mit Zeit- und Mengenbudget. Auch das Skalieren erfolgt in kleinen Stücken. Eingaben werden während großer Übertragungen weiterbearbeitet; unvollständig gesendete TCP-Daten werden korrekt nachgesendet. Bildschirmänderungen werden zusammengefasst und nur bei tatsächlichen Änderungen aktualisiert. Die große Kopie bei der Ersteinrichtung erfolgt im Hintergrund statt auf der UI-Schleife. Das Plugin kann auch mit dem ursprünglichen Startskript verwendet werden; dann bleiben allerdings dessen alte Snapshot- und Datenverlust-Risiken bestehen.
- **Datenschutz beim Start:** Ein Snapshot wird nur beim ersten Start einer nachweislich unveränderten Kopie des Basisimages geladen. Spätere Starts booten kalt und setzen vorhandene Android-Daten nicht automatisch auf den Snapshot zurück. Ein ausdrückliches Zurücksetzen ersetzt die Daten weiterhin. Die VM wird beim Beenden jedoch nicht garantiert im Gast ordnungsgemäß heruntergefahren; sichere wichtige Daten zusätzlich.

Es gibt keine gemessene Vorher-nachher-Latenz auf dem Libra Colour. Die Änderungen beheben konkrete Blockaden und reduzieren Arbeit, beweisen aber nicht, dass die gemeldeten sieben Minuten allein durch diese Ursachen entstanden sind. E-Ink, Softwaregrafik, RAM und die CPU begrenzen die erreichbare Geschwindigkeit weiterhin.

## Vollständiges Paket bauen

1. Dieses Verzeichnis als GitHub-Repository hochladen oder in ein bestehendes Repository übernehmen.
2. Unter **Actions → build-android-kobo → Run workflow** den normalen Build starten; `diag_only` ausgeschaltet lassen.
3. Nach erfolgreichem Build das Artefakt **android-kobo** herunterladen und entpacken. Der Workflow verwendet standardmäßig Googles API-19-ARM-v7-Systemabbild; die Repository-Variable `ANDROID19_SYSIMG_URL` kann bei Bedarf eine kompatible andere Quelle vorgeben. Bitte Googles SDK-Lizenzbedingungen beachten.
4. Der normale Build schlägt bei fehlgeschlagenem Boot oder Snapshot fehl, statt stillschweigend ein defektes Paket als fertig auszugeben. `build-status.txt` im Paket beschreibt den Status. Ein ausschließlich zur Diagnose erlaubtes `COLD_BOOT_ONLY`-Paket enthält keinen vorbereiteten Snapshot und startet langsamer.

Der Build kann lange dauern. Sein QEMU und das mitgelieferte Kobo-QEMU müssen zueinander und zu `qemu-args.sh` passen. Vorhandene 632×840-Snapshots sind mit der neuen 480×640-Konfiguration nicht zuverlässig kompatibel: **das vollständige Paket neu bauen**, statt lediglich `qemu-args.sh` zu überschreiben und den alten Snapshot weiterzuverwenden. Für ein Experiment mit zwei vCPUs muss das Paket samt Snapshot mit den entsprechend geänderten QEMU-Argumenten neu gebaut werden; ein Wechsel ohne neuen Snapshot ist nicht unterstützt.

## Installation und Backup

1. Android und KOReader beenden. Auf dem Computer den bisherigen Ordner `.adds/android` und das Plugin `.adds/koreader/plugins/android.koplugin` vollständig sichern, besonders `data.qcow2`. Auf ausreichend freien Speicher achten.
2. Aus dem gebauten Paket den Ordner `android` als `.adds/android` und `koreader/plugins/android.koplugin` als `.adds/koreader/plugins/android.koplugin` auf den Kobo kopieren. Für einen sauberen Ersttest keinen alten `run`-Ordner übernehmen.
3. KOReader neu starten und im Menü **Android → Starten** wählen. Die erste Einrichtung kopiert `data.base.qcow2` nach `data.qcow2`; bei einem intakten Snapshot wird dieser einmalig geladen. Spätere Starts sind Kaltstarts, damit der gespeicherte Android-Datenträger nicht zurückgesetzt wird.
4. Oben links lange drücken, um Android zu beenden. Die seitlichen Tasten dienen als Android-Zurück/Home, sofern sie von KOReader entsprechend zugeordnet werden. **Zurücksetzen** löscht die Daten im Arbeitsimage nach Bestätigung.

Wer vorhandene Android-Daten weiterverwenden möchte, behält zunächst die Sicherung unverändert und kopiert dann nur die alte `data.qcow2` in das neue `.adds/android`-Verzeichnis; keinen alten `run`-Ordner und keinen alten Snapshot zurückspielen. Der erste Start erfolgt kalt. Kompatibilität mit einem abweichenden alten Android-Systemabbild ist nicht garantiert. Ein Rückweg ist durch Wiederherstellen des gesicherten alten Ordners möglich.

## Grenzen und Sicherheit

Android 4.4.2 und das verwendete Entwickler-Systemabbild sind veraltet und sicherheitstechnisch nicht für sensible Konten geeignet. VNC bindet nur an `127.0.0.1`, verwendet dort aber keine Authentifizierung. Der Entwicklungs-Build verwendet einen privilegierten ADB-Dienst im Gast. Nicht ungeschützt ins Netz freigeben und keine sensiblen Zugangsdaten verwenden.

Die Anzahl der virtuellen CPUs und der Grafikmodus sind Bestandteil der Snapshot-Konfiguration. Änderungen daran erfordern einen neuen Snapshot mit denselben QEMU-Geräten und kompatibler Version. Siehe [Technische Quellen](docs/QUELLEN.md).

## Tests

```sh
# LuaJIT und LuaSocket erforderlich
luajit tests/plugin/test_rfb.lua
luajit tests/plugin/test_view.lua
luajit tests/plugin/test_socket.lua
python3 tests/device/test_start.py
sh tests/ci/test_bootanim.sh

# Grundlegende Shell- und Python-Syntax
for f in device/*.sh ci/*.sh; do sh -n "$f" || exit 1; done
python3 -m py_compile ci/patch-virtgpu-fb.py ci/patch-virtio-input.py
```

Die Tests ersetzen keinen echten Test auf dem Kobo. Der Projekt-Build wurde zusätzlich in einer ARM-Testumgebung durchgeführt; Details zu erfolgreichen und nicht durchgeführten Tests stehen im Auslieferungshinweis.
