# -*- coding: utf-8 -*-
r"""How fast does a SPAWNED CHILD reach its first statement?

    python bench/child_start.py                  the d5 worker
    python bench/child_start.py _d3_worker.ring  another one

The estate spawns interpreters of itself -- cluster workers, backend hosts,
the load driver's children -- and every one of them compiles the library
unless something lets it skip that. Whether something does is a question
this project has answered WRONG from memory: CLAUDE.md said on 2026-09-21
that "the prefix never warms -- every run stays ~35 s". Measured on
2026-09-23 it was 0.25 s, and the 35 s had been a prefix left STALE by a
rebuild -- which is its own defect, guarded since (why432 re-keys the prefix
on the tree and on rnxc). This asks the question in five seconds instead.

THREE PATHS, and it reports which one a child took:

    image    the child has run before under this rnxc: its own compiled
             image is read back            (measured: ~0.07 s)
    prefix   a child that has NEVER run: the library comes from the prefix
             and only the root is compiled (measured: ~0.25 s)
    cold     no usable prefix: all ~612 files compiled (measured: ~7.8 s)

The PREFIX path is the one a fresh clock pass puts every child on, so that
is what it measures by default: a throwaway cache holding a COPY of the
prefix and nothing else, so the child has no image of its own. The real
cache is never written or deleted. A prefix older than rnxc is reported as
such, not measured -- run `python bench/why432.py` (or clockall) once and it
is rebuilt.

The FIRST read of a freshly written 22 MB prefix once took 14 s here, where
every read after it took 0.05 s -- most likely the virus scanner's first
look at a new file. So it runs three times and reports each, and the one
that matters is the steady state.
"""
import glob, os, shutil, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RNXC = os.path.join(ROOT, 'zig-out', 'bin', 'rnxc.exe')
CACHE = os.path.join(ROOT, 'runtime', 'wide-cache')
CWD = os.path.join(ROOT, 'runtime', 'clock-copy', 'libraries', 'stzlib',
                   'base', 'test', 'cluster')


def once(script, cache, port):
    env = dict(os.environ)
    env['RNXC_IMAGE'] = '1'
    env['RNXC_CACHE'] = cache
    t0 = time.time()
    p = subprocess.Popen([RNXC, script, str(port)], cwd=CWD, env=env,
                         stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    seen, first = [], [None]

    def pump():
        for raw in p.stderr:
            ln = raw.decode('utf-8', 'replace').rstrip()
            seen.append(ln)
            if 'running the top level' in ln and first[0] is None:
                first[0] = time.time() - t0
    th = threading.Thread(target=pump, daemon=True)
    th.start()
    while first[0] is None and time.time() - t0 < 60 and p.poll() is None:
        time.sleep(0.02)
    p.kill()           # a worker waits on its socket for ever: the answer is in
    th.join(2)
    text = '\n'.join(seen)
    if 'image: used' in text:
        path = 'image'
    elif 'prefix used' in text:
        path = 'prefix'
    elif 'written by another build' in text:
        path = 'STALE PREFIX -> cold'
    else:
        path = 'cold'
    return first[0], path


def main():
    script = sys.argv[1] if len(sys.argv) > 1 else '_d5_worker.ring'
    if not os.path.isdir(CWD):
        print('SKIP: no clock-copy at %s -- run bench/clock34.py --copy' % CWD)
        return 0
    prefixes = glob.glob(os.path.join(CACHE, '*.rnxp'))
    if not prefixes:
        print('SKIP: no prefix in %s -- run bench/why432.py once' % CACHE)
        return 0
    tmp = tempfile.mkdtemp(prefix='rnxc_child_')
    try:
        for p in prefixes:
            shutil.copy2(p, tmp)
        print('child: %s   (a throwaway cache holding the prefix only)' % script)
        for k in range(3):
            # a fresh throwaway image dir each time, so every run is a child
            # that has never run -- the prefix path, not its own image
            for f in glob.glob(os.path.join(tmp, '*.rnxi')):
                os.remove(f)
            t, path = once(script, tmp, 46970 + k)
            print('  run %d  %-22s %s' % (k + 1, path,
                  'first statement at %.2f s' % t if t else 'no first statement in 60 s'))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
