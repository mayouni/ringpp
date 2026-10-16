"""RingServ's own compatibility suites, run on Ring++ against the oracle -- the second rung of the ladder measured the way
RingServ measures itself, and its library censused.

    python bench/ringserv_sweep.py              run what has no output yet, then classify
    python bench/ringserv_sweep.py --rerun      run everything again
    python bench/ringserv_sweep.py --classify   classify the outputs already on disk

RingServ (D:/GitHub/ringserv, RINGSERV_DIR) is READ, never written: its tests/sweep.js, ring-exe.js and oracle.js are
copied to runtime/ringserv/sweep and patched there in three places each -- the runtime under test is rnxc, run as
`rnxc <file>`, and RingServ's KNOWN_DIVERGENCES (its own eval limits) are emptied. The corpora are copied beside them:

    samples        the six folders RingServ sweeps of Ring's samples (RING_SAMPLES, default D:/ring127/samples --
                   a measurement corpus read once, like the stzlib census corpus, never a dependency)
    doc-snippets   RingServ's tests/doc-snippets, 499 programs cut from Ring's documentation
    examples       RingScript's 24 playground examples (RINGSCRIPT_DIR), through RingServ's tests/oracle.js

The sweep classifies each program as RingServ does: compare (output must match the oracle), nocrash (random, clock,
input: must run cleanly), skip (system(), pointers, GUI, threads...). Every divergence is then run again on both
runtimes and filed by WHAT RING++ SAID -- a missing builtin, a refusal, another error, or a quiet difference -- because
the census tells you where and the source tells you what.

FIRST MEASUREMENT, 2026-10-13, the package's rnxc (14cc535): 607 of 766 compared programs agree (79%) -- samples 243 of
315, doc snippets 364 of 451 -- and 11 of 24 playground examples. The library: 14 files, 749 statements, 700 compiled
(93%), 49 refused, every one a top-level global read bare in a function (Rule A); 30 natives, all RingServ's own.
CLAUDE.md "RINGSERV ON RING++" holds the causes.

SKIPs, named, when node, RingServ, the corpus or the oracle is absent."""
import collections, io, json, os, re, shutil, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RS = os.environ.get('RINGSERV_DIR', r'D:\GitHub\ringserv')
SAMPLES = os.environ.get('RING_SAMPLES', r'D:\ring127\samples')
RINGSCRIPT = os.environ.get('RINGSCRIPT_DIR', r'D:\GitHub\ringscript')
RNXC = os.environ.get('RNXC', os.path.join(ROOT, 'runtime', 'package', 'ringpp-win64', 'bin', 'rnxc.exe'))
RING = os.environ.get('RING', os.path.join(ROOT, 'runtime', 'win64', 'ring.exe'))
BASE = os.path.join(ROOT, 'runtime', 'ringserv')
SWEEP, CORPUS, OUT = (os.path.join(BASE, d) for d in ('sweep', 'corpus', 'out'))
DIRS = ['AQuickStart', 'Language', 'Algorithms', 'DataStructure', 'ProblemSolving', 'General']
INPUT = b'3\n7\n2\n4\n1\n9\n8\n5\n5\n5\n5\n5\n5\n5\n'   # what the sweep feeds a program that reads
LIB = ['json_c', 'serv', 'data', 'generic', 'contract', 'topology', 'sync', 'jsserv', 'actor', 'journal', 'gesture',
       'family', 'config', 'testing']                     # the order bridge.zig's rs_init runs them in
BS = chr(92)


def js(p):
    return p.replace(BS, BS * 2)


def patched(src, subs, name):
    for old, new in subs:
        assert src.count(old) == 1, '%s: the patch no longer applies at %r' % (name, old[:50])
        src = src.replace(old, new)
    return src


def lay_out(rerun):
    os.makedirs(SWEEP, exist_ok=True)
    os.makedirs(OUT, exist_ok=True)
    rnxc_js = '// PATCHED (ringpp): the runtime under test is Ring++\'s rnxc.\nconst RINGSERV = process.env.RNXC || "%s";' % js(RNXC)
    serv_decl = 'const RINGSERV = path.join(__dirname, "..", "zig-out", "bin",\n    process.platform === "win32" ? "ringserv.exe" : "ringserv");'
    s = io.open(os.path.join(RS, 'tests', 'sweep.js'), encoding='utf-8').read()
    s = patched(s, [(serv_decl, rnxc_js),
                    ('const serv = run(RINGSERV, ["run", file], file, input);',
                     'const serv = run(RINGSERV, [file], file, input);   // PATCHED (ringpp): rnxc <file>')], 'sweep.js')
    s, n = re.subn(r'const KNOWN_DIVERGENCES = new Map\(\[.*?\]\);',
                   'const KNOWN_DIVERGENCES = new Map([]);   // PATCHED (ringpp): RingServ\'s entries are its eval limits', s, count=1, flags=re.S)
    assert n == 1, 'sweep.js: KNOWN_DIVERGENCES moved'
    io.open(os.path.join(SWEEP, 'sweep.js'), 'w', encoding='utf-8', newline='').write(s)
    o = io.open(os.path.join(RS, 'tests', 'oracle.js'), encoding='utf-8').read()
    o = patched(o, [(serv_decl, rnxc_js),
                    ('const args = exe === RINGSERV ? ["run", file] : [file];', 'const args = [file];   // PATCHED (ringpp): rnxc <file>'),
                    ('path.join(__dirname, "..", "..", "ringscript")', '"%s"' % js(RINGSCRIPT))], 'oracle.js')
    io.open(os.path.join(SWEEP, 'oracle.js'), 'w', encoding='utf-8', newline='').write(o)
    shutil.copy2(os.path.join(RS, 'tests', 'ring-exe.js'), os.path.join(SWEEP, 'ring-exe.js'))
    for d in DIRS:
        dst = os.path.join(CORPUS, 'samples', d)
        if rerun or not os.path.isdir(dst):
            shutil.rmtree(dst, ignore_errors=True)
            shutil.copytree(os.path.join(SAMPLES, d), dst)
    dst = os.path.join(CORPUS, 'doc-snippets')
    if rerun or not os.path.isdir(dst):
        shutil.rmtree(dst, ignore_errors=True)
        shutil.copytree(os.path.join(RS, 'tests', 'doc-snippets'), dst)


def node(args, out, failures=None):
    env = dict(os.environ, RING_EXE=RING, RNXC=RNXC)
    r = subprocess.run(['node'] + args, cwd=SWEEP, env=env, capture_output=True)
    io.open(out, 'w', encoding='utf-8', newline='').write(r.stdout.decode('utf-8', 'replace') + r.stderr.decode('utf-8', 'replace'))
    f = os.path.join(SWEEP, 'sweep-failures.json')
    if failures:
        if os.path.exists(f):
            shutil.move(f, failures)
        else:
            io.open(failures, 'w', encoding='utf-8').write('[]')


def tally(path):
    t = {}
    for ln in io.open(path, encoding='utf-8', errors='replace'):
        m = re.match(r'(exact match|ran \(nondet\)|mismatch|ringserv err|native fail|skipped|known diverg)\s*:\s*(\d+)', ln)
        if m:
            t[m.group(1)] = int(m.group(2))
    return t


def say(exe, f):
    try:
        r = subprocess.run([exe, f], cwd=os.path.dirname(f), capture_output=True, timeout=25, input=INPUT)
        return r.stdout.decode('utf-8', 'replace').replace('\r', '')
    except subprocess.TimeoutExpired:
        return None


ERR = re.compile(r'Error \((\w+)\) : ([^\n]*)|^Line \d+ (Bad parameter type!|[A-Z][^\n(]*)$', re.M)


def cause(o, ro):
    """What Ring++ said, against what the oracle said."""
    if o is None:
        return 'Ring++ timed out'
    m = re.search(r'Ring\+\+ refused this statement \(([^`(]+)', o)
    if m:
        return 'refused: ' + m.group(1).strip()
    e, eo = ERR.search(o), ERR.search(ro or '')
    if e and not (eo and eo.group(0).split(':')[0] == e.group(0).split(':')[0]):
        if e.group(1) == 'R3':
            return 'R3 -- a Ring builtin Ring++ lacks, or an eval-defined function: ' + e.group(2).split(':')[-1].strip()
        if e.group(1):
            return ('Ring++ raises %s: %s' % (e.group(1), re.sub(r'\d+', '#', e.group(2))))[:80]
        return 'Ring++ raises: ' + e.group(3).strip()
    if eo and not e:
        return 'Ring raises, Ring++ does not: %s' % (eo.group(1) or eo.group(3))
    return 'output differs, no error on either side'


def classify():
    rows = []
    for name, root in (('samples-failures.json', 'samples'), ('docs-failures.json', 'doc-snippets')):
        p = os.path.join(OUT, name)
        if os.path.exists(p):
            rows += [(os.path.join(CORPUS, root, x['rel']), x['rel']) for x in json.load(io.open(p, encoding='utf-8'))]
    groups = collections.defaultdict(list)
    for f, rel in rows:
        k = cause(say(RNXC, f), say(RING, f))
        if k.startswith('R3'):
            groups['R3 -- a builtin Ring++ lacks'].append('%s (%s)' % (rel, k.split(': ')[-1]))
        else:
            groups[k].append(rel)
    json.dump(groups, io.open(os.path.join(OUT, 'causes.json'), 'w', encoding='utf-8'), indent=1)
    print('\nthe %d divergences, by what Ring++ said:' % len(rows))
    for k, v in sorted(groups.items(), key=lambda kv: -len(kv[1])):
        print('  %3d  %s' % (len(v), k))
        print('         ' + ', '.join(os.path.basename(x) for x in v[:6]) + (' ...' if len(v) > 6 else ''))


def census():
    unit = os.path.join(BASE, 'ringlib_unit.ring')
    have = sorted(f[:-5] for f in os.listdir(os.path.join(RS, 'src', 'ringlib')) if f.endswith('.ring'))
    io.open(unit, 'w', encoding='utf-8', newline='\n').write(
        "# RingServ's Ring library, in the order bridge.zig runs it (rs_init), read in place.\n" +
        ''.join('load "%s"\n' % os.path.join(RS, 'src', 'ringlib', n + '.ring').replace(BS, '/') for n in LIB))
    r = subprocess.run([RNXC, 'census', unit, '--natives'], capture_output=True)
    o = (r.stdout + r.stderr).decode('utf-8', 'replace')
    st = re.search(r'statements [^\n]*', o)
    nat = re.findall(r'^native:\s+\d+\s+(\S+)', o, re.M)
    print('\nRingServ\'s library (%d files; not in rs_init: %s): %s; %d native names'
          % (len(LIB), ', '.join(n for n in have if n not in LIB) or 'none', st.group(0) if st else '?', len(nat)))
    for m in re.finditer(r'^\s+(\d+x .*)$', o, re.M):
        print('    ' + m.group(1)[:110])


def main():
    for what, p in (('node', shutil.which('node')), ('RingServ', os.path.join(RS, 'tests', 'sweep.js')), ('the oracle', RING),
                    ('rnxc', RNXC), ('Ring\'s samples', SAMPLES)):
        if not p or not os.path.exists(p):
            print('SKIP  RingServ sweep -- %s not found (%s)' % (what, p))
            return 0
    rerun = '--rerun' in sys.argv
    if '--classify' not in sys.argv:
        lay_out(rerun)
        jobs = [(['sweep.js', '--root=' + os.path.join(CORPUS, 'samples'), '--verbose'], 'samples.txt', 'samples-failures.json'),
                (['sweep.js', '--root=' + os.path.join(CORPUS, 'doc-snippets'), '--dirs=.', '--verbose'], 'docs.txt', 'docs-failures.json')]
        if os.path.isdir(os.path.join(RINGSCRIPT, 'playground')):
            jobs.append((['oracle.js'], 'examples.txt', None))
        else:
            print('SKIP  the playground examples -- RingScript not found (%s)' % RINGSCRIPT)
        for args, out, fails in jobs:
            if rerun or not os.path.exists(os.path.join(OUT, out)):
                print('running', ' '.join(a if len(a) < 40 else '...' + a[-30:] for a in args), flush=True)
                node(args, os.path.join(OUT, out), fails and os.path.join(OUT, fails))
    agree = compared = 0
    for out in ('samples.txt', 'docs.txt'):
        p = os.path.join(OUT, out)
        if not os.path.exists(p):
            continue
        t = tally(p)
        a = t.get('exact match', 0) + t.get('ran (nondet)', 0)
        c = a + t.get('mismatch', 0) + t.get('ringserv err', 0)
        agree, compared = agree + a, compared + c
        print('%-12s %d of %d agree (exact %d, ran cleanly %d; mismatch %d, Ring++ failed %d; skipped %d, oracle failed %d)'
              % (out[:-4], a, c, t.get('exact match', 0), t.get('ran (nondet)', 0), t.get('mismatch', 0),
                 t.get('ringserv err', 0), t.get('skipped', 0), t.get('native fail', 0)))
    if compared:
        print('%-12s %d of %d agree (%.0f%%)' % ('both', agree, compared, 100.0 * agree / compared))
    p = os.path.join(OUT, 'examples.txt')
    if os.path.exists(p):
        s = io.open(p, encoding='utf-8', errors='replace').read()
        ok, bad = len(re.findall(r'^PASS ', s, re.M)), len(re.findall(r'^FAIL ', s, re.M))
        print('%-12s %d of %d playground examples agree; failing: %s' % ('examples', ok, ok + bad,
              ', '.join(re.findall(r'^FAIL\s+(\S+)', s, re.M))))
    classify()
    census()
    return 0


if __name__ == '__main__':
    sys.exit(main())
