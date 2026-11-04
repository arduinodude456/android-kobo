set -eu
mkdir -p out
[ -d linux ] || git clone --depth 1 -b deprecated/android-4.4 https://android.googlesource.com/kernel/common linux
# The deprecated Android 4.4 lowmemorykiller uses poll_table without including
# its defining header; patch the fetched upstream tree before compiling it.
grep -q '^#include <linux/poll.h>$' linux/drivers/staging/android/lowmemorykiller.c || \
    sed -i '/^#include <linux\/circ_buf.h>$/a #include <linux/poll.h>' linux/drivers/staging/android/lowmemorykiller.c
cd linux
export ARCH=arm CROSS_COMPILE=arm-linux-gnueabi-
make multi_v7_defconfig
for o in ANDROID ANDROID_BINDER_IPC ANDROID_BINDER_IPC_32BIT ASHMEM ANDROID_LOW_MEMORY_KILLER STAGING \
         VIRTIO VIRTIO_MMIO VIRTIO_BLK VIRTIO_NET VIRTIO_INPUT DRM DRM_VIRTIO_GPU DRM_FBDEV_EMULATION \
         FB INPUT_EVDEV INPUT_TOUCHSCREEN EXT4_FS TMPFS DEVTMPFS DEVTMPFS_MOUNT AEABI \
         ANDROID_PARANOID_NETWORK NETFILTER HW_RANDOM HW_RANDOM_VIRTIO ANDROID_LOGGER ; do
    o=${o%\?}; scripts/config --enable "$o" || true
done
scripts/config --set-str CMDLINE "" --disable MODULES
# Alarm-Gerät, falls der Kernel es kennt (KitKat braucht /dev/alarm):
for o in RTC_INTF_ALARM RTC_INTF_ALARM_DEV ANDROID_ALARM_DEV; do scripts/config --enable "$o" 2>/dev/null || true; done
make olddefconfig
# Pflicht-Optionen pruefen: ohne virtio-gpu/fbdev gibt es kein /dev/graphics/fb0 (surfaceflinger
# stuerzt in Endlosschleife ab), ohne virtio-input keine Eingabe, ohne Logger kein logcat.
miss=0
for o in DRM_VIRTIO_GPU DRM_FBDEV_EMULATION VIRTIO_INPUT VIRTIO_MMIO VIRTIO_BLK VIRTIO_NET ANDROID_BINDER_IPC ASHMEM ANDROID_LOGGER FB; do
    if ! grep -q "^CONFIG_$o=y" .config; then
        echo "FEHLT in .config: CONFIG_$o"; miss=1
        grep -rn -A8 "^config $o\$" --include=Kconfig* . 2>/dev/null | head -14 || true
    fi
done
[ "$miss" = 0 ] || { echo "Kernel-Konfiguration unvollstaendig (siehe oben)"; exit 1; }
grep -E 'CONFIG_(HW_RANDOM_VIRTIO|ANDROID_BINDER_IPC|ANDROID_BINDER_IPC_32BIT|ASHMEM|DRM_VIRTIO_GPU|VIRTIO_INPUT)[= ]' .config || true
# KitKat-Userspace spricht die alte 32-Bit-Binder-API (struct binder_write_read = 24 Byte).
grep -q '^CONFIG_ANDROID_BINDER_IPC_32BIT=y' .config || echo 'WARNUNG: ANDROID_BINDER_IPC_32BIT nicht aktiv - erzwinge per -DBINDER_IPC_32BIT=1'
make -j"$(nproc)" KCFLAGS="-Wno-error -DBINDER_IPC_32BIT=1" HOSTCFLAGS=-fcommon zImage
cp arch/arm/boot/zImage ../out/zImage
