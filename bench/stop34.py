r"""Where does each of the 34 STOP on Ring++, and what stood in the way?

    python bench/stop34.py              all of them
    python bench/stop34.py perf         only tests whose name matches

The clock (bench/clock34.py) answers "how many match". This answers the
next question, and it is a different one: of those that do not, which stop
EARLY, at which line, and on what. That list is the work queue, so it is
measured here rather than remembered -- the last hand-written breakdown
went stale the same day two of its entries were fixed.

It runs the oracle ONCE, not twice. The noise floor exists to decide
whether a line DIFFERS; nothing here asks that. It asks how far each
runtime got and what Ring++ said when it gave up, and a measurement line
that wobbles does not change either answer.

The causes are read out of Ring++'s own error text, never guessed:

    R3  Calling Function without definition: <name>
            -- either a Ring builtin the VM lacks, or a Softanza function
               whose own definition was refused, which surfaces as R3 at
               the CALL SITE rather than where the trouble is. `rnxc
               poison` tells those two apart; this reports the name so the
               question can be asked.
    R21 Using operator with values of incorrect type
    R2  Calling Function with wrong number of parameters
    R12 Error in property name
    REFUSED  the compiler refused a construct and said so

A test that produces MORE lines than the oracle is reported too, because
that is not stopping early and should not be counted as if it were.
"""
import os, re, sys, collections

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import clock34 as C  # the tree paths, THE_34, run(), lines(), make_copy()

ERR = re.compile(rb'Error \(([A-Z]?\d+)\)\s*:\s*(.*)')
LINE_NO = re.compile(rb'^Line (\d+)\b')
# Ring++'s OWN refusal wording, anchored. The first version of this matched
# any line containing "refus", and three tests assert on the word -- `[OK] an
# action outside the closed catalog refuses` is the test PASSING. It reported
# them as refusals of the compiler. An instrument that reads a program's
# output has to match the runtime's voice, not the program's.
REFUSAL = re.compile(rb'Ring\+\+ refused this statement')


def classify(out_lines):
    """The cause Ring++ reported, as (code, detail, at_line).

    Read ONLY the runtime's own report line -- `Line <n> <message>`, which
    is where dieRing prints -- and only the FIRST one. Scanning every line
    for a keyword read the tests' own assertion text instead: three of them
    print the word `refuses` when they PASS, and an earlier version of this
    reported those as refusals of the compiler.
    """
    for l in out_lines:
        n = LINE_NO.match(l)
        if not n:
            continue
        at = int(n.group(1))
        rest = l[n.end():].strip()
        m = ERR.search(rest)
        if m:
            return m.group(1).decode(), m.group(2).decode('utf-8', 'replace').strip(), at
        if REFUSAL.search(rest):
            return 'REFUSED', rest.decode('utf-8', 'replace').strip(), at
        # a raise() from the estate's own code -- Ring++ got somewhere Ring
        # did not, which is a difference worth seeing, not an error code
        return 'RAISED', rest.decode('utf-8', 'replace').strip(), at
    for l in out_lines:
        if b'TOP LEVEL DID NOT COMPILE' in l:
            # nothing ran at all: the file's own top level carries a refused
            # statement, so exec declines it before the first line of output
            return 'NO-TOP', 'the file\'s own top level was refused', None
    return None, None, None


def main():
    only = [a for a in sys.argv[1:] if not a.startswith('-')]
    if not os.path.isdir(C.LIB):
        print('SKIP stop34: no Softanza tree at ' + C.LIB)
        return 0
    if not os.path.isdir(C.ENGINE_DLLS):
        print('SKIP stop34: no Ring++ engine DLLs -- run `python bench/engine_copy.py`')
        return 0
    if '--copy' in sys.argv or not os.path.isdir(C.LP + C.COPY):
        C.make_copy()

    names = [t for t in C.THE_34 if not only or any(o in t for o in only)]
    sub = os.path.join(*C.TESTS.split('/'))
    rows = []
    for rel in names:
        mod, fn = rel.split('/')
        ao, ae = C.run([C.RING, fn], os.path.join(C.LIB, sub, mod))
        A = C.lines(ao + ae)
        co, ce = C.run([C.RNXC, fn], os.path.join(C.COPY, sub, mod))
        Cl = C.lines(co, drop_warnings=True)
        code, detail, at = classify(Cl)
        rows.append((rel, len(A), len(Cl), code, detail, at))
        state = 'ok' if len(Cl) >= len(A) and code is None else (code or 'short')
        print('%-46s ring %3d  rnx %3d  %s' % (rel, len(A), len(Cl), state), flush=True)

    print()
    early = [r for r in rows if r[2] < r[1]]
    longer = [r for r in rows if r[2] > r[1]]
    print('STOPS EARLY: %d of %d' % (len(early), len(rows)))
    print()
    by = collections.OrderedDict()
    for rel, na, nc, code, detail, at in sorted(early, key=lambda r: r[1] - r[2], reverse=True):
        key = code or 'no error reported -- ended quietly'
        by.setdefault(key, []).append((rel, na, nc, detail, at))
    for key, items in sorted(by.items(), key=lambda kv: -len(kv[1])):
        print('  %-8s %d test(s)' % (key, len(items)))
        for rel, na, nc, detail, at in items:
            where = (' at line %d' % at) if at else ''
            print('        %-44s %3d of %3d lines%s' % (rel, nc, na, where))
            if detail:
                print('            %s' % detail[:78])
        print()
    if longer:
        print('LONGER THAN RING (not stopping early): %d' % len(longer))
        for rel, na, nc, code, detail, at in longer:
            print('        %-44s %3d against %3d' % (rel, nc, na))
    return 0


if __name__ == '__main__':
    sys.exit(main())
