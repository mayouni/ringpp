# -*- coding: utf-8 -*-
"""`rnxc graph` -- the resolved graph (L2) of a load unit -- is what the compiler bound, and says so in stzCodeGraph's own protocol.

    python bench/graph.py [--plant]          fixtures + consistency + determinism of the unit (~35 s; the gate step)
    python bench/graph.py --peer             + the name-based Ring peer (stzRingCodeGraph) over the same files, every difference named (~2 min)
    python bench/graph.py --ingest           + the protocol ingested by stzlib's own stzCodeGraph, its queries checked (~1.5 min)

  F  FIXTURES (bench/graph/*.ring, with the graph each must print, written by hand BEFORE the verb printed anything): a plain call, a
     method call through inheritance, a receiver the compiler proves and one it cannot, a call with the wrong number of arguments (no edge:
     it compiles to a trap), a builtin and a class's own method of the same name, a lambda, Ring's case folding, a function it cannot finish
  C  CONSISTENCY of the Softanza unit (D:\\GitHub\\stzlib\\...\\stzLib.ring, 612 files): every line is well formed; every parent, method owner,
     caller and static callee is declared; each dynamic edge's width is the number of methods of that name, recomputed here; no edge twice;
     the floors; at most three functions unfinished; and the same unit printed twice is the same text
  P  THE PEER, a text scan of Ring that ships with Softanza: its call edges against ours, and every one that differs given a CAUSE read out of
     the source (a builtin's name, a comment it does not strip, a `func` it does not register, a quote inside a quote ...), at most 2 percent
     of the differences left unexplained
  I  INGESTION: the stream, fed to stzCodeGraph unchanged, gives the counts and the answers it should

A check that cannot fail is not a check: --plant corrupts one callee and the consistency check must say so.
"""
import bisect, collections, os, re, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RNXC = os.environ.get('RNXC') or os.path.join(ROOT, 'zig-out', 'bin', 'rnxc.exe')
PACKAGE = os.path.join(ROOT, 'runtime', 'package', 'ringpp-win64', 'bin', 'rnxc.exe')
CORPUS = r'D:\GitHub\stzlib\libraries\stzlib\stzLib.ring'
WORK = os.path.join(ROOT, 'runtime', 'graph')
PLANT = '--plant' in sys.argv
PEER = '--peer' in sys.argv
INGEST = '--ingest' in sys.argv
REUSE = '--reuse-peer' in sys.argv          # keep the last run of the Ring peer (a minute and a half) when only the classification changed
low = str.lower
fails = []
SUMMARY = []


def check(ok, text):
    print(('  ok   ' if ok else '  FAIL ') + text)
    if not ok:
        fails.append(text)


def graph(path, cwd=None):
    r = subprocess.run([RNXC, 'graph', path], capture_output=True, cwd=cwd, timeout=900)
    return r.stdout.decode('latin-1'), r.stderr.decode('latin-1'), r.returncode


KINDS = {'FILE': (2,), 'CLASS': (4,), 'METHOD': (4,), 'FUNC': (3,), 'IMPORT': (2,), 'CALL': (4, 5), 'UNFINISHED': (2,)}


class L2:
    def __init__(self, text):
        self.files, self.classes, self.methods, self.funcs = [], {}, {}, {}
        self.calls, self.unfinished, self.bad = [], set(), []
        cur = None
        seen = set()
        for n, ln in enumerate(text.split('\n')):
            if not ln:
                continue
            p = ln.split('|')
            if p[0] not in KINDS or len(p) not in KINDS[p[0]]:
                self.bad.append('line %d is not the protocol: %r' % (n + 1, ln[:80]))
                continue
            k = p[0]
            if k == 'FILE':
                cur = p[1]
                self.files.append(cur)
                seen = set()
            elif k == 'CLASS':
                self.classes[low(p[1])] = (p[1], low(p[2]), int(p[3]), cur)
            elif k == 'METHOD':
                self.methods[(low(p[1]), low(p[2]))] = (p[1], p[2], int(p[3]), cur)
            elif k == 'FUNC':
                self.funcs.setdefault(low(p[1]), (p[1], int(p[2]), cur))
            elif k == 'CALL':
                if ln in seen:
                    self.bad.append('the edge is printed twice: %r' % ln[:80])
                seen.add(ln)
                self.calls.append((p[1], p[2], p[3], int(p[4]) if len(p) == 5 else None, cur))
            elif k == 'UNFINISHED':
                self.unfinished.add(low(p[1]))


def consistency(g, name):
    bad = list(g.bad)
    names = collections.Counter(m for _, m in g.methods)
    for (c, m), v in g.methods.items():
        if c not in g.classes:
            bad.append('method %s.%s belongs to a class nothing declares' % (v[0], v[1]))
    declared = {low(a + '.' + b) for (a, b) in ((v[0], v[1]) for v in g.methods.values())} | set(g.funcs)
    for caller, callee, tier, fan, f in g.calls:
        if low(caller) != '<top>' and low(caller) not in declared:
            bad.append('caller %s is not declared' % caller)
        if tier == 'static' and low(callee) not in declared:
            bad.append('static callee %s is not declared' % callee)
        if tier == 'dynamic' and fan != names.get(low(callee), 0):
            bad.append('dynamic %s says %s methods carry the name, the unit has %d' % (callee, fan, names.get(low(callee), 0)))
    check(not bad, '%s: well formed, every owner, caller and static callee declared, every dynamic width recounted, no edge twice%s'
          % (name, '' if not bad else ' -- ' + '; '.join(bad[:3])))
    return not bad


def fixtures():
    d = os.path.join(HERE, 'graph')
    names = sorted(f[:-5] for f in os.listdir(d) if f.endswith('.ring'))
    bad = []
    for n in names:
        out, err, code = graph(n + '.ring', cwd=d)
        want = open(os.path.join(d, n + '.expected'), encoding='utf-8').read().replace('\r\n', '\n')
        if out.replace('\r\n', '\n') != want:
            a, b = out.split('\n'), want.split('\n')
            i = next((i for i in range(min(len(a), len(b))) if a[i] != b[i]), min(len(a), len(b)))
            bad.append('%s: line %d is %r, the fixture says %r' % (n, i + 1, a[i] if i < len(a) else None, b[i] if i < len(b) else None))
    check(not bad and len(names) >= 5, '%d fixtures print the graph they say (%d fail)%s' % (len(names), len(bad), '' if not bad else ' -- ' + bad[0]))


def unit():
    if not os.path.isfile(CORPUS):
        print('  SKIP the Softanza unit is not at %s' % CORPUS)
        return None
    t0 = time.time()
    out, err, code = graph(CORPUS)
    if code != 0 or 'graph:' not in err:
        check(False, 'rnxc graph on the unit exited %d: %s' % (code, err.strip()[-120:]))
        return None
    os.makedirs(WORK, exist_ok=True)
    open(os.path.join(WORK, 'stz_base.lines'), 'w', encoding='latin-1', newline='').write(out)
    g = L2(out)
    print('       %s   (%.0f s)' % (err.strip(), time.time() - t0))
    if PLANT:
        victim = next(i for i, c in enumerate(g.calls) if c[2] == 'static')
        c = g.calls[victim]
        g.calls[victim] = (c[0], c[1] + '__planted', c[2], c[3], c[4])
    ok = consistency(g, 'the unit')
    nstat = sum(1 for c in g.calls if c[2] == 'static')
    SUMMARY.append('%d classes, %d methods, %d functions, %d static and %d dynamic edges' % (len(g.classes), len(g.methods), len(g.funcs), nstat, len(g.calls) - nstat))
    check(len(g.classes) >= 500 and len(g.methods) >= 30000 and len(g.funcs) >= 5000 and nstat >= 40000,
          'the floors: %d classes, %d methods, %d functions, %d static edges, %d dynamic' % (len(g.classes), len(g.methods), len(g.funcs), nstat, len(g.calls) - nstat))
    check(len(g.unfinished) <= 3, '%d function(s) unfinished (pinned at most 3): %s' % (len(g.unfinished), ', '.join(sorted(g.unfinished))[:80]))
    out2, _, _ = graph(CORPUS)
    check(out2 == out, 'the unit printed twice is the same text (%d lines)' % out.count('\n'))
    return g, out


# ---------------------------------------------------------------------------------------------------------------------------------------
# the peer
BUILTINS = set()
try:
    BUILTINS = set(re.findall(r'"([a-z0-9_]+)"', open(os.path.join(ROOT, 'src', 'builtins.zig'), encoding='utf-8').read().split('pub const names')[1].split('};')[0]))
except Exception:
    pass
KEYWORDS = {'to', 'in', 'step', 'if', 'but', 'while', 'and', 'or', 'not', 'return', 'put', 'see', 'give', 'case', 'on', 'other', 'switch', 'for', 'again',
            'catch', 'try', 'load', 'new', 'call', 'exit', 'loop', 'from', 'class', 'def', 'func'}
LEX = {}


def lex(path):
    """(text, state per byte: 0 code, 1 comment, 2 string, line starts)"""
    if path in LEX:
        return LEX[path]
    s = open(path, 'rb').read().decode('latin-1')
    kind = bytearray(len(s))
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c in '"\'`':
            j = s.find(c, i + 1)
            j = n - 1 if j < 0 else j
            kind[i:j + 1] = b'\x02' * (j + 1 - i)
            i = j + 1
        elif c == '#' or s.startswith('//', i):
            j = s.find('\n', i)
            j = n if j < 0 else j
            kind[i:j] = b'\x01' * (j - i)
            i = j
        elif s.startswith('/*', i):
            j = s.find('*/', i + 2)
            j = n - 2 if j < 0 else j
            kind[i:j + 2] = b'\x01' * (j + 2 - i)
            i = j + 2
        else:
            i += 1
    starts = [0] + [m.end() for m in re.finditer('\n', s)]
    LEX[path] = (s, kind, starts)
    return LEX[path]


def peer(g):
    if not os.path.isfile(PACKAGE):
        print('  SKIP the Ring++ package is not at %s (python bench/package.py lays it out)' % PACKAGE)
        return
    files = os.path.join(WORK, 'stz_base.files')
    open(files, 'w', encoding='latin-1', newline='').write('\n'.join(g.files) + '\n')
    t0 = time.time()
    if REUSE and os.path.isfile(os.path.join(WORK, 'peer.calls')):
        print('       the last run of the peer is reused')
    else:
        r = subprocess.run([PACKAGE, os.path.join(HERE, 'codegraph_peer.ring'), files, os.path.join(WORK, 'peer')], capture_output=True, timeout=1700)
        tail = r.stdout.decode('latin-1').strip().split('\n')[-2:]
        print('       %s   (%.0f s)' % (' | '.join(tail)[:150], time.time() - t0))

    def rows(ext):
        return [ln.rstrip('\n').split('\t') for ln in open(os.path.join(WORK, 'peer.' + ext), encoding='latin-1')]
    pcalls = {(low(a), low(b), low(c)) for a, b, c, *_ in rows('calls')}
    pm = {(low(a), low(b)) for a, b, *_ in rows('methods')}
    pm_names = {m for _, m in pm}
    pclasses = {low(a) for a, *_ in rows('classes')}

    # the compiler's edges in the peer's shape: (caller class, caller method, callee name), the callee a method name
    mnames = {m for _, m in g.methods} | pm_names
    l2 = {}
    for caller, callee, tier, fan, f in g.calls:
        if '.' not in caller:
            continue
        c, m = low(caller).split('.', 1)
        n = low(callee).split('.', 1)[1] if '.' in callee else low(callee)
        if n in mnames:
            l2.setdefault((c, m, n), tier)
    static_pairs = {(low(a), low(b)) for a, b, t, *_ in g.calls if t == 'static'}
    func_names = set(g.funcs)
    method_line = {k: v for k, v in g.methods.items()}

    decl_by_file = collections.defaultdict(list)
    for c, (nm, parent, line, f) in g.classes.items():
        decl_by_file[f].append(line)
    for (c, m), v in g.methods.items():
        decl_by_file[v[3]].append(v[2])
    for fn, v in g.funcs.items():
        decl_by_file[v[2]].append(v[1])
    for f in decl_by_file:
        decl_by_file[f].sort()

    def body(path, line):
        ls = decl_by_file[path]
        k = bisect.bisect_right(ls, line)
        return line, (ls[k] - 1 if k < len(ls) else 10 ** 9)

    def occurrences(path, name, lo, hi):
        s, kind, starts = lex(path)
        out = []
        for m in re.finditer(r'(?<![A-Za-z0-9_@$])' + re.escape(name) + r'\s*\(', s, re.I):
            ln = bisect.bisect_right(starts, m.start())
            if lo <= ln <= hi:
                out.append((ln, kind[m.start()]))
        return out

    def srcline(path, n):
        s, kind, starts = lex(path)
        return s[starts[n - 1]:starts[n] - 1] if 0 < n < len(starts) else ''

    def why_peer_only(c, m, n):
        if (c, m) not in g.methods:
            return 'the caller is a pairing the compiler does not have: a spurious class took the method'
        if (c + '.' + m) in g.unfinished:
            return 'the compiler could not finish the caller: its edges are missing'
        path, line = method_line[(c, m)][3], method_line[(c, m)][2]
        lo, hi = body(path, line)
        occ = occurrences(path, n, lo + 1, hi)
        if n in KEYWORDS:
            return 'a keyword before a parenthesis'
        if occ and all(st == 1 for _, st in occ):
            return 'a call only inside a comment (the peer strips # comments, not // or /* */)'
        if occ and all(st == 2 for _, st in occ):
            return 'a call only inside a string literal'
        if n in BUILTINS:
            return 'a Ring builtin of that name: no edge, not user code'
        if (c + '.' + m, n) in static_pairs:
            return 'the compiler binds it to a plain function of that name'
        if n in func_names:
            return 'a plain function of that name that the compiler did not edge (a call it compiled to an arity trap)'
        if not occ:
            return 'no call of that name in the method body'
        return 'a call to a name that is no function or builtin of the unit (a native, or undefined: R3 if it runs)'

    def why_l2_only(c, m, n):
        if (c, m) not in pm:
            path, line = method_line[(c, m)][3], method_line[(c, m)][2]
            t = srcline(path, line).strip().lower()
            return 'the caller is a `func`-declared method, which the peer never registers' if t.startswith('func') else 'the caller is a method the peer filed under a spurious class'
        if n not in pm_names:
            return 'the callee is a method the peer never registered (`func`-declared): it cannot resolve it'
        path, line = method_line[(c, m)][3], method_line[(c, m)][2]
        lo, hi = body(path, line)
        occ = occurrences(path, n, lo, hi)
        head = srcline(path, line)
        one_line = bool(re.search(r'\)\s*\S', head.split('(', 1)[1] if '(' in head else ''))
        if one_line and (not occ or any(ln == lo for ln, st in occ if st == 0)):
            return 'a one-line def: the peer never reads a body that shares the def line'
        if not occ:
            return 'no `name(` in the body: an implicit call'
        for ln in sorted({ln for ln, st in occ if st == 0}):
            t = srcline(path, ln)
            if "'" in t and '"' in t:
                return "a quote inside a quote on the line defeats the peer's string stripping"
        for ln in sorted({ln for ln, st in occ if st == 0}):
            for k in range(lo + 1, ln):
                sl, kd, st_ = lex(path)
                text = srcline(path, k)
                at = st_[k - 1] + len(text) - len(text.lstrip())
                if re.match(r'\s*(class|def|func)\s', text, re.I) and at < len(kd) and kd[at] == 1:
                    return 'a line inside a comment that begins with `class`, `def` or `func`: the peer reads it as a declaration and ends the method'
        for ln in sorted({ln for ln, st in occ if st == 0}):
            for k in range(lo + 1, ln + 1):          # the call's own line counts: a line that BEGINS with `func` is never harvested
                if re.match(r'\s*func\s', srcline(path, k), re.I):
                    return 'a line beginning with `func` (a nested function or lambda) at or before the call: the peer stops reading the method'
        return 'unexplained'

    both = pcalls & set(l2)
    po, lo_ = pcalls - set(l2), set(l2) - pcalls
    print('       calls whose callee is a method name -- the peer %d, the compiler %d, both %d (%.1f%% of the peer\'s)' % (len(pcalls), len(l2), len(both), 100.0 * len(both) / max(1, len(pcalls))))
    print('       classes: peer %d, compiler %d, both %d; methods: peer %d, compiler %d, both %d' % (
        len(pclasses), len(g.classes), len(pclasses & set(g.classes)), len(pm), len(g.methods), len(pm & set(g.methods))))
    sp = pclasses - set(g.classes)
    print('       spurious classes the peer reads out of comments: %s' % ', '.join(sorted(sp)))
    unexplained = 0
    for title, edges, fn in (('only the peer finds', po, why_peer_only), ('only the compiler finds', lo_, why_l2_only)):
        why, ex = collections.Counter(), collections.defaultdict(list)
        for e in sorted(edges):
            w = fn(*e)
            why[w] += 1
            if len(ex[w]) < 3:
                ex[w].append('%s.%s -> %s' % e)
        print('     %s: %d' % (title, len(edges)))
        for w, k in why.most_common():
            print('       %5d  %s%s' % (k, w, '   e.g. ' + '; '.join(ex[w][:2]) if w != 'unexplained' or ex[w] else ''))
        unexplained += why.get('unexplained', 0)
        with open(os.path.join(WORK, 'diff_' + title.split()[2] + '.txt'), 'w', encoding='latin-1') as o:
            for e in sorted(edges):
                o.write('%s\t%s\t%s\t%s\n' % (e + (fn(*e),)))
    total = len(po) + len(lo_)
    SUMMARY.append('peer: %d of %d edges agree, %d differences, %d unexplained' % (len(both), len(pcalls), total, unexplained))
    check(len(pcalls) >= 10000 and len(both) * 100 >= 95 * len(pcalls), 'the peer and the compiler agree on at least 95%% of the peer\'s edges (%d of %d)' % (len(both), len(pcalls)))
    check(unexplained * 50 <= total, '%d of the %d differences are unexplained (at most 2 percent)' % (unexplained, total))


# ---------------------------------------------------------------------------------------------------------------------------------------
def ingest(g):
    if not os.path.isfile(PACKAGE):
        print('  SKIP the Ring++ package is not at %s' % PACKAGE)
        return
    # the answer expected from the compiler's own graph for the most-called callee
    callers = collections.defaultdict(set)
    for caller, callee, tier, fan, f in g.calls:
        callers[low(callee)].add(caller)
    target = max(callers, key=lambda k: len(callers[k]))
    # the deepest inheritance chain of the unit, followed by the first parent as AncestryOf does
    def chain(c):
        out, seen = [g.classes[c][0]], {c}
        while True:
            par = g.classes[c][1]
            if not par or par in seen:
                return out
            out.append(g.classes[par][0] if par in g.classes else par)
            if par not in g.classes:
                return out
            seen.add(par)
            c = par
    deepest = max(g.classes, key=lambda c: len(chain(c)))
    t0 = time.time()
    r = subprocess.run([PACKAGE, os.path.join(HERE, 'codegraph_ingest.ring'), os.path.join(WORK, 'stz_base.lines'), os.path.join(WORK, 'ingest.txt'), target, g.classes[deepest][0]], capture_output=True, timeout=1700)
    got = dict(ln.split('\t', 1) for ln in open(os.path.join(WORK, 'ingest.txt'), encoding='latin-1').read().split('\n') if '\t' in ln)
    print('       stzCodeGraph ingested the stream (%.0f s)' % (time.time() - t0))
    raw = collections.Counter(ln.split('|', 1)[0] for ln in open(os.path.join(WORK, 'stz_base.lines'), encoding='latin-1'))
    want = {'classes': raw['CLASS'], 'methods': raw['METHOD'], 'functions': raw['FUNC'], 'calls': raw['CALL'], 'imports': raw['IMPORT'], 'callers': len(callers[target]), 'ancestry': '>'.join(chain(deepest))}
    bad = ['%s: ingested %s, the stream has %s' % (k, got.get(k), v) for k, v in want.items() if str(got.get(k)) != str(v)]
    check(not bad, 'stzCodeGraph ingests the stream unchanged: %s%s' % (', '.join('%s %s' % (k, v) for k, v in want.items()), '' if not bad else ' -- ' + bad[0]))


def main():
    t0 = time.time()
    fixtures()
    res = unit()
    if res and (PEER or INGEST):
        g, out = res
        if PEER:
            peer(g)
        if INGEST:
            ingest(g)
    if PLANT and not fails:
        fails.append('PLANTED defect not caught')
        print('  FAIL the planted corruption was NOT caught')
    print(('GRAPH OK' if not fails else 'GRAPH FAIL') + '   5 fixtures; %s; printed twice the same%s   %d s' % (SUMMARY[0] if SUMMARY else 'the unit not present', ' ' + ' / '.join(SUMMARY[1:]) if len(SUMMARY) > 1 else '', time.time() - t0))
    return 0 if not fails else 1


if __name__ == '__main__':
    sys.exit(main())
