"""C-28's guard: Ring reads files nobody named, and Ring++ refuses the program instead of running it as another one.

    python bench/implicit_files.py

Four shapes, each built afresh under runtime/implicit_files/ and run on the oracle and on rnxc:

    syntax-loaded   a loaded file's folder holds ringsyntax.ring renaming `func` to `proc` (Ring's own SyntaxFiles sample)
    syntax-root     the root's folder holds one
    startup         the root's folder holds startup.ring
    instead         the CURRENT folder holds ring.ring, which Ring runs in place of the program named
    control         none of them: both runtimes print the same line

The ORACLE half shows the file is read on Ring (its output carries the implicit file's effect); the rnxc half must exit 1
with the C-28 refusal naming the file -- and print nothing of the program. Standalone (about 2 s); RNXC= picks the build."""
import os, shutil, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RNXC = os.environ.get('RNXC', os.path.join(ROOT, 'zig-out', 'bin', 'rnxc.exe' if os.name == 'nt' else 'rnxc'))
RING = os.environ.get('RING', os.path.join(ROOT, 'runtime', 'win64', 'ring.exe'))
BASE = os.path.join(ROOT, 'runtime', 'implicit_files')

CASES = {
    'syntax-loaded': ({'main.ring': 'load "sub/lib.ring"\nhello()\n',
                       'sub/ringsyntax.ring': 'ChangeRingKeyword func proc\n',
                       'sub/lib.ring': 'proc hello\n\t? "hello from lib"\n'}, 'main.ring', 'hello from lib'),
    'syntax-root': ({'main.ring': 'proc main\n\t? "renamed keyword ran"\n',
                     'ringsyntax.ring': 'ChangeRingKeyword func proc\n'}, 'main.ring', 'renamed keyword ran'),
    'startup': ({'main.ring': '? "main"\n', 'startup.ring': '? "startup ran first"\n'}, 'main.ring', 'startup ran first'),
    'instead': ({'main.ring': '? "main"\n', 'ring.ring': '? "ring.ring ran instead"\n'}, 'main.ring', 'ring.ring ran instead'),
    'control': ({'main.ring': '? "main"\n'}, 'main.ring', 'main'),
}


def run(exe, cwd, f):
    r = subprocess.run([exe, f], cwd=cwd, capture_output=True, timeout=30)
    return r.returncode, r.stdout.decode('utf-8', 'replace').replace('\r', '')


def main():
    for what, p in (('rnxc', RNXC), ('the oracle', RING)):
        if not os.path.exists(p):
            print('SKIP  implicit files -- %s not found (%s)' % (what, p))
            return 0
    bad = 0
    for name, (files, root, ring_says) in CASES.items():
        d = os.path.join(BASE, name)
        shutil.rmtree(d, ignore_errors=True)
        for rel, text in files.items():
            os.makedirs(os.path.dirname(os.path.join(d, rel)), exist_ok=True)
            open(os.path.join(d, rel), 'w', encoding='utf-8', newline='\n').write(text)
        rc_o, out_o = run(RING, d, root)
        rc_r, out_r = run(RNXC, d, root)
        oracle_ok = ring_says in out_o
        if name == 'control':
            ok = rc_r == 0 and out_r.strip() == out_o.strip() == 'main'
        else:
            ok = rc_r == 1 and 'C-28' in out_r and ring_says not in out_r and 'main' not in out_r.replace('main.ring', '')
        bad += not (ok and oracle_ok)
        print('%-4s %-14s oracle: %-26s rnxc exit %d: %s' % ('ok' if ok and oracle_ok else 'BAD', name,
              (out_o.strip().split('\n') or [''])[0][:26], rc_r, out_r.strip()[:110]))
    print('implicit files: %s' % ('PASS' if not bad else '%d BAD' % bad))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
