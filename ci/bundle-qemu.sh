# Läuft in alpine:3.x (x86_64). Holt QEMU als armv7-Paket samt Abhängigkeiten.
set -eu
V=${ALPINE:-3.20}
mkdir -p /tmp/r out/android
apk add --root /tmp/r --arch armv7 --initdb --no-scripts --no-cache --allow-untrusted \
    -X https://dl-cdn.alpinelinux.org/alpine/v$V/main -X https://dl-cdn.alpinelinux.org/alpine/v$V/community \
    qemu-system-arm qemu-hw-display-virtio-gpu
rm -rf /tmp/r/var /tmp/r/usr/share/man /tmp/r/usr/share/doc /tmp/r/usr/share/locale /tmp/r/lib/apk /tmp/r/etc
# FAT32 kennt keine Symlinks -> dereferenzieren
mkdir -p out/android/qemu
for d in lib usr; do cp -aL /tmp/r/$d out/android/qemu/; done
rm -rf out/android/qemu/usr/lib/apk
test -e out/android/qemu/lib/ld-musl-armhf.so.1
ls out/android/qemu/usr/lib/qemu/ 2>&1 | grep -q 'virtio-gpu' || { echo "virtio-gpu-Modul fehlt im Buendel"; exit 1; }
