#!/usr/bin/env python3
import atexit, hashlib, os, pathlib, shutil, subprocess, tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2] / 'device'
TOP = pathlib.Path(tempfile.mkdtemp(prefix='kobo-start-test-'))
atexit.register(shutil.rmtree, TOP, ignore_errors=True)


def fixture(name):
    base = TOP / name
    (base / 'run').mkdir(parents=True)
    (base / 'run/min_ram_kb').write_text('1\n')
    (base / 'qemu/lib').mkdir(parents=True)
    (base / 'qemu/usr/share/qemu/keymaps').mkdir(parents=True)
    (base / 'qemu/usr/share/qemu/keymaps/en-us').touch()
    (base / 'data.base.qcow2').write_text('BASE-DATA\n')
    shutil.copy(ROOT / 'qemu-args.sh', base / 'qemu-args.sh')
    def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
    (base/'build-status.txt').write_text('status=SNAPSHOT\nsnapshot=homescreen\nsha256:\n' +
       digest(base/'qemu-args.sh')+'  /w/out/android/qemu-args.sh\n' +
       digest(base/'data.base.qcow2')+'  /w/out/android/data.base.qcow2\n')
    source = (ROOT / 'android-start.sh').read_text().replace(
        'AND=/mnt/onboard/.adds/android', f'AND={base}').replace(
        'PIDF=/tmp/android-qemu.pid', f'PIDF={base}/test.pid').replace(
        'GOVF=/tmp/android-gov.save', f'GOVF={base}/gov.save')
    network_setup = ('up_lo() {\n'
                     '    ifconfig lo 127.0.0.1 netmask 255.0.0.0 up 2>/dev/null || ip link set lo up 2>/dev/null || true\n'
                     '}')
    assert network_setup in source, 'test isolation: loopback setup not found'
    source = source.replace(network_setup, 'up_lo() { :; }')
    (base / 'android-start.sh').write_text(source)
    fake = base / 'qemu/lib/ld-musl-armhf.so.1'
    fake.write_text('''#!/bin/sh
case "$*" in
  *"-device help"*)
    if [ "${FAKE_PCI_ONLY:-0}" = 1 ]; then echo virtio-gpu-pci; else echo virtio-gpu-device; fi
    exit 0 ;;
esac
printf '%s\n' "$*" >> "$FAKE_LOG"
if [ "${FAKE_PCI_ONLY:-0}" = 1 ]; then
    echo 'virtio-gpu-device fehlt' >&2
    exit 4
fi
case "$*" in
  *"-loadvm homescreen"*)
    if [ "${FAKE_FAIL_LOAD:-0}" = 1 ]; then
      [ "${FAKE_MUTATE:-0}" = 1 ] && printf 'USER-WRITE\\n' >> "$FAKE_DATA"
      exit 9
    fi ;;
esac
exit "${FAKE_EXIT:-0}"
''')
    fake.chmod(0o755)
    return base


def call(base, mode, **opts):
    env = os.environ.copy()
    env.update(FAKE_LOG=str(base / 'qemu.calls'), FAKE_DATA=str(base / 'data.qcow2'))
    env.update({k:str(v) for k,v in opts.items()})
    p = subprocess.run(['dash', str(base / 'android-start.sh'), mode], text=True, capture_output=True, env=env, timeout=15)
    return p.returncode, p.stdout + p.stderr


def calls(base):
    f = base / 'qemu.calls'
    return f.read_text().splitlines() if f.exists() else []


def assert_ok(label, cond, detail=''):
    if not cond: raise AssertionError(f'{label}: {detail}')
    print('PASS',label)

# A clean installation gets a snapshot only on its first start.
a=fixture('first')
rc,out=call(a,'check')
assert_ok('check initial copy', rc==0 and (a/'data.qcow2').read_text()=='BASE-DATA\n' and (a/'run/fresh-snapshot').exists(),out)
assert_ok('check does not prematurely release VNC', not (a/'run/launch-ready').exists())
rc,out=call(a,'start')
c=calls(a)
assert_ok('first start loads snapshot once', rc==0 and len(c)==1 and '-loadvm homescreen' in c[0] and not (a/'run/fresh-snapshot').exists(),out)
assert_ok('start releases VNC after checks', (a/'run/launch-ready').exists(),out)
assert_ok('shared final CPU GPU cache settings', '-M virt -cpu cortex-a15 -m 512 -smp 1 -accel tcg,thread=multi,tb-size=64' in c[0] and 'cache=writeback' in c[0] and 'virtio-gpu-device,xres=480,yres=640' in c[0],c[0])
(a/'data.qcow2').write_text('MY-PERSISTENT-DATA\n')
rc,out=call(a,'check')
assert_ok('check keeps existing data', rc==0 and (a/'data.qcow2').read_text()=='MY-PERSISTENT-DATA\n',out)
rc,out=call(a,'start')
c=calls(a)
assert_ok('subsequent start preserves data and cold boots', rc==0 and len(c)==2 and '-loadvm' not in c[1] and (a/'data.qcow2').read_text()=='MY-PERSISTENT-DATA\n',out)

# A stale first-start marker cannot reset an already-modified image.
b=fixture('stale')
(b/'data.qcow2').write_text('USER-DATA\n')
(b/'run/fresh-snapshot').touch()
rc,out=call(b,'start')
assert_ok('stale marker checked against base', rc==0 and '-loadvm' not in calls(b)[0] and (b/'data.qcow2').read_text()=='USER-DATA\n',out)

# Explicit cold-only and missing manifests never set a snapshot marker.
for name,status in [('cold-only','status=COLD_BOOT_ONLY\nsnapshot=none\n'),('missing-status',None)]:
    h=fixture(name)
    if status is None: (h/'build-status.txt').unlink()
    else: (h/'build-status.txt').write_text(status)
    rc,out=call(h,'check')
    assert_ok(name+' creates no snapshot marker',rc==0 and not (h/'run/fresh-snapshot').exists(),out)
    rc,out=call(h,'start')
    assert_ok(name+' boots cold',rc==0 and len(calls(h))==1 and '-loadvm' not in calls(h)[0],out)

# A success marker without a matching base image or QEMU args is not trusted.
for name,filename in [('mismatch-base','data.base.qcow2'),('mismatch-args','qemu-args.sh')]:
    h=fixture(name)
    if filename=='data.base.qcow2': (h/filename).write_text('MISMATCH\n')
    else: (h/filename).write_text((h/filename).read_text()+'\n# mismatch\n')
    rc,out=call(h,'check')
    assert rc==0 and (h/'run/fresh-snapshot').exists()
    rc,out=call(h,'start')
    assert_ok(name+' boots cold instead of restoring',rc==0 and len(calls(h))==1 and '-loadvm' not in calls(h)[0],out)

# When the very first load fails, do not restart or replace the image.
c=fixture('failed-load')
assert call(c,'check')[0]==0
rc,out=call(c,'start',FAKE_FAIL_LOAD=1,FAKE_MUTATE=1)
cc=calls(c)
assert_ok('failed snapshot returns error without restart or replacement', rc==9 and len(cc)==1 and '-loadvm' in cc[0] and 'USER-WRITE' in (c/'data.qcow2').read_text(),out)
rc,out=call(c,'start')
cc=calls(c)
assert_ok('retry after failed snapshot is cold and preserves data', rc==0 and len(cc)==2 and '-loadvm' not in cc[1] and 'USER-WRITE' in (c/'data.qcow2').read_text(),out)

# PCI fallback is rejected and does not trigger another boot or rewrite data.
d=fixture('pci-only')
assert call(d,'check')[0]==0
before=(d/'data.qcow2').read_bytes()
rc,out=call(d,'start',FAKE_PCI_ONLY=1)
assert_ok('PCI-only GPU rejected without retry or overwrite', rc==4 and len(calls(d))==1 and (d/'data.qcow2').read_bytes()==before,out)

# Reset is explicitly destructive but copies transactionally; missing source preserves old data.
e=fixture('reset')
(e/'data.qcow2').write_text('USER-DATA\n')
(e/'data.base.qcow2').unlink()
rc,out=call(e,'reset')
assert_ok('failed explicit reset preserves old data', rc!=0 and (e/'data.qcow2').read_text()=='USER-DATA\n' and not (e/'run/data-copy.lock').exists(),out)
(e/'data.base.qcow2').write_text('BASE-DATA\n')
rc,out=call(e,'reset')
assert_ok('explicit reset uses base and prepares one fresh snapshot', rc==0 and (e/'data.qcow2').read_text()=='BASE-DATA\n' and (e/'run/fresh-snapshot').exists(),out)

# PID belongs to an unrelated live process: must not be killed.
f=fixture('other-pid')
proc=subprocess.Popen(['sleep','30'])
try:
    (f/'test.pid').write_text(str(proc.pid))
    rc,out=call(f,'stop')
    assert_ok('stop does not kill unrelated process',rc==0 and proc.poll() is None,out)
finally:
    proc.terminate(); proc.wait()

# A QEMU using the same image but missing its PID file must block start/reset.
o=fixture('orphan')
(o/'data.qcow2').write_text('USER-DATA\n')
exe=o/'qemu/usr/bin/qemu-system-arm'
exe.parent.mkdir(parents=True)
exe.write_text('#!/bin/sh\nexec sleep 30\n')
exe.chmod(0o755)
# Keep both identifying arguments in the live shell's command line.
proc=subprocess.Popen(['/bin/sh','-c','while :; do sleep 1; done', str(exe), 'file='+str(o/'data.qcow2')+',if=none'])
try:
    import time
    time.sleep(0.1)
    rc,out=call(o,'start')
    assert_ok('orphan blocks start without touching data',rc!=0 and not calls(o) and (o/'data.qcow2').read_text()=='USER-DATA\n',out)
    rc,out=call(o,'reset')
    assert_ok('orphan blocks destructive reset',rc!=0 and (o/'data.qcow2').read_text()=='USER-DATA\n',out)
finally:
    proc.terminate(); proc.wait()

# Failed QEMU on an existing installation is surfaced and does not reset it.
g=fixture('failure-existing')
(g/'data.qcow2').write_text('USER-DATA\n')
rc,out=call(g,'start',FAKE_EXIT=17)
assert_ok('existing install failure propagates without retry or overwrite', rc==17 and len(calls(g))==1 and '-loadvm' not in calls(g)[0] and (g/'data.qcow2').read_text()=='USER-DATA\n',out)

print('All isolated mock tests passed.')
