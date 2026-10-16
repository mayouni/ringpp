# -*- coding: utf-8 -*-
"""`rnxc dump --json` is LOSSLESS: the file comes back from it, byte for byte, and nothing in it has to be guessed.

`rnxc dump` prints the parse one node a line and loses four things (haro/CODEGRAPH.md 4.2): a leaf's text past 40 bytes, a newline
inside a leaf, every position, and the tokens the grammar hides -- the `(` of a parameter list, the `[` of a subscript, the quotes
and parts of a string. Whoever read it recovered those by walking the leaves against the source, which is a heuristic that failed
quietly on the files it did not fit. src/dumpjson.zig is the export it stands in for; this is its guard.

    python bench/dumpjson.py            every check, ~20 s
    python bench/dumpjson.py --plant    a corrupted export, which must FAIL

For each file, in a corpus of the probes, Ring's standard library, the checker's fixtures, Softanza's (a sample, when it is there) and
a set of hard cases written below (empty, comment-only, CRLF, a byte-order mark, Latin-1 and UTF-8 bytes, a NUL, no final newline, an
unclosed string and an unclosed comment, 600 levels of nesting, a 300 KB line):

  1. the export parses as JSON and is ASCII, whatever bytes the file holds
  2. `head` + the root + `tail`, with each node read as its gaps and its children in order, IS the file
  3. every span is inside its parent's, children in order and not overlapping; a leaf's text is the file's bytes at its span; a gap is
     the file's bytes between the spans on either side of it
  4. where the file loads nothing, the shape agrees with `rnxc dump`'s own: the same kinds, in the same order, at the same depths --
     the export and the old dump are two readers of one tree
  5. `error` says the tree holds an ERROR or MISSING node exactly when `rnxc dump` says so

A check that cannot fail is not a check: --plant drops one gap from one export and the reconstruction must notice.
"""
import glob, json, os, re, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RNXC = os.environ.get('RNXC') or os.path.join(ROOT, 'zig-out', 'bin', 'rnxc.exe')
STZ = r'D:\GitHub\stzlib\libraries\stzlib'
PLANT = '--plant' in sys.argv
LINE = re.compile(r"^( *)(\S+)(?:  '.*')?$")
FLOOR_FILES = 150           # the corpus may not shrink to nothing and pass


def hard_cases(d):
    cases = {
        'empty': b'',
        'blank': b'\n\n  \t\n',
        'comment_only': b'# a comment\n',
        'block_comment_only': b'/* a block\n   comment */\n',
        'crlf': b'x = 1\r\nfunc F(a)\r\n\treturn a\r\n',
        'bom': b'\xef\xbb\xbfx = 1\n? x\n',
        'latin1': b'x = "caf\xe9 \xff\x80"\n# \xe9t\xe9\n',
        'utf8': 'x = "caf\u00e9 \u4e2d"\n# \u00e9\n'.encode('utf-8'),
        'nul': b'x = "a\x00b"\n',
        'no_final_newline': b'x = 1\n? x',
        'lead_trail': b'\n\n; x = 1 ; y = 2 ;\n\n\n',
        'unclosed_string': b'x = "never closed\n? x\n',
        'unclosed_comment': b'x = 1\n/* never closed\n? x\n',
        'forms': b'f(a)[1].g(2)\nfunc H(a, b)\n\treturn a[b]\nclass K from B\n\tx = 1\n\tprivate\n\ty = 2\n',
        'deep': ('x = ' + '(' * 600 + '1' + ')' * 600 + '\n').encode(),
        'long_line': ('x = "' + 'ab' * 150000 + '"\n').encode(),
        'chain': ('x = ' + ' + '.join(str(i) for i in range(1500)) + '\n').encode(),
        'error_token': b'x = 1 @@@ 2 )\nfunc\n',
    }
    paths = []
    for name, data in cases.items():
        p = os.path.join(d, name + '.ring')
        open(p, 'wb').write(data)
        paths.append(p)
    return paths


def corpus(d):
    files = sorted(glob.glob(os.path.join(HERE, 'exec', '*.ring')))
    files += sorted(glob.glob(os.path.join(HERE, 'check', '*.ring')))
    files += sorted(glob.glob(os.path.join(ROOT, 'vendor', 'ring-stdlib', '**', '*.ring'), recursive=True))
    files += sorted(glob.glob(os.path.join(ROOT, 'rpp', '**', '*.ring'), recursive=True))
    files += sorted(glob.glob(os.path.join(ROOT, 'examples', '**', '*.ring'), recursive=True))
    files += sorted(glob.glob(os.path.join(ROOT, 'haro', 'spike', '*.ring')))
    if os.path.isdir(STZ):
        stz = sorted(glob.glob(os.path.join(STZ, 'base', '**', '*.ring'), recursive=True))
        files += [p for p in stz[::61] if os.path.getsize(p) <= 150_000]
    return files + hard_cases(d)


def export(path):
    r = subprocess.run([RNXC, 'dump', '--json', path], capture_output=True, timeout=300)
    return r.returncode, r.stdout


def text_dump(path):
    r = subprocess.run([RNXC, 'dump', path], capture_output=True, timeout=300)
    return r.stdout.decode('latin-1'), r.stderr.decode('latin-1')


def kids_of(nodes):
    """Children by parent index, in order; the nodes are flat and in pre-order."""
    kids = [[] for _ in nodes]
    for i, n in enumerate(nodes):
        if 'p' in n:
            kids[n['p']].append(i)
    return kids


def build(nodes, kids, i):
    """The source of node i: its gaps and its children, in order."""
    node = nodes[i]
    if not kids[i]:
        return node.get('t', '')
    g, out = node.get('g', {}), []
    for k, c in enumerate(kids[i]):
        out.append(g.get(str(k), ''))
        out.append(build(nodes, kids, c))
    out.append(g.get(str(len(kids[i])), ''))
    return ''.join(out)


def check_spans(nodes, kids, i, src, lo, hi, bad):
    node = nodes[i]
    s, e = node['s'], node['e']
    if not (lo <= s <= e <= hi):
        bad.append(f"span {s}..{e} outside {lo}..{hi} in {node['k']}")
        return
    ks = kids[i]
    if not ks:
        if node.get('t', '') != src[s:e]:
            bad.append(f"leaf {node['k']} text is not the bytes at {s}..{e}")
        return
    g, prev = node.get('g', {}), s
    for k in range(len(ks) + 1):
        nxt = nodes[ks[k]]['s'] if k < len(ks) else e
        want = src[prev:nxt] if nxt > prev else ''
        if g.get(str(k), '') != want:
            bad.append(f"gap {k} of {node['k']} at {s}..{e} is not the bytes between the spans around it")
            return
        if k < len(ks):
            check_spans(nodes, kids, ks[k], src, prev, e, bad)
            prev = max(prev, nodes[ks[k]]['e'])


def shape(nodes):
    depth, out = [], []
    for n in nodes:
        d = 0 if 'p' not in n else depth[n['p']] + 1
        depth.append(d)
        out.append((d, n['k']))
    return out


def old_shape(text):
    out = []
    for raw in text.split('\n'):
        if not raw.strip():
            continue
        m = LINE.match(raw)
        if not m:
            return None
        out.append((len(m.group(1)) // 2, m.group(2)))
    return out


def has_load(raw):
    return re.search(rb'(?im)^[ \t]*(load|import)\b', raw) is not None


def judge(path, plant=False):
    """-> (a list of failures, [] when the export holds; the node count)."""
    raw = open(path, 'rb').read()
    src = raw.decode('latin-1')
    code, out = export(path)
    if code != 0:
        return ['rnxc dump --json exited %d' % code], 0
    try:
        text = out.decode('ascii')
    except UnicodeDecodeError:
        return ['the export is not ASCII'], 0
    try:
        doc = json.loads(text)
    except ValueError as e:
        return ['the export is not JSON: %s' % e], 0
    nodes = doc['nodes']
    kids = kids_of(nodes)
    if plant:
        i = 0
        while kids[i]:                                         # the deepest first child, and its text spoiled
            i = kids[i][0]
        nodes[i]['t'] = nodes[i]['t'][:-1] if nodes[i].get('t') else 'X'
    bad = []
    if doc.get('format') != 'rnxc-dump/1' or doc.get('bytes') != len(raw):
        bad.append('the header does not describe the file')
    rebuilt = doc['head'] + build(nodes, kids, 0) + doc['tail']
    if rebuilt != src:
        i = next((i for i in range(min(len(rebuilt), len(src))) if rebuilt[i] != src[i]), min(len(rebuilt), len(src)))
        bad.append(f'the file does not come back from its export: first difference at byte {i} (file {len(src)}, rebuilt {len(rebuilt)})')
    check_spans(nodes, kids, 0, src, nodes[0]['s'], nodes[0]['e'], bad)
    if doc['head'] != src[:nodes[0]['s']] or doc['tail'] != src[nodes[0]['e']:]:
        bad.append('head or tail is not the bytes outside the root')
    if not has_load(raw):
        old, err = text_dump(path)
        mine = shape(nodes)
        theirs = old_shape(old)
        if theirs is None:
            bad.append('rnxc dump printed a line this check cannot read')
        elif mine != theirs:
            i = next((i for i in range(min(len(mine), len(theirs))) if mine[i] != theirs[i]), min(len(mine), len(theirs)))
            bad.append(f'the shape differs from rnxc dump at node {i}: export {mine[i:i+1]}, dump {theirs[i:i+1]}')
        if bool(doc['error']) != ('tree contains errors' in err):
            bad.append("`error` disagrees with rnxc dump's own note")
    return bad, len(nodes)


def main():
    t0 = time.time()
    d = tempfile.mkdtemp(prefix='dumpjson_')
    files = corpus(d)
    nodes, failures = 0, []
    for p in files:
        bad, n = judge(p)
        nodes += n
        if bad:
            failures.append((p, bad[0]))
    for p, why in failures[:8]:
        print('  FAIL', os.path.relpath(p, ROOT) if p.startswith(ROOT) else p, '--', why[:200])
    ok = not failures and len(files) >= FLOOR_FILES
    # a check that cannot fail is not a check: one corrupted export must be caught
    victim = os.path.join(HERE, 'exec', 'zip.ring')
    bad, _ = judge(victim, plant=True)
    planted = bool(bad)
    if not planted:
        print('  FAIL the planted corruption was NOT caught')
    ok = ok and planted
    if PLANT:
        ok = False
        print('  FAIL PLANTED')
    print(('EXPORT OK' if ok else 'EXPORT FAIL') + f'   {len(files)} file(s), {nodes} nodes: each comes back byte for byte, every span and gap '
          f'is the file\'s own, and the shape is `rnxc dump`\'s; a corrupted export is caught   {time.time() - t0:.0f} s')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.setrecursionlimit(100000)
    import threading
    threading.stack_size(128 * 1024 * 1024)
    rc = []
    t = threading.Thread(target=lambda: rc.append(main()))
    t.start()
    t.join()
    sys.exit(rc[0] if rc else 1)
