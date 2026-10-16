# -*- coding: utf-8 -*-
"""`rnxc fmt` prints the canonical text the reference prints, and the canonical text means what the file meant.

    python bench/fmt.py [--stride=N] [--all] [--plant]       exit 1 on any failure

`rnxc fmt` (src/fmt.zig) is a port: the reference is rung 18's graph and printer (haro/spike/v18/l1.py), which is itself judged by its
fixtures and by the compiler. So the port is judged three ways, from the cheapest answer to the one that matters:

  F  the fixtures (haro/spike/v18/fixtures.txt, composed before either implementation): each program prints the text its fixture says,
     byte for byte
  P  PARITY with the reference, on a corpus of the probes, Ring's standard library, the checker's fixtures, a set of hard cases
     (empty, CRLF, a byte-order mark, 1,500 operands in a chain ...) and a sample of Softanza: the same bytes -- or, where the reference
     refuses a file, `fmt` refuses it too and prints nothing
  I  IDEMPOTENCE: formatting the output changes nothing
  R  ROUND TRIP: the output, read by the reference, is the graph the file was (every --rstep-th file; 4)
  D  COMPILED CODE: the output and the file compile to the same code (`rnxc dis`, loads blanked, lambda names and a few annotations
     normalised as in rung 18's court) -- every --dstep-th file, 10; a file that does not compile, or that rnxc refuses part of, is skipped
  S  SEMANTICS: each probe of bench/exec, formatted, prints on the ORACLE (what Ring itself does, never rnxc) what the original printed,
     with the same exit code. Whether two texts mean the same is a question for Ring; a reading of the tree cannot answer it for itself
  C  three controls that must FAIL: a reference that indents with two spaces must part from `fmt` on a real file; one byte of an output is
     changed and the comparison has to notice; and a formatted probe with one printed word changed must print something else on the oracle

The reference reads the tree through `rnxc dump --json` (CST_EXPORT=1), the same tree `fmt` is built on. It runs in this process; the
port runs as `rnxc fmt <file>`, as a user would.
"""
import glob, os, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
V18 = os.path.join(ROOT, 'haro', 'spike', 'v18')
if not os.path.isdir(V18):
    # Ring++'s public main is published without haro/, and the reference this court judges by is Haro's
    print('SKIP fmt court: its reference, haro/spike/v18, is not in this tree')
    sys.exit(0)
sys.path.insert(0, V18)
sys.path.insert(0, HERE)
import cst, l1, l1_check, dumpjson

RNXC = os.environ.get('RNXC') or os.path.join(ROOT, 'zig-out', 'bin', 'rnxc.exe')
ORACLE = os.environ.get('RING') or os.path.join(ROOT, 'runtime', 'win64', 'ring.exe')
STZ = r'D:\GitHub\stzlib\libraries\stzlib'
PLANT = '--plant' in sys.argv
STRIDE, OFFSET, RSTEP, DSTEP = 61, 0, 4, 10
for a in sys.argv[1:]:
    if a == '--all':
        STRIDE = 1
    elif a.startswith('--stride='):
        STRIDE = int(a[9:])
    elif a.startswith('--offset='):
        OFFSET = int(a[9:])
    elif a.startswith('--rstep='):
        RSTEP = int(a[8:])
    elif a.startswith('--dstep='):
        DSTEP = int(a[8:])
os.environ['CST_EXPORT'] = '1'
cst.RNXC = RNXC
FLOOR_FILES = 200
fails = []


def fmt(path):
    r = subprocess.run([RNXC, 'fmt', path], capture_output=True, timeout=300)
    return r.returncode, r.stdout, r.stderr.decode('latin-1').strip()


CLOSURE_BIAS = 1 << 30   # vm.closure_bias: a closure's first element is 2^30 + the lambda's id
JUMPS = {'jmp', 'jlt', 'jle', 'jgt', 'jge', 'jeq', 'jne', 'jeqi', 'jnei', 'jgti', 'jfalsy', 'jtruthy', 'forloop', 'forloops', 'ptry',
         'jmpl', 'lnhi'}


def lambda_order_free(dis):
    """`rnxc dis` up to the ORDER lambdas are compiled in -- which is not a result. A `return func t {` the grammar misreads is compiled
    through the re-read path, after every function the grammar read directly, and `fmt` prints it `func(t) {`, which the grammar reads
    directly (bench/exec/lambda_return.ring, 2026-10-12): the same lambdas, other ids and entries. Each function's code with its jumps
    relative to its entry and every closure id blanked; the named functions in order, the lambdas as a sorted list. Which lambda a closure
    builds is NOT compared here -- the S check, on the oracle, is the judge of that."""
    import re
    heads, code = [], {}
    for line in dis.splitlines():
        m = re.match(r'^(\S+)\s+entry=(\d+) frame=(\d+) id=\d+ mask=(\S+)', line)
        if m:
            heads.append((m.group(1), int(m.group(2)), m.group(3), m.group(4)))
            continue
        m = re.match(r'^\s*(\d+)\s+(\w+)\s+a=(\d+)\s+b=(\d+)\s+c=(\d+)\s+d=(-?\d+)', line)
        if m:
            code[int(m.group(1))] = (m.group(2), m.group(3), m.group(4), m.group(5), int(m.group(6)))
    heads.sort(key=lambda h: h[1])
    lambda_entries = {h[1] for h in heads if h[0].startswith('@@lambda')}
    named, lambdas = [], []
    for k, (name, entry, frame, mask) in enumerate(heads):
        end = heads[k + 1][1] if k + 1 < len(heads) else max(code, default=entry) + 1
        body = []
        for pc in range(entry, end):
            if pc not in code:
                continue
            op, a, b, c, d = code[pc]
            if op in JUMPS:
                d = 'rel%d' % (d - entry) if d else 'unpatched'
            elif op == 'loadi' and d >= CLOSURE_BIAS:
                d = 'CLOS'
            elif op == 'call' and d in lambda_entries:   # a lambda called by entry: which one, and its frame, move with the order
                b, d = '_', 'LAMBDA'
            body.append((op, a, b, c, d))
        (lambdas if name.startswith('@@lambda') else named).append((name, frame, mask, tuple(body)))
    return named, sorted(lambdas, key=repr)


def reference(path):
    """-> (the canonical text as bytes, None, its graph), or (None, why it refuses, None)."""
    try:
        g, why = l1.parse_ring(path)
    except Exception as e:
        return None, 'raised %s: %s' % (type(e).__name__, str(e)[:60]), None
    if g is None:
        return None, why, None
    try:
        return l1.print_ring(g).encode('latin-1'), None, g
    except Exception as e:
        return None, 'print raised %s: %s' % (type(e).__name__, str(e)[:60]), None


def corpus(d):
    files = sorted(glob.glob(os.path.join(HERE, 'exec', '*.ring')))
    files += sorted(glob.glob(os.path.join(HERE, 'check', '*.ring')))
    files += sorted(glob.glob(os.path.join(ROOT, 'vendor', 'ring-stdlib', '**', '*.ring'), recursive=True))
    files += sorted(glob.glob(os.path.join(ROOT, 'rpp', '**', '*.ring'), recursive=True))
    files += sorted(glob.glob(os.path.join(ROOT, 'haro', 'spike', '*.ring')))
    if os.path.isdir(STZ):
        stz = sorted(glob.glob(os.path.join(STZ, '**', '*.ring'), recursive=True))
        files += [p for p in stz[OFFSET::STRIDE] if os.path.getsize(p) <= 400_000]
    return files + dumpjson.hard_cases(d)


def judge_pair(a, b):
    """The first place two byte strings part, as a sentence; None when they agree."""
    if a == b:
        return None
    i = next((i for i in range(min(len(a), len(b))) if a[i] != b[i]), min(len(a), len(b)))
    ln = a.count(b'\n', 0, i) + 1
    return 'line %d: %r | %r' % (ln, a[max(0, i - 20):i + 40], b[max(0, i - 20):i + 40])


def main():
    t0 = time.time()
    d = tempfile.mkdtemp(prefix='fmtcourt_')

    # F -- the fixtures
    fx = [f for f in l1_check.read_fixtures(os.path.join(V18, 'fixtures.txt')) if f['out'] is not None and f['ring'] is not None]
    bad = 0
    for f in fx:
        p = os.path.join(d, 'fx%s.ring' % f['id'])
        open(p, 'wb').write(f['ring'].encode('latin-1'))
        code, out, err = fmt(p)
        why = None if code == 0 and out == f['out'].encode('latin-1') else (judge_pair(out, f['out'].encode('latin-1')) or err or 'exit %d' % code)
        if why:
            bad += 1
            print('  FAIL fixture %s %s -- %s' % (f['id'], f['name'], why[:160]))
    ok = bad == 0 and len(fx) >= 20
    print(('  ok   ' if ok else '  FAIL ') + 'F %d fixtures print the text they say (%d fail)' % (len(fx), bad))
    if not ok:
        fails.append('F')

    # P and I -- parity with the reference, and idempotence
    files = corpus(d)
    same = both_refuse = 0
    parity_bad, idem_bad, rt_bad, dis_bad = [], [], [], []
    rt_n = dis_n = dis_skip = dis_order = 0
    outputs = {}
    for n, p in enumerate(files):
        ref, rwhy, graph = reference(p)
        code, out, err = fmt(p)
        if ref is None and code != 0:
            both_refuse += 1
            continue
        if ref is None:
            parity_bad.append((p, 'the reference refuses (%s) and fmt prints' % rwhy[:60]))
            continue
        if code != 0:
            parity_bad.append((p, 'fmt refuses (%s) where the reference prints' % err[:80]))
            continue
        w = judge_pair(out, ref)
        if w:
            parity_bad.append((p, w))
            continue
        same += 1
        outputs[p] = out
        q = os.path.join(d, 'idem%d.ring' % n)
        open(q, 'wb').write(out)
        c2, out2, err2 = fmt(q)
        if c2 != 0 or out2 != out:
            idem_bad.append((p, judge_pair(out2, out) or err2 or 'exit %d' % c2))
        if n % RSTEP == 0:
            rt_n += 1
            try:
                g2, why2 = l1.parse_ring(q)
            except Exception as e:
                g2, why2 = None, 'raised %s' % type(e).__name__
            if g2 != graph:
                # EXACT. It was exact up to parentheses the printer added while the abstraction read a statement-leading unary as the
                # grammar does (`-a - b` as `-(a - b)`): one file in 6,275, bench/exec/newline_rule.ring, and the cause was a wrong graph
                # (HF-79), not a printer's habit -- so no tolerance is left to hide the next one
                rt_bad.append((p, why2 or 'the graph of the output is not the graph of the file'))
        if n % DSTEP == 0 and p.startswith((STZ, ROOT)):
            text = open(p, 'rb').read().decode('latin-1')
            canon = out.decode('latin-1')
            ao = l1_check.dis(l1_check.strip_loads(text), 'o%d.ring' % n)
            ak = l1_check.dis(l1_check.strip_loads(canon), 'k%d.ring' % n)
            if ao[0] != 0 or ak[0] != 0:
                dis_skip += 1
            elif ao != ak and l1_check.refusals(l1_check.strip_loads(text), 'r%d.ring' % n):
                dis_skip += 1
            elif ao != ak and lambda_order_free(ao[1]) == lambda_order_free(ak[1]):
                dis_n += 1
                dis_order += 1
            elif ao != ak:
                i = next((i for i in range(min(len(ao[1]), len(ak[1]))) if ao[1][i] != ak[1][i]), 0)
                dis_bad.append((p, 'at %d: %r | %r' % (i, ao[1][max(0, i - 50):i + 70], ak[1][max(0, i - 50):i + 70])))
            else:
                dis_n += 1
        if n % 500 == 499:
            print('  ...', n + 1, 'of', len(files), flush=True)
    for p, why in parity_bad[:12]:
        print('  FAIL parity', os.path.relpath(p, ROOT) if p.startswith(ROOT) else p, '--', why[:200])
    for p, why in idem_bad[:8]:
        print('  FAIL idempotence', os.path.relpath(p, ROOT) if p.startswith(ROOT) else p, '--', why[:200])
    okp = not parity_bad and len(files) >= FLOOR_FILES
    print(('  ok   ' if okp else '  FAIL ') + 'P %d file(s): %d print the reference\'s bytes, %d are refused by both, %d differ (floor %d files)'
          % (len(files), same, both_refuse, len(parity_bad), FLOOR_FILES))
    for p, why in rt_bad[:8]:
        print('  FAIL round trip', os.path.relpath(p, ROOT) if p.startswith(ROOT) else p, '--', why[:200])
    for p, why in dis_bad[:8]:
        print('  FAIL compiled', os.path.relpath(p, ROOT) if p.startswith(ROOT) else p, '--', why[:300])
    okr = not rt_bad
    print(('  ok   ' if okr else '  FAIL ') + 'R %d output(s), read back, are exactly the graph of the file (%d are not)' % (rt_n, len(rt_bad)))
    okd = not dis_bad
    print(('  ok   ' if okd else '  FAIL ') + 'D %d file(s) compile to the same code formatted (%d of them only up to the order lambdas are compiled'
          ' in; %d skipped: they do not compile alone, or rnxc refuses part; %d differ)' % (dis_n, dis_order, dis_skip, len(dis_bad)))
    if not okr:
        fails.append('R')
    if not okd:
        fails.append('D')
    oki = not idem_bad
    print(('  ok   ' if oki else '  FAIL ') + 'I %d output(s) are their own canonical form (%d are not)' % (same, len(idem_bad)))
    if not okp:
        fails.append('P')
    if not oki:
        fails.append('I')

    # S -- the probes, formatted, on the oracle
    probes = sorted(glob.glob(os.path.join(HERE, 'exec', '*.ring')))
    sd = os.path.join(d, 'sem')
    os.makedirs(sd)
    mism, ran = [], 0
    for p in probes:
        out = outputs.get(p)
        if out is None:
            continue
        q = os.path.join(sd, os.path.basename(p))
        open(q, 'wb').write(out)
        a = subprocess.run([ORACLE, p], capture_output=True, timeout=120, cwd=os.path.dirname(p))
        b = subprocess.run([ORACLE, q], capture_output=True, timeout=120, cwd=os.path.dirname(p))
        if a.returncode == 0 and b.returncode == 0 and a.stdout.replace(p.encode(), b'<f>') == b.stdout.replace(q.encode(), b'<f>'):
            ran += 1
        elif a.returncode != 0 and b.returncode == a.returncode:
            ran += 1            # a probe that ends in an error ends in the same one
        else:
            mism.append((p, 'oracle exit %d vs %d, %s' % (a.returncode, b.returncode, judge_pair(a.stdout, b.stdout) or 'same stdout')))
    for p, why in mism[:10]:
        print('  FAIL semantics', os.path.relpath(p, ROOT), '--', why[:200])
    oks = not mism and ran >= 80
    print(('  ok   ' if oks else '  FAIL ') + 'S %d probe(s), formatted, do on the oracle what the original does (%d differ)' % (ran, len(mism)))
    if not oks:
        fails.append('S')

    # C -- the controls. A comparison that cannot fail is not a court.
    probe = os.path.join(HERE, 'exec', 'newline_rule.ring')
    indented = next((q for q, o in outputs.items() if b'\n\t' in o), None)           # a file with a block in it: the one place a tab shows
    keep = l1.TAB
    l1.TAB = '  '
    try:
        spoiled = reference(indented)[0] if indented else None
    finally:
        l1.TAB = keep
    c1 = spoiled is not None and judge_pair(outputs[indented], spoiled) is not None
    print(('  ok   ' if c1 else '  FAIL ') + 'C a reference that indents with two spaces parts from fmt on a real file')
    victim = next(iter(outputs.values()), b'x\n')
    c2 = judge_pair(victim[:-2] + b'Z' + victim[-1:], victim) is not None
    print(('  ok   ' if c2 else '  FAIL ') + 'C a corrupted output is caught by the comparison')
    q = os.path.join(sd, 'control.ring')
    good = outputs.get(probe, b'')
    open(q, 'wb').write(good.replace(b'"P2 "', b'"PX "'))
    ra = subprocess.run([ORACLE, probe], capture_output=True, timeout=120, cwd=os.path.dirname(probe))
    rb = subprocess.run([ORACLE, q], capture_output=True, timeout=120, cwd=os.path.dirname(probe))
    c3 = b'"PX "' in open(q, 'rb').read() and ra.stdout != rb.stdout
    print(('  ok   ' if c3 else '  FAIL ') + 'C a formatted probe with one printed word changed prints something else on the oracle')
    for ok_, tag in ((c1, 'C1'), (c2, 'C2'), (c3, 'C3')):
        if not ok_:
            fails.append(tag)
    if PLANT:
        print('  FAIL PLANTED')
        fails.append('plant')
    print(('FMT OK' if not fails else 'FMT FAIL') + '   %d fixtures, %d files byte for byte as the reference (%d refused by both), %d read back, %d compiled alike, %d probes alike on the oracle   %d s'
          % (len(fx), same, both_refuse, rt_n, dis_n, ran, time.time() - t0))
    return 0 if not fails else 1


if __name__ == '__main__':
    sys.setrecursionlimit(100000)
    threading.stack_size(128 * 1024 * 1024)
    rc = []
    t = threading.Thread(target=lambda: rc.append(main()))
    t.start()
    t.join()
    sys.exit(rc[0] if rc else 1)
