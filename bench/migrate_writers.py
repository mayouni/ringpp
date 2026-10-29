"""THE FOURTH PART OF Rule A: a function that writes a global must say `$name` EVERYWHERE it names it.

    python bench/migrate_writers.py <report.tsv> --within <folder> [--skip a,b] [--dry]

<report.tsv> is `rnxc shadows <root> --bare`, taken BEFORE bench/migrate_toplevel.py renames the top-level declarations (afterwards a bare name is no longer a
bare top-level global, and the report no longer lists its writers -- they have become plain locals, which is the bug): path, LINE, name, function, verdict.
For every function that holds such a write, every bare occurrence of that name in the function -- the write, the reads that follow it, the `x = x + 1` -- becomes
`$name`, outside strings and comments, never before `(` and never after `.`, `$` or `@`. Half a function is the failure this prevents: `$_oldVar = _var` reads a
`_var` nothing assigns any more, and since a name assigned nowhere is a run-time R24 and not a refusal, the census does not see it.

A name the function also takes as a PARAMETER is a local and is left alone, reported. The names given to --skip are left out (a name with no `$name` anywhere in the
library was a plain local all along). Occurrences inside a string are counted and NOT changed: an eval string that names the variable is a hand decision.
Files are read and written as bytes, line endings kept; --within is required. Nothing is committed here."""
import os, re, sys, collections
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from migrate_toplevel import file_spans, is_word_edge, is_symbol, WORD  # noqa: E402

DEF = re.compile(rb'^[ \t]*(func|def|class|package)[ \t]+([A-Za-z_@][A-Za-z0-9_]*)(.*)$', re.I)


def norm(p):
    return os.path.normcase(os.path.normpath(os.path.abspath(p.replace('/', os.sep).replace(chr(92), os.sep))))


def arg(name, default=None):
    if name in sys.argv:
        i = sys.argv.index(name)
        return sys.argv[i + 1] if i + 1 < len(sys.argv) else default
    return default


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if not args or arg('--within') is None:
        raise SystemExit(__doc__)
    within = norm(arg('--within'))
    skip = set(x.lower() for x in (arg('--skip') or '').split(',') if x)
    dry = '--dry' in sys.argv
    want = collections.defaultdict(set)              # path -> {(line, name)}
    for l in open(args[0], encoding='utf-8', errors='replace'):
        p = l.rstrip('\r\n').split('\t')
        if len(p) < 3 or p[2].lower() in skip:
            continue
        try:
            want[norm(p[0])].add((int(p[1]), p[2]))
        except ValueError:
            pass
    total, strings, params, outside = 0, [], [], 0
    touched = set()
    for path, sites in want.items():
        if not (path == within or path.startswith(within + os.sep)):
            outside += len(sites)
            continue
        lines = open(path, 'rb').read().split(b'\n')
        spans = file_spans(lines)
        isdef = lambda k: not spans[k][1] and DEF.match(lines[k])   # a `func` that begins inside a string or a comment is text
        todo = collections.defaultdict(set)         # (start, end) -> {names}
        for ln, nm in sites:
            i = min(ln, len(lines)) - 1
            while i >= 0 and not isdef(i):
                i -= 1
            if i < 0 or DEF.match(lines[i]).group(1).lower() == b'class':
                params.append((path, ln, nm, 'not inside a function'))
                continue
            j = i + 1
            while j < len(lines) and not isdef(j):
                j += 1
            todo[(i, j)].add(nm)
        for (a, b), names in todo.items():
            head = lines[a].lower()
            for nm in sorted(names):
                low = nm.lower().encode()
                if re.search(rb'[(,][ \t]*' + re.escape(low) + rb'[ \t]*[,)]', head):
                    params.append((path, a + 1, nm, 'is a parameter'))
                    continue
                for k in range(a, b):
                    L = lines[k]
                    new, shift = L, 0
                    for s, e in spans[k][0]:
                        for m in WORD.finditer(L, s, e):
                            if m.group(0).lower() != low:
                                continue
                            before = L[m.start() - 1:m.start()] if m.start() > 0 else b' '
                            if before in (b'$', b'@', b'.') or not is_word_edge(L, m.start(), m.end()) or is_symbol(L, m.start()) or L[m.end():m.end() + 1] == b'(':
                                continue
                            pos = m.start() + shift
                            new = new[:pos] + b'$' + new[pos:]
                            shift += 1
                            total += 1
                            touched.add(path)
                    lines[k] = new
                    # a mention inside a string or a comment is counted, not changed
                    for m in re.finditer(rb'(?<![\w$@.])' + re.escape(low) + rb'(?![\w(])', L.lower()):
                        if not any(s <= m.start() < e for s, e in spans[k][0]) and not L.strip().startswith((b'#', b'//')):
                            strings.append((path, k + 1, nm, L.strip()[:80]))
        if path in touched and not dry:
            tmp = path + '.migrating'
            with open(tmp, 'wb') as f:
                f.write(b'\n'.join(lines))
            os.replace(tmp, path)
    print('%s %d bare occurrence(s) in %d file(s); outside --within: %d site(s)' % ('would put' if dry else 'put', total, len(touched), outside))
    for p, ln, nm, why in params[:20]:
        print('  LEFT   %s:%d %s %s' % (os.path.relpath(p, within), ln, nm, why))
    for p, ln, nm, t in strings[:20]:
        print('  STRING %s:%d %s | %s' % (os.path.relpath(p, within), ln, nm, t))
    return 0


if __name__ == '__main__':
    sys.exit(main())
