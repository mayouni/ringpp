"""AUDIT OF A RULE A MIGRATION: every byte it changed, by kind and by context.

    python bench/migrate_audit.py --tree <worktree of stzlib> [--rev HEAD] [--list N]

For each library file the worktree changes against <rev> (default HEAD), the old and the new lines are paired and aligned byte by byte. Every difference must be one of

    insert $         a `$` put in front of a name                          (migrate_apply, migrate_toplevel, migrate_writers)
    rename @x -> _x_ a plain function's `@x` made the local `_x_`         (migrate_locals)

and each is classified by where it stands in the OLD file, by Ring's scanner rules with the state carried over newlines: CODE, or TEXT (inside quotes, a
multi-line string included, or a comment). A `$` inserted into text is an edit of prose, not of code: the first run of the migration put three into prose (a
logo in a multi-line string, a symbol `:Maori` with a non-ASCII letter) that no census could see, and this is what finds the next. Anything that is neither of
the two kinds above is listed as OTHER -- the hand fixes of migrate_tree.HAND_FIXES, and nothing else should be there.

And per function, by name: a function the migration leaves spelling one name both bare (a use, a loop variable, a parameter) and `$name` is MIXED -- a local
read as a global or a half-migrated writer -- unless the original already did (Softanza's box-drawing data names a function `X` and returns `$X`).

The exit status is 1 when a `$` went into text, in front of a `:symbol`, or in front of part of a name, or a function was left MIXED. A @x -> _x_ rename in text is listed and does not fail (an eval string may name the variable; that is a
decision), and neither do the OTHER hunks, which are for a person to read. Nothing is written."""
import difflib, os, re, subprocess, sys, collections
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import migrate_toplevel as T  # noqa: E402


def arg(name, default=None):
    if name in sys.argv:
        i = sys.argv.index(name)
        return sys.argv[i + 1] if i + 1 < len(sys.argv) else default
    return default


def git(tree, *a):
    r = subprocess.run(['git', '-C', tree] + list(a), capture_output=True)
    if r.returncode != 0:
        raise SystemExit('git %s failed: %s' % (' '.join(a), r.stderr.decode('utf-8', 'replace')[:300]))
    return r.stdout


def context(spans, off, line=None, kind='rename @x'):
    """CODE when the old offset stands in a code span of its line (the byte an inserted `$` goes in front of, or the `@` of a rename); TEXT when it stands in a
    string or a comment, which includes every line that begins inside a multi-line string or a block comment.

    A `$` is also wrong in code when what follows it is not a variable: SYMBOL when the name is `:name` (a string, never a variable), FRAGMENT when the name
    goes on past where the tool saw it to end -- `:Maori` with a non-ASCII letter was read as the word `M`, and `$M` was put in front of it. Position alone calls
    both CODE: the first version of this audit let the planted `:$Maori` through."""
    if not any(a <= off < b for a, b in spans[0]):
        return 'TEXT'
    if kind == 'insert $' and line is not None:
        if re.match(rb'@(?![A-Za-z0-9_$])', line[off:off + 2]):
            return 'CODE'          # the placeholder `@ = 0` of stzFuncs.ring, a real identifier (migrate_tree.HAND_FIXES): a lone @, no name after it
        m = T.WORD.match(line, off)
        if m is None or not T.is_word_edge(line, off, m.end()):
            return 'FRAGMENT'
        if T.is_symbol(line, off):
            return 'SYMBOL'
    return 'CODE'


DEFLINE = re.compile(rb'^[ \t]*(func|def)[ \t]+([A-Za-z_@][A-Za-z0-9_]*)', re.I)
NAMES = re.compile(rb'[A-Za-z_][A-Za-z0-9_$]*')


def mixed_pairs(lines):
    """{(function, name)} for every function that spells one name both bare and `$name` in code. A whole migration never makes one: a global is `$x`
    everywhere in a function and a local `x` everywhere. The first run of the driver made three -- `for n = 1 to ...` indexing with `$n` -- and no per-byte
    rule sees that, because each `$` sits in front of a whole identifier in code."""
    sp = T.file_spans(lines)
    out, fn, bare, dollar = set(), None, set(), set()

    def close():
        out.update((fn, nm) for nm in bare & dollar)

    for k, L in enumerate(lines):
        m = DEFLINE.match(L) if not sp[k][1] else None
        if m:
            if fn is not None:
                close()
            fn, bare, dollar = m.group(2).lower(), set(), set()
            ps = re.search(rb'\(([^)]*)\)', L[m.end():])  # a parameter is a bare local: a `$name` read beside it is the same mixture
            if ps:
                bare.update(w.lower() for w in NAMES.findall(ps.group(1)))
            continue                                   # the function's own name is not a use
        if fn is None:
            continue
        for a, b in sp[k][0]:
            for w in NAMES.finditer(L, a, b):
                before = L[w.start() - 1:w.start()] if w.start() else b' '
                if before in (b'.', b'@') or T.is_symbol(L, w.start()):
                    continue
                if before == b'$':
                    dollar.add(w.group(0).lower())
                elif T.is_word_edge(L, w.start(), w.end()) and L[w.end():w.end() + 1] != b'(':
                    bare.add(w.group(0).lower())
    if fn is not None:
        close()
    return out


def align(old, new):
    """[(kind, old offset, text)] when new is old plus inserted `$` and renamed `@x`; None when it is something else."""
    edits, i, j = [], 0, 0
    while i < len(old) and j < len(new):
        if old[i] == new[j]:
            i += 1
            j += 1
        elif new[j:j + 1] == b'$':
            edits.append(('insert $', i, b''))
            j += 1
        elif old[i:i + 1] == b'@':
            m = re.match(rb'@([A-Za-z0-9_]+)', old[i:])
            if not m or new[j:j + len(m.group(1)) + 2] != b'_' + m.group(1) + b'_':
                return None
            edits.append(('rename @x', i, m.group(0)))
            i += len(m.group(0))
            j += len(m.group(1)) + 2
        else:
            return None
    if i != len(old):
        return None
    if any(c != 0x24 for c in new[j:]):
        return None
    edits.extend(('insert $', len(old), b'') for _ in new[j:])
    return edits


def main():
    tree = arg('--tree')
    if not tree:
        raise SystemExit(__doc__)
    rev = arg('--rev', 'HEAD')
    limit = int(arg('--list', '12'))
    names = [n.decode('utf-8', 'replace') for n in git(tree, 'diff', '--name-only', '-z', rev, '--', 'libraries/stzlib').split(b'\0') if n]
    count = collections.Counter()
    bad, listed, other, mixed = [], [], [], []
    for rel in names:
        if not rel.endswith('.ring'):
            continue
        p = os.path.join(tree, rel.replace('/', os.sep))
        if not os.path.exists(p):
            continue
        # the blob and the working file may differ in line endings alone (core.autocrlf): compare without the CR of a CRLF line
        old = [L[:-1] if L.endswith(b'\r') else L for L in git(tree, 'show', '%s:%s' % (rev, rel)).split(b'\n')]
        new = [L[:-1] if L.endswith(b'\r') else L for L in open(p, 'rb').read().split(b'\n')]
        spans = T.file_spans(old)
        for fn, nm in sorted(mixed_pairs(new) - mixed_pairs(old)):
            mixed.append((rel, fn.decode('latin-1'), nm.decode('latin-1')))
        sm = difflib.SequenceMatcher(None, old, new, autojunk=False)
        for tag, i1, i2, j1, j2 in sm.get_opcodes():
            if tag == 'equal':
                continue
            if tag != 'replace' or (i2 - i1) != (j2 - j1):
                other.append((rel, i1 + 1, i2 - i1, j2 - j1))
                continue
            for k in range(i2 - i1):
                o, n = old[i1 + k], new[j1 + k]
                ed = align(o, n)
                if ed is None:
                    other.append((rel, i1 + k + 1, 1, 1))
                    continue
                for kind, off, txt in ed:
                    ctx = context(spans[i1 + k], off, o, kind)
                    count[(kind, ctx)] += 1
                    if ctx != 'CODE':
                        item = (rel, i1 + k + 1, '%s (%s)' % (kind, ctx), o.strip()[:90].decode('utf-8', 'replace'))
                        (bad if kind == 'insert $' else listed).append(item)
    print('files changed against %s: %d' % (rev, len(names)))
    for (kind, ctx), n in sorted(count.items()):
        print('  %-10s in %-7s %6d' % (kind, ctx, n))
    print('  OTHER hunks (not an insert or a rename): %d' % len(other))
    for rel, ln, a, b in other[:limit + 8]:
        print('     %s:%d  (%d line(s) became %d)' % (rel, ln, a, b))
    for rel, ln, kind, t in listed[:limit]:
        print('  LISTED  %s:%d %s outside code | %s' % (rel, ln, kind, t.encode('ascii', 'backslashreplace').decode()))
    for rel, ln, kind, t in bad[:limit]:
        print('  BAD     %s:%d %s | %s' % (rel, ln, kind, t.encode('ascii', 'backslashreplace').decode()))
    print('  functions the migration left spelling one name both bare and with $: %d' % len(mixed))
    for rel, fn, nm in mixed[:limit]:
        print('  MIXED   %s  %s()  %s and $%s' % (rel, fn, nm, nm))
    return 1 if bad or mixed else 0


if __name__ == '__main__':
    sys.exit(main())
