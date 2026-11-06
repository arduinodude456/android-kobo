#!/system/bin/sh
# Eingabe-Diagnose: schreibt auf die serielle Konsole (-> run/console.log auf dem Kobo).
# STANDARD AUS: "getevent -l" schreibt jedes Eingabeereignis Zeichen fuer Zeichen auf die emulierte UART;
# QEMU macht pro Zeichen einen write() auf FAT32 -> jede Touch-Geste kostet spuerbar Zeit.
# Einschalten (adb): setprop debug.inputdiag 1; start inputdiag
[ "$(getprop debug.inputdiag)" = 1 ] || exit 0
C=/dev/ttyAMA0
{
echo "INPUTDIAG start"
echo "INPUTDIAG --- /proc/bus/input/devices"
cat /proc/bus/input/devices
echo "INPUTDIAG --- warte auf erstes Eingabeereignis vom Host"
} > $C 2>&1
getevent -c 1 > /dev/null 2>&1
{
echo "INPUTDIAG --- erstes Ereignis angekommen"
echo "INPUTDIAG --- getevent -p"; getevent -p
echo "INPUTDIAG --- dumpsys input"; dumpsys input
echo "INPUTDIAG --- weitere Ereignisse (getevent -l)"
} > $C 2>&1
exec getevent -l > $C 2>&1
