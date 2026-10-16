r"""What a program printed before a native library PANICKED must survive.

    python bench/abort_flush.py                    the Linux rnxc in zig-out-linux
    python bench/abort_flush.py --rnxc=<path>      another Linux build

A panic inside a native library -- Softanza's engine is built ReleaseSafe,
so it checks -- prints its own trace and aborts. On POSIX that is SIGABRT,
which neither rnxc's panic interface nor its segfault handler sees, and the
64 KB of buffered output went with the process: neural/semantic_retrieval
on Linux printed three passing assertions on Ring and nothing on Ring++,
where the engine panics on both (2026-10-09). rnxc flushes on SIGABRT now.

The guard builds bench/bridge_demo.zig for x86_64-linux-gnu -- a bridge
written as Softanza's are, whose BridgePanic() panics as an engine bridge
would -- and runs bench/bridge_panic.ring under WSL: three lines, then the
call. It passes when the three lines come out, the panic's own message is
on stderr, and nothing after the call ran.

Linux only, standalone (~20 s, one zig build-lib): the oracle cannot host a
Ring++ bridge, and on Windows Zig's abort() is ExitProcess(3), which no
handler sees -- that half is named in src/main.zig, not covered here.
"""
import os, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DISTRO = os.environ.get('RPP_WSL_DISTRO', 'Ubuntu')
WORK = os.path.join(ROOT, 'runtime', 'abort-flush')


def to_wsl(p):
    p = os.path.abspath(p).replace(chr(92), '/')
    return '/mnt/' + p[0].lower() + p[2:]


def main():
    rnxc = os.path.join(ROOT, 'zig-out-linux', 'bin', 'rnxc')
    for a in sys.argv[1:]:
        if a.startswith('--rnxc='):
            rnxc = a.split('=', 1)[1]
    if not os.path.exists(rnxc):
        print('abort_flush: no Linux rnxc at %s -- build with -Dtarget=x86_64-linux-gnu' % rnxc)
        return 1
    os.makedirs(WORK, exist_ok=True)
    r = subprocess.run(['zig', 'build-lib', '-dynamic', '-OReleaseSafe', '-lc',
                        '-target', 'x86_64-linux-gnu', os.path.join(HERE, 'bridge_demo.zig'),
                        '--name', 'rppbridge'], cwd=WORK, capture_output=True, text=True)
    if r.returncode != 0:
        print('abort_flush: the bridge did not build: ' + (r.stderr.strip().splitlines() or [''])[0][:160])
        return 1
    shutil.copyfile(os.path.join(WORK, 'librppbridge.so'), os.path.join(WORK, 'rppbridge.so'))
    shutil.copyfile(os.path.join(HERE, 'bridge_panic.ring'), os.path.join(WORK, 'bridge_panic.ring'))
    r = subprocess.run(['wsl.exe', '-d', DISTRO, '--cd', to_wsl(WORK), '--exec',
                        'env', 'RNXC_NOCACHE=1', to_wsl(rnxc), 'bridge_panic.ring'],
                       capture_output=True, timeout=120)
    if r.returncode in (126, 127) and not r.stdout:
        print('abort_flush: rnxc did not run under WSL (%s): %s'
              % (DISTRO, r.stderr.decode('utf-8', 'replace').strip()[:160]))
        return 1
    out = r.stdout.decode('utf-8', 'replace')
    err = r.stderr.decode('utf-8', 'replace')
    want = ['before 1', 'before 2', 'before 3: 42']
    missing = [w for w in want if w not in out]
    problems = []
    if missing:
        problems.append('lost before the panic: ' + ', '.join(repr(m) for m in missing))
    if 'after the panic' in out:
        problems.append('the line after the call ran')
    if 'BridgePanic' not in err:
        problems.append('the library\'s panic message is not on stderr')
    if 'PANIC PROBE FAIL' in out:
        problems.append(out.strip().splitlines()[0])
    if problems:
        print('abort_flush: FAIL (exit %d) -- %s' % (r.returncode, '; '.join(problems)))
        return 1
    print('abort_flush: OK -- the three lines printed before a library panic survive it '
          '(exit %d, the panic on stderr)' % r.returncode)
    return 0


if __name__ == '__main__':
    sys.exit(main())
