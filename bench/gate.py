# -*- coding: utf-8 -*-
"""The pre-commit gate: run once per task, not after every edit.

`ab.py` is the fast loop -- it answers "does this still agree with Ring".
This answers the two questions ab.py cannot:

    * does the compiler survive a LARGE program with checks on?
    * does the VM survive the same probes with checks on?

Both need ReleaseSafe, and both exist because of a real bug. `Func.id`
was a u8 with 43,713 functions in Softanza; past 255 the cast is illegal
behaviour rather than a truncation, and ReleaseFast does not check. The
A/B benchmarks are small enough that ids stay under 256, and the census
compiles without running, so nothing caught it for the whole of Stage 2.
The first ReleaseSafe census panicked on the first try.

ReleaseSafe costs 1.65x (measured: Sieve 10.14 -> 16.73 ms), which is
affordable precisely because Ring++ has the headroom -- so there is no
reason for this class of bug to accumulate again.

    python bench/gate.py            everything
    python bench/gate.py --fast     skip the ReleaseSafe passes

A gate that could not run is NAMED with its reason, never quietly
skipped.
"""
import os, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CORPUS = r'D:\GitHub\stzlib\libraries\stzlib\stzLib.ring'
# Ring resolves a relative `load` against the CURRENT DIRECTORY, so the
# corpus can only be compiled from its own -- stzLib.ring's first line is
# `load "base/stzBase.ring"`. Running it from ringpp's root loaded exactly
# nothing and the census said `ok` in 0.0s: a gate passing because it saw
# no work, which is the failure mode this file exists to refuse.
CORPUS_DIR = os.path.dirname(CORPUS)
FLAGS = ['-j2', '-Dmi=true', '-Drc=true', '-Dtyped=true', '-Dcow=true']

results = []


# THE ReleaseSafe BUILD HAS ITS OWN PREFIX (2026-10-03). It used to be
# installed into zig-out and the ReleaseFast one put back afterwards -- and
# zig-out/bin/rnxc.exe is what OTHER sessions run, the Haro forge many times
# a second. So the gate either raced them (AccessDenied on install, and the
# steps after it ran on whichever binary was left) or handed their
# experiments a checked, slower compiler for a minute. The ReleaseSafe steps
# run on zig-out-safe through RNXC=, which every measuring script reads; a
# prefix install carries load/, so it compiles the same unit.
SAFE_PREFIX = 'zig-out-safe'
SAFE_EXE = os.path.join(ROOT, SAFE_PREFIX, 'bin', 'rnxc.exe')


def run(cmd, cwd, timeout=1800, env=None):
    t0 = time.time()
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, env=env)
    return r.returncode, (r.stdout + r.stderr).replace('\r', ''), time.time() - t0


def with_rnxc(exe):
    """The environment that points every measuring script at `exe`."""
    return dict(os.environ, RNXC=exe) if exe else None


def record(name, ok, note, secs=None):
    tag = 'PASS' if ok is True else ('SKIP' if ok is None else 'FAIL')
    t = ('  %5.1fs' % secs) if secs else ''
    results.append((tag, name, note, t))
    print('%-4s %-26s %s%s' % (tag, name, note, t))


def build(mode, prefix=None):
    """One build; an install refused because another process holds the
    binary for a moment (AccessDenied) is tried again, three times in all."""
    cmd = ['zig', 'build', '-Doptimize=' + mode] + FLAGS + (['-p', prefix] if prefix else [])
    total = 0.0
    for attempt in range(3):
        code, out, secs = run(cmd, ROOT)
        total += secs
        if code == 0 or 'AccessDenied' not in out:
            break
        time.sleep(3)
    if code != 0:
        record('build ' + mode, False, out.strip().split('\n')[0][:70], total)
        return False
    record('build ' + mode, True, 'ok' + (' (%s)' % prefix if prefix else ''), total)
    return True


def ab(mode, exe=None):
    code, out, secs = run([sys.executable, 'bench/ab.py'], ROOT, env=with_rnxc(exe))
    last = [l for l in out.strip().split('\n') if l.strip()]
    summary = last[-1] if last else '(no output)'
    record('A/B ' + mode, code == 0, summary.strip(), secs)
    return code == 0


def bridge():
    """The engine boundary, proved without the engine.

    bench/bridge_demo.zig is written exactly as Softanza's 88 bridge files
    are -- the same R.* calls, the same Reg table, the same registerAll --
    and differs in one line: it imports bench/ring_api_rpp.zig, the second
    backend of that boundary, instead of Ring's. Building it and running
    bench/bridge.ring is the claim under test: a second backend carries the
    engine across and no bridge changes. Fourteen checks, each against the
    same answer computed in plain Ring."""
    code, out, secs = run(['zig', 'build-lib', '-dynamic', '-OReleaseFast', '-lc',
                           'bridge_demo.zig', '--name', 'rppbridge'], HERE)
    if code != 0:
        record('bridge (ABI 2)', False, out.strip().split('\n')[0][:70], secs)
        return False
    exe = os.path.join(ROOT, 'zig-out', 'bin', 'rnxc.exe')
    code, out, secs = run([exe, 'exec', 'bridge.ring'], HERE)
    ok = 'BRIDGE OK' in out
    note = 'a Softanza-shaped bridge, unchanged, on Ring++'
    if not ok:
        bad = [l for l in out.split('\n') if 'FAIL' in l]
        note = (bad[0][:70] if bad else 'no BRIDGE OK line')
    record('bridge (ABI 2)', ok, note, secs)
    return ok


def natives():
    """Nothing of RING's is reached for. `bench/natives.py` says why at
    length: rnxc must ship no dynamic library, nothing it ships may CALL
    LoadLib, and every library the estate will load must carry `rpp_init`
    rather than Ring's `ringlib_init`. The zip extension was reached for
    weeks and nobody noticed, because the reach failed QUIETLY."""
    code, out, secs = run([sys.executable, os.path.join(HERE, 'natives.py')], ROOT)
    last = [l for l in out.strip().split(chr(10)) if l.strip()]
    record('natives', code == 0, last[-1].strip() if last else '(no output)', secs)
    return code == 0


def dumpjson():
    """`rnxc dump --json` is lossless. `bench/dumpjson.py` says why: the file comes back from the export byte for byte, every span
    and gap is the file's own, and the shape is `rnxc dump`'s. The text dump lost four things and every reader recovered them by a
    heuristic; this is the guard of what replaced it."""
    code, out, secs = run([sys.executable, os.path.join(HERE, 'dumpjson.py')], ROOT)
    last = [l for l in out.strip().split(chr(10)) if l.strip()]
    record('dump --json', code == 0, last[-1].strip()[:110] if last else '(no output)', secs)
    return code == 0


def fmtcourt():
    """`rnxc fmt` prints the canonical text of rung 18's reference, and the text means what the file meant. `bench/fmt.py` says how: the
    fixtures byte for byte, parity with the reference on a corpus, idempotence, the graph read back, the compiled code, and the probes run
    on the oracle -- formatted and not."""
    # the reference is Haro's rung-18 printer; a tree published without haro/ (Ring++'s public main) has no reference to judge by
    if not os.path.isdir(os.path.join(ROOT, 'haro', 'spike', 'v18')):
        record('fmt', None, 'its reference, haro/spike/v18, is not in this tree', 0)
        return True
    code, out, secs = run([sys.executable, os.path.join(HERE, 'fmt.py')], ROOT)
    last = [l for l in out.strip().split(chr(10)) if l.strip()]
    record('fmt', code == 0, last[-1].strip()[:110] if last else '(no output)', secs)
    return code == 0


def graphcourt():
    """`rnxc graph` -- the resolved graph (L2) of a load unit -- is what the compiler bound, in stzCodeGraph's own protocol. `bench/graph.py`
    says how: five fixtures written before the verb printed anything, the Softanza unit's consistency (every owner, caller and callee declared,
    every dynamic width recounted, no edge twice), and the same text twice. `--peer` and `--ingest` are the slower comparisons, standalone."""
    code, out, secs = run([sys.executable, os.path.join(HERE, 'graph.py')], ROOT)
    last = [l for l in out.strip().split(chr(10)) if l.strip()]
    record('graph', code == 0, last[-1].strip()[:110] if last else '(no output)', secs)
    return code == 0


def shadows():
    """C-2's guard. A function that assigns a bare name which also exists
    as a global WRITES the global on Ring and makes a local here -- the one
    divergence a top-level global admits. `rnxc shadows` lists every such
    site; bench/shadows.max pins the count, and it may only shrink. A rise
    is a new silent divergence in the estate, named here before it hides."""
    if not os.path.exists(CORPUS):
        record('shadows (C-2)', None, 'corpus absent: ' + CORPUS)
        return True
    exe = os.path.join(ROOT, 'zig-out', 'bin', 'rnxc.exe')
    code, out, secs = run([exe, 'shadows', CORPUS], CORPUS_DIR)
    n = len([l for l in out.split('\n') if l.strip() and '\t' in l])
    try:
        pinned = int(open(os.path.join(HERE, 'shadows.max')).read().strip())
    except Exception:
        pinned = -1
    ok = code == 0 and pinned >= 0 and n <= pinned
    record('shadows (C-2)', ok, '%d site(s), pinned at %d%s' % (n, pinned, '' if ok else ' -- GREW'), secs)
    return shadows_bare(code, out) and ok


def shadows_bare(code, out):
    """C-2's OWN population, pinned apart (Mansour, 2026-09-23). The pin
    above counts bare uses of `$` names -- where Ring and Ring++ agree,
    because `$g` and `g` are two names to Ring -- and until that day it was
    the only one, so the divergence C-2 accepts had no guard at all: a
    function, method or lambda assigning a BARE top-level global writes the
    global on Ring and a local here. The same run reports those write sites
    on one line, and the base unit reads 0. A rise means a library function
    now writes a name a library top level writes bare.

    A MISSING line fails, as the census's codegen count does: a counter
    that stops being printed reads exactly like a zero."""
    line = [l for l in out.split('\n')
            if l.startswith('bare globals written in a function, method or lambda')]
    if not line:
        record('shadows bare (C-2)', False,
               'the report no longer counts bare-global write sites -- cannot tell 0 from unmeasured')
        return False
    import re
    m = re.search(r'(\d+) write site', line[0])
    n = int(m.group(1)) if m else -1
    try:
        pinned = int(open(os.path.join(HERE, 'shadows_bare.max')).read().strip())
    except Exception:
        pinned = -1
    ok = code == 0 and n >= 0 and pinned >= 0 and n <= pinned
    record('shadows bare (C-2)', ok, '%d write site(s), pinned at %d%s'
           % (n, pinned, '' if ok else ' -- GREW (rnxc shadows <corpus> --bare lists them)'))
    return ok


def checker():
    """The 17 rules of docs/FINDINGS.md, against tests/fixtures.

    Folded into rnxc on 2026-09-10; until then check.zig, why.zig and
    types.zig were in the tree unbuilt and this gate said SKIP. The
    expectation is RECORDED, not compared against the oracle -- Ring has
    no checker -- and bench/check.py says so at the top."""
    code, out, secs = run([sys.executable, "bench/check.py"], ROOT)
    last = [l for l in out.strip().split("\n") if l.strip()]
    line = [l for l in last if l.startswith("CHECKER")]
    record("checker", code == 0, (line[0] if line else last[-1] if last else "(no output)").strip(), secs)
    return code == 0

def execprobes(mode=None, exe=None):
    """Whole programs against the oracle (bench/exec.py): the top level, a
    class the grammar cut in two, Ring's newline rule, an attribute
    resolved by name -- everything ab.py's function calls cannot see.

    Run on the ReleaseSafe build too since 2026-10-03. They had only ever
    run on ReleaseFast, where a reference count taken below zero WRAPS in
    silence: a caught error after a borrow freed a global's list under it,
    and builtin_badparam.ring printed every right answer on ReleaseFast
    while ReleaseSafe said `integer overflow` in release. It was found only
    because a failed rebuild left the ReleaseSafe binary in place."""
    code, out, secs = run([sys.executable, 'bench/exec.py'], ROOT, env=with_rnxc(exe))
    last = [l for l in out.strip().split('\n') if l.strip()]
    name = 'exec probes' + (' ' + mode if mode else '')
    record(name, code == 0, (last[-1] if last else '(no output)').strip(), secs)
    return code == 0


def onto():
    """The library as a PREFIX (bench/onto.py --probes): a file compiled on
    top of a restored library answers as the whole unit does. Every wide-
    clock test runs this way, and every other probe here compiles whole --
    which is how eval in a library function crashed thirteen clock rows
    with this gate green (2026-09-25)."""
    code, out, secs = run([sys.executable, 'bench/onto.py', '--probes'], ROOT)
    last = [l for l in out.strip().split('\n') if l.strip()]
    ok = code == 0 and any('used one' in l and not l.split('; ', 1)[1].startswith('0 used') for l in last)
    record('prefix path (onto)', ok, (last[-1] if last else '(no output)').strip(), secs)
    return ok


def imagecache():
    """The compiled image (bench/image.py): a warm run must answer exactly
    as a cold one, must actually HAVE used the image, and must abandon it
    the moment a source file changes."""
    code, out, secs = run([sys.executable, 'bench/image.py'], ROOT)
    last = [l for l in out.strip().split('\n') if l.strip()]
    record('compiled image', code == 0, (last[-1] if last else '(no output)').strip(), secs)
    return code == 0


def census(mode, exe=None):
    """The compile-time half. A large program is the only thing that
    exercises the scale paths -- 43,713 functions, 575 classes."""
    if not os.path.exists(CORPUS):
        record('census ' + mode, None,
               'corpus absent: ' + CORPUS)
        return True
    exe = exe or os.path.join(ROOT, 'zig-out', 'bin', 'rnxc.exe')
    code, out, secs = run([exe, 'census', CORPUS], CORPUS_DIR)
    if 'panic' in out or code != 0:
        first = [l for l in out.split('\n') if 'panic' in l or 'error' in l.lower()]
        record('census ' + mode, False,
               (first[0][:70] if first else 'exit %d' % code), secs)
        return False
    line = [l for l in out.split('\n') if l.startswith('statements')]
    # A census that saw almost nothing is not a pass. Softanza is over a
    # hundred thousand statements; anything under this floor means the
    # unit did not load, not that the compiler had an easy day.
    n = 0
    if line:
        try:
            n = int(line[0].split()[1].rstrip(':'))
        except Exception:
            n = 0
    if n < 50000:
        record('census ' + mode, False,
               'saw %d statement(s) -- the corpus did not load' % n, secs)
        return False
    # A FUNCTION WHOSE CODEGEN FAILED OUTSIDE A STATEMENT stops being silent
    # here. On 2026-09-23 one such function stopped emitAll, the census
    # counted 70,512 statements instead of 118,637, and this step PASSED --
    # the floor above catches a corpus that did not load, not one that lost
    # 40% of itself. The census continues past such a function now and
    # prints how many there were; this makes any of them a failure. A MISSING
    # line fails too: a counter that stops being printed reads exactly like a
    # zero.
    ef = [l for l in out.split('\n')
          if l.startswith('functions whose codegen failed outside a statement:')]
    if not ef:
        record('census ' + mode, False,
               'the census no longer reports codegen failures -- cannot tell 0 from unmeasured',
               secs)
        return False
    nfail = int(ef[0].rsplit(':', 1)[1].strip() or '0')
    if nfail:
        record('census ' + mode, False,
               '%d function(s) failed codegen outside a statement' % nfail, secs)
        return False
    record('census ' + mode, True, line[0], secs)
    return True


def console():
    """The four console builtins (tui_init/key/size/done), gated by
    bench/tui_probe.py: a child in a NEW console, keys injected from
    outside, no human at the keyboard. It opens a console window on the
    desktop for about a second, which is why it is opt-in on a machine
    someone is using -- and why it is NAMED here when skipped, never
    silently absent."""
    if '--console' not in sys.argv:
        record('console builtins', None, 'opens a console window; run with --console')
        return True
    code, out, secs = run([sys.executable, 'bench/tui_probe.py'], ROOT)
    last = [l for l in out.strip().split('\n') if l.strip()]
    record('console builtins', code == 0, (last[-1] if last else '(no output)').strip(), secs)
    return code == 0


def tui72():
    """Widget-tree contract 7.2: two renderers, one model. The line
    renderer on Ring 1.27 and the keystroke renderer on Ring++ are fed
    the same session and their serialised model + events must be
    byte-identical. Both scripted; no console is touched."""
    code, out, secs = run([sys.executable, 'bench/tui72.py'], ROOT)
    last = [l for l in out.strip().split('\n') if l.strip()]
    record('7.2 two renderers', code == 0, (last[-1] if last else '(no output)').strip(), secs)
    return code == 0


def refusal():
    """A refused statement raises where it stood. Ring runs bench/refusal.ring
    to the end; Ring++ must stop AT the refusal with an error naming it, and
    must not print the line after it. Before this behaviour existed the
    program ran to completion with a silently wrong answer -- the failure
    this step exists to keep out."""
    exe = os.path.join(ROOT, 'zig-out', 'bin', 'rnxc.exe')
    # the probe is only meaningful while it still CONTAINS a refusal: the
    # construct it uses was supported once already, and the step went green
    # by accident. Say which it is rather than reporting a regression.
    ccode, cout, _ = run([exe, 'census', 'bench/refusal.ring'], ROOT)
    stat = [l for l in cout.split(chr(10)) if l.startswith('statements')]
    still_refuses = bool(stat) and ', 0 refused' not in stat[0]
    code, out, secs = run([exe, 'exec', 'bench/refusal.ring'], ROOT)
    raised = 'Ring++ refused this statement' in out
    ran_on = 'REFUSAL PROBE REACHED THE END' in out
    ok = still_refuses and raised and not ran_on
    if not still_refuses:
        note = 'probe refuses nothing now -- point it at another refused construct'
    elif raised and not ran_on:
        note = 'stops at the refusal, and says so'
    elif ran_on:
        note = 'RAN PAST THE REFUSAL -- a skipped statement is silent again'
    else:
        note = 'no refusal error: ' + ' | '.join(out.split(chr(10))[-2:]).strip()
    record('refusal raises', ok, note, secs)
    return ok


def quiet():
    """A plain run prints the PROGRAM's output and nothing of rnxc's own. Ring
    prints nothing around a program; rnxc's three status lines went to stderr,
    which a terminal shows too, and every person who tried the v2.0.0 package
    saw them on every run (2026-10-16). They print only under RNXC_VERBOSE now.
    Checked on both paths -- a cold compile and a warm start from the compiled
    image, which prints its own status -- and with the variable set, so the
    harnesses that read the lines (image.py, onto.py, child_start.py) still
    find them."""
    import tempfile
    exe = os.path.join(ROOT, 'zig-out', 'bin', 'rnxc.exe')
    t0 = time.time()
    d = tempfile.mkdtemp(prefix='rnxc_quiet_')
    with open(os.path.join(d, 'q.ring'), 'w', newline='\n') as f:
        f.write('? "quiet"\n')
    base = {k: v for k, v in os.environ.items() if k not in ('RNXC_VERBOSE', 'RNXC_NOCACHE')}
    base['RNXC_CACHE'] = os.path.join(d, 'cache')
    problems = []
    for label, extra in (('cold', {}), ('warm', {}), ('verbose', {'RNXC_VERBOSE': '1'})):
        r = subprocess.run([exe, 'q.ring'], cwd=d, capture_output=True, text=True, env=dict(base, **extra))
        out, err = r.stdout.replace('\r', ''), r.stderr.replace('\r', '')
        if r.returncode != 0 or out != 'quiet\n':
            problems.append('%s: exit %d, stdout %r' % (label, r.returncode, out[:60]))
        elif label != 'verbose' and err.strip():
            problems.append('%s run printed %r' % (label, err.strip().split('\n')[0][:60]))
        elif label == 'verbose' and not ('running the top level' in err and 'TOP LEVEL RAN TO COMPLETION' in err):
            problems.append('RNXC_VERBOSE=1 printed no status')
    shutil.rmtree(d, ignore_errors=True)
    ok = not problems
    record('quiet by default', ok, 'only the program speaks; RNXC_VERBOSE=1 brings the status back' if ok
           else ' | '.join(problems), time.time() - t0)
    return ok


def websock():
    """Contract 5.1's socket, driven for real: the binary serves the tree,
    a POST comes back, and the model must be the one the terminal
    renderers leave. This opens no window -- a socket can be spoken to --
    so it is gated rather than left behind a flag like the console."""
    code, out, secs = run([sys.executable, 'bench/web_probe.py'], ROOT)
    last = [l for l in out.strip().split(chr(10)) if l.strip()]
    record('5.1 browser socket', code == 0,
           (last[-1] if last else '(no output)').strip(), secs)
    return code == 0


def main():
    fast_only = '--fast' in sys.argv
    print('Ring++ gate\n')

    ok = True
    if build('ReleaseFast'):
        ok &= ab('ReleaseFast')
        ok &= census('ReleaseFast')
    else:
        ok = False

    if not fast_only:
        print()
        if build('ReleaseSafe', SAFE_PREFIX):
            # Checks ON: the compiler against a large program, then the
            # VM against every probe. These are the two the fast build
            # cannot answer. On its own prefix: zig-out is never swapped.
            ok &= census('ReleaseSafe', SAFE_EXE)
            ok &= ab('ReleaseSafe', SAFE_EXE)
            ok &= execprobes('ReleaseSafe', SAFE_EXE)
        else:
            ok = False
    else:
        record('ReleaseSafe passes', None, '--fast given; run without it before committing')

    ok &= console()
    ok &= refusal()
    ok &= quiet()
    ok &= execprobes()
    ok &= onto()
    ok &= imagecache()
    ok &= checker()
    ok &= bridge()
    ok &= natives()
    ok &= dumpjson()
    ok &= fmtcourt()
    ok &= graphcourt()
    ok &= shadows()
    ok &= tui72()
    ok &= websock()

    print()
    bad = [r for r in results if r[0] == 'FAIL']
    skipped = [r for r in results if r[0] == 'SKIP']
    if bad:
        print('GATE FAILED -- %d failing' % len(bad))
        for r in bad:
            print('   %s: %s' % (r[1], r[2]))
    else:
        print('GATE PASSED')
    for r in skipped:
        print('   SKIPPED %s -- %s' % (r[1], r[2]))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
