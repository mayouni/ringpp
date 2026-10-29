"""RULE A FOR ONE PROGRAM -- a test, a guard, a script -- on top of a library that is already migrated.

    python bench/migrate_file.py <program.ring> [--rnxc <rnxc>] [--dry]

A program's own top level declares its globals bare (`nPass = 0`), and its helpers write them bare (`nPass++` in a `chk()`): on Ring the helper writes the
global, under Ring++'s Rule A it makes a local, and `nPass++` on a local nothing assigned is refused -- which the compiler files under the construct
(`identifier nPass`), so `rnxc migrate` does not report it. This does, for <program.ring> only, what bench/migrate_tree.py does for a library:

  1. the bare-write report     `rnxc shadows <program> --bare`, the rows that stand in this file
  2. the writers               every bare occurrence of each such name in each writing function becomes `$name` (migrate_writers)
  3. the top level             the same names, bare, in this file's top level (before its first definition) become `$name`: the declaration and its reads
  4. migrate_apply             to a fixpoint, --within this file: a function that only READS one of the program's globals
  5. what is left              the refusals the census still places in this file

Nothing outside <program.ring> is written. Names the program takes as a parameter in a writing function are left alone and listed (migrate_writers)."""
import os, re, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PY = sys.executable
sys.path.insert(0, HERE)
import migrate_toplevel as T  # noqa: E402


def arg(name, default=None):
    if name in sys.argv:
        i = sys.argv.index(name)
        return sys.argv[i + 1] if i + 1 < len(sys.argv) else default
    return default


def norm(p):
    return os.path.normcase(os.path.normpath(os.path.abspath(p.replace('/', os.sep).replace(chr(92), os.sep))))


def toplevel(path, names, dry):
    """Step 3: `$` on every bare occurrence of `names` in the program's top level, in code, as whole identifiers."""
    lines = open(path, 'rb').read().split(b'\n')
    sp = T.file_spans(lines)
    low = {n.lower().encode() for n in names}
    done = 0
    for i in range(T.region(lines, sp)):
        L, new, shift = lines[i], lines[i], 0
        for a, b in sp[i][0]:
            for m in T.WORD.finditer(L, a, b):
                if m.group(0).lower() not in low:
                    continue
                before = L[m.start() - 1:m.start()] if m.start() else b' '
                if before in (b'$', b'@', b'.') or not T.is_word_edge(L, m.start(), m.end()) or T.is_symbol(L, m.start()) or L[m.end():m.end() + 1] == b'(':
                    continue
                pos = m.start() + shift
                new = new[:pos] + b'$' + new[pos:]
                shift += 1
                done += 1
        lines[i] = new
    if done and not dry:
        tmp = path + '.migrating'
        with open(tmp, 'wb') as f:
            f.write(b'\n'.join(lines))
        os.replace(tmp, path)
    return done


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if not args:
        raise SystemExit(__doc__)
    prog = os.path.abspath(args[0])
    me = norm(prog)
    rnxc = arg('--rnxc') or os.path.join(ROOT, 'zig-out', 'bin', 'rnxc.exe')
    dry = '--dry' in sys.argv
    # The program's bare top-level globals, taken once, before anything is renamed.
    lines = open(prog, 'rb').read().split(b'\n')
    declared = T.top_level_declared({prog: lines}, {prog: T.file_spans(lines)})
    done = set()
    for rd in range(1, 9):
        r = subprocess.run([rnxc, 'shadows', prog, '--bare'], capture_output=True)
        rows = [l.split('\t') for l in r.stdout.decode('utf-8', 'replace').splitlines() if l.count('\t') >= 2]
        mine = [x for x in rows if norm(x[0]) == me]
        # The report counts assignments; `nPass++` in a helper is a write it does not list, and the compiler files that refusal under the construct
        # (`identifier nPass`), not as Rule A. So the census's own refusals in this file are read too: a refused name the program's top level declared bare
        # is the same site, a write of the program's global from a function. The census names one refusal per statement, so this runs to a fixpoint.
        c = subprocess.run([rnxc, 'census', prog, '--all'], capture_output=True)
        for l in c.stdout.decode('utf-8', 'replace').splitlines():
            m = re.match(r'^\s*(.+?):(\d+)\s+(\S+)\s+.*\s(\S+)\s*$', l)
            if m and norm(m.group(1)) == me and m.group(4).lower().encode() in declared:
                mine.append([m.group(1), m.group(2), m.group(4), m.group(3).rstrip('()'), 'refused'])
        names = sorted({x[2] for x in mine}, key=str.lower)
        print('round %d. 1. bare writes of this program\'s globals in its functions: %d site(s), names: %s' % (rd, len(mine), ', '.join(names) or '-'))
        if not mine or dry or set(n.lower() for n in names) <= done:
            break
        done |= set(n.lower() for n in names)
        fd, rep = tempfile.mkstemp(suffix='.tsv')
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write('\n'.join('\t'.join(x) for x in mine) + '\n')
        w = subprocess.run([PY, '-I', os.path.join(HERE, 'migrate_writers.py'), rep, '--within', prog], capture_output=True, text=True, errors='replace')
        os.remove(rep)
        print('         2. ' + (w.stdout.strip() or w.stderr.strip()).replace('\n', '\n            '))
        print('         3. top level: put %d occurrence(s)' % toplevel(prog, names, dry))
    if not dry:
        a = subprocess.run([PY, '-I', os.path.join(HERE, 'migrate_apply.py'), prog, '--within', prog, '--rnxc', rnxc], capture_output=True, text=True, errors='replace')
        print('4. ' + a.stdout.strip().split('\n')[-1])
    c = subprocess.run([rnxc, 'census', prog, '--all'], capture_output=True)
    left = [l for l in c.stdout.decode('utf-8', 'replace').splitlines() if os.path.basename(prog).lower() in l.lower() and re.search(r':\d+\s', l)]
    print('5. refusals the census still places in this file: %d' % len(left))
    for l in left[:12]:
        print('   ' + l.strip()[:160])
    return 1 if left else 0


if __name__ == '__main__':
    sys.exit(main())
