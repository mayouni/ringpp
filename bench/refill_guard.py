"""A REFILL TAKEN ON A THROTTLED MACHINE, and which of its transcripts to take again at full speed.

    python bench/refill_guard.py baseline     before the refill: every cached oracle transcript, summarised
    python bench/refill_guard.py compare      after it: the re-taken transcripts that came back WORSE than before

Why this is sound. On 2026-10-19 the firmware capped this machine's CPU to 50-70% of nominal whenever the charger fed it
(bench/heartbeat.py measures it), and the checkpoint refill had to run anyway. A slower machine can only make Ring's
answers WORSE: an oracle run that crosses the 90 s cap, a timing assertion that fails, a bounded wait that gives up.
It cannot add a pass that full speed would not give -- with one known kind of exception, an assertion that some time
"advanced", and those were calibrated against the clock in his tree (df45357f2 and its two siblings). So a transcript
re-taken throttled that answers at least as well as its full-speed predecessor is kept, and one that answers worse --
a new timeout, fewer passes, more fails, in either of its two runs -- is flagged to be re-taken at full speed. A row
can also come back worse for a REAL reason (thirteen library files changed since the old snapshot); re-taking it at
full speed settles which.

The baseline is a summary (2.7 GB of transcripts are not copied): per test, the time it was taken, the timeout flag and
each run's passes, fails and line count, counted with parity432.marks so a check is counted as the parity figure counts
it. Written to runtime/refill-baseline.json; compare writes runtime/refill-suspects.json.
"""
import glob, io, json, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from parity432 import marks  # noqa: E402

ROOT = os.path.dirname(HERE)
CACHE = os.path.join(ROOT, 'runtime', 'oracle-cache-snap')
BASE = os.path.join(ROOT, 'runtime', 'refill-baseline.json')
SUSP = os.path.join(ROOT, 'runtime', 'refill-suspects.json')


def summary(path):
    try:
        d = json.load(io.open(path, encoding='utf-8'))
    except (OSError, ValueError):
        return None
    out = {'when': d.get('when'), 'timeout': bool(d.get('oracle_timeout')), 'stamp': d.get('stamp')}
    for k in ('a1', 'a2'):
        t = d.get(k) or ''
        p, f = marks(t)
        out[k] = [p, f, t.count('\n')]
    return out


def entries():
    for p in sorted(glob.glob(os.path.join(CACHE, '*.json'))):
        yield os.path.basename(p)[:-5], p


def baseline():
    if os.path.exists(BASE):
        raise SystemExit('%s exists -- a baseline is taken once, before the refill; move it aside first' % BASE)
    t = time.time()
    rows = {rel: summary(p) for rel, p in entries()}
    io.open(BASE, 'w', encoding='utf-8').write(json.dumps({'taken': time.strftime('%Y-%m-%d %H:%M'), 'rows': rows}))
    print('baseline: %d transcripts summarised in %.0f s -> %s' % (len(rows), time.time() - t, BASE))


def worse(b, n):
    """Why the re-taken transcript n answers worse than the baseline b, or None."""
    why = []
    if n['timeout'] and not b['timeout']:
        why.append('now times out on the oracle')
    if b['timeout']:
        return None   # it timed out at full speed too: a throttled run cannot lose anything there
    for k in ('a1', 'a2'):
        bp, bf, _ = b[k]
        np_, nf, _ = n[k]
        if np_ < bp:
            why.append('%s: %d passes, was %d' % (k, np_, bp))
        if nf > bf:
            why.append('%s: %d fails, was %d' % (k, nf, bf))
    return '; '.join(why) or None


def compare():
    base = json.load(io.open(BASE, encoding='utf-8'))
    rows = base['rows']
    retaken = flagged = 0
    out = {}
    for rel, p in entries():
        n = summary(p)
        b = rows.get(rel)
        if not n or (b and n['when'] == b['when']):
            continue
        retaken += 1
        # no baseline: its full-speed transcript was already gone (chunk 1's 33, voided 2026-10-18), so nothing can
        # say this one is sound -- take it again at full speed
        why = worse(b, n) if b else 'no full-speed baseline'
        if why:
            flagged += 1
            out[rel] = {'why': why, 'was': b, 'now': n}
    io.open(SUSP, 'w', encoding='utf-8').write(json.dumps(out, indent=1))
    print('re-taken since the baseline (%s): %d; answering WORSE than before: %d -> %s'
          % (base['taken'], retaken, flagged, SUSP))
    for rel, v in sorted(out.items())[:40]:
        print('  %-70s %s' % (rel[:70], v['why'][:90]))
    if flagged > 40:
        print('  ... and %d more' % (flagged - 40))


if __name__ == '__main__':
    {'baseline': baseline, 'compare': compare}.get((sys.argv[1:] or ['?'])[0],
                                                   lambda: sys.exit(__doc__))()
