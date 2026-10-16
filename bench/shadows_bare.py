# -*- coding: utf-8 -*-
r"""C-2's BARE globals: does `rnxc shadows` see them, and how many are there?

    python bench/shadows_bare.py              13 shapes, held to the ORACLE
    python bench/shadows_bare.py --sample=36  the base unit, http_setters, and
                                              every 36th narrated test (~7 s a
                                              unit, one at a time, read-only)

WHY. C-2 (docs/CORRECTIONS.md) made a bare top-level name a global and
accepted one silent divergence: a function that assigns such a name bare
WRITES THE GLOBAL on Ring and makes a LOCAL on Ring++. Its record named
`rnxc shadows` as the guard. Measured 2026-09-23, the guard counted only
names defined as `$` globals -- where the two runtimes AGREE, because `$g`
and `g` are two names to Ring -- and saw none of C-2's own population.
`rnxc shadows` reports the bare ones now, tab-free and apart from the `$`
count; `--bare` prints their write sites as TSV. The gate pins the base
unit's write sites at 0 (bench/shadows_bare.max, Mansour, 2026-09-23).

THE SHAPES are the proof. Each is run on the oracle (what Ring does), on rnx
(what Ring++ does), and through the report, and the verdict must agree with
Ring: a shape counted "reader" must be one where the two runtimes print
different answers, and a shape where they agree must not be. P11-P12 are why
that check exists -- the first version counted a `for` variable as a write of
the global, and Ring says it is the function's local.
"""
import io, os, re, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RING = os.path.join(ROOT, 'runtime', 'win64', 'ring.exe')
# RNXC_BIN runs the shapes against another build -- which is how this was
# made to fail on the tool as it stood before 2026-09-23.
RNXC = os.environ.get('RNXC_BIN') or os.path.join(ROOT, 'zig-out', 'bin', 'rnxc.exe')
LIB = r'D:\GitHub\stzlib\libraries\stzlib'

# name -> (source, expected verdict: reader / scratch / none / loud)
SHAPES = [
    ('P1  $-global, a function writes bare g', 'none',
     '$g = "top"\nG()\n? "P " + $g\nfunc G()\n\tg = "from G"\n'),
    ('P2  bare global, a function writes it', 'reader',
     'g = "top"\nG()\n? "P " + g\nfunc G()\n\tg = "from G"\n'),
    # C-14 (2026-09-24): a top-level lambda's bare write reaches the global on
    # both runtimes, so this shape AGREES now and the walker counts no site
    ('P3  bare global, a lambda writes it', 'none',
     'g = "top"\nf = func { g = "from f" }\ncall f()\n? "P " + g\n'),
    ('P4  $-global, a lambda writes bare g', 'none',
     '$g = "top"\nf = func { g = "from f" }\ncall f()\n? "P " + $g\n'),
    ('P5  bare global, a method writes it', 'reader',
     'g = "top"\no = new K\no.M()\n? "P " + g\nclass K\n\tdef M()\n\t\tg = "from M"\n'),
    ('P6  bare global, a function reads it', 'loud',
     'g = "top"\n? "P " + R()\nfunc R()\n\treturn g\n'),
    ('P7  $-global, a function reads bare g', 'none',
     '$g = "top"\n? "P " + R()\nfunc R()\n\treturn g\n'),
    ('P8  bare global, the top never reads it', 'scratch',
     'g = "top"\nG()\n? "P done"\nfunc G()\n\tg = "x"\n\tsee ""\n'),
    ('P10 a lambda inside a function writes it', 'reader',
     'g = "top"\nF()\n? "P " + g\nfunc F()\n\tf = func { g = "lam" }\n\tcall f()\n'),
    ('P11 a for variable on a bare global', 'none',
     'i = 100\nF()\n? "P " + i\nfunc F()\n\tfor i = 1 to 3 next\n'),
    ('P12 a for-in variable on a bare global', 'none',
     'x = "top"\nF()\n? "P " + x\nfunc F()\n\tfor x in [1, 2] next\n'),
    ('P13 a for variable read after its loop', 'none',
     'i = 100\n? "P " + F()\nfunc F()\n\tfor i = 1 to 3 next\n\treturn i\n'),
    ('P14 the task probe: a lambda AND a function', 'reader',
     'cWhy = "(never)"\nf = func e { cWhy = "" + e }\ncall f("boom")\nG()\n? "P " + cWhy\n'
     'func G()\n\tcWhy = "from G"\n'),
]


def run(cmd, cwd):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True)
    return r.stdout.decode('utf-8', 'replace'), r.stderr.decode('utf-8', 'replace'), r.returncode


def report(err):
    def num(pat):
        m = re.search(pat, err)
        return int(m.group(1)) if m else -1
    return dict(
        globals=num(r'bare top-level globals in this unit: (\d+)'),
        names=num(r'bare globals written in a function, method or lambda.*?: (\d+) name'),
        sites=num(r'bare globals written in a function, method or lambda.*?: \d+ name\(s\), (\d+) write'),
        reader=num(r'written for a reader --.*?: (\d+) name'),
        reader_sites=num(r'written for a reader --.*?: \d+ name\(s\), (\d+) site'),
        scratch=num(r'scratch -- written first.*?: (\d+) name'),
        loud=num(r'REFUSES it \(loud\): (\d+)'))


def shapes():
    tmp = tempfile.mkdtemp(prefix='shadows_bare_')
    bad = 0
    try:
        p = os.path.join(tmp, 'probe.ring')
        for label, want, src in SHAPES:
            io.open(p, 'w', encoding='utf-8', newline='\n').write(src)
            ro, _, _ = run([RING, 'probe.ring'], tmp)
            xo, _, _ = run([RNXC, 'probe.ring'], tmp)
            _, se, _ = run([RNXC, 'shadows', 'probe.ring'], tmp)
            # CR is stripped: one runtime ends its lines in CRLF, and a
            # difference in line endings is not a difference in the answer
            ring = [l.rstrip('\r') for l in ro.split('\n') if l.startswith('P ')]
            rnx = [l.rstrip('\r') for l in xo.split('\n') if l.startswith('P ')]
            differ = bool(ring) and bool(rnx) and ring != rnx
            r = report(se)
            got = ('reader' if r['reader'] > 0 else 'scratch' if r['scratch'] > 0
                   else 'loud' if r['loud'] > 0 else 'none')
            # The verdict must agree with RING: "reader" only where the two
            # runtimes answer differently, and never where they agree.
            ok = got == want and (differ == (got == 'reader'))
            bad += not ok
            print('%-4s %-46s ring %-12s rnx %-12s -> %s' % (
                'ok' if ok else 'BAD', label, (ring[-1][2:] if ring else '(none)')[:12],
                (rnx[-1][2:] if rnx else '(refused)')[:12], got))
    finally:
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)
    print('%d of %d shapes agree with Ring' % (len(SHAPES) - bad, len(SHAPES)))
    return 1 if bad else 0


def sample(step):
    sys.path.insert(0, HERE)
    import clockall as W
    names = [l.strip() for l in io.open(W.LIST, encoding='utf-8') if l.strip()]
    pick = ['reactivehttp/01_http_setters_narrated.ring']
    pick += [n for n in names[::step] if n not in pick]
    units = [('BASE stzLib.ring', LIB, 'stzLib.ring')]
    for rel in pick:
        d, fn = os.path.split(rel.replace('/', os.sep))
        units.append((rel, os.path.join(LIB, 'base', 'test', d), fn))
    print('%d unit(s), one at a time, ~7 s each' % len(units))
    t0 = time.time()
    with_reader = 0
    total = 0
    for label, cwd, fn in units:
        t = time.time()
        so, se, code = run([RNXC, 'shadows', fn, '--bare'], cwd)
        r = report(se)
        tsv = [l.split('\t') for l in so.split('\n') if '\t' in l]
        if not label.startswith('BASE'):
            with_reader += r['reader'] > 0
            total += max(r['reader_sites'], 0)
        print('%-54s %4.1f s  globals %3d  written %3d/%3d  reader %3d/%3d  scratch %3d  loud %3d' % (
            label[:54], time.time() - t, r['globals'], r['names'], r['sites'],
            r['reader'], r['reader_sites'], r['scratch'], r['loud']), flush=True)
        for f in tsv:
            if len(f) >= 5 and f[4] == 'reader':
                print('      %s:%s  %s  in %s' % (os.path.basename(f[0]), f[1], f[2], f[3]))
    print('%d test unit(s) of %d with a reader site, %d reader site(s) in all; %.0f s'
          % (with_reader, len(units) - 1, total, time.time() - t0))
    return 0


if __name__ == '__main__':
    step = None
    for a in sys.argv[1:]:
        if a.startswith('--sample'):
            step = int(a.split('=', 1)[1]) if '=' in a else 36
    sys.exit(sample(step) if step else shapes())
