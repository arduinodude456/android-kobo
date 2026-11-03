set -eu
mkdir -p out
[ -d linux ] || git clone --depth 1 -b deprecated/android-4.4 https://android.googlesource.com/kernel/common linux
cd linux
export ARCH=arm CROSS_COMPILE=arm-linux-gnueabi-
make multi_v7_defconfig
for o in ANDROID ANDROID_BINDER_IPC ANDROID_BINDER_IPC_32BIT ASHMEM ANDROID_LOW_MEMORY_KILLER STAGING \
         VIRTIO VIRTIO_MMIO VIRTIO_BLK VIRTIO_NET VIRTIO_INPUT DRM DRM_VIRTIO_GPU DRM_FBDEV_EMULATION \
         FB INPUT_EVDEV INPUT_TOUCHSCREEN EXT4_FS TMPFS DEVTMPFS DEVTMPFS_MOUNT AEABI \
         ANDROID_PARANOID_NETWORK NETFILTER INET_ESP_OFFLOAD? ; do
    o=${o%\?}; scripts/config --enable "$o" || true
done
scripts/config --set-str CMDLINE "" --disable MODULES
# Alarm-Gerät, falls der Kernel es kennt (KitKat braucht /dev/alarm):
for o in RTC_INTF_ALARM RTC_INTF_ALARM_DEV ANDROID_ALARM_DEV; do scripts/config --enable "$o" 2>/dev/null || true; done
make olddefconfig
grep -E 'CONFIG_(ANDROID_BINDER_IPC|ASHMEM|DRM_VIRTIO_GPU|VIRTIO_INPUT)=y' .config
make -j"$(nproc)" KCFLAGS=-Wno-error zImage
cp arch/arm/boot/zImage ../out/zImage
