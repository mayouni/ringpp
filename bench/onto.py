r"""The library as a PREFIX: a file compiled on top must answer exactly as it
does when the whole unit is compiled together.

    python bench/onto.py            the probes, and the 34 if Softanza is here
    python bench/onto.py perf       only cases whose name matches
    python bench/onto.py --probes   the probes only -- the gate's step, ~2 s

THE GATE DID NOT RUN THIS until 2026-09-25, and it is the path every
wide-clock test takes. eval inside a LIBRARY function crashed thirteen of
them there -- a prefix carried no function's locals, so the eval compiler
fell through to code that read a class table it does not have -- while the
gate's probes, all compiled whole, stayed green.

613 of the 614 files in a Softanza test's unit are the library, and they are
the same 613 for every test in the estate. `rnxc prefix <library.ring>`
compiles them once into a file; every later run restores that and compiles
only what sits on top (src/prefix.zig, and compilePrefix / compileOnto /
prefixApplies in src/compile.zig). That is worth having only if nothing about
the answer changes, and this is what says so.

WITH A NOISE FLOOR, because half of these tests print measurements. THREE
whole runs give the lines this build does not reproduce from itself; the
prefix run is compared to the first, ignoring exactly those positions.
Comparing without a floor is the mistake F-57 exists to prevent, and it was
made on this very question: twelve tests read as "differing" when every line
of the difference was a clock. Two runs were not enough either -- another
five lines agreed twice and differed on the third.

A case that FALLS BACK to the whole-unit compile is reported rather than
counted: it proves the fallback, not the prefix.
"""
import os, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RNXC = os.environ.get('RNXC') or os.path.join(ROOT, 'zig-out', 'bin', 'rnxc.exe')
PROBES = os.path.join(HERE, 'exec')
CACHE = os.path.join(ROOT, 'runtime', 'onto-cache')

WHOLE = dict(os.environ)
WHOLE['RNXC_NOCACHE'] = '1'
WHOLE.pop('RNXC_CACHE', None)
ONTO = dict(os.environ)
ONTO.pop('RNXC_NOCACHE', None)
ONTO['RNXC_CACHE'] = CACHE


def lines(b):
    return [l.rstrip(b'\r') for l in b.split(b'\n') if l.strip() and not l.startswith(b'WARNING: ')]


def run(fn, cwd, env):
    r = subprocess.run([RNXC, fn], cwd=cwd, capture_output=True, timeout=900, env=env)
    return lines(r.stdout), r.stderr


def drop_program_images():
    """A whole-PROGRAM image would answer before the prefix is ever asked."""
    if os.path.isdir(CACHE):
        for f in os.listdir(CACHE):
            if f.endswith('.rnxi'):
                os.remove(os.path.join(CACHE, f))


def build_prefix(lib_path):
    d, fn = os.path.dirname(lib_path), os.path.basename(lib_path)
    r = subprocess.run([RNXC, 'prefix', fn], cwd=d, capture_output=True, timeout=900, env=ONTO)
    return r.returncode == 0 and b'prefix:' in r.stdout


def check(name, fn, cwd, floor_runs=3):
    A, _ = run(fn, cwd, WHOLE)
    floor = set()
    for _ in range(floor_runs - 1):
        B, _ = run(fn, cwd, WHOLE)
        floor |= {i for i, (x, y) in enumerate(zip(A, B)) if x != y}
        if len(A) != len(B):
            floor |= set(range(min(len(A), len(B)), max(len(A), len(B))))
    drop_program_images()
    C, err = run(fn, cwd, ONTO)
    new = [i for i, (x, z) in enumerate(zip(A, C)) if x != z and i not in floor]
    if len(A) != len(C):
        new += list(range(min(len(A), len(C)), max(len(A), len(C))))
    first = ''
    if new:
        i = new[0]
        x = A[i].decode('utf-8', 'replace') if i < len(A) else '<none>'
        z = C[i].decode('utf-8', 'replace') if i < len(C) else '<none>'
        first = 'line %d: whole %r | onto %r' % (i + 1, x[:44], z[:44])
    return len(new), (b'(library as a prefix)' in err), first


def main():
    only = [a for a in sys.argv[1:] if not a.startswith('-')]
    if not os.path.exists(RNXC):
        print('SKIP onto: no rnxc build')
        return 0
    shutil.rmtree(CACHE, ignore_errors=True)

    cases = []
    if build_prefix(os.path.join(PROBES, 'onto_prefix_lib.ring')):
        cases.append(('probe/onto_prefix.ring', 'onto_prefix.ring', PROBES))
    else:
        print('note: could not build the probe prefix')
    # Every other probe is a single file or loads out of order: they exercise
    # the FALLBACK, which is the other half of being safe.
    for f in sorted(x for x in os.listdir(PROBES) if x.endswith('.ring')):
        if f != 'onto_prefix.ring':
            cases.append(('probe/' + f, f, PROBES))

    try:
        if '--probes' in sys.argv:
            raise RuntimeError('--probes given')
        sys.path.insert(0, HERE)
        import clock34 as K
        lib = os.path.join(K.COPY, 'base', 'stzBase.ring')
        if os.path.isdir(K.COPY) and os.path.exists(lib):
            if build_prefix(lib):
                for rel in K.THE_34:
                    mod, fn = rel.split('/')
                    cases.append((rel, fn, os.path.join(K.COPY, K.TESTS.replace('/', os.sep), mod)))
            else:
                print('note: could not build the Softanza prefix')
    except Exception as e:
        print('note: the 34 are not available (%s)' % e)

    cases = [c for c in cases if not only or any(o in c[0] for o in only)]
    bad, fell_back, used = [], [], 0
    for name, fn, cwd in cases:
        n, hit, first = check(name, fn, cwd)
        used += 1 if hit else 0
        if n:
            bad.append((name, first))
        elif not hit:
            fell_back.append(name)
        print('%-46s %s%s' % (name, 'SAME' if not n else 'DIFFERS  ' + first,
                              '' if hit else '   (fell back)'), flush=True)

    print()
    for name, first in bad:
        print('DIFF  %s -- %s' % (name, first))
    if bad:
        print('ONTO FAILED   %d of %d differ' % (len(bad), len(cases)))
        return 1
    print('ONTO OK   %d file(s) answer the same on a prefix; %d used one, %d fell back'
          % (len(cases), used, len(fell_back)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
