"""`rnxc check --closed`, `--subst` and `--natives`: the question the rung-5 refinement gate asks of a unit (Haro D32), held apart from Ring's.

    python bench/check_closed.py            RNXC=<path> picks the compiler (default zig-out/bin/rnxc.exe)

A default `rnxc check` makes Ring's claim -- Error (Rn) the moment this line runs -- and so stays silent where it cannot prove one: a unit in which
nothing runs (a library), and a unit holding eval, loadlib or an admission. A CLOSED check asks instead whether the unit DEFINES every name it uses:
it speaks in both places, and says so in its words; it resolves a call's arity through the whole unit (one definition per name, C22); `--subst`
checks the unit with one file's text replaced without touching the file; `--natives` names what native libraries register. A file that could not
be read is still a hole. Each case below runs a small unit written to a temporary folder, in both modes where the difference is the point."""
import os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RNXC = os.environ.get('RNXC') or os.path.join(ROOT, 'zig-out', 'bin', 'rnxc.exe')

LIB = 'class Box\n\tfunc Grow(n)\n\t\treturn Helper(n) + Nope(n)\n'
ROOT_EVAL = 'load "lib.ring"\n? new Box { }\neval("x = 1")\nloadlib("stz_engine.dll")\n\nfunc Helper(n)\n\treturn n\n'


def check(d, root, *flags):
    r = subprocess.run([RNXC, 'check', root] + list(flags), cwd=d, capture_output=True)
    out = (r.stdout + r.stderr).decode('utf-8', 'replace').replace('\r', '')
    finds = []
    lines = out.split('\n')
    for i, l in enumerate(lines):
        p = l.split()
        if len(p) == 3 and ':' in p[0] and p[1] in ('error', 'warn'):
            finds.append((p[2], lines[i + 1].strip() if i + 1 < len(lines) else ''))
    return finds, out


def names(finds, rule):
    return sorted(m.split('(')[0].split()[0] for r, m in finds if r == rule)


def unit(files):
    d = tempfile.mkdtemp(prefix='rnxc-closed-')
    for n, t in files.items():
        open(os.path.join(d, n), 'wb').write(t.encode('latin-1'))
    return d


fails, n = [], 0


def case(name, ok, detail=''):
    global n
    n += 1
    if not ok:
        fails.append('%s: %s' % (name, detail))


# 1. a library alone: Ring's question has no answer, the closed one does
d = unit({'lib.ring': LIB})
f, out = check(d, 'lib.ring')
case('library alone, default', not f and 'NOT checked -- nothing in this unit runs' in out, out[-300:])
f, out = check(d, 'lib.ring', '--closed')
case('library alone, closed', names(f, 'rpp/undefined-function') == ['Helper', 'Nope'] and 'checked CLOSED' in out, f)
case('closed wording', all('checked closed' in m and 'Error (R3)' not in m for r, m in f) and 'absence is proof' not in out, f)

# 2. eval and loadlib in the loading program
d = unit({'lib.ring': LIB, 'root.ring': ROOT_EVAL})
f, out = check(d, 'root.ring')
case('eval + loadlib, default', not f and 'NOT checked -- the unit calls loadlib() or eval()' in out, out[-300:])
f, out = check(d, 'root.ring', '--closed')
case('eval + loadlib, closed', names(f, 'rpp/undefined-function') == ['Nope'], f)

# 3. one file's text replaced, the file on disk untouched
open(os.path.join(d, 'lib_new.ring'), 'wb').write(LIB.replace('Nope', 'Other').encode('latin-1'))
f, out = check(d, 'root.ring', '--closed', '--subst=lib.ring=lib_new.ring')
case('--subst', names(f, 'rpp/undefined-function') == ['Other'], f)
case('--subst leaves the file', open(os.path.join(d, 'lib.ring'), 'rb').read().decode('latin-1') == LIB)

# 4. the natives a library registers
open(os.path.join(d, 'natives.txt'), 'wb').write(b'nope\nsomethingelse\n')
f, out = check(d, 'root.ring', '--closed', '--natives=natives.txt')
case('--natives', not names(f, 'rpp/undefined-function') and '2 native name(s) given' in out, f)

# 5. arity through the whole unit: a call into the loading program, and a name two files define
d = unit({'lib.ring': 'class Box\n\tfunc Grow(n)\n\t\treturn Helper(n, 2)\n\nfunc Both(n)\n\treturn Helper(n, 2) + Dup(1, 2, 3)\n',
          'two.ring': 'func Dup(n)\n\treturn n\n',
          'root.ring': 'load "lib.ring"\nload "two.ring"\n? Helper(1)\n\nfunc Helper(n)\n\treturn n\n\nfunc Dup(a, b)\n\treturn a\n'})
f, out = check(d, 'root.ring')
case('arity, default (the calling file\'s own loads only)', not names(f, 'rpp/type-arity'), f)
f, out = check(d, 'root.ring', '--closed')
ar = [m for r, m in f if r == 'rpp/type-arity']
case('arity, closed', len(ar) == 2 and all(m.startswith('Helper() takes 1') and 'root.ring' in m for m in ar), ar)
case('arity, a name two files define says nothing', not any(m.startswith('Dup()') for m in ar), ar)

# 6. a hole is still a hole
d = unit({'lib.ring': LIB, 'root.ring': 'load "lib.ring"\nload "missing.ring"\n? 1\n\nfunc Helper(n)\n\treturn n\n'})
f, out = check(d, 'root.ring', '--closed')
case('a missing load shuts a closed check', not f and 'NOT checked -- a loaded file could not be read' in out, out[-300:])

for x in fails:
    print('  FAIL ' + x)
print('check --closed: %d of %d cases%s' % (n - len(fails), n, '' if not fails else ' -- FAILED'))
sys.exit(1 if fails else 0)
