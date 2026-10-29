"""WHAT THE CENSUS CANNOT SEE AFTER A RULE A MIGRATION: a `$name` that nothing assigns.

    python bench/migrate_check.py <folder of the library> [--known a,b,c]

A function that reads `$name` where no file assigns `$name` is not refused by the compiler -- a name assigned nowhere is a run-time R24, only if the line runs -- so
`rnxc census` reads 0 refused over a tree in which a declaration and its readers disagree. That is exactly how four of Softanza's globals (`_$aRegexPatterns_` and
three more, whose names hold a `$`) came out of the first run of the migration: the reads were spelt `$_$a...`, the declarations were left bare because the
tokenizer stopped at the inner `$`, and the census said 0.

For every name that occurs as `$name` in the library, this looks for a use that writes it (an assignment, a compound assignment, `++`, an index assignment, a loop
variable, or an argument of add / del / insert / remove / sort / reverse / list2str, or an append statement `$x + item`). A name with no such use is listed, with
the number of reads and the files. A name passed to a function by name is counted apart (a list is by reference: the callee may fill it).

An empty list is the result; names given to --known are the ones already judged (a documented defect of the library, not of the migration) and are printed apart.
The exit status is 1 when a name is listed that --known does not name. Nothing is written."""
import os, re, sys, collections
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import migrate_toplevel as T  # noqa: E402

TOK = re.compile(rb'\$([A-Za-z_][A-Za-z0-9_@$]*)')
WRITE = re.compile(rb'^(?:\s*(\[[^\]\n]*\]\s*)*)(?:=(?!=)|\+=|-=|\*=|/=|\+\+|--)')
WRITERS = (b'for', b'add(', b'del(', b'insert(', b'remove(', b'sort(', b'reverse(', b'list2str(')


def scan(lib):
    uses, writes, where = collections.Counter(), collections.Counter(), collections.defaultdict(set)
    for p in T.library_files(lib):
        lines = open(p, 'rb').read().split(b'\n')
        for L, (sp, _) in zip(lines, T.file_spans(lines)):
            for a, b in sp:
                for m in TOK.finditer(L, a, b):
                    nm = m.group(1).lower().decode('latin-1')
                    uses[nm] += 1
                    where[nm].add(os.path.basename(p))
                    rest = L[m.end():b]
                    pre = L[:m.start()].rstrip().lower()
                    is_write = bool(WRITE.match(rest)) or pre.endswith(WRITERS) or pre.endswith(b'+')
                    if not is_write and pre == b'' and re.match(rb'\s*\+', rest):
                        is_write = True              # an append statement: `$x + item`
                    if not is_write and pre.endswith((b'(', b',')):
                        writes[nm + ':passed'] += 1
                    if is_write:
                        writes[nm] += 1
    return uses, writes, where


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if not args:
        raise SystemExit(__doc__)
    known = set()
    if '--known' in sys.argv:
        known = set(x.lower() for x in sys.argv[sys.argv.index('--known') + 1].split(',') if x)
    uses, writes, where = scan(args[0])
    na = sorted(n for n in uses if writes[n] == 0)
    print('names used as $name: %d    with no write-looking use: %d' % (len(uses), len(na)))
    new = 0
    for n in na:
        tag = 'known' if n in known else 'NEW  '
        new += n not in known
        print('  %s %-34s %4d use(s)  passed-as-arg %-3s  %s' % (tag, n, uses[n], writes[n + ':passed'] or '', sorted(where[n])[:3]))
    return 1 if new else 0


if __name__ == '__main__':
    sys.exit(main())
