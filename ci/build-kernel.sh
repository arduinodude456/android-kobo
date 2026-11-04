set -eu
mkdir -p out
[ -d linux ] || git clone --depth 1 -b deprecated/android-4.4 https://android.googlesource.com/kernel/common linux
# The deprecated Android 4.4 lowmemorykiller uses poll_table without including
# its defining header; patch the fetched upstream tree before compiling it.
grep -q '^#include <linux/poll.h>$' linux/drivers/staging/android/lowmemorykiller.c || \
    sed -i '/^#include <linux\/circ_buf.h>$/a #include <linux/poll.h>' linux/drivers/staging/android/lowmemorykiller.c
# KitKat-Userspace (liblog/logcat) braucht /dev/log/*; der Logger-Treiber fehlt in android-4.4.
# Aus dem 3.18-Staging-Baum vendored (ci/logger) und in Kconfig/Makefile eingehaengt.
SA=linux/drivers/staging/android
cp ci/logger/logger.c ci/logger/logger.h "$SA"/
grep -q 'ANDROID_LOGGER' "$SA/Kconfig" || python3 - "$SA/Kconfig" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
blk = "config ANDROID_LOGGER\n\tbool \"Android log driver\"\n\tdefault y\n\n"
i=s.index("config ASHMEM")
open(p,"w").write(s[:i]+blk+s[i:])
PY
grep -q 'logger.o' "$SA/Makefile" || printf 'obj-$(CONFIG_ANDROID_LOGGER)\t\t+= logger.o\n' >> "$SA/Makefile"
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
# netd (KitKat) richtet beim Start iptables-Regeln ein; fehlen die Tabellen, scheitert
# NetworkManagementService und system_server/zygote laufen im Neustart-Loop. Alles fest einbauen (MODULES=n).
for o in NETFILTER NETFILTER_ADVANCED NF_CONNTRACK NF_CONNTRACK_IPV4 NF_CONNTRACK_IPV6 NF_NAT NF_NAT_IPV4 NF_DEFRAG_IPV4 NF_DEFRAG_IPV6 \
         NETFILTER_XTABLES NETFILTER_XT_MARK NETFILTER_XT_CONNMARK NETFILTER_XT_TARGET_MARK NETFILTER_XT_TARGET_CONNMARK \
         NETFILTER_XT_TARGET_TCPMSS NETFILTER_XT_TARGET_NFLOG NETFILTER_XT_MATCH_COMMENT NETFILTER_XT_MATCH_CONNMARK \
         NETFILTER_XT_MATCH_CONNTRACK NETFILTER_XT_MATCH_MARK NETFILTER_XT_MATCH_OWNER NETFILTER_XT_MATCH_QUOTA \
         NETFILTER_XT_MATCH_STATE NETFILTER_XT_MATCH_STATISTIC NETFILTER_XT_MATCH_MULTIPORT NETFILTER_XT_MATCH_LIMIT \
         NETFILTER_XT_MATCH_PKTTYPE NETFILTER_XT_MATCH_TCPMSS NETFILTER_XT_MATCH_U32 NETFILTER_XT_MATCH_HELPER \
         NETFILTER_XT_MATCH_QTAGUID NETFILTER_XT_MATCH_QUOTA2 NETFILTER_XT_MATCH_SOCKET NETFILTER_XT_TARGET_REDIRECT \
         NETFILTER_XT_NAT NETFILTER_XT_TARGET_MASQUERADE \
         IP_NF_IPTABLES IP_NF_FILTER IP_NF_MANGLE IP_NF_NAT IP_NF_TARGET_REJECT IP_NF_TARGET_MASQUERADE IP_NF_TARGET_REDIRECT \
         IP_NF_RAW IP6_NF_IPTABLES IP6_NF_FILTER IP6_NF_MANGLE IP6_NF_RAW IP6_NF_TARGET_REJECT IPV6 INET_ESP \
         IP_MULTIPLE_TABLES NET_SCHED NET_CLS_U32 CGROUPS ; do
    scripts/config --enable "$o" 2>/dev/null || true
done
# Alarm-Gerät, falls der Kernel es kennt (KitKat braucht /dev/alarm):
for o in RTC_INTF_ALARM RTC_INTF_ALARM_DEV ANDROID_ALARM_DEV; do scripts/config --enable "$o" 2>/dev/null || true; done
make olddefconfig
# Pflicht-Optionen pruefen: ohne virtio-gpu/fbdev gibt es kein /dev/graphics/fb0 (surfaceflinger
# stuerzt in Endlosschleife ab), ohne virtio-input keine Eingabe, ohne Logger kein logcat.
miss=0
for o in DRM_VIRTIO_GPU DRM_FBDEV_EMULATION VIRTIO_INPUT VIRTIO_MMIO VIRTIO_BLK VIRTIO_NET ANDROID_BINDER_IPC ASHMEM FB; do
    if ! grep -q "^CONFIG_$o=y" .config; then
        echo "FEHLT in .config: CONFIG_$o"; miss=1
        grep -rn -A8 "^config $o\$" --include=Kconfig* . 2>/dev/null | head -14 || true
    fi
done
grep -q '^CONFIG_ANDROID_LOGGER=y' .config || { echo 'FEHLT in .config: CONFIG_ANDROID_LOGGER'; miss=1; }
for o in IP_NF_IPTABLES IP_NF_FILTER IP_NF_MANGLE IP_NF_NAT IP6_NF_IPTABLES IP6_NF_FILTER NF_CONNTRACK; do
    grep -q "^CONFIG_$o=y" .config || { echo "FEHLT in .config: CONFIG_$o"; miss=1; }
done
[ "$miss" = 0 ] || { echo "Kernel-Konfiguration unvollstaendig (siehe oben)"; exit 1; }
grep -E 'CONFIG_(HW_RANDOM_VIRTIO|ANDROID_BINDER_IPC|ANDROID_BINDER_IPC_32BIT|ASHMEM|DRM_VIRTIO_GPU|VIRTIO_INPUT)[= ]' .config || true
# KitKat-Userspace spricht die alte 32-Bit-Binder-API (struct binder_write_read = 24 Byte).
grep -q '^CONFIG_ANDROID_BINDER_IPC_32BIT=y' .config || echo 'WARNUNG: ANDROID_BINDER_IPC_32BIT nicht aktiv - erzwinge per -DBINDER_IPC_32BIT=1'
make -j"$(nproc)" KCFLAGS="-Wno-error -DBINDER_IPC_32BIT=1" HOSTCFLAGS=-fcommon zImage || {
    # Paralleler Build verschluckt die eigentliche Fehlermeldung: seriell nachfahren (schnell, Objekte sind fertig)
    echo "=== BUILD-FEHLER (serieller Nachlauf) ==="
    make -j1 KCFLAGS="-Wno-error -DBINDER_IPC_32BIT=1" HOSTCFLAGS=-fcommon zImage 2>&1 | grep -v '^  CC\|^  LD\|^  AR' | tail -60
    exit 1
}
cp arch/arm/boot/zImage ../out/zImage
