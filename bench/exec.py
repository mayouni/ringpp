# -*- coding: utf-8 -*-
"""Whole programs, end to end, against the oracle.

`ab.py` calls FUNCTIONS and compares their results; it cannot see the top
level of a program, a class cut in two by the grammar, a newline that Ring
reads as a statement boundary, or an attribute resolved by name at run
time. Each file under bench/exec/ is a complete program: it is run on the
oracle and through `rnxc exec`, and the two outputs must be byte-identical
line for line (line endings aside -- the oracle prints CRLF, rnx LF).

    python bench/exec.py            every probe
    python bench/exec.py top        only those whose name contains it

A probe that raises on the oracle is compared on the RAISE too: Ring's
error text is part of the contract (R12's wording, R24's), and an rnx that
answers where Ring refuses is a difference, not a pass.
"""
import io, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RING = os.environ.get('RING') or os.path.join(ROOT, 'runtime', 'win64', 'ring.exe')
RNXC = os.environ.get('RNXC') or os.path.join(ROOT, 'zig-out', 'bin', 'rnxc.exe')
PROBES = os.path.join(HERE, 'exec')


def run(cmd, cwd):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, timeout=120)
    return r.stdout, r.stderr


def lines(b):
    # BLANK LINES ARE OUTPUT (2026-10-11). This dropped them, and so could not
    # see that `? aList` on Ring ends with a blank line Ring++ left out --
    # 108 rows of the wide suite differed in nothing else (F-106). Only the
    # line ending and the trailing newlines are not compared.
    out = [l.rstrip(b'\r') for l in b.split(b'\n')]
    while out and not out[-1]:
        out.pop()
    return out


def main():
    only = sys.argv[1:]
    names = sorted(f for f in os.listdir(PROBES) if f.endswith('.ring'))
    if only:
        names = [n for n in names if any(o in n for o in only)]
    bad = 0
    for n in names:
        want_out, want_err = run([RING, n], PROBES)
        want = lines(want_out + want_err)
        # A program's output is on STDOUT, as Ring's is, since 2026-09-12;
        # rnxc's own status lines are the ones on stderr now. They were the
        # other way round, which no terminal shows you and every caller that
        # captures output trips over.
        got_out, _ = run([RNXC, n], PROBES)
        got = lines(got_out)
        # A Ring error names its file, and since 2026-09-11 so does rnx --
        # the root as typed, a loaded file as Ring spells it -- so the
        # `in file` line is compared like every other line.
        #
        # It used to be STRIPPED here, from rnx's side only, which is not
        # comparing it: a probe whose last line is exactly `in file x`
        # then failed because the oracle kept the line and rnx lost it.
        # Only a TOP-LEVEL error prints that line bare -- inside a
        # function Ring writes `In function f() in file x` -- so no probe
        # had reached the case until uninit_read (2026-09-12).
        if want == got:
            print('OK   %-28s %d line(s)' % (n, len(want)))
        else:
            bad += 1
            print('DIFF %-28s' % n)
            for i in range(max(len(want), len(got))):
                w = want[i] if i < len(want) else b'<none>'
                g = got[i] if i < len(got) else b'<none>'
                if w != g:
                    print('        oracle: ' + w.decode('utf-8', 'replace')[:90])
                    print('        rnx   : ' + g.decode('utf-8', 'replace')[:90])
                    break
    print()
    print('%s   %d differing of %d' % ('EXEC PROBES AGREE WITH RING' if bad == 0 else 'EXEC PROBES FAIL', bad, len(names)))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
