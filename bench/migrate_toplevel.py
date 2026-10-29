"""THE THIRD PART OF Rule A: the top level of a library file declares what the functions read as `$name`.

    python bench/migrate_toplevel.py --within <folder> [--dry]

`x = 5` at the top level of a file and `$x` in a function are TWO variables (measured on Ring 1.27, the oracle and Ring++: the function reads `$x` and gets
R24). `rnxc migrate` puts the `$` on the sites a function refuses; on the 2026-09-01 compiler it listed the top-level declarations too, and the current one does
not -- a top-level bare assignment is legal, nothing reads it bare any more, and so the declaration stays bare and every `$name` read finds nothing. This is the
step that finds them: a name that is ASSIGNED at the top level of some library file (before its first func / def / class / package, Ring's own rule for what
runs at load) and that occurs as `$name` somewhere in the library gets its `$` on every bare occurrence in the top-level regions -- the assignment and any
top-level read -- outside strings and comments, never before `(` (a call) and never after `.`, `$` or `@`.

The library is every .ring file under --within except the folders that are not part of it (test, doc, docs, temp, future, archive, education, wings, ...);
gallery scripts and exercises declare their own `v` and `n`. Files are read and written as bytes, line endings kept. Nothing is committed here.
Check the result with `rnxc census` (0 refused), `rnxc shadows --bare`, and a program that exercises the globals: the R24 it prevents is raised at run time."""
import os, re, sys, collections
SKIP = {'test', 'tests', 'doc', 'docs', 'temp', 'future', 'archive', '_archive', 'education', 'wings', 'models', 'tools', 'cli',
        'node_modules', 'zig-out', '.zig-cache', 'src', 'vendor', 'data_files', 'fonts'}
DEF = re.compile(rb'^[ \t]*(func|def|class|package)[ \t]', re.I)
# A Ring identifier may hold a `$` after its first character: Softanza's `_$aRegexPatterns_` and `_$aMATCH_TYPES` are four such top-level names, and a
# tokenizer that stops at the `$` reads them as `_` and a `$name`, never finds their declaration, and leaves every `$_$a...` read with nothing assigned.
ASSIGN = re.compile(rb'^[ \t]*([A-Za-z_][A-Za-z0-9_$]*)[ \t]*(?:\[[^\]\n]*\][ \t]*)*(?:=|\+=|-=|\*=|/=)(?!=)')
WORD = re.compile(rb'[A-Za-z_][A-Za-z0-9_$]*')
KEYWORDS = set('if for while return but else ok next end load see put give exit loop try catch done do again switch on other off import new bye elseif in to step '
               'and or not func def class package private from changeringkeyword'.split())


def library_files(within):
    out = []
    for dp, dn, fns in os.walk(within):
        dn[:] = [d for d in dn if d.lower() not in SKIP]
        for f in fns:
            if f.endswith('.ring'):
                out.append(os.path.join(dp, f))
    return out


QUOTES = (b'"', b"'", b'`')


def file_spans(lines):
    """For every line of a file, (spans, opened): its code spans -- the stretches outside quotes and comments -- and whether the line BEGINS inside a string or a
    comment. Ring's scanner (scanner.c) carries that state over newlines: a string runs to the next quote of its own kind, with no escapes, and a /* */ comment
    runs to its end, so the body of a multi-line string (Softanza's logo in stzFuncs.ring is one, 14 lines of art and a name) is not code on any of its lines."""
    q, out = None, []
    for line in lines:
        n, spans, i, start = len(line), [], 0, 0
        opened = q is not None
        if q == b'/*':
            end = line.find(b'*/')
            if end < 0:
                out.append(([], opened))
                continue
            q = None
            i = start = end + 2
        tail = True
        while i < n:
            c = line[i:i + 1]
            if q is None:
                if c in QUOTES:
                    spans.append((start, i))
                    q = c
                elif c == b'#' or line[i:i + 2] == b'//':
                    spans.append((start, i))
                    tail = False
                    break
                elif line[i:i + 2] == b'/*':
                    spans.append((start, i))
                    end = line.find(b'*/', i + 2)
                    if end < 0:
                        q = b'/*'
                        tail = False
                        break
                    i = end + 1
                    start = end + 2
            elif c == q:
                q = None
                start = i + 1
            i += 1
        if tail and q is None:
            spans.append((start, n))
        out.append(([(a, b) for a, b in spans if b > a], opened))
    return out


def region(lines, spans=None):
    """Index of the first definition that runs at load's end: the lines before it run when the file is loaded. A `func` that begins inside a string or a block
    comment is text, not a definition."""
    spans = spans or file_spans(lines)
    for i, L in enumerate(lines):
        if not spans[i][1] and DEF.match(L):
            return i
    return len(lines)


def is_word_edge(L, m_start, m_end):
    """True when the word found at [m_start, m_end) is a whole identifier: nothing that continues a name stands on either side -- and a non-ASCII byte does
    (Softanza spells `Māori` and Arabic names; WORD stops at the first such byte and would otherwise hand back a fragment)."""
    before = L[m_start - 1:m_start] if m_start > 0 else b' '
    after = L[m_end:m_end + 1]
    if before.isalnum() or before == b'_' or before >= b'\x80':
        return False
    if after and (after.isalnum() or after == b'_' or after >= b'\x80'):
        return False
    return True


def is_symbol(L, m_start):
    """`:name` is a symbol, a string, never a variable -- unless the colon is Ring's range operator (`1:n`, `)` or `]` before it)."""
    if m_start < 1 or L[m_start - 1:m_start] != b':':
        return False
    prev = L[m_start - 2:m_start - 1] if m_start > 1 else b' '
    return not (prev.isalnum() or prev in (b'_', b')', b']') or prev >= b'\x80')


def code_spans(line):
    """(start, end) of the stretches of a line that are code: outside quotes and comments."""
    spans, q, i, start = [], None, 0, 0
    n = len(line)
    while i < n:
        c = line[i:i + 1]
        if q is None:
            if c in (b'"', b"'", b'`'):
                spans.append((start, i))
                q = c
            elif c == b'#' or line[i:i + 2] == b'//':
                spans.append((start, i))
                return spans
            elif line[i:i + 2] == b'/*':
                end = line.find(b'*/', i + 2)
                spans.append((start, i))
                if end < 0:
                    return spans
                i = end + 1
                start = end + 2
        elif c == q:
            q = None
            start = i + 1
        i += 1
    if q is None:
        spans.append((start, n))
    return spans


def top_level_declared(split, spans):
    """The names (lower case) a top-level line of some library file assigns BARE, before the file's first definition: the globals a bare use in a function could
    have meant on Ring. A name that is only ever `$name` (stzBpmnDiagram's `$n`, written inside a function) is not one of them."""
    declared = set()
    for p, lines in split.items():
        for i, L in enumerate(lines[:region(lines, spans[p])]):
            if spans[p][i][1] or L.strip().startswith((b'#', b'//')):
                continue                                  # begins inside a string or a comment, or is one
            m = ASSIGN.match(L)
            if m and m.group(1).decode('latin-1').lower() not in KEYWORDS:
                declared.add(m.group(1).lower())
    return declared


def library_split(within):
    split = {p: open(p, 'rb').read().split(b'\n') for p in library_files(within)}
    return split, {p: file_spans(l) for p, l in split.items()}


def main():
    if '--within' not in sys.argv:
        raise SystemExit(__doc__)
    within = sys.argv[sys.argv.index('--within') + 1]
    dry = '--dry' in sys.argv
    files = library_files(within)
    data = {p: open(p, 'rb').read() for p in files}
    split = {p: d.split(b'\n') for p, d in data.items()}
    spans = {p: file_spans(l) for p, l in split.items()}
    declared = top_level_declared(split, spans)
    # the twin is looked for in CODE only: a `$m` inside a comment ("$argon2id$v=19$m=19456") is not a global `m`
    code_text = b'\n'.join(L[a:b] for p, lines in split.items() for L, (sp, _) in zip(lines, spans[p]) for a, b in sp).lower()
    names = {n for n in declared if re.search(rb'(?<![\w$])\$' + re.escape(n) + rb'(?![\w$])', code_text)}
    print('library files: %d; top-level names assigned: %d; with a $ twin: %d' % (len(files), len(declared), len(names)))
    total, per_file = 0, collections.Counter()
    for p, d in data.items():
        lines = split[p]
        end = region(lines, spans[p])
        changed = 0
        for i in range(end):
            L = lines[i]
            new, shift = L, 0
            for a, b in spans[p][i][0]:
                for m in WORD.finditer(L, a, b):
                    w = m.group(0)
                    if w.lower() not in names:
                        continue
                    before = L[m.start() - 1:m.start()] if m.start() > 0 else b' '
                    if before in (b'$', b'@', b'.') or not is_word_edge(L, m.start(), m.end()) or is_symbol(L, m.start()):
                        continue
                    if L[m.end():m.end() + 1] == b'(':
                        continue
                    pos = m.start() + shift
                    new = new[:pos] + b'$' + new[pos:]
                    shift += 1
                    changed += 1
            lines[i] = new
        if changed:
            per_file[p] = changed
            total += changed
            if not dry:
                tmp = p + '.migrating'
                with open(tmp, 'wb') as f:
                    f.write(b'\n'.join(lines))
                os.replace(tmp, p)
    print('%s %d occurrence(s) in %d file(s)' % ('would put' if dry else 'put', total, len(per_file)))
    for p, n in per_file.most_common(8):
        print('  %4d  %s' % (n, os.path.relpath(p, within)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
