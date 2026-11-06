#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
printf 'service bootanim /system/bin/bootanimation\n    disabled\n    oneshot\n' > "$t/init.rc"
sh ci/patch-bootanim.sh "$t/init.rc"
grep -q '^service bootanim /system/bin/sh -c exit$' "$t/init.rc"
grep -q '^    disabled$' "$t/init.rc"
grep -q '^    oneshot$' "$t/init.rc"
if sh ci/patch-bootanim.sh "$t/init.rc" >/dev/null 2>&1; then
    echo 'FAIL: unrecognized/already patched init.rc accepted' >&2; exit 1
fi
printf 'PASS: exact KitKat bootanimation service patch and safe failure\n'
