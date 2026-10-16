# -*- coding: utf-8 -*-
"""A/B every bench module against Ring 1.27.

For each `<m>_run.ring`, run it under Ring, then call each function it
prints through the Ring++ prototype and compare. The output of the two
must agree exactly -- byte-identical answers BEFORE any other claim, the
same rule the ringpp examples enforce.

    python bench/ab.py            all modules
    python bench/ab.py li sx      only these

A module can declare expected differences in `ab-known.txt`, one
`module:Func  reason` per line. They are reported as KNOWN (not built
yet) or DIVERGE (built differently on purpose -- the reason begins with
DIVERGENCE), never as passes. A gate that did not run is named, never
quietly skipped.
"""
import io, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
# The oracle: Ring 1.27's VM built from vendor/ring-vm by tests/b2_runtimes.ps1
# -- OUR build, not an installation upstream controls. RING=<path> in the
# environment overrides it, e.g. to compare against the official binary.
RING = os.environ.get('RING') or os.path.join(os.path.dirname(HERE), 'runtime', 'win64', 'ring.exe')
RNXC = os.environ.get('RNXC') or os.path.join(HERE, '..', 'zig-out', 'bin', 'rnxc.exe')

CALL = re.compile(r'^\s*\?\s*(?:"[^"]*"\s*\+\s*)?([A-Za-z_][A-Za-z_0-9]*)\s*\(([^)]*)\)')


def known():
    out = {}
    p = os.path.join(HERE, 'ab-known.txt')
    if not os.path.exists(p):
        return out
    for line in io.open(p, encoding='utf-8'):
        line = line.split('#')[0].strip()
        if not line:
            continue
        key, _, reason = line.partition(' ')
        out[key.strip()] = reason.strip() or 'no reason given'
    return out


def calls(run_path):
    """The (func, args) pairs a runner prints, in order."""
    got = []
    for line in io.open(run_path, encoding='utf-8'):
        m = CALL.match(line)
        if not m:
            continue
        raw = m.group(2).strip()
        args = [a.strip() for a in raw.split(',')] if raw else []
        # only integer literals can cross the `call` boundary today
        if any(not re.fullmatch(r'-?\d+', a) for a in args):
            args = None
        got.append((m.group(1), args))
    return got


def value_of(line):
    """The value a line reports, with any `CHECK <name>` prefix removed.

    Applied to BOTH sides: `rnxc call` always prints that prefix, and some
    runners print one of their own, so normalising only one side made
    `CHECK nestalias 0` differ from `0`.
    """
    line = line.strip()
    parts = line.split(None, 2)
    if parts and parts[0] == 'CHECK':
        return parts[2].strip() if len(parts) >= 3 else ''
    return line


def run(cmd, cwd):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=300)
    return (r.stdout + r.stderr).replace('\r', '')


def main(only):
    ks = known()
    fail = skipped = 0
    mods = sorted(f[:-9] for f in os.listdir(HERE) if f.endswith('_run.ring'))
    for m in mods:
        if only and m not in only:
            continue
        expect = run([RING, m + '_run.ring'], HERE).split('\n')
        expect = [x for x in (e.strip() for e in expect) if x]
        # The WHOLE printed value, not its last word. Reducing each result
        # to `x.split()[-1]` meant "...less number of parameters" and
        # "...extra number of parameters" both became "parameters" and
        # agreed with each other, and every multi-word result in the suite
        # was being checked on a single token.
        want = [value_of(x) for x in expect]

        pairs = calls(os.path.join(HERE, m + '_run.ring'))
        if not pairs:
            continue
        bad, notes = [], []
        for i, (fn, args) in enumerate(pairs):
            key = '%s:%s' % (m, fn)
            if key in ks:
                tag = 'DIVERGE' if ks[key].startswith('DIVERGENCE') else 'KNOWN  '
                notes.append('%s %s -- %s' % (tag, key, ks[key]))
                skipped += 1
                continue
            if args is None:
                notes.append('SKIP  %s -- non-integer argument, `call` cannot pass it' % key)
                skipped += 1
                continue
            out = run([RNXC, 'call', m + '.ring', fn] + args, HERE).strip().split('\n')
            got = value_of(out[-1]) if out else '<none>'
            exp = want[i] if i < len(want) else '<missing>'
            if got != exp:
                bad.append('    %-22s\n        ring= %s\n        rnx=  %s' %
                           (fn + '(' + ','.join(args) + ')', exp, got))
        if bad:
            fail += len(bad)
            print('DIFF %s' % m)
            print('\n'.join(bad))
        else:
            print('OK   %s  (%d checked)' % (m, len(pairs) - len(notes)))
        for n in notes:
            print('     ' + n)

    print('\n%s   %d differing, %d named-and-skipped' %
          ('FAIL' if fail else 'ALL AGREE WITH RING', fail, skipped))
    return 1 if fail else 0


if __name__ == '__main__':
    sys.exit(main(set(sys.argv[1:])))
