r"""Two reactors spawning at once must not hand each other their pipes.

    python bench/spawn_race.py            the three runtimes, each with its own
                                          build of stz_reactor
    python bench/spawn_race.py --his      oracle and official Ring on the build
                                          in Mansour's tree (zig-out/bin)

WHY (2026-10-03). On Windows uv_spawn creates a child's stdio ends
INHERITABLE, calls CreateProcessW with bInheritHandles = TRUE, and closes
them -- inside one call. Every reactor runs its loop on its own thread, so
a second reactor spawning inside that window gave its child the first
child's stdout end, and the first job -- ready only at EOF -- waited for
the OTHER child to exit. cluster/d3_supervision's supervisor never saw its
child die while the test's watcher, spawned on another reactor a moment
earlier, was alive: 8 of 8 here on all three runtimes, and on Ring the test
passed only because the interpreter is slow enough between the two spawns.
The engine's reactor.zig serializes uv_spawn now (Mansour's tree).

Each runtime loads its own flavour, laid out by bench/engine_copy.py:
    rnx       runtime/engine-copy      the Ring++ backend (rpp_init)
    oracle    runtime/engine-oracle    Ring's API, imported from ring.exe
    official  runtime/engine-official  his own build, imported from ring.dll
and the oracle runs with D:\Ring127 OFF the PATH, which is the other check:
a library that names ring.dll could only load there by reaching the
official installation (F-96). The modules each process maps are printed.

Windows only; ~25 s a runtime. Exit 1 when any A was held open, a runtime
could not load its library, or a library it needs was not built.
"""
import os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PROBE = os.path.join(HERE, 'spawn_race.ring')
HIS = r'D:\GitHub\stzlib\libraries\stzlib\engine\zig-out\bin\stz_reactor.dll'
OFFICIAL = os.environ.get('RING', r'D:\Ring127\bin\ring.exe')


def flavour(name):
    return os.path.join(ROOT, 'runtime', name, 'zig-out', 'bin', 'stz_reactor.dll')


def run(label, exe, dll, nopath):
    if not os.path.exists(dll):
        print('%-9s NOT BUILT: %s -- run bench/engine_copy.py, then ONLY=stz_reactor zig build' % (label, dll))
        return False
    if not os.path.exists(exe):
        print('%-9s NO RUNTIME at %s' % (label, exe))
        return False
    env = dict(os.environ)
    if nopath:
        env['PATH'] = ';'.join(p for p in env['PATH'].split(';') if 'ring127' not in p.lower())
    p = subprocess.Popen([exe, PROBE, dll], cwd=HERE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, env=env)
    time.sleep(1.5)
    mods = subprocess.run(['powershell', '-NoProfile', '-Command',
                           "(Get-Process -Id %d -ErrorAction SilentlyContinue).Modules | "
                           "Where-Object { $_.ModuleName -like 'ring*' -or $_.ModuleName -like 'stz*' } | "
                           "ForEach-Object { $_.ModuleName }" % p.pid],
                          capture_output=True, text=True).stdout.split()
    out, _ = p.communicate(timeout=300)
    lines = out.decode('utf-8', 'replace').replace('\r', '').strip().split('\n')
    last = lines[-1] if lines else ''
    ok = p.returncode == 0 and last.startswith('A held open by B: 0 of')
    print('%-9s %s   %s%s   maps %s' % (label, 'ok  ' if ok else 'FAIL', last or '(no output)',
                                       '   [D:\\Ring127 off PATH]' if nopath else '', ', '.join(mods)))
    if not ok:
        for l in lines[-4:]:
            print('            ' + l)
    return ok


def main():
    if os.name != 'nt':
        print('SKIP spawn_race: Windows only (POSIX libuv opens its pipes close-on-exec)')
        return 0
    his = '--his' in sys.argv
    rows = []
    if his:
        rows.append(('oracle', os.path.join(ROOT, 'runtime', 'win64', 'ring.exe'), HIS, False))
        rows.append(('official', OFFICIAL, HIS, False))
    else:
        rows.append(('rnx', os.path.join(ROOT, 'zig-out', 'bin', 'rnxc.exe'), flavour('engine-copy'), False))
        rows.append(('oracle', os.path.join(ROOT, 'runtime', 'win64', 'ring.exe'), flavour('engine-oracle'), True))
        rows.append(('official', OFFICIAL, flavour('engine-official'), False))
    bad = [r[0] for r in rows if not run(*r)]
    print('spawn race: %s' % ('every runtime clean' if not bad else 'FAILED on ' + ', '.join(bad)))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
