# Auslieferungs- und Testhinweise

## Getestet

- Der Android-4.4-Gastkernel wurde aus dem im Projekt vorgesehenen Android-Kernelzweig für ARM gebaut; die Virtio-GPU-/Framebuffer- und Touch-Patches wurden angewendet und Pflicht-Kerneloptionen geprüft.
- Das gebündelte 32-Bit-ARM-QEMU 9.0.2 wurde gestartet; Virtio-GPU und TCG-Konfiguration wurden geprüft. Einen Kobo hatte die Testumgebung nicht.
- Ein Android-4.4.2-ARM-Gast startete in QEMU bis zu laufendem Zygote und SurfaceFlinger. Die auf 480 × 640 eingestellte VNC-Anzeige und die nichtblockierende RFB-Implementierung wurden miteinander getestet.
- Mit dem tatsächlichen RFB-Client kamen Touch-Down/Up als `BTN_TOUCH` und die Navigationsknöpfe als `KEY_BACK` und `KEY_HOMEPAGE` im Android-Eingabetreiber an. Das bestätigt den Eingabepfad, nicht die Reaktionszeit einer Android-App.
- Eine separat gestartete Ramdisk mit abgeschalteter Bootanimation meldete bei laufendem SurfaceFlinger `init.svc.bootanim=stopped`.
- Automatische Tests decken fragmentierte VNC-Daten, begrenzte Arbeit pro Poll, die Reihenfolge teilweise gesendeter Eingaben, Bildschirmbereiche, Startfehler, Datensicherung und die Bootanimationsänderung ab.

## Noch nicht nachgewiesen

Der Android-Erststart und ein automatisch erzeugter Homescreen-Snapshot waren zum Testzeitpunkt noch nicht erfolgreich vollständig abgeschlossen. In einem Zweikern-Testgast wurde ein Android-Systemdienst während des langen Kaltstarts neu gestartet. Ein dauerhafter Startfehler ist damit nicht bewiesen; genauso wenig ist ein funktionsfähiger Homescreen-Snapshot bewiesen. Es gibt keine Messung auf einem Kobo Libra Colour und keinen Vorher-nachher-Nachweis für die behauptete Sieben-Minuten-Latenz. Die Langzeitanwendungen und ein sauberer Android-Shutdown sind nicht getestet.

Ein Paket mit `status=COLD_BOOT_ONLY` enthält **keinen** vorbereiteten Snapshot. Sein Kaltstart kann sehr lange dauern oder scheitern. Im Normalmodus muss der GitHub-Build fehlschlagen, wenn der Snapshot nicht erfolgreich erstellt werden konnte; nicht ein als vollständig behauptetes Paket daraus erzeugen.

## Sicherheit und Daten

Vor jeder Installation Android und KOReader beenden und `.adds/android` sowie das alte Plugin vollständig sichern. Insbesondere `data.qcow2` nur aus einer separaten Sicherung übernehmen. Der Starter setzt eine bestehende Arbeitsplatte nicht automatisch auf einen alten Snapshot zurück; das ausdrückliche Zurücksetzen löscht sie nach Bestätigung. Stromausfall oder erzwungenes Beenden können trotzdem Gastdaten beschädigen. Android 4.4 und das Entwickler-Systemabbild sind unsicher und nicht für sensible Daten geeignet.
