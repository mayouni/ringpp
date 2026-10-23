r"""Run one of Softanza's security guards on rnxc, against a Ring++ build of ANOTHER worktree's engine.

    python bench/sec_guard.py [--worktree D:\GitHub\_wts] [--test base/test/security/stale_handle_narrated.ring] [--no-copy]

stzlib-security works in a worktree of its own (`_wts`, branch security/week1) whose engine differs from the live tree's, and its guards
are written for it: SECURITY-R16's `stale_handle_narrated.ring` tests the checked ids the security branch's bridges hand out. rnxc can run
it only against engine DLLs built from THAT engine with the Ring++ backend:

    python bench/engine_copy.py --src=<worktree>\libraries\stzlib\engine --dst=runtime\engine-sec     (seed its .zig-cache from runtime/engine-copy)
    cd runtime\engine-sec && ONLY=<domains> zig build -j2

This copies the migrated library (runtime/clock-copy) into runtime/sec-copy, lays the guard test of the worktree over it, puts the DLLs of runtime/engine-sec
in its engine/zig-out/bin, and runs the test with the rnxc given by RNXC (default zig-out). The oracle is not involved: the guard's question is
whether rnxc raises where it must, and the answer is in its own assertions.
"""
import os, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import clock34

RNXC = os.environ.get('RNXC') or os.path.join(ROOT, 'zig-out', 'bin', 'rnxc.exe')
DLLS = os.path.join(ROOT, 'runtime', 'engine-sec', 'zig-out', 'bin')
COPY = os.path.join(ROOT, 'runtime', 'sec-copy', 'libraries', 'stzlib')


def arg(name, default):
    for i, a in enumerate(sys.argv):
        if a == name and i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return default


def make_copy(worktree, overlay):
    """The MIGRATED library (runtime/clock-copy: his branch ringpp/migrate-rule-a, which rnxc can compile) plus the files of the worktree that the work under
    test changed, plus the engine DLLs built from the worktree's engine. A worktree on main has no Rule A migration, so rnxc refuses it at stzFuncs.ring:54; but
    security R16 changed no library file at all -- only its guard test and the engine's bridges -- so the migrated library and the security engine are exactly
    what R16 asks of the VM."""
    base = clock34.COPY
    if not os.path.isdir(base):
        raise SystemExit('no migrated copy at ' + base + ' -- python bench/clock34.py --copy')
    if os.path.exists(COPY):
        shutil.rmtree(COPY, onexc=clock34._force_rm)
    n = 0
    for dirpath, dirs, names in os.walk(base):
        dirs[:] = [d for d in dirs if d not in ('zig-out', '.zig-cache')]
        rel = os.path.relpath(dirpath, base)
        out = os.path.join(COPY, rel) if rel != '.' else COPY
        os.makedirs(out, exist_ok=True)
        for f in names:
            try:
                shutil.copyfile(os.path.join(dirpath, f), os.path.join(out, f))
                n += 1
            except OSError:
                pass
    lib = os.path.join(worktree, 'libraries', 'stzlib')
    for rel in overlay:
        src = os.path.join(lib, *rel.split('/'))
        dst = os.path.join(COPY, *rel.split('/'))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(src, dst)
    dst = os.path.join(COPY, 'engine', 'zig-out', 'bin')
    os.makedirs(dst, exist_ok=True)
    m = 0
    for f in os.listdir(DLLS):
        if f.endswith('.dll'):
            shutil.copyfile(os.path.join(DLLS, f), os.path.join(dst, f))
            m += 1
    print('sec-copy: %d files of the migrated library, %d overlaid from %s, %d Ring++ engine DLLs from %s' % (n, len(overlay), worktree, m, DLLS))


def main():
    worktree = arg('--worktree', r'D:\GitHub\_wts')
    test = arg('--test', 'base/test/security/stale_handle_narrated.ring')
    if '--no-copy' not in sys.argv:
        make_copy(worktree, [test])
    path = os.path.join(COPY, *test.split('/'))
    env = dict(os.environ, STZ_NO_VIEW='1')
    t0 = time.time()
    r = subprocess.run([RNXC, os.path.basename(path)], cwd=os.path.dirname(path), capture_output=True, env=env, timeout=1800)
    out = (r.stdout + r.stderr).decode('utf-8', 'replace').replace('\r\n', '\n')
    open(os.path.join(ROOT, 'runtime', 'sec-guard.out'), 'w', encoding='utf-8', newline='\n').write(out)
    print(out)
    print('rnxc %s: exit %d in %.1f s (the output is kept in runtime/sec-guard.out)' % (os.path.basename(path), r.returncode, time.time() - t0))
    return r.returncode


if __name__ == '__main__':
    sys.exit(main())
