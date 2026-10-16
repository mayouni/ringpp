# -*- coding: utf-8 -*-
r"""ASSERTION PARITY over the wide clock -- what the estate's own tests say.

    python bench/parity432.py        from the cache; runs nothing, ~2 s
    python bench/parity432.py --suite=wide     the wide suite's table

`why432.py` asks whether a test's output agrees with Ring's LINE FOR LINE,
and that is the strict question: a test that prints `Executed in 0.01`
where Ring prints 0.03 differs, although nothing in it failed. The question
a migration asks is different -- do the assertions Ring passes pass here?
The narrated harness prints `[PASS]`/`[FAIL]` per assertion, and both
transcripts are cached (oracle run 1, rnx stdout), so this counts them.

Then, for every test where Ring++ passes FEWER, it names what Ring++ said
when it stopped -- its own error line, digits blanked -- and ranks those
causes by ASSERTIONS LOST, not by tests: one missing builtin that stops a
200-assertion test outweighs a wrong line in five small ones. First
reading, 2026-09-23: 4,254 of Ring's 6,078 passes (70%), 172 of 250
assertion-bearing tests at parity, and the gap in a few classes.

It reads what the last `why432.py` pass kept, so it is as fresh as that.
A test whose ORACLE timed out measures nothing and is counted apart.
"""
import collections, json, os, re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CACHE = os.path.join(ROOT, 'runtime', 'oracle-cache')
REPORT = os.path.join(ROOT, 'runtime', 'why432.json')
D = re.compile(r'\d+')
# Ring++'s own voice when it stops: an error report, a refusal, a crash, the
# watchdog. Matched on rnx's streams only, never on the test's text.
STOP = re.compile(r'(Error \((?:R|E|C)\d+\).*|Line \d+ Ring\+\+ refused.*|panic: .*|FAULT at .*'
                  r'|Segmentation fault.*|(?:Line \d+ )?Bad parameter type!.*|Stack Overflow.*'
                  r'|.*[Ww]atchdog.*)')


def main():
    # --platform=linux: the Linux clock's cache and table (why432.py --platform=linux)
    global CACHE, REPORT
    import sys
    if '--platform=linux' in sys.argv:
        CACHE = os.path.join(ROOT, 'runtime', 'oracle-cache-linux')
        REPORT = os.path.join(ROOT, 'runtime', 'why-linux.json')
        # the Linux oracle's copy taken from the snapshot (clock34
        # --linux-snapshot), the same rule why432.py follows
        rule = os.path.join(ROOT, 'runtime', 'oracle-copy-linux', 'libraries', 'stzlib',
                            '_copy_rule.txt')
        try:
            snap = 'sources from the snapshot' in open(rule, encoding='utf-8').readline()
        except OSError:
            snap = False
        if snap and '--his-tree' not in sys.argv:
            CACHE = os.path.join(ROOT, 'runtime', 'oracle-cache-linux-snap')
    # the SNAPSHOT's cache on Windows, the same rule why432.py follows (F-96):
    # once the oracle's copy exists its transcripts are the ones measured
    elif ('--his-tree' not in sys.argv and os.path.isdir(
            os.path.join(ROOT, 'runtime', 'oracle-copy-win', 'libraries', 'stzlib'))):
        CACHE = os.path.join(ROOT, 'runtime', 'oracle-cache-snap')
    # --suite=wide: the wide suite's own table (why432.py --suite=wide); its
    # transcripts share the one oracle cache with the 432
    if '--suite=wide' in sys.argv:
        REPORT = os.path.join(ROOT, 'runtime', 'why-%s.json'
                              % ('linux-wide' if '--platform=linux' in sys.argv else 'wide'))
    if not os.path.exists(REPORT):
        print('no table at %s yet -- run `python bench/why432.py%s` first'
              % (REPORT, ''.join(' ' + a for a in sys.argv[1:] if a.startswith('--'))))
        return 1
    rows = json.load(open(REPORT, encoding='utf-8'))
    tot = collections.Counter()
    kinds = collections.Counter()
    causes = collections.defaultdict(lambda: [0, []])
    for r in rows:
        try:
            c = json.load(open(os.path.join(CACHE, r['rel'].replace('/', '__') + '.json'),
                               encoding='utf-8'))
        except (OSError, ValueError):
            kinds['no transcript'] += 1
            continue
        if c.get('oracle_timeout'):
            kinds['oracle timed out'] += 1
            continue
        a, x, e = c.get('a1', ''), c.get('c', ''), c.get('e', '')
        ap, af, xp, xf = a.count('[PASS]'), a.count('[FAIL]'), x.count('[PASS]'), x.count('[FAIL]')
        tot['ring pass'] += ap
        tot['ring fail'] += af
        tot['rnx pass'] += xp
        tot['rnx fail'] += xf
        # per test: Ring's passes that Ring++ also has, and the passes Ring++
        # has OVER Ring's (counted, not matched by name -- a test's assertions
        # are compared as a count)
        tot['kept'] += min(xp, ap)
        tot['surplus'] += max(xp - ap, 0)
        if ap + af == 0:
            kinds['no assertions'] += 1
            continue
        kinds['with assertions'] += 1
        if xp >= ap and xf <= af:
            kinds['at parity'] += 1
            continue
        kinds['passing fewer'] += 1
        say = None
        for l in (x + '\n' + e).replace('\r', '').split('\n'):
            if l.startswith('WARNING'):
                continue
            m = STOP.search(l.strip())
            if m:
                say = m.group(1).strip()
                break
        if say is None:
            say = '(no error: %s)' % ('ran on and FAILED assertions' if xf > af
                                      else 'stopped without saying why')
        g = causes[D.sub('#', say)[:96]]
        g[0] += max(ap - xp, 0)
        g[1].append(r['rel'].replace('_narrated.ring', ''))

    print('tests with assertions      %4d' % kinds['with assertions'])
    print('  at parity                %4d   (Ring++ passes every assertion Ring passes)' % kinds['at parity'])
    print('  passing fewer            %4d' % kinds['passing fewer'])
    print('tests with no assertions   %4d   (demos and reports: why432 judges those)' % kinds['no assertions'])
    print('oracle timed out           %4d   (measure nothing)' % kinds['oracle timed out'])
    print()
    # THE HEADLINE WAS Ring++'s pass count over Ring's, and that counted
    # every pass Ring++ printed -- including passes on assertions RING FAILS.
    # On 2026-09-30 it read "8,501 of Ring's 8,507 (99.9%)" while 14 of those
    # were such surplus passes: Ring++ running on past an R24 and a dead
    # handler where Ring stops (F-89, F-90). When they closed, the "share"
    # FELL to 99.8% with nothing lost. The two are printed apart now.
    print('assertions   Ring   %5d pass %4d fail' % (tot['ring pass'], tot['ring fail']))
    print('             Ring++ %5d pass %4d fail' % (tot['rnx pass'], tot['rnx fail']))
    print('  of Ring\'s passes, Ring++ also passes %d -> %.1f%%'
          % (tot['kept'], 100.0 * tot['kept'] / max(1, tot['ring pass'])))
    print('  passes Ring++ has OVER Ring\'s        %d   (where Ring fails or stops first)' % tot['surplus'])
    lost = sum(v[0] for v in causes.values())
    print()
    print('%d passes Ring has and Ring++ does not, by what Ring++ said when it stopped:' % lost)
    for key, (n, tests) in sorted(causes.items(), key=lambda kv: -kv[1][0]):
        print('%5d  %3d test(s)  %s' % (n, len(tests), key))
        print('                   e.g. %s' % ', '.join(tests[:3]))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
