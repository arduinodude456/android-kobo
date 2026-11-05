#!/system/bin/sh
# Eingabe-Diagnose: schreibt auf die serielle Konsole (-> run/console.log auf dem Kobo).
# Wird nach dem Boot gestartet, steht im Snapshot auf "getevent -c 1" und gibt erst beim ERSTEN echten
# Eingabeereignis (Touch/Taste vom Kobo) den Gast-Eingabezustand aus. Alle Zeilen beginnen mit INPUTDIAG
# bzw. /dev/input/ (getevent), damit das Plugin sie filtern kann.
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
