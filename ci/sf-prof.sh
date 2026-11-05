#!/system/bin/sh
# Diagnose: wo verbringt surfaceflinger seine Zeit? (Aufruf: sh /sf-prof.sh)
p=$(ps | while read u q r; do case "$r" in */surfaceflinger) echo $q; break;; esac; done)
echo "sf pid=$p"
[ -n "$p" ] || exit 1
for n in 1 2 3; do
  for t in /proc/$p/task/*; do
    echo "$(basename $t) $(cat $t/comm) | syscall: $(cat $t/syscall 2>&1 | cut -c1-60) | wchan: $(cat $t/wchan 2>&1) | utime,stime: $(cat $t/stat | sed 's/^.*) //' | cut -d' ' -f12,13)"
  done
  echo ---; sleep 1
done
echo "== fds"; ls -l /proc/$p/fd 2>&1 | cut -c40-140
echo "== maps (Auszug)"; cat /proc/$p/maps | grep -E 'fb|graphics|drm|hwcomposer|gralloc|GLES|libagl|surfaceflinger|libui' | cut -c1-120
echo "== backtrace"; debuggerd -b $p 2>&1 | head -60
echo "== sysprops"; getprop | grep -E 'debug\.|sf\.|qemu|hwui|egl'
