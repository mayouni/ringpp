"""RULE A FOR A LIBRARY THAT ARRIVES ONE FILE AT A TIME: RingServ's fourteen ringlib files, copied and migrated.

    python bench/resident_migrate.py <ringlib folder> <out folder> [--dry]

RingServ's host runs its library into one Ring state file by file (src/bridge.zig, rs_init), and its globals are declared bare at the top of the file that owns
them (`aRsContracts = []`) and read bare in that file's functions -- and in other files' (config.ring reads serv.ring's `aRsServDecl`). On Ring a bare name in a
function that is also a top-level name IS that global; under Ring++'s Rule A it is a local, and the read is refused. `rnxc resident` refuses nine of the
fourteen files for it (bench/resident.py).

This writes a COPY: every name a top-level line of any of the files assigns bare (before the file's first definition) becomes `$name` at every bare occurrence
in all of the files -- the declarations, the reads, the writes -- in code only, never before `(`, never after `.`, `$` or `@`, never a `:symbol`. Renaming every
occurrence of a global keeps a program's meaning on Ring too, where `$name` is simply another name; a function whose PARAMETER carries one of the names would
not, so the script refuses to write if it finds one. RingServ's folder is read, never written (CLAUDE.md: RingServ is a test bed)."""
import os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import migrate_toplevel as T  # noqa: E402

# rs_init's order (src/bridge.zig, ringlib_files)
FILES = ['json_c.ring', 'serv.ring', 'data.ring', 'generic.ring', 'contract.ring', 'topology.ring', 'sync.ring', 'jsserv.ring', 'actor.ring',
         'journal.ring', 'gesture.ring', 'family.ring', 'config.ring', 'testing.ring']
PARAMS = re.compile(rb'^[ \t]*(?:func|def)[ \t]+[A-Za-z_][A-Za-z0-9_$]*[ \t]*\(?([^)\n#]*)', re.I)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    src, out = sys.argv[1], sys.argv[2]
    dry = '--dry' in sys.argv
    split = {f: open(os.path.join(src, f), 'rb').read().split(b'\n') for f in FILES}
    spans = {f: T.file_spans(l) for f, l in split.items()}
    names = T.top_level_declared(split, spans)
    print(f'{len(names)} top-level global(s): ' + ', '.join(sorted(n.decode() for n in names)))

    # a parameter with a global's name would be renamed with it, and on Ring the parameter shadows the global
    clash = []
    for f, lines in split.items():
        for i, L in enumerate(lines):
            m = PARAMS.match(L)
            if m and not spans[f][i][1]:
                for p in re.split(rb'[ \t,]+', m.group(1).strip()):
                    if p.lower() in names:
                        clash.append(f'{f}:{i + 1} parameter {p.decode()}')
    if clash:
        print('NOT written -- a parameter carries a global\'s name:\n  ' + '\n  '.join(clash))
        return 1

    total = 0
    if not dry:
        os.makedirs(out, exist_ok=True)
    for f, lines in split.items():
        done = 0
        for i, L in enumerate(lines):
            new, shift = L, 0
            for a, b in spans[f][i][0]:
                for m in T.WORD.finditer(L, a, b):
                    if m.group(0).lower() not in names:
                        continue
                    before = L[m.start() - 1:m.start()] if m.start() else b' '
                    if before in (b'$', b'@', b'.') or not T.is_word_edge(L, m.start(), m.end()) or T.is_symbol(L, m.start()):
                        continue
                    if L[m.end():m.end() + 1] == b'(':
                        continue
                    pos = m.start() + shift
                    new = new[:pos] + b'$' + new[pos:]
                    shift += 1
                    done += 1
            lines[i] = new
        total += done
        print(f'  {f:16} {done:4d} site(s)')
        if not dry:
            with open(os.path.join(out, f), 'wb') as fh:
                fh.write(b'\n'.join(lines))
    print(f'{total} site(s) in {len(FILES)} file(s)' + (' (dry run, nothing written)' if dry else f', written to {out}'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
