r"""The compiled image: a warm run must answer exactly as a cold one.

    python bench/image.py

`rnxc` writes what compilation produced to a file and reads it back on the
next run of the same program (src/image.zig). That is only worth having if
nothing about the answer changes, so this runs every exec probe three times

    cold    RNXC_NOCACHE=1        the compiler, as before any of this
    write   cache empty           compiles, and writes the image
    read    cache warm            runs from the image

and requires all three to produce the same bytes on stdout.

IT ALSO REQUIRES THE THIRD RUN TO HAVE USED THE IMAGE. A guard that passes
because the cache never engaged proves nothing at all -- the shape of the two
gaps CLAUDE.md already names -- so the `(compiled image)` line rnxc prints on
a warm start is checked, per probe, and a probe that never hits is a FAIL.

And it checks the other direction, which is the one that can be silently
wrong: change a source file by one byte and the image must be ABANDONED. The
probe is edited, re-run, and restored; if the old answer comes back, the key
is not doing its job.
"""
import io, os, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RNXC = os.path.join(ROOT, 'zig-out', 'bin', 'rnxc.exe')
PROBES = os.path.join(HERE, 'exec')
CACHE = os.path.join(ROOT, 'runtime', 'image-cache')
# rnxc's own status line when it refuses a program before compiling it
# (src/rnxc.zig, refuseMissingLoads)
REFUSED = b'refused: a load names a file that cannot be opened'


def run(path, cache, nocache=False):
    env = dict(os.environ)
    # the `(compiled image)` status line this guard reads is printed only under RNXC_VERBOSE
    env['RNXC_VERBOSE'] = '1'
    if nocache:
        env['RNXC_NOCACHE'] = '1'
        env.pop('RNXC_CACHE', None)
    else:
        env.pop('RNXC_NOCACHE', None)
        env['RNXC_CACHE'] = cache
    r = subprocess.run([RNXC, os.path.basename(path)], cwd=os.path.dirname(path),
                       capture_output=True, timeout=300, env=env)
    return r.stdout, r.stderr


def main():
    if not os.path.exists(RNXC):
        print('SKIP image: no rnxc build')
        return 0
    if os.path.isdir(CACHE):
        shutil.rmtree(CACHE, ignore_errors=True)
    names = sorted(f for f in os.listdir(PROBES) if f.endswith('.ring'))
    bad, nohit, refused = [], [], []
    for f in names:
        p = os.path.join(PROBES, f)
        cold, _ = run(p, CACHE, nocache=True)
        warm1, _ = run(p, CACHE)
        warm2, err2 = run(p, CACHE)
        if not (cold == warm1 == warm2):
            bad.append(f)
        # A program Ring refuses before it runs (F-101, a load nobody can
        # open) is refused before it compiles, so there is no image to warm:
        # it is counted apart, and still has to answer alike all three times.
        if REFUSED in err2:
            refused.append(f)
        elif b'(compiled image)' not in err2:
            nohit.append(f)

    # The key, tested in the direction that can be silently wrong.
    #
    # The edit goes at the TOP, not the bottom: Ring puts all functions and
    # classes after the top level, so a line appended to the end of a probe
    # that ends in a class is part of that class and never runs -- which is
    # how the first version of this check passed itself while proving
    # nothing. The premise is asserted here rather than assumed: the cold
    # run must change first, or the check is reported as broken.
    stale = None
    probe = os.path.join(PROBES, names[0])
    src = io.open(probe, encoding='utf-8', newline='').read()
    edited = '? "the image must not answer this"\n' + src
    try:
        before, _ = run(probe, CACHE)
        io.open(probe, 'w', encoding='utf-8', newline='').write(edited)
        cold_after, _ = run(probe, CACHE, nocache=True)
        if cold_after == before:
            stale = 'the check is broken: the edit does not change a COLD run'
        else:
            after, err = run(probe, CACHE)
            if after == before:
                stale = 'a changed source still ran the old image'
            elif b'(compiled image)' in err:
                stale = 'a changed source was answered from the image'
    finally:
        io.open(probe, 'w', encoding='utf-8', newline='').write(src)

    for f in bad:
        print('DIFF  %s -- warm run differs from cold' % f)
    for f in nohit:
        print('COLD  %s -- never used the image, so it proved nothing' % f)
    if stale:
        print('STALE %s' % stale)
    print()
    if bad or nohit or stale:
        print('IMAGE FAILED   %d differing, %d never warm%s' % (
            len(bad), len(nohit), ', key stale' if stale else ''))
        return 1
    print('IMAGE OK   %d probe(s) identical cold and warm, and the key '
          'refuses a changed source%s' % (
              len(names) - len(refused),
              ('; %d refused before compiling, as on Ring, and alike every time' % len(refused))
              if refused else ''))
    return 0


if __name__ == '__main__':
    sys.exit(main())
