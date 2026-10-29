"""THE IMAGE CACHE IS BOUNDED (image.prune, 2026-10-29): a seeded cache folder, one run of rnxc, and what must be left.

    python bench/cache_cap.py            (RNXC=<rnxc> to test another build)

Six fake 1 MB images of graded age, an old prefix, an hour-old and a minute-old temporary, a cap of 4 MB: the run's own image goes in, the
oldest images go until three quarters of the cap, the prefix and the fresh temporary stay, the stale one goes. Then the same with
RNXC_CACHE_MB=0, which must delete nothing. The folder is runtime/cache_cap, made and emptied here; the user's own cache is never touched."""
import os, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RNXC = os.environ.get('RNXC') or os.path.join(ROOT, 'zig-out', 'bin', 'rnxc.exe' if os.name == 'nt' else 'rnxc')
C = os.path.join(ROOT, 'runtime', 'cache_cap', 'cache')
PROG = os.path.join(ROOT, 'runtime', 'cache_cap', 'hello.ring')


def seed():
    os.makedirs(C, exist_ok=True)
    for f in os.listdir(C):
        os.remove(os.path.join(C, f))
    now = time.time()
    for i in range(6):
        p = os.path.join(C, 'old%d.rnxi' % i)
        with open(p, 'wb') as f:
            f.write(b'\0' * (1 << 20))
        os.utime(p, (now - 86400 * (6 - i),) * 2)
    for name, size, age in (('lib0.rnxp', 2 << 20, 86400 * 30), ('stale.x.tmp', 100, 7200), ('fresh.x.tmp', 100, 60)):
        p = os.path.join(C, name)
        with open(p, 'wb') as f:
            f.write(b'\0' * size)
        os.utime(p, (now - age,) * 2)


def run(cap):
    env = dict(os.environ, RNXC_CACHE=C, RNXC_CACHE_MB=cap)
    r = subprocess.run([RNXC, PROG], capture_output=True, text=True, env=env)
    if r.stdout.strip() != 'hello':
        raise SystemExit('FAIL: the program did not run: %r %r' % (r.stdout, r.stderr[-300:]))
    return sorted(os.listdir(C))


def main():
    os.makedirs(os.path.dirname(PROG), exist_ok=True)
    with open(PROG, 'w') as f:
        f.write('? "hello"\n')
    seed()
    left = run('4')
    bad = []
    if 'lib0.rnxp' not in left:
        bad.append('a prefix was evicted')
    if 'fresh.x.tmp' not in left:
        bad.append("a live writer's temporary was removed")
    if 'stale.x.tmp' in left:
        bad.append("a dead writer's temporary was kept")
    if any(f in left for f in ('old0.rnxi', 'old1.rnxi', 'old2.rnxi', 'old3.rnxi')):
        bad.append('an old image survived over the cap')
    if 'old5.rnxi' not in left or not any(f.endswith('.rnxi') and not f.startswith('old') for f in left):
        bad.append('the newest images were evicted')
    seed()
    if sum(f.endswith('.rnxi') for f in run('0')) != 7:
        bad.append('RNXC_CACHE_MB=0 deleted something')
    if bad:
        print('CACHE CAP FAILED: ' + '; '.join(bad))
        return 1
    print('CACHE CAP OK   over the cap the oldest images go, never a prefix or a live temporary; 0 is unbounded')
    return 0


if __name__ == '__main__':
    sys.exit(main())
