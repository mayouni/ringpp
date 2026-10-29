"""THE SECOND HALF OF Rule A: `@name` inside a plain function is a local, spelt `_name_`.

    python bench/migrate_locals.py <root.ring> --within <folder> [--rnxc <rnxc>] [--rounds N] [--dry]

On Ring a loop variable written `for @i = 1 to n` in a PLAIN FUNCTION is simply a variable; under Rule A `@` means an attribute of the running object, so
the compiler refuses it ("@attribute outside a class") and `rnxc migrate` -- which selects Rule A bare-global sites -- does not list it. The fix is a local, in
Softanza's own style `_i_`: the census names the function and the first such name in each statement, and every `@name` of that name inside that function (its
code and its comments) becomes `_name_`. The compiler reports ONE name per statement, so a function with `@i` and `@j` takes two rounds: the run repeats until the
census reports no such record, or nothing it reports can be applied.

Refused, never guessed: a name that would collide with one the function already uses (`_i_` twice would merge two variables); a function the file does not
hold under that name; a name followed by `(` (a call to a function Softanza spells with an @: `@IsNumberInString(...)`). What the census files under another
kind -- `@ = 0`, a bare `del(_aVars, ..)`, a name inside an eval string (FirstNPrimesW's condition) -- is a hand fix, and is not touched here.
Files are read and written as bytes with their own line endings; --within is required and a path outside it is refused. Nothing is committed here."""
import os, re, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
REC = re.compile(r'\s+(\S.*?\.ring):(\d+)\s+(\S.*?)\s{2}(.*?)\s{2}(.*)$')
BOUNDARY = re.compile(rb'^[ \t]*(func|def|class)[ \t]', re.I)


def arg(name, default=None):
    if name in sys.argv:
        i = sys.argv.index(name)
        return sys.argv[i + 1] if i + 1 < len(sys.argv) else default
    return default


def norm(p):
    return os.path.normcase(os.path.normpath(os.path.abspath(p.replace('/', os.sep).replace(chr(92), os.sep))))


def records(rnxc, root):
    r = subprocess.run([rnxc, 'census', root, '--all'], capture_output=True, timeout=3600)
    got = {}
    for line in r.stdout.decode('utf-8', 'replace').split('\n'):
        m = REC.match(line.rstrip('\r'))
        if m and 'outside a class' in m.group(4):
            name = m.group(5).strip().split()[0] if m.group(5).strip() else ''
            if name.startswith('@') and len(name) > 1:
                got.setdefault((norm(m.group(1)), m.group(3).rstrip('()')), set()).add(name)
    return got


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if not args or arg('--within') is None:
        raise SystemExit(__doc__)
    root, within = args[0], norm(arg('--within'))
    rnxc = arg('--rnxc') or os.path.join(ROOT, 'zig-out', 'bin', 'rnxc.exe')
    rounds, dry = int(arg('--rounds', '12')), '--dry' in sys.argv
    renamed = 0
    for rd in range(1, rounds + 1):
        t = time.time()
        recs = records(rnxc, root)
        done, refused = 0, []
        for (path, fn), names in recs.items():
            if not (path == within or path.startswith(within + os.sep)):
                refused.append((path, fn, 'outside --within'))
                continue
            data = open(path, 'rb').read()
            lines = data.split(b'\n')
            head = re.compile(rb'^[ \t]*(func|def)[ \t]+' + re.escape(fn.encode()) + rb'\b', re.I)
            start = next((i for i, L in enumerate(lines) if head.match(L)), None)
            if start is None:
                refused.append((path, fn, 'function not found'))
                continue
            end = next((j for j in range(start + 1, len(lines)) if BOUNDARY.match(lines[j])), len(lines))
            body = b'\n'.join(lines[start:end])
            for nm in sorted(names):
                new = '_' + nm[1:] + '_'
                if re.search(rb'(?<![\w$@])' + re.escape(new.encode()) + rb'(?!\w)', body, re.I):
                    refused.append((path, fn, '%s -> %s collides with a name the function uses' % (nm, new)))
                    continue
                pat = re.compile(rb'(?<![\w$@])' + re.escape(nm.encode()) + rb'(?![\w(])', re.I)
                body, n = pat.subn(new.encode(), body)
                done += n
            lines[start:end] = body.split(b'\n')
            if not dry:
                tmp = path + '.migrating'
                with open(tmp, 'wb') as f:
                    f.write(b'\n'.join(lines))
                os.replace(tmp, path)
        renamed += done
        print('round %2d: %2d function(s) reported; %3d name(s) renamed; refused %d  (%.0f s)' % (rd, len(recs), done, len(refused), time.time() - t))
        for p, fn, why in refused:
            print('   REFUSED %s %s: %s' % (p, fn, why))
        if dry or done == 0:
            break
    print('renamed %d occurrence(s)' % renamed)
    return 0


if __name__ == '__main__':
    sys.exit(main())
