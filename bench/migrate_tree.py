"""RULE A FOR A WHOLE STZLIB TREE, in the order that works.

    python bench/migrate_tree.py --tree <worktree of stzlib> [--root max/stzMax.ring] [--rnxc <rnxc>]

Runs, on <tree>/libraries/stzlib, the steps that took `main` (1b76a6ed8, 2026-10-23) from 502 refused statements to 0, each one a tool of this folder:

  1. migrate_apply          `rnxc migrate` to a fixpoint: every global a function reads gets its `$` (one refusal per statement, so rounds)
  2. migrate_apply shadows  the flags and constants whose meaning the first step changed on Ring, sigil restored everywhere -- only for names that some
                            top level declared BARE before step 1 (a bare use of any other name meant no global on Ring, and stays a local)
  3. HAND FIXES             the few places no tool can decide (below); each an exact replacement that must match once, or the run STOPS
  4. migrate_locals         `@i` in a plain function is a local `_i_`
  5. the bare-write report  `rnxc shadows --bare`, TAKEN HERE: once step 6 has renamed the declarations, a function's bare write of a global is a plain
                            local and no report lists it -- which is the bug, not a cure
  6. migrate_toplevel       the top level declares what the functions read as `$name`
  7. the writers            the report of step 5, names with no `$name` anywhere left out, every bare occurrence of the name in each writing function
  8. migrate_apply          once more, to a fixpoint: the reads that steps 6-7 left bare are refused again and named
  9. the census             must read 0 refused
 10. migrate_check          what the census cannot see: a `$name` that nothing assigns (a name assigned nowhere is a run-time R24, not a refusal)
 11. migrate_audit          every byte changed against the tree's HEAD: a `$` only before a whole identifier in code, `@x` -> `_x_` only, the rest listed

Steps 10 and 11 exist because steps 1-9 once finished with "0 refused" on a tree that was wrong in two ways the census cannot see: four globals whose names
hold a `$` (`_$aRegexPatterns_`) read as `$_$a...` and declared bare, and five `$` put into prose -- a logo in a multi-line string, a symbol `:Maori`, two words
of a stop-word list. Both are now caught by the check or the audit, each of which was made to fail on the planted defect before it was trusted.

HAND FIXES are data about one tree. A tree that has moved will not match them; the run stops at the first that does not, and says which. Add the new
ones (or drop the old) in HAND_FIXES. They are: the placeholder `@ = 0` (a real Softanza identifier: `migrate` reports no name for it); two globals read with
the attribute sigil; a `del(_aVars, ..)` that `migrate` files as an identifier; FirstNPrimesW and stzWCondition, whose CONDITION TEXT names @prime, @item and @i and is
evaluated in the function's own scope -- the text is rewritten onto the locals before the eval, so a renamed variable never leaves its condition behind.

Nothing is committed, and nothing outside <tree>/libraries/stzlib is written."""
import os, re, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PY = sys.executable

HAND_FIXES = [
    # (file, old, new) -- exact, must match once. LF in this table; the file's own line ending is kept.
    ('base/common/stzFuncs.ring', '\n@ = 0\n', '\n$@ = 0\n'),
    ('base/graph/stzGraph.ring', '\treturn @acGraphTypes\n', '\treturn $acGraphTypes\n'),
    ('base/graph/stzGraph.ring', '\treturn @cDefaultGraphType\n', '\treturn $cDefaultGraphType\n'),
    ('base/common/stzNamedVars.ring', '\t\tdel(_aVars, _n_)\n', '\t\tdel($_aVars, _n_)\n'),
    ('base/number/stzListOfNumbers.ring',
     "\t_cCode_ = 'bOk = (' + _StzStripBraces(pcCondition) + ' )'\n\n\t_anResult_ = []\n\n\t@prime = 0\n",
     "\t# The condition names @prime; the loop's own variable is _prime_. A\n"
     "\t# bare @name in a plain function is refused under Ring++'s Rule A (@ is\n"
     "\t# an attribute), so the condition is rewritten onto the local before it\n"
     "\t# is evaluated -- case-insensitively, as Ring's names are.\n"
     "\t_cCode_ = 'bOk = (' + StzReplaceCS(_StzStripBraces(pcCondition), \"@prime\", \"_prime_\", FALSE) + ' )'\n\n\t_anResult_ = []\n\n\t_prime_ = 0\n"),
    ('base/number/stzListOfNumbers.ring', '\t\t@prime = NextPrimeAfter(@prime)\n', '\t\t_prime_ = NextPrimeAfter(_prime_)\n'),
    ('base/number/stzListOfNumbers.ring', '\t\t\t_anResult_ + @prime\n', '\t\t\t_anResult_ + _prime_\n'),
    ('base/list/stzWCondition.ring',
     "func _StzWCheckedPositions(paItems, pcCond)\n\t_aR_ = []\n\t_n_ = len(paItems)\n\tfor _i_ = 1 to _n_\n\t\t@item = paItems[_i_]\n\t\t@i = _i_\n",
     "func _StzWCheckedPositions(paItems, pcCond)\n\t_aR_ = []\n\t_n_ = len(paItems)\n"
     "\t# The condition names the engine's @item and @i; here they are _item_ and\n"
     "\t# _i_, the loop's own locals -- an @name in a plain function is refused\n"
     "\t# under Ring++'s Rule A. Rewritten before the eval, as FirstNPrimesW does.\n"
     "\tpcCond = StzReplaceCS(StzReplaceCS(pcCond, \"@item\", \"_item_\", 0), \"@i\", \"_i_\", 0)\n"
     "\tfor _i_ = 1 to _n_\n\t\t_item_ = paItems[_i_]\n"),
    ('base/list/stzWCondition.ring',
     "func _StzWCheckedValues(paItems, pcExpr)\n\t_aR_ = []\n\t_n_ = len(paItems)\n\tfor _i_ = 1 to _n_\n\t\t@item = paItems[_i_]\n\t\t@i = _i_\n",
     "func _StzWCheckedValues(paItems, pcExpr)\n\t_aR_ = []\n\t_n_ = len(paItems)\n"
     "\t# The condition names the engine's @item and @i; here they are _item_ and\n"
     "\t# _i_, the loop's own locals -- an @name in a plain function is refused\n"
     "\t# under Ring++'s Rule A. Rewritten before the eval, as FirstNPrimesW does.\n"
     "\tpcExpr = StzReplaceCS(StzReplaceCS(pcExpr, \"@item\", \"_item_\", 0), \"@i\", \"_i_\", 0)\n"
     "\tfor _i_ = 1 to _n_\n\t\t_item_ = paItems[_i_]\n"),
]


# Names read as `$name` that no file of main (1b76a6ed8) assigns: defects of the library, present before any migration, and raising R24 when the line runs on
# Ring too -- `$aoExplanation` (stzGraph), `$cDefaultDiagramOutputFormat` (stzDiagram, stzDotCode), `$pcFolder` (stzDiagram). Not the migration's; named so a
# FOURTH is a failure.
KNOWN_UNASSIGNED = 'aoexplanation,cdefaultdiagramoutputformat,pcfolder'


def arg(name, default=None):
    if name in sys.argv:
        i = sys.argv.index(name)
        return sys.argv[i + 1] if i + 1 < len(sys.argv) else default
    return default


def run(label, cmd, capture=False):
    t = time.time()
    print('\n== %s' % label, flush=True)
    r = subprocess.run(cmd, capture_output=capture, text=True, encoding='utf-8', errors='replace')
    if capture:
        sys.stdout.write((r.stdout or '')[-1500:])
    print('   (%.0f s, exit %d)' % (time.time() - t, r.returncode), flush=True)
    if r.returncode != 0:
        raise SystemExit('STOPPED at: ' + label)
    return r


def hand_fixes(lib):
    print('\n== 3. hand fixes')
    for rel, old, new in HAND_FIXES:
        p = os.path.join(lib, rel.replace('/', os.sep))
        data = open(p, 'rb').read()
        nl = b'\r\n' if b'\r\n' in data else b'\n'
        o, n = old.replace('\n', nl.decode()).encode('utf-8'), new.replace('\n', nl.decode()).encode('utf-8')
        if data.count(o) != 1:
            raise SystemExit('STOPPED: hand fix does not match exactly once (%d) in %s: %r' % (data.count(o), rel, old[:70]))
        open(p, 'wb').write(data.replace(o, n))
        print('   ok  %s | %s' % (rel, old.strip().split('\n')[0][:60]))


def twinless(report, lib):
    """Names in the bare-write report that occur as `$name` nowhere in the library: plain locals all along."""
    sys.path.insert(0, HERE)
    import migrate_toplevel as T
    text = b'\n'.join(open(p, 'rb').read().lower() for p in T.library_files(lib))
    names = set()
    for l in open(report, encoding='utf-8', errors='replace'):
        p = l.rstrip('\r\n').split('\t')
        if len(p) >= 3:
            names.add(p[2])
    return sorted(n for n in names if not re.search(rb'\$' + re.escape(n.lower().encode()) + rb'(?![\w])', text))


def main():
    tree = arg('--tree')
    if not tree:
        raise SystemExit(__doc__)
    lib = os.path.join(tree, 'libraries', 'stzlib')
    root = os.path.join(lib, (arg('--root') or 'max/stzMax.ring').replace('/', os.sep))
    rnxc = arg('--rnxc') or os.path.join(ROOT, 'zig-out', 'bin', 'rnxc.exe')
    base = ['--within', lib, '--rnxc', rnxc]
    scratch = os.path.join(ROOT, 'runtime', 'migrate_tree')
    os.makedirs(scratch, exist_ok=True)
    t0 = time.time()
    sys.path.insert(0, HERE)
    import migrate_toplevel as T
    # Taken BEFORE step 1, which may put the `$` on a top-level declaration itself.
    declared0 = {n.decode('latin-1') for n in T.top_level_declared(*T.library_split(lib))}
    run('1. migrate to a fixpoint', [PY, os.path.join(HERE, 'migrate_apply.py'), root] + base, True)
    # `rnxc shadows` lists every bare use of a name that is also a `$` global. That is a changed meaning only when the bare use MEANT a global on Ring -- a
    # name some top level declared bare. Main declares no bare `n`; its `$n` is written inside a function of stzBpmnDiagram; and the 40 bare `n` the report
    # lists are loop variables, parameters and reads of nothing. The first run of this driver put `$` on all of them, and `for n = 1 to ...` then indexed with
    # a `$n` nothing assigns: R24, in a graphex test, invisible to the census, the check and the per-byte audit.
    r = subprocess.run([rnxc, 'shadows', root], capture_output=True)
    reported = sorted({l.split('\t')[2].lower() for l in r.stdout.decode('utf-8', 'replace').splitlines() if l.count('\t') >= 2})
    left = [n for n in reported if n not in declared0]
    print('\n   shadows names: %d; declared bare at a top level, given the sigil: %s; never declared bare, left alone: %s'
          % (len(reported), ', '.join(n for n in reported if n in declared0) or '-', ', '.join(left) or '-'))
    run('2. shadows: the sigil back on flags and constants a top level declared bare',
        [PY, os.path.join(HERE, 'migrate_apply.py'), root, '--verb', 'shadows'] + (['--skip', ','.join(left)] if left else []) + base, True)
    hand_fixes(lib)
    run('4. @name in a plain function is a local', [PY, os.path.join(HERE, 'migrate_locals.py'), root] + base, True)
    report = os.path.join(scratch, 'bare_writes.tsv')
    print('\n== 5. the bare-write report (before the declarations move)')
    with open(report, 'wb') as f:
        r = subprocess.run([rnxc, 'shadows', root, '--bare'], stdout=f, stderr=subprocess.PIPE, text=True, errors='replace')
    print('   ' + [l for l in r.stderr.split('\n') if 'bare globals written' in l][0].strip()[:150])
    skip = twinless(report, lib)
    print('   no $ twin anywhere (plain locals, left alone): %s' % ', '.join(skip))
    run('6. the top level declares what functions read as $name', [PY, os.path.join(HERE, 'migrate_toplevel.py'), '--within', lib], True)
    run('7a. the writes: first occurrence', [PY, os.path.join(HERE, 'migrate_apply.py'), 'x', '--from', report, '--lines', '--skip', ','.join(skip)] + base, True)
    run('7b. the writes: every occurrence in the writing function', [PY, os.path.join(HERE, 'migrate_writers.py'), report, '--within', lib, '--skip', ','.join(skip)], True)
    run('8. migrate once more, to a fixpoint', [PY, os.path.join(HERE, 'migrate_apply.py'), root] + base, True)
    print('\n== 9. the census')
    out = subprocess.run([rnxc, 'census', root], capture_output=True, text=True, encoding='utf-8', errors='replace').stdout
    line = [l for l in out.split('\n') if l.startswith('statements')]
    print('\n' + (line[0] if line else '?') + '   (%.0f s in all)' % (time.time() - t0))
    failed = []
    print('\n== 10. a $name that nothing assigns')
    r = subprocess.run([PY, '-I', os.path.join(HERE, 'migrate_check.py'), lib, '--known', KNOWN_UNASSIGNED], capture_output=True, text=True, encoding='utf-8', errors='replace')
    print(r.stdout.rstrip())
    if r.returncode != 0:
        failed.append('migrate_check')
    print('\n== 11. the audit against HEAD')
    r = subprocess.run([PY, '-I', os.path.join(HERE, 'migrate_audit.py'), '--tree', tree], capture_output=True, text=True, encoding='utf-8', errors='replace')
    print(r.stdout.rstrip())
    if r.returncode != 0:
        failed.append('migrate_audit')
    if failed:
        raise SystemExit('FAILED: ' + ', '.join(failed))
    return 0


if __name__ == '__main__':
    sys.exit(main())
