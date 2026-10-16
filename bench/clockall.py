r"""The WIDE clock: every assertion-bearing test in Softanza's suite, not 34.

    python bench/clockall.py --discover    re-derive the list, and write it
    python bench/clockall.py               run it
    python bench/clockall.py perf          only those whose name matches

`bench/clock34.py` samples 34 files. That number was not a judgement about
coverage -- it was what could be afforded: every run compiled Softanza's 613
library files first, 8 s a test, so 226 tests meant half an hour of compiling
before any of them said anything. `rnxc prefix` removes that (src/prefix.zig):
the library is compiled once into a file and each test is compiled on top of
it, 0.4 s. So the clock can be the suite instead of a sample.

WHAT COUNTS AS ASSERTION-BEARING, and why this set and not a bigger one.
The estate names its narrated tests `*_narrated.ring`, and 431 of the 5,143
files under `base/test` carry that name -- including every one of clock34's
34 but two, which are added by name. The rule is checked against that
hand-made list of 2026-09-09: if it does not find all 34 it is the wrong
rule and says so, rather than quietly measuring something else.

A LOOSER RULE WAS TRIED AND REJECTED: "contains Then( / chk( / Scenario("
matches 1,505 files, and "loads a narrated harness" matches 1,303. Those are
the next increment and they are not free -- the ORACLE side alone is ~8 s a
test, so 1,303 is nearly three hours against this set's one. Widen when
there is a reason to, not because the scan was cheap to write.

THE SAME TWO NUMBERS, for the same reasons, and the noise floor first: the
oracle runs TWICE per test and the lines it does not reproduce from itself
are set aside by position. See clock34.py for why that is not optional.

WHAT IT COSTS: the oracle dominates -- two runs of ~3.5 s each against one
rnx run of ~0.4 s -- so a full pass is roughly 30-50 minutes. The per-program
image is deleted as it goes: 226 of them would be 9 GB, and the prefix is the
part worth keeping.
"""
import io, os, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import clock34 as K

LIST = os.path.join(HERE, 'clockall.txt')
# THE WIDE SUITE (item 8, 2026-09-28): every program Mansour's repository
# TRACKS under base/test, max/test and core/test whose first `load` is one of
# the library aggregators. Tracked, because the tests WRITE .ring files as
# they run -- generated hosts and shells -- and a list that picked those up
# cost two fills once already. max and core names carry an `@` and resolve
# from the library root; base names are relative to base/test, as before.
LIST_WIDE = os.path.join(HERE, 'clockall-wide.txt')
WIDE_ROOTS = ('base/test', 'max/test', 'core/test')
AGGREGATORS = ('stzbase.ring', 'stzmax.ring', 'stzlib.ring', 'stklib.ring')
CACHE = os.path.join(K.ROOT, 'runtime', 'wide-cache')
TESTROOT = os.path.join(K.LIB, 'base', 'test')

ENV = dict(os.environ)
ENV['RNXC_CACHE'] = CACHE
ENV.pop('RNXC_NOCACHE', None)

def discover_wide():
    """The wide suite: tracked programs that load an aggregator first."""
    import re
    repo = os.path.dirname(os.path.dirname(K.LIB))
    rels = ['libraries/stzlib/' + r for r in WIDE_ROOTS]
    out = subprocess.run(['git', '-C', repo, 'ls-files', '--'] + rels,
                         capture_output=True).stdout.decode('utf-8', 'replace')
    first_load = re.compile(r'(?im)^[ \t]*load[ \t]+"([^"]+)"')
    found = []
    for line in out.split('\n'):
        p = line.strip()
        if not p.endswith('.ring'):
            continue
        inside = p[len('libraries/stzlib/'):]
        if os.path.basename(inside) == '_narrated.ring':
            continue
        try:
            src = io.open(os.path.join(K.LIB, inside.replace('/', os.sep)),
                          encoding='utf-8', errors='replace').read()
        except OSError:
            continue
        src = re.sub(r'(?s)/\*.*?\*/', '', src)
        m = first_load.search(src)
        if not m or m.group(1).replace('\\', '/').split('/')[-1].lower() not in AGGREGATORS:
            continue
        if inside.startswith('base/test/'):
            found.append(inside[len('base/test/'):])
        else:
            found.append('@' + inside)
    # ...and the 432, by name: it must CONTAIN the narrow clock. Eighteen of
    # them fall outside the rule -- the gpu tests load Ring's full stdlib.ring
    # first, and some graphics tests are new and not tracked yet.
    if os.path.exists(LIST):
        found += [l.strip() for l in io.open(LIST, encoding='utf-8') if l.strip()]
    return sorted(set(found))


def discover():
    found = []
    for dp, dn, fn in os.walk(TESTROOT):
        dn[:] = [d for d in dn if d not in ('.git', 'zig-out', '__pycache__')]
        for f in sorted(fn):
            if not f.endswith('_narrated.ring'):
                continue
            rel = os.path.relpath(os.path.join(dp, f), TESTROOT).replace(os.sep, '/')
            # The harness itself is not a test.
            if os.path.basename(rel) == '_narrated.ring':
                continue
            found.append(rel)
    # The two members of clock34's list that carry no such name. Named
    # rather than pattern-matched, because two is not a pattern.
    for t in K.THE_34:
        if t not in found:
            found.append(t)
    return sorted(found)


def check_rule(found):
    """The rule has to find every one of clock34's 34, or it is not the rule
    that made them."""
    missing = [t for t in K.THE_34 if t not in found]
    return missing


def build_prefix():
    lib = os.path.join(K.COPY, 'base', 'stzBase.ring')
    if not os.path.exists(lib):
        return False, 'no library at ' + lib
    r = subprocess.run([K.RNXC, 'prefix', 'stzBase.ring'],
                       cwd=os.path.dirname(lib), capture_output=True, timeout=1800, env=ENV)
    out = r.stdout.decode('utf-8', 'replace').strip()
    return (r.returncode == 0 and 'prefix:' in out), out.split('\n')[0] if out else ''


def drop_images():
    if os.path.isdir(CACHE):
        for f in os.listdir(CACHE):
            if f.endswith('.rnxi'):
                try:
                    os.remove(os.path.join(CACHE, f))
                except OSError:
                    pass


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('-')]
    if not os.path.isdir(K.LIB):
        print('SKIP wide clock: no Softanza tree at ' + K.LIB)
        return 0

    if '--discover' in sys.argv and '--wide' in sys.argv:
        found = discover_wide()
        narrated = [n for n in found if n.endswith('_narrated.ring')]
        by_root = {}
        for n in found:
            r = n[1:].split('/')[0] if n.startswith('@') else 'base'
            by_root[r] = by_root.get(r, 0) + 1
        print('discovered %d tracked program(s) that load an aggregator first: %s; '
              '%d of them narrated' % (len(found), ', '.join('%s %d' % kv for kv in sorted(by_root.items())),
                                       len(narrated)))
        io.open(LIST_WIDE, 'w', encoding='utf-8', newline='\n').write('\n'.join(found) + '\n')
        print('written to ' + LIST_WIDE)
        return 0

    if '--discover' in sys.argv:
        found = discover()
        missing = check_rule(found)
        print('discovered %d assertion-bearing test(s) under base/test' % len(found))
        if missing:
            print('THE RULE IS WRONG: it misses %d of clock34\'s 34:' % len(missing))
            for m in missing[:10]:
                print('   ', m)
            return 1
        print('it finds all 34 of clock34\'s list, so it is the rule that made them')
        io.open(LIST, 'w', encoding='utf-8', newline='\n').write('\n'.join(found) + '\n')
        print('written to ' + LIST)
        return 0

    if not os.path.exists(LIST):
        print('no list yet -- run `python bench/clockall.py --discover` first')
        return 1
    names = [l.strip() for l in io.open(LIST, encoding='utf-8') if l.strip()]
    names = [n for n in names if not args or any(a in n for a in args)]

    if not os.path.isdir(K.COPY):
        K.make_copy()
    shutil.rmtree(CACHE, ignore_errors=True)
    ok, note = build_prefix()
    if not ok:
        print('SKIP wide clock: could not build the library prefix (%s)' % note)
        return 0
    print(note)

    exact = stable = 0
    volatile_total = 0
    timeouts, missing, hung = [], [], []
    diffs = []
    t0 = time.time()
    for i, rel in enumerate(names):
        mod, fn = rel.rsplit('/', 1)
        a_dir = os.path.join(K.LIB, 'base', 'test', mod.replace('/', os.sep))
        c_dir = os.path.join(K.COPY, 'base', 'test', mod.replace('/', os.sep))
        if not os.path.exists(os.path.join(c_dir, fn)):
            missing.append(rel)
            continue
        a1o, a1e = K.run([K.RING, fn], a_dir, timeout=90)
        a2o, a2e = K.run([K.RING, fn], a_dir, timeout=90)
        A, B = K.lines(a1o + a1e), K.lines(a2o + a2e)
        volatile = {i2 for i2, (x, y) in enumerate(zip(A, B)) if x != y}
        if len(A) != len(B):
            volatile |= set(range(min(len(A), len(B)), max(len(A), len(B))))
        drop_images()
        # A test that hangs is a row, not a crash: 432 of them means one
        # runaway must not end the pass.
        K.clear_generated(c_dir)
        try:
            r = subprocess.run([K.RNXC, fn], cwd=c_dir, capture_output=True, timeout=120, env=ENV)
            rnx_out = r.stdout
        except subprocess.TimeoutExpired as e:
            rnx_out = e.stdout or b''
            hung.append(rel)
        C = K.lines(rnx_out, drop_warnings=True)
        if b'<TIMEOUT>' in a1e:
            timeouts.append(rel)
        is_exact = (A == C)
        is_stable = True
        first = ''
        if len(A) != len(C):
            is_stable = False
            first = 'length %d vs %d' % (len(A), len(C))
        else:
            for k, (x, z) in enumerate(zip(A, C)):
                if x != z and k not in volatile:
                    is_stable = False
                    first = 'line %d: ring %r | rnx %r' % (
                        k + 1, x[:40].decode('utf-8', 'replace'), z[:40].decode('utf-8', 'replace'))
                    break
        exact += is_exact
        stable += is_stable
        volatile_total += len(volatile)
        tag = 'SAME ' if is_exact else ('STABLE' if is_stable else 'DIFF  ')
        if not is_stable:
            diffs.append((rel, first))
        print('%s %-54s %3d lines %2d vol  %s' % (tag, rel, len(A), len(volatile), first[:48]), flush=True)

    n = len(names) - len(missing)
    print()
    print('EXACT   %d of %d -- every line, measurements included' % (exact, n))
    print('STABLE  %d of %d -- every line the oracle reproduces from itself' % (stable, n))
    print('        %d lines set aside as the oracle\'s own noise' % volatile_total)
    print('        %.0f minutes' % ((time.time() - t0) / 60))
    if missing:
        print('        %d not in the copy, not counted' % len(missing))
    if timeouts:
        print('        %d timed out ON THE ORACLE, so they measure nothing' % len(timeouts))
    if hung:
        print('        %d timed out on RNX at 120 s -- ours, and named:' % len(hung))
        for h in hung:
            print('            ' + h)
    return 0


if __name__ == '__main__':
    sys.exit(main())
