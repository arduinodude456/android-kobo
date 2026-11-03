# Gemeinsam genutzt von CI (Snapshot erzeugen) und Kobo (Snapshot laden).
# Beide MÜSSEN dieselbe Gerätekonfiguration sehen, sonst schlägt loadvm fehl.
# Erwartet: $AND (Verzeichnis), $QEMU_CMD (Befehl, evtl. mit Loader), $NETOPT (optional)
GUEST_W=632
GUEST_H=840
run_qemu() {
    GPU_ARGS=
    if $QEMU_CMD -device help 2>&1 | grep -q 'virtio-gpu-device'; then
        GPU_ARGS="-device virtio-gpu-device,xres=$GUEST_W,yres=$GUEST_H"
    elif $QEMU_CMD -device help 2>&1 | grep -q 'virtio-gpu-pci'; then
        GPU_ARGS="-device virtio-gpu-pci,xres=$GUEST_W,yres=$GUEST_H"
    fi
    $QEMU_CMD -M virt -cpu cortex-a15 -m 512 -smp 1 -accel tcg \
        -rtc base=utc,clock=host -nodefaults \
        -kernel "$AND/zImage" -initrd "$AND/ramdisk.img" \
        -append "console=ttyAMA0 androidboot.hardware=goldfish androidboot.console=ttyAMA0 qemu=1 qemu.gles=0 android.checkjni=0" \
        -drive file="$AND/system.img",if=none,id=sys,format=raw,readonly=on \
        -device virtio-blk-device,drive=sys \
        -drive file="$AND/data.qcow2",if=none,id=dat,format=qcow2 \
        -device virtio-blk-device,drive=dat \
        -netdev "user,id=n0${NETOPT:-}" -device virtio-net-device,netdev=n0 \
        $GPU_ARGS \
        -device virtio-keyboard-device -device virtio-tablet-device \
        -serial file:"$AND/run/console.log" \
        -vnc 127.0.0.1:0 "$@"
}
