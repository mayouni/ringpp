# -*- coding: utf-8 -*-
r"""The checker's gate: `rnxc check` against tests/fixtures.

Commitment #4 says the compiler refusing statically IS the checker. For a
week that was half true -- src/check.zig, why.zig and types.zig sat in the
tree unbuilt, and tests/run-all.ps1 printed `SKIP checker` on every run.
They are folded into rnxc now, and this is what keeps them honest.

THE EXPECTATION IS RECORDED, NOT DERIVED, for most rules -- and that is worth
saying: every other gate in this project compares against the ORACLE,
because Ring can answer the same question. Ring has no checker, so for a
rule about style or cost there is nothing to compare against: these are
golden values, read out of the fixtures by hand once. A golden gate catches
a regression; it cannot catch a rule that was wrong from the start.

FOUR RULES ARE THE EXCEPTION, and since 2026-09-22 they are held to the
oracle as well. rpp/undefined-function, rpp/uninitialized-variable,
rpp/unknown-class and rpp/unknown-package each make a RUNTIME claim --
"Error (R3/R24/R11/R25) the moment this line runs" -- and a runtime claim
is one Ring can check. So each fixture in ORACLE_CONFIRMS is also run on the
oracle, and the line Ring stops on must be a line the checker reported. A
rule that drifted into a false positive would now disagree with Ring, not
merely with a number someone wrote down.

Line and rule only, never the message text: a diagnostic's wording should
be free to improve without a gate failing.

    python bench/check.py            all of it
    python bench/check.py lint       only fixtures matching
"""
import os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RNXC = os.path.join(ROOT, 'zig-out', 'bin', 'rnxc.exe')
RING = os.environ.get('RING') or os.path.join(ROOT, 'runtime', 'win64', 'ring.exe')
FIX = os.path.join(ROOT, 'tests', 'fixtures')

# fixture -> the findings it must produce, as "row:col rule"
EXPECT = {
    'anchors.ring': [
        '18:2 rpp/cache-impure', '23:2 rpp/cache-impure', '28:13 rpp/cache-impure',
        '31:1 rpp/anchor-unknown', '51:2 rpp/cache-reads-object'],
    'char_truncates.ring': [
        '10:9 rpp/char-truncates', '14:9 rpp/char-truncates', '17:9 rpp/char-truncates'],
    'default_dyn.ring': ['11:4 rpp/type-arity'],
    'defaults_check.ring': [
        '11:1 rpp/default-unknown-param', '16:1 rpp/default-not-trailing',
        '20:1 rpp/default-missing-value'],
    'lint_bad.ring': [
        '24:23 rpp/varptr-unknown-name', '37:9 rpp/empty-catch', '45:21 rpp/substr-in-loop',
        '54:18 rpp/len-in-loop-header', '68:39 rpp/substr-in-loop',
        '76:9 rpp/exit-outside-loop', '80:23 rpp/exit-bad-depth'],
    'named_bad_missing.ring': ['9:4 rpp/type-arity'],
    # The R24 at 15:11 was ALWAYS there -- the fixture's own comment on line 14
    # predicts it ("R24 at run time, but only when this line is reached").
    # It went unrecorded because the rule was silent when this was written,
    # and it lit up the day the universe was wired. Ring confirms it.
    'string_escape.ring': [
        '11:10 rpp/string-escape', '15:11 rpp/string-escape',
        '15:11 rpp/uninitialized-variable'],
    'types_bad.ring': [
        '12:7 rpp/type-arg-mismatch', '12:12 rpp/type-arg-mismatch', '13:3 rpp/type-arity',
        '14:3 rpp/type-arity', '15:9 rpp/type-arg-mismatch', '17:1 rpp/type-hints-missing',
        '23:1 rpp/type-not-a-hint'],
    # THE DEFINITION UNIVERSE, wired 2026-09-22 (src/universe.zig). Silent for
    # fourteen days before that, because `rnxc check` handed every file an
    # empty context. Each value below was checked against the oracle when it
    # was recorded -- nine findings, nine confirmed, the ones the oracle could
    # not reach (it stops at the first error) by a probe that made each the
    # first line to run.
    'undefined_fn.ring': ['11:1 rpp/undefined-function'],
    'unknown_class.ring': [
        '5:10 rpp/unknown-class', '9:10 rpp/unknown-class', '20:19 rpp/unknown-class'],
    'unknown_package.ring': ['6:8 rpp/unknown-package'],
    'uninit_var.ring': ['13:7 rpp/uninitialized-variable'],
    'uninit_method.ring': ['27:16 rpp/uninitialized-variable'],
    # correctly silent: working code the rules must not shout at
    'alias.ring': [],
    'cache_fib.ring': [],
    'cache_method.ring': [],
    'str_fold.ring': [],
    'types_good.ring': [],
}

# Fixtures whose FIRST runtime error the oracle can observe. For each, the
# line Ring stops on must be a line the checker reported -- see the header.
ORACLE_CONFIRMS = [
    'string_escape.ring', 'undefined_fn.ring', 'unknown_class.ring',
    'unknown_package.ring', 'uninit_var.ring', 'uninit_method.ring',
]

# Fixtures that must produce NOTHING, and why.
#
# These two were listed with the universe fixtures, as if they were waiting
# on it. They were not. Their rules lived in the library-era TRANSFORM, which
# rewrote `#rpp: named` calls into positional ones and checked them as it
# went -- types.zig says so in as many words ("the call sites are checked at
# transform time"). The transform went with the library half (52ed663), and
# the universe could never have woken them.
#
# Whether they should come back is not a checker question. `#rpp: named`
# makes `:name = value` bind BY NAME, and F-59 (2026-09-20) made Ring++
# compile that same spelling exactly as Ring does -- as the two-element list
# ["name", value]. The two cannot both hold for one call. Whether Ring++
# offers named arguments at all is a language decision, and it is Mansour's.
#
# Counted rather than passed: if either lights up, this gate says so.
NOT_CHECKED = {
    'named_bad_order.ring':
        'a positional argument after a named one -- its rule was in the deleted transform',
    'named_bad_unknown.ring':
        'a named argument that is not a parameter -- its rule was in the deleted transform',
}

FIND = re.compile(r'^  (\d+:\d+)\s+\S+\s+(rpp/\S+)')
RING_ERR = re.compile(r'^Line (\d+) Error \((R\d+)\)')
ABSENCE = {'rpp/undefined-function', 'rpp/uninitialized-variable',
           'rpp/unknown-class', 'rpp/unknown-package'}


def findings(path):
    r = subprocess.run([RNXC, 'check', os.path.basename(path)], cwd=FIX,
                       capture_output=True, text=True, timeout=120)
    out = []
    for line in (r.stdout + r.stderr).split('\n'):
        m = FIND.match(line.rstrip('\r'))
        if m:
            out.append('%s %s' % (m.group(1), m.group(2)))
    return out


def oracle_first_error(name):
    """(row, code) of the first error Ring raises running the fixture."""
    r = subprocess.run([RING, name], cwd=FIX, capture_output=True, timeout=60)
    for line in (r.stdout + r.stderr).decode('utf-8', 'replace').split('\n'):
        m = RING_ERR.match(line.strip())
        if m:
            return int(m.group(1)), m.group(2)
    return None


def main():
    only = sys.argv[1:]
    bad = 0
    checked = 0
    for name in sorted(EXPECT):
        if only and not any(o in name for o in only):
            continue
        want = EXPECT[name]
        got = findings(os.path.join(FIX, name))
        checked += 1
        if got == want:
            print('OK   %-24s %d finding(s)' % (name, len(got)))
            continue
        bad += 1
        print('DIFF %s' % name)
        for w in want:
            if w not in got:
                print('       missing: %s' % w)
        for g in got:
            if g not in want:
                print('       unexpected: %s' % g)

    confirmed = 0
    if os.path.exists(RING):
        for name in ORACLE_CONFIRMS:
            if only and not any(o in name for o in only):
                continue
            first = oracle_first_error(name)
            if first is None:
                print('ORACLE %-22s raised NOTHING -- the fixture no longer '
                      'reaches the line it pins' % name)
                bad += 1
                continue
            row, code = first
            hit = [f for f in findings(os.path.join(FIX, name))
                   if f.split(':')[0] == str(row) and f.split()[1] in ABSENCE]
            if hit:
                confirmed += 1
                print('RING  %-24s stops at line %d with %s -- the checker '
                      'said so' % (name, row, code))
            else:
                bad += 1
                print('RING  %-24s stops at line %d with %s and the checker '
                      'did NOT report that line' % (name, row, code))
    else:
        # Named, never quietly skipped: the gate without the oracle is only
        # the golden half of itself.
        print('SKIP  oracle confirmation -- no oracle at %s' % RING)

    silent = 0
    for name in sorted(NOT_CHECKED):
        if only and not any(o in name for o in only):
            continue
        got = findings(os.path.join(FIX, name))
        if got:
            print('LIT   %-24s now reports %d finding(s) -- decide what it '
                  'checks, then add it to EXPECT' % (name, len(got)))
            bad += 1
        else:
            silent += 1
    print()
    if bad:
        print('CHECKER GATE FAILED -- %d fixture(s) differ' % bad)
    else:
        print('CHECKER OK   %d fixture(s), %d rule(s) fired, %d confirmed by '
              'the oracle' % (checked, sum(len(v) for v in EXPECT.values()),
                              confirmed))
    if silent:
        print('  %d fixture(s) silent, checked by nothing yet:' % silent)
        for name in sorted(NOT_CHECKED):
            print('     %-24s %s' % (name, NOT_CHECKED[name]))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
