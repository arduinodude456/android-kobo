#!/bin/sh
# Keep the KitKat bootanim service target valid, but don't software-render the
# animation continuously during the slow first boot and later cold boots.
set -eu
[ "$#" -eq 1 ] && [ -f "$1" ] || { echo 'Aufruf: patch-bootanim.sh <init.rc>' >&2; exit 2; }
count=$(grep -c '^service bootanim /system/bin/bootanimation$' "$1" || true)
[ "$count" = 1 ] || { echo 'FEHLER: KitKat-bootanim-Dienst nicht eindeutig gefunden' >&2; exit 1; }
sed -i 's|^service bootanim /system/bin/bootanimation$|service bootanim /system/bin/sh -c exit|' "$1"
