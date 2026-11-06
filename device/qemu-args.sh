# Gemeinsam genutzt von CI (Snapshot erzeugen) und Kobo (Snapshot laden).
# Beide MÜSSEN dieselbe Gerätekonfiguration sehen, sonst schlägt loadvm fehl.
# Erwartet: $AND (Verzeichnis), $QEMU_CMD (Befehl, evtl. mit Loader), $NETOPT (optional).
# VNC_DISPLAY ist nur fuer getrennte CI-Tests; auf dem Kobo gilt stets 0.
GUEST_W=480
GUEST_H=640
run_qemu() {
    # CI erstellt den Snapshot mit virtio-gpu-device. PCI waere eine andere
    # migrierbare Geraetekonfiguration und darf nicht still gewaehlt werden.
    # Kein eigener "-device help"-Start: Fehlt das Modul, meldet der eigentliche
    # QEMU-Aufruf den Fehler selbst. Das spart einen langsamen Zusatzprozess.
    # virtio-gpu und virtio-input sind in QEMU "virtio 1.0 only". Der virtio-mmio-Transport der
    # virt-Maschine ist standardmaessig Legacy -> beide Geraete werden vom Gast-Kernel nie gebunden
    # (kein fb0, kein Eingabegeraet, surfaceflinger bricht mit "failed to open framebuffer" ab).
    # Deshalb moderne Transportversion erzwingen (virtio-blk/net/rng laufen damit ebenfalls).
    # Eine vCPU liess im Kaltstartvergleich auf dem Testhost Android schneller
    # vorankommen und laesst auf einem Zweikern-Kobo mehr CPU fuer KOReader.
    # Kein Geschwindigkeitsversprechen fuer den echten Kobo. Ein Wechsel auf
    # zwei vCPUs erfordert zwingend einen passenden neu erzeugten Snapshot.
    $QEMU_CMD -M virt -cpu cortex-a15 -m 512 -smp 1 -accel tcg,thread=multi,tb-size=64 \
        -global virtio-mmio.force-legacy=false \
        -rtc base=utc,clock=host -nodefaults \
        -kernel "$AND/zImage" -initrd "$AND/ramdisk.img" \
        -append "console=ttyAMA0,115200 rdinit=/init androidboot.hardware=goldfish androidboot.console=ttyAMA0 qemu=1 qemu.gles=0 android.checkjni=0" \
        -drive file="$AND/system.img",if=none,id=sys,format=raw,readonly=on,cache=unsafe \
        -device virtio-blk-device,drive=sys \
        -drive file="$AND/data.qcow2",if=none,id=dat,format=qcow2,cache=writeback \
        -device virtio-blk-device,drive=dat \
        -netdev "user,id=n0${NETOPT:-}" -device virtio-net-device,netdev=n0 \
        -device "virtio-gpu-device,xres=$GUEST_W,yres=$GUEST_H" \
        -device virtio-rng-device \
        -device virtio-keyboard-device -device virtio-tablet-device \
        -serial file:"$AND/run/console.log" \
        -vnc "127.0.0.1:${VNC_DISPLAY:-0}" "$@"
}
