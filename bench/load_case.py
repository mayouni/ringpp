"""LOADS THAT NAME A FILE IN ANOTHER CASE -- harmless on Windows, E9 on a real Linux disk (ext4 is case-sensitive).

    python bench/load_case.py <libraries/stzlib folder> [--tests] [--fix]

Every `load "..."` in code (not in a string or a comment) of the library's files -- and with --tests the test folders too -- resolved
as Ring resolves a relative load (against the loading file's folder), and compared, component by component, with the names on disk.
A load that exists only in another case is reported with the spelling on disk; --fix rewrites the literal to that spelling (bytes, line
endings kept). A load that exists in no case at all is reported apart and never touched (C-25 refuses it on every platform). Found
2026-10-09 on the branch and fixed there (a88293bb7, bcb1dc903); stzlib main never took it, and on 2026-10-29 the Linux package of main
stopped at load on two of them."""
import os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import migrate_toplevel as T  # noqa: E402

LOAD = re.compile(rb'^(?:\xef\xbb\xbf)?[ \t]*load[ \t]+"([^"]+)"', re.I)     # a BOM may open line 1 (stzExterCode.ring)


def exact(base, rel):
    """The on-disk spelling of base/rel, or None when some component exists in no case; '' components are skipped."""
    cur = base
    parts = [p for p in rel.replace('\\', '/').split('/') if p not in ('', '.')]
    out = []
    for p in parts:
        if p == '..':
            cur = os.path.dirname(cur)
            out.append('..')
            continue
        try:
            names = os.listdir(cur)
        except OSError:
            return None
        hit = next((n for n in names if n == p), None) or next((n for n in names if n.lower() == p.lower()), None)
        if hit is None:
            return None
        out.append(hit)
        cur = os.path.join(cur, hit)
    return '/'.join(out)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if not args:
        raise SystemExit(__doc__)
    lib = args[0]
    files = T.library_files(lib)
    if '--tests' in sys.argv:
        for sub in ('base/test', 'max/test', 'core/test'):
            for dp, dn, fns in os.walk(os.path.join(lib, sub.replace('/', os.sep))):
                files += [os.path.join(dp, f) for f in fns if f.endswith('.ring')]
    wrong, missing, fixed_files = [], [], 0
    for p in sorted(set(files)):
        data = open(p, 'rb').read()
        lines = data.split(b'\n')
        spans = T.file_spans(lines)
        changed = False
        for i, L in enumerate(lines):
            m = LOAD.match(L)
            kw = L.lower().find(b'load', m.start()) if m else -1     # the KEYWORD must be code; the path itself is a string
            if not m or spans[i][1] or not any(a <= kw < b for a, b in spans[i][0]):
                continue
            target = m.group(1).decode('utf-8', 'replace')
            if target.startswith('/') or os.path.isabs(target):
                continue                                   # Ring's load-folder form or an absolute path: not a relative file
            on_disk = exact(os.path.dirname(p), target)
            if on_disk is None:
                if not os.path.exists(os.path.join(os.path.dirname(p), target)):
                    missing.append((p, i + 1, target))
                continue
            norm = '/'.join(x for x in target.replace('\\', '/').split('/') if x not in ('', '.'))
            if on_disk != norm:
                wrong.append((p, i + 1, target, on_disk))
                if '--fix' in sys.argv:
                    new = on_disk if '/' in target or '\\' not in target else on_disk.replace('/', '\\')
                    lines[i] = L[:m.start(1)] + new.encode('utf-8') + L[m.end(1):]
                    changed = True
        if changed:
            tmp = p + '.loadcase'
            with open(tmp, 'wb') as f:
                f.write(b'\n'.join(lines))
            os.replace(tmp, p)
            fixed_files += 1
    print('files %d; loads in another case: %d%s; loads of a file that exists in no case: %d'
          % (len(set(files)), len(wrong), (' (fixed in %d files)' % fixed_files) if '--fix' in sys.argv else '', len(missing)))
    for p, ln, t, d in wrong[:60]:
        print('  CASE     %s:%d  "%s" -> "%s"' % (os.path.relpath(p, lib), ln, t, d))
    for p, ln, t in missing[:10]:
        print('  MISSING  %s:%d  "%s"' % (os.path.relpath(p, lib), ln, t))
    return 1 if wrong and '--fix' not in sys.argv else 0


if __name__ == '__main__':
    sys.exit(main())
