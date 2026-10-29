"""THE APPLIER OF `rnxc migrate`: Rule A, mechanically, to a fixpoint.

    python bench/migrate_apply.py <root.ring> --within <folder> [--verb migrate|shadows] [--bare] [--rnxc <rnxc>] [--rounds N] [--dry]

`rnxc migrate <root>` prints, for every statement the compiler refuses under Rule A, one line `path <TAB> byte offset <TAB> name`: the bare global a function
reads (or a top-level assignment to a name a function reads) that must be spelt `$name`. This inserts the `$` at each offset, in BYTES (Softanza contains
Arabic, and the files are CRLF on Windows), after checking that the bytes there are the name the compiler reported -- a site that does not match is
reported and left alone, never guessed at. The compiler names ONE refusal per statement, so a line holding three globals needs three rounds: the run
repeats until `migrate` reports nothing, or nothing it reports can be applied. 2026-09-01's migration of the branch took 1598 sites, then 187, 75, 29, ...

`--from <tsv> --lines [--skip a,b]` applies a report read from a file whose second column is a LINE number (`rnxc shadows --bare` prints those): the first bare
occurrence of the name on that line gets the `$`, once; one pass, since the file would be stale after it. `--verb shadows` reads `rnxc shadows` instead: the same TSV for the sites whose meaning the first migration changed on Ring (a flag or a constant whose
writing sites kept the bare spelling); `--verb shadows --bare` reads C-2's bare-global write sites. One refusal per statement does not apply there, but
the loop is the same and stops when the report is empty or nothing in it can be applied.

What it does NOT do, by design (4f4f7cad6 and cd2e41df5 name the same limits):
  * a site whose name is not alphanumeric -- `@ = 0` in stzFuncs.ring: the placeholder `@` is a real Softanza identifier, `migrate` reports no name for it
    and the applier has nothing to verify; it is done by hand (`$@ = 0`).
  * `@attribute outside a class` (a `for @i` in a plain function): `migrate` does not select it; the fix is a local, by hand.
  * anything outside <folder>: --within is required, and a path outside it is refused, so a stray reported path can never be written.
The files are written whole or not at all (a temporary beside the file, then a rename). Nothing is committed here."""
import os, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def arg(name, default=None):
    if name in sys.argv:
        i = sys.argv.index(name)
        return sys.argv[i + 1] if i + 1 < len(sys.argv) else default
    return default


def norm(p):
    return os.path.normcase(os.path.abspath(p.replace('/', os.sep).replace(chr(92), os.sep)))


def sites(rnxc, root, verb='migrate', bare=False, src=None):
    if src:
        out, tail = open(src, encoding='utf-8', errors='replace').read(), '(read from ' + os.path.basename(src) + ')'
    else:
        r = subprocess.run([rnxc, verb, root] + (['--bare'] if bare else []), capture_output=True, timeout=3600)
        out, tail = r.stdout.decode('utf-8', 'replace'), r.stderr.decode('utf-8', 'replace').strip().split('\n')[-1]
    got = []
    for line in out.split('\n'):
        line = line.rstrip('\r')
        if not line:
            continue
        parts = line.split('\t')
        if len(parts) < 3:
            continue
        try:
            got.append((parts[0], int(parts[1]), parts[2]))
        except ValueError:
            pass
    return got, tail


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if not args or arg('--within') is None:
        raise SystemExit(__doc__)
    root = args[0]
    within = norm(arg('--within'))
    rnxc = arg('--rnxc') or os.path.join(ROOT, 'zig-out', 'bin', 'rnxc.exe')
    rounds = int(arg('--rounds', '40'))
    dry = '--dry' in sys.argv
    verb, bare = arg('--verb', 'migrate'), '--bare' in sys.argv
    src, lines_mode = arg('--from'), '--lines' in sys.argv
    skip = set(x.lower() for x in (arg('--skip') or '').split(',') if x)
    total, files_touched, unmatched_all = 0, set(), []
    for rd in range(1, rounds + 1):
        t = time.time()
        got, tail = sites(rnxc, root, verb, bare, src)
        by_file = {}
        for p, b, nm in got:
            if nm.lower() in skip:
                continue
            by_file.setdefault(norm(p), set()).add((b, nm))
        applied, unmatched, outside = 0, [], 0
        for p, items in by_file.items():
            if not (p == within or p.startswith(within + os.sep)):
                outside += len(items)
                continue
            data = open(p, 'rb').read()
            edits = []
            if lines_mode:                       # the report's second column is a LINE: start from that line's first byte
                starts = [0] + [i + 1 for i, c in enumerate(data) if c == 10]
                items = {(starts[min(b, len(starts)) - 1], nm) for b, nm in items}
            for b, nm in sorted(items, reverse=True):
                nb = nm.encode('utf-8')
                if data[b:b + len(nb)] == nb and (b == 0 or data[b - 1:b] != b'$'):
                    edits.append(b)
                    continue
                # The offset of a statement the grammar cuts -- `return x = y`, a bare return and the row after -- is the
                # STATEMENT's start, not the name's. Accept the name only if it occurs exactly once on that line after the
                # offset, as a whole word nothing sigils or qualifies (`$x`, `@x`, `.x`, `x1`); else report it and leave it.
                eol = data.find(b'\n', b)
                line_end = len(data) if eol < 0 else eol
                hits, at = [], b
                while True:
                    k = data.find(nb, at, line_end)
                    if k < 0:
                        break
                    before = data[k - 1:k] if k > 0 else b' '
                    after = data[k + len(nb):k + len(nb) + 1]
                    word = lambda c: c.isalnum() or c == b'_' or c >= b'\x80'
                    if not (word(before) or before in (b'$', b'@', b'.')) and not (after and word(after)):
                        hits.append(k)
                    at = k + len(nb)
                if len(hits) == 1 or (hits and lines_mode):   # a line report: the write is the first one; the reads after it are the next round's
                    edits.append(hits[0])
                else:
                    unmatched.append((p, b, nm, data[b:b + len(nb) + 8]))
            if not edits:
                continue
            for b in edits:                       # descending: earlier offsets stay valid
                data = data[:b] + b'$' + data[b:]
            applied += len(edits)
            files_touched.add(p)
            if not dry:
                tmp = p + '.migrating'
                with open(tmp, 'wb') as f:
                    f.write(data)
                os.replace(tmp, p)
        total += applied
        unmatched_all = unmatched
        print('round %2d: migrate reported %4d site(s) in %3d file(s); applied %4d, unmatched %d, outside %d  (%.0f s)  [%s]'
              % (rd, len(got), len(by_file), applied, len(unmatched), outside, time.time() - t, tail))
        if dry or applied == 0 or src:
            break
    print('applied %d insertion(s) in %d file(s)' % (total, len(files_touched)))
    for p, b, nm, seen in unmatched_all[:20]:
        print('  UNMATCHED %s @%d wanted %r saw %r' % (p, b, nm, seen))
    return 0


if __name__ == '__main__':
    sys.exit(main())
