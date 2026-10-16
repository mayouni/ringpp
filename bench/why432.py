"""WHY does each of the 432 differ? The first divergence, classified,
ranked by how many tests share a cause.

    python bench/why432.py --fill              take the oracle transcripts
    python bench/why432.py --fill --budget=480   ...for at most 8 minutes
    python bench/why432.py                     read them, run rnx, report
    python bench/why432.py number/             just those whose name matches
    python bench/why432.py --rerun             run rnx on every test again, cached rows or not

--rerun exists because a pass can be VOID with nothing in its key moving: on
2026-09-26 the machine slept from 02:34 to 08:49 in the middle of one, so a
test running across the sleep was killed at its 120 s cap (a hang that was
not) and every timing row churned -- and the next pass re-cut those same
rows from the cache, because the binary, the tree and the copy had not
changed. A pass whose rnx took far longer than its usual 8-11 minutes is
the sign; the Windows System log (Kernel-Power 42/107) is the proof.

`bench/clockall.py` answers HOW MANY match. `bench/stop34.py` answers where
the 34 stop and on what. This is that second question asked of the wide set,
and it exists because picking a test by hand fixes one test: both wins of
2026-09-15/16 -- the flush that ended 68 blind rows, and the float that
crashed nine builtins -- came out of a census of CAUSES, and the float was
chosen because it was 19 rows, not because it was interesting.

TWO PHASES, BECAUSE ONE OF THEM IS ALL THE COST. `--fill` runs the ORACLE
and nothing else: two runs per test at ~8 s, ~100 minutes for 432, written
to disk. Everything after that is rnx-only on the library prefix -- 7-8
minutes when rnx has to run on all 427 comparable tests, and about ONE
SECOND when nothing rnx depends on has moved, because rnx's streams are
banked too and the rows are re-cut from them (see measure()). `--budget`
stops either phase early and both are resumable, because a transcript
taken is a transcript banked; a pass the budget stopped says so and
leaves the tables alone.

WHAT THE CACHE IS KEYED ON, and what that does NOT cover. The stamp is the
oracle executable (size + mtime), the test file's own bytes, and a TREE
STAMP -- the path, size and mtime of every .ring and .rh under Mansour's
stzlib, 6,075 files in 0.3 s. So an edit anywhere in the library invalidates
every transcript, which is correct and also expensive; it is his tree and it
moves. It does NOT cover his engine DLLs beyond their mtimes, nor anything a
test reads from outside the tree. A stale transcript is REFUSED by default
and re-taken by the next fill; `--stale-ok` uses it and marks every row it
used, because a measurement taken against a different tree is not the same
measurement.

RNX'S SIDE IS KEYED SEPARATELY, on what rnx actually ran: the rnxc binary,
the tree stamp above, the clock-copy by CONTENT with its Ring++ engine DLLs
(stamp_copy), the timeout and the test's bytes. Not on Mansour's tree
alone -- rnx never reads it, and an edit to the copy alone moves nothing
there. A `--restamp` drops the rnx key of every transcript it touches.

THE NOISE FLOOR IS NOT OPTIONAL HERE EITHER. The oracle runs twice, the
lines it does not reproduce from itself are set aside BY POSITION, and the
first divergence is the first line outside that set. Without it the ranking
fills with `Executed in 0.01 second(s)` and the work queue is fiction
(F-57; clock34.py says it at greater length).

HOW A CAUSE IS NAMED. Out of the RUNTIME's own report, never the test's
text -- stop34.py's first version matched the word "refuses" in three tests'
assertions and called three passing tests refusals. So:

    crash           the panic or fault rnx printed on STDERR
    refused/raised  the code in rnx's own `Line <n> Error (R<n>)` report
    stops quietly   rnx's output is a prefix of the oracle's and it said
                    nothing at all about why -- the shape that hid forty
                    tests which merely fail assertions
    assertion       the same line, PASS on the oracle and FAIL on rnx
    line differs    everything else, with rnx's line quoted
    longer          rnx kept printing after the oracle stopped

Within every cause the rows are grouped by that line with its DIGITS
BLANKED, so twenty tests failing the same assertion read as one cause and
not as twenty. That grouping is the whole point of the instrument.
"""
import collections
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import clock34 as K
import clockall as W
import stop34 as S

CACHE = os.path.join(K.ROOT, 'runtime', 'oracle-cache')
REPORT = os.path.join(K.ROOT, 'runtime', 'why432.json')
ORACLE_TIMEOUT = 90
RNX_TIMEOUT = 120
RERUN = [False]  # --rerun: ignore cached rnx rows for this pass

# --platform=linux (item 8, 2026-09-28): the same clock on LINUX, under WSL
# -- the Linux oracle (runtime/linux-x64/ring, glibc) on its own copy of the
# tree with the oracle-flavour engine, and the Linux rnxc (zig-out-linux) on
# the clock copy with the Ring++ engine; its own caches and tables. The
# distribution is NAMED: this machine's default is docker-desktop, where a
# run does not happen at all (bench/exec_wsl.py paid for that once).
PLATFORM = ['windows']
WSL_DISTRO = os.environ.get('RPP_WSL_DISTRO', 'Ubuntu')
# THE SNAPSHOT (2026-10-03, F-96): on Windows, once clock34.make_snapshot()
# has laid it out, the oracle runs a COPY of his tree holding an engine built
# from that copy's own source against the oracle -- not his tree with his
# zig-out, whose DLLs reached D:\Ring127's ring.dll and were not his current
# source. Its transcripts live in their own cache, keyed on the snapshot by
# content, so the old ones stay to be compared with. `--his-tree` measures
# the old way.
SNAPSHOT = [False]


def use_snapshot():
    global CACHE, TREE_LIST, PREFIX_TREE, COPY_LIST
    SNAPSHOT[0] = True
    # the Linux oracle runs its own copy of the snapshot (clock34
    # --linux-snapshot), so its transcripts are kept apart from both the
    # Windows snapshot's and the Linux ones taken on his live tree
    CACHE = os.path.join(K.ROOT, 'runtime', 'oracle-cache-linux-snap'
                         if PLATFORM[0] == 'linux' else 'oracle-cache-snap')
    TREE_LIST = os.path.join(CACHE, '_tree.json')
    PREFIX_TREE = os.path.join(CACHE, '_prefix_tree.txt')
    COPY_LIST = os.path.join(CACHE, '_copy_tree.json')
    os.makedirs(CACHE, exist_ok=True)


def linux_copy_is_snapshot():
    try:
        rule = io.open(os.path.join(K.LP + K.ORACLE_COPY_LINUX, '_copy_rule.txt'),
                       encoding='utf-8').readline()
    except OSError:
        return False
    return K.FROM_SNAPSHOT in rule


# THE MIRROR (2026-10-08). Under WSL every file of a tree on D: is read
# through the /mnt/d bridge, and a Softanza run reads ~613 library files:
# rnx took about 6 s a test there against under 1 s on Windows, and the
# oracle 5 against 3 (item 8, 2026-09-29). So on Linux the trees a run
# READS are laid out on WSL's own disk, under RPP_WSL_MIRROR (/root/rpp by
# default; `0` turns it off), each at its path relative to this repository
# -- so copy rule 5's sibling folder still sits six levels above a test.
# The Windows copies stay the masters: the stamps and keys are taken on
# them, and a mirror is re-synced from its master only when the master's
# stamp has moved (runtime/linux-mirror.json), so the state the tests leave
# in the mirror accumulates as it does in a Windows copy.
WSL_MIRROR = os.environ.get('RPP_WSL_MIRROR', '/root/rpp').rstrip('/')
# runtime/libraries and runtime/extensions are what the ORACLE's load shims
# reach (`load "/../../libraries/stdlib/stdlib.rh"` is two levels above its
# own folder): without them the first mirrored fill printed 59 lines of
# E9 and C27 and ran nothing -- caught by reading the transcript, which a
# count of transcripts taken would never have done.
MIRRORED = ('runtime/clock-copy', 'runtime/oracle-copy-linux', 'runtime/softanza',
            'runtime/linux-x64', 'runtime/libraries', 'runtime/extensions',
            'zig-out-linux', 'runtime/linux-mirror-tools', 'runtime/wide-cache-linux')
NOT_SYNCED = ('runtime/wide-cache-linux',)     # output: images and the prefix
MIRROR_MAP = []                                # (Windows prefix, Linux prefix)
MIRROR_LIST = os.path.join(K.ROOT, 'runtime', 'linux-mirror.json')
MIRROR_TOOLS = os.path.join(K.ROOT, 'runtime', 'linux-mirror-tools')
# rnx writes one compiled image per test into RNXC_CACHE, ~40 MB each, and
# W.drop_images() cannot see a cache on WSL's disk -- so on the mirror rnx
# runs through this, which drops them first, as drop_images() does on
# Windows. A file, because a script passed through wsl.exe is re-parsed by
# a shell on the way in.
DROP_THEN_RUN = '#!/bin/sh\nrm -f "$RNXC_CACHE"/*.rnxi\nexec "$@"\n'


def mnt_path(p):
    p = os.path.abspath(p).replace(chr(92), '/')
    return '/mnt/' + p[0].lower() + p[2:]


def to_wsl(p):
    """A Windows path as a Linux process under WSL sees it: on the mirror
    when one holds it, through /mnt/<drive> otherwise."""
    p = os.path.abspath(p)
    low = p.lower()
    for win, nat in MIRROR_MAP:
        w = win.lower()
        if low == w or low.startswith(w + os.sep):
            return nat + p[len(win):].replace(chr(92), '/')
    return mnt_path(p)


def listing_stamp(rel):
    """A small tree's stamp by name, size and mtime -- the binaries and
    the fixtures, where content hashing buys nothing."""
    root = os.path.join(K.ROOT, *rel.split('/'))
    h = hashlib.sha256()
    for dp, dn, fn in os.walk(root):
        dn.sort()
        for f in sorted(fn):
            p = os.path.join(dp, f)
            st = os.stat(p)
            h.update(('%s %d %d\n' % (os.path.relpath(p, root), st.st_size,
                                      st.st_mtime_ns)).encode('utf-8', 'replace'))
    return h.hexdigest()[:16]


def rule_mtime(copy_root):
    try:
        return '%d' % os.stat(os.path.join(K.LP + copy_root, '_copy_rule.txt')).st_mtime_ns
    except OSError:
        return 'no-rule'


def sync_mirror(parts):
    """Bring each mirrored tree in line with its master when the master's
    stamp has moved, or when the mirror is missing. `rsync -a --delete`
    from /mnt/d, so a re-sync also discards what the tests left there --
    as re-taking a Windows copy does."""
    try:
        done = json.load(io.open(MIRROR_LIST, encoding='utf-8'))
    except (OSError, ValueError):
        done = {}
    for rel, stamp in parts:
        nat = WSL_MIRROR + '/' + rel
        there = subprocess.run(['wsl.exe', '-d', WSL_DISTRO, '--exec', 'test', '-d', nat]
                               ).returncode == 0
        if there and done.get(rel) == stamp:
            continue
        t = time.time()
        src = mnt_path(os.path.join(K.ROOT, *rel.split('/')))
        for cmd in (['mkdir', '-p', nat], ['rsync', '-a', '--delete', src + '/', nat + '/']):
            r = subprocess.run(['wsl.exe', '-d', WSL_DISTRO, '--exec'] + cmd,
                               capture_output=True)
            if r.returncode != 0:
                raise SystemExit('mirror: %s failed (exit %d): %s' % (
                    ' '.join(cmd[:2]), r.returncode,
                    r.stderr.decode('utf-8', 'replace').strip()[:300]))
        done[rel] = stamp
        write_atomic(MIRROR_LIST, json.dumps(done, indent=1))
        print('mirror: %s -> %s, %s (%.0f s)' % (rel, nat, 'synced' if there else 'laid out',
                                                time.time() - t), flush=True)


def wsl_run(exe, args, cwd, timeout, env=()):
    """Run a LINUX program under WSL, as K.run does a Windows one: (stdout,
    stderr), with `<TIMEOUT>` appended to stderr when it was stopped. The
    kill happens INSIDE Linux (`timeout -s KILL`): killing wsl.exe from here
    does not reliably stop the process it started."""
    # an exe already spelt as a Linux path (/bin/sh) is taken as it is
    cmd = ['wsl.exe', '-d', WSL_DISTRO, '--cd', to_wsl(cwd), '--',
           'timeout', '-s', 'KILL', str(int(timeout)), 'env', 'STZ_NO_VIEW=1'] + list(env) + \
          [exe if exe.startswith('/') else to_wsl(exe)] + list(args)
    try:
        r = subprocess.run(cmd, capture_output=True, timeout=timeout + 60)
    except subprocess.TimeoutExpired as e:
        return (e.stdout or b''), (e.stderr or b'') + b'\n<TIMEOUT>'
    if r.returncode in (126, 127) and not r.stdout:
        raise SystemExit('why432 --platform=linux: %s did not run (exit %d): %s'
                         % (exe, r.returncode, r.stderr.decode('utf-8', 'replace').strip()[:200]))
    err = r.stderr
    # THE TIMEOUT FIRED: 137 from GNU's `timeout -s KILL`, and 124 from the
    # uutils coreutils this distribution ships (0.8.0), which exits 124 for
    # KILL as for TERM. Only 137 was checked until 2026-10-09, so on Linux a
    # timed-out ORACLE run was stored as a complete transcript and a timed-out
    # rnx run read as `stops quietly` -- system/auth_totp both ways. Neither
    # runtime exits 124 of its own accord.
    if r.returncode in (124, 137):
        err += b'\n<TIMEOUT>'
    return r.stdout, err


def run_oracle(fn, a_dir):
    if PLATFORM[0] == 'linux':
        return wsl_run(K.RING, [fn], a_dir, ORACLE_TIMEOUT,
                       env=['LD_LIBRARY_PATH=' + to_wsl(os.path.dirname(K.RING))])
    # on the snapshot nothing of a Ring installation is on the PATH, so a
    # library still naming ring.dll fails loudly instead of finding one (F-96)
    return K.run([K.RING, fn], a_dir, timeout=ORACLE_TIMEOUT,
                 env=K.without_ring_install() if SNAPSHOT[0] else None)


def run_rnx(fn, c_dir):
    """(stdout, stderr, hung) of rnx on one test."""
    if PLATFORM[0] == 'linux':
        if MIRROR_MAP:
            # wsl_run maps the exe; the drop script runs it after the drop
            out, err = wsl_run('/bin/sh', [to_wsl(os.path.join(MIRROR_TOOLS, 'drop_then_run.sh')),
                                           to_wsl(K.RNXC), fn], c_dir, RNX_TIMEOUT,
                               env=['RNXC_CACHE=' + to_wsl(W.CACHE)])
        else:
            out, err = wsl_run(K.RNXC, [fn], c_dir, RNX_TIMEOUT,
                               env=['RNXC_CACHE=' + to_wsl(W.CACHE)])
        hung = err.endswith(b'<TIMEOUT>')
        return out, (err[:-len(b'\n<TIMEOUT>')] if hung else err), hung
    K.clear_generated(c_dir)
    try:
        r = subprocess.run([K.RNXC, fn], cwd=c_dir, capture_output=True,
                           timeout=RNX_TIMEOUT, env=W.ENV)
        return r.stdout, r.stderr, False
    except subprocess.TimeoutExpired as e:
        return (e.stdout or b''), (e.stderr or b''), True


def build_prefix_linux():
    base = os.path.join(K.COPY, 'base')
    out, err = wsl_run(K.RNXC, ['prefix', 'stzBase.ring'], base, 1800,
                       env=['RNXC_CACHE=' + to_wsl(W.CACHE)])
    text = out.decode('utf-8', 'replace').strip()
    return ('prefix:' in text), (text.split('\n')[0] if text else err.decode('utf-8', 'replace')[:200])


def use_linux():
    global CACHE, TREE_LIST, PREFIX_TREE, COPY_LIST, REPORT, PREV, MOVED
    PLATFORM[0] = 'linux'
    CACHE = os.path.join(K.ROOT, 'runtime', 'oracle-cache-linux')
    TREE_LIST = os.path.join(CACHE, '_tree.json')
    PREFIX_TREE = os.path.join(CACHE, '_prefix_tree.txt')
    COPY_LIST = os.path.join(CACHE, '_copy_tree.json')
    REPORT = os.path.join(K.ROOT, 'runtime', 'why-linux.json')
    PREV = os.path.join(K.ROOT, 'runtime', 'why-linux-prev.json')
    MOVED = os.path.join(K.ROOT, 'runtime', 'why-linux-moved.json')
    K.RING = os.path.join(K.ROOT, 'runtime', 'linux-x64', 'ring')
    K.RNXC = os.path.join(K.ROOT, 'zig-out-linux', 'bin', 'rnxc')
    W.CACHE = os.path.join(K.ROOT, 'runtime', 'wide-cache-linux')
    W.build_prefix = build_prefix_linux
    for d in (CACHE, W.CACHE):
        os.makedirs(d, exist_ok=True)
    for what, p in (('the Linux oracle', K.RING), ('the Linux rnxc', K.RNXC),
                    ('the Linux oracle\'s tree copy', K.ORACLE_COPY_LINUX)):
        if not os.path.exists(p):
            raise SystemExit('why432 --platform=linux: no %s at %s' % (what, p))
    if WSL_MIRROR and WSL_MIRROR != '0':
        MIRROR_MAP[:] = sorted(((os.path.join(K.ROOT, *rel.split('/')), WSL_MIRROR + '/' + rel)
                                for rel in MIRRORED), key=lambda wn: -len(wn[0]))
        # a Linux program on the mirror prints the mirror's paths
        K.EXTRA_ROOTS[:] = [to_wsl(K.COPY), to_wsl(K.ORACLE_COPY_LINUX)]
        os.makedirs(MIRROR_TOOLS, exist_ok=True)
        tool = os.path.join(MIRROR_TOOLS, 'drop_then_run.sh')
        try:
            same = io.open(tool, encoding='utf-8', newline='').read() == DROP_THEN_RUN
        except OSError:
            same = False
        if not same:
            io.open(tool, 'w', encoding='utf-8', newline='\n').write(DROP_THEN_RUN)
        # the drop happens inside the run, on WSL's disk
        W.drop_images = lambda: None
        print('Linux runs read the MIRROR under %s (RPP_WSL_MIRROR=0 reads /mnt/d)' % WSL_MIRROR)

# Every shape the runtime dies in, and the list is longer than it looks.
# `Stack Overflow` / `aborting due to recursive panic` was missing from the
# first version, and 20 of the 35 rows filed as "stopped and said nothing"
# had said Stack Overflow on stderr all along -- the instrument was deaf to
# them, not the runtime silent. A classifier that does not match is
# indistinguishable from a program that does not speak.
CRASH = re.compile(r'(panic: .*|FAULT at .*|Segmentation fault.*'
                   r'|Unhandled exception.*|Stack Overflow.*'
                   r'|aborting due to recursive panic.*|thread \d+ panic.*)')
DIGITS = re.compile(r'\d+')


TREE_LIST = os.path.join(CACHE, '_tree.json')
# The tree the library PREFIX was compiled from. Without it the prefix
# survives an edit to the library and every test cold-compiles.
PREFIX_TREE = os.path.join(CACHE, '_prefix_tree.txt')
# What rnx last RAN on: the clock-copy, by content. See stamp_copy().
COPY_LIST = os.path.join(CACHE, '_copy_tree.json')


def ring_files(root):
    """(relative path, path) for every .ring and .rh under root, sorted.

    ONE walk for both trees -- Mansour's, which keys the oracle, and the
    clock-copy, which keys rnx -- so the two can never disagree about which
    files are input."""
    for dp, dn, fn in os.walk(root):
        # A file the tests WRITE is output, not input, and it must not
        # invalidate the cache the tests are measured against. The estate
        # puts all of them behind a leading dot -- the generated backend
        # hosts (base/appserver/.stzbackend_host_*.ring) and the generated
        # shells (base/test/platform/.stzapp/shells/*.ring), which is a dot
        # DIRECTORY and cost an hour of oracle time by not being covered
        # when the rule named dot FILES alone.
        dn[:] = sorted(d for d in dn if d not in K.SKIP_DIRS and not d.startswith('.'))
        for f in sorted(fn):
            if f.startswith('.'):
                continue
            if f.endswith('.ring') or f.endswith('.rh'):
                p = os.path.join(dp, f)
                yield os.path.relpath(p, root).replace(os.sep, '/'), p


def tree_files():
    """Path -> (size, mtime) for every .ring and .rh in Mansour's tree."""
    out = {}
    for rel, p in ring_files(K.LIB):
        try:
            st = os.stat(p)
        except OSError:
            continue
        out[rel] = [st.st_size, st.st_mtime_ns]
    return out


def stamp_tree(quiet=False):
    """The stamp, and -- when it has MOVED -- what moved.

    A fill that finds every transcript stale has thrown away an hour of
    oracle time, and it happened twice while this was being written: once
    to the generated backend hosts above, once to something that left no
    trace at all in the mtimes. So the list itself is kept beside the
    transcripts and the difference is NAMED, rather than the run quietly
    starting over.
    """
    if SNAPSHOT[0]:
        # what the oracle READS: the snapshot's sources and its engine, by
        # content -- a fresh copy has new mtimes and the same bytes
        return stamp_root(K.LP + (K.ORACLE_COPY_LINUX if PLATFORM[0] == 'linux'
                                  else K.ORACLE_COPY_WIN),
                          TREE_LIST, 'THE SNAPSHOT', 'every transcript is stale', quiet)
    files = tree_files()
    h = hashlib.sha256()
    for p in sorted(files):
        h.update(p.encode('utf-8', 'replace'))
        h.update(('%d %d' % tuple(files[p])).encode())
    stamp = h.hexdigest()[:16]
    prev = None
    try:
        prev = json.load(io.open(TREE_LIST, encoding='utf-8'))
    except (OSError, ValueError):
        pass
    if prev and prev.get('stamp') != stamp and not quiet:
        old = prev.get('files', {})
        added = sorted(set(files) - set(old))
        gone = sorted(set(old) - set(files))
        moved = sorted(p for p in set(files) & set(old) if files[p] != old[p])
        print('THE TREE MOVED since the last run (%s -> %s): '
              '%d added, %d gone, %d changed -- every transcript is stale.'
              % (prev.get('stamp'), stamp, len(added), len(gone), len(moved)))
        for tag, lst in (('added', added), ('gone', gone), ('changed', moved)):
            for p in lst[:6]:
                print('    %-8s %s' % (tag, p))
            if len(lst) > 6:
                print('    %-8s ... and %d more' % (tag, len(lst) - 6))
    os.makedirs(CACHE, exist_ok=True)
    write_atomic(TREE_LIST,
        json.dumps({'stamp': stamp, 'when': time.strftime('%Y-%m-%d %H:%M'),
                    'files': files}))
    return stamp


def stamp_copy(quiet=False):
    """The stamp of what RNX runs on -- the clock-copy -- and, when it has
    moved, what moved.

    Not stamp_tree(): that is MANSOUR'S tree, and rnx never reads it. rnx
    compiles the copy and loads the Ring++ engine DLLs laid out in it, so an
    edit to the copy alone -- or a rebuilt engine copied in -- changes what
    rnx answers while his tree, and therefore stamp_tree(), stands still.

    By CONTENT, where stamp_tree() uses mtimes, because make_copy() writes
    every file afresh: a re-sync that changes no byte would otherwise
    discard every row. 6,067 sources and 80 DLLs (84 MB), once per pass:
    1.1 s measured alone, 0.5-3.8 s across the passes of 2026-09-23 --
    the first read of the day is the slow one.

    What it does NOT cover, the same gap the oracle's stamp has: data files
    (.txt, .json ...) and anything a test leaves behind in the copy. Both
    are written by the tests themselves -- file/00_file answers differently
    depending on whether its own sandbox survived the last run -- so
    covering them would move the stamp on every pass and nothing would ever
    re-cut. The RULE that chose them is covered: make_copy() writes it to
    the first line of _copy_rule.txt at the copy's root, and a copy taken
    under the old extension list (no such file) stamps differently from one
    taken under the new. Only that line -- the counts under it move with
    whatever the tests last wrote into his tree.
    """
    return stamp_root(K.LP + K.COPY, COPY_LIST, 'THE COPY',
                      'no rnx row taken on the old copy is re-used', quiet)


def snapshot_disagreement():
    """The SOURCES the oracle's snapshot and rnx's clock copy hold
    differently, read off the two lists the stamps just wrote -- the engine
    DLLs differ by design (two flavours) and are left out."""
    try:
        a = json.load(io.open(TREE_LIST, encoding='utf-8')).get('files', {})
        b = json.load(io.open(COPY_LIST, encoding='utf-8')).get('files', {})
    except (OSError, ValueError):
        return []
    src = lambda d: {k: v for k, v in d.items() if k.endswith(('.ring', '.rh'))}
    a, b = src(a), src(b)
    return sorted(p for p in set(a) | set(b) if a.get(p) != b.get(p))


def stamp_root(root, list_path, label, consequence, quiet=False):
    """A tree copy's stamp by CONTENT -- its .ring/.rh sources, its copy
    rule and the engine DLLs laid out in it -- and, when it has moved, what
    moved. stamp_copy() is this for the clock copy rnx runs; on the
    SNAPSHOT (2026-10-03) stamp_tree() is this for the oracle's copy, whose
    engine is part of what the oracle answers with and was never keyed
    before."""
    files = {}
    try:
        rule = io.open(os.path.join(root, '_copy_rule.txt'),
                       encoding='utf-8').readline().strip()
    except OSError:
        rule = 'rule 1: an extension list'
    files['_copy_rule.txt'] = hashlib.sha256(rule.encode()).hexdigest()[:16]
    for rel, p in ring_files(root):
        try:
            files[rel] = hashlib.sha256(io.open(p, 'rb').read()).hexdigest()[:16]
        except OSError:
            continue
    dlls = os.path.join(root, 'engine', 'zig-out', 'bin')
    if os.path.isdir(dlls):
        for f in sorted(os.listdir(dlls)):
            if f.endswith('.dll'):
                try:
                    b = io.open(os.path.join(dlls, f), 'rb').read()
                except OSError:
                    continue
                files['engine/zig-out/bin/' + f] = hashlib.sha256(b).hexdigest()[:16]
    # On Linux the engine a run loads is engine/zig-out/lib/lib*.so. Hashed
    # there only, so a Linux rebuild of it never moves a Windows stamp.
    libs = os.path.join(root, 'engine', 'zig-out', 'lib')
    if PLATFORM[0] == 'linux' and os.path.isdir(libs):
        for f in sorted(os.listdir(libs)):
            if f.endswith('.so'):
                try:
                    b = io.open(os.path.join(libs, f), 'rb').read()
                except OSError:
                    continue
                files['engine/zig-out/lib/' + f] = hashlib.sha256(b).hexdigest()[:16]
    h = hashlib.sha256()
    for p in sorted(files):
        h.update(p.encode('utf-8', 'replace'))
        h.update(files[p].encode())
    stamp = h.hexdigest()[:16]
    prev = None
    try:
        prev = json.load(io.open(list_path, encoding='utf-8'))
    except (OSError, ValueError):
        pass
    if prev and prev.get('stamp') != stamp and not quiet:
        old = prev.get('files', {})
        added = sorted(set(files) - set(old))
        gone = sorted(set(old) - set(files))
        moved = sorted(p for p in set(files) & set(old) if files[p] != old[p])
        print('%s MOVED since the last pass (%s -> %s): %d added, %d gone, '
              '%d changed -- %s.'
              % (label, prev.get('stamp'), stamp, len(added), len(gone), len(moved), consequence))
        for tag, lst in (('added', added), ('gone', gone), ('changed', moved)):
            for p in lst[:6]:
                print('    %-8s %s' % (tag, p))
            if len(lst) > 6:
                print('    %-8s ... and %d more' % (tag, len(lst) - 6))
    os.makedirs(CACHE, exist_ok=True)
    write_atomic(list_path,
        json.dumps({'stamp': stamp, 'when': time.strftime('%Y-%m-%d %H:%M'),
                    'files': files}))
    return stamp


def rnx_run_stamp(tree, copy):
    """Everything an rnx row depends on that is the same for every test:
    the rnxc binary, Mansour's tree, the copy it ran on, and the timeout
    that decides `hangs`."""
    h = hashlib.sha256()
    for part in (rnxc_stamp(), tree, copy, str(RNX_TIMEOUT)):
        h.update(part.encode())
        h.update(b'\0')
    return h.hexdigest()[:16]


def rnx_key(run, test_path):
    """The key an rnx row is kept under: the run stamp and the test's own
    bytes, as the copy holds them."""
    h = hashlib.sha256()
    h.update(run.encode())
    try:
        h.update(io.open(test_path, 'rb').read())
    except OSError:
        h.update(b'missing')
    return h.hexdigest()[:16]


def stamp_of(path, tree):
    h = hashlib.sha256()
    h.update(tree.encode())
    # on the snapshot the test is keyed by its bytes alone (below): a re-taken
    # copy gives every file a new mtime and the same content
    for p in ((K.RING,) if SNAPSHOT[0] else (K.RING, path)):
        try:
            st = os.stat(p)
            h.update(('%d %d' % (st.st_size, st.st_mtime_ns)).encode())
        except OSError:
            h.update(b'missing')
    try:
        h.update(io.open(path, 'rb').read())
    except OSError:
        pass
    return h.hexdigest()[:16]


def cache_path(rel):
    return os.path.join(CACHE, rel.replace('/', '__') + '.json')


def cache_read(rel):
    try:
        return json.load(io.open(cache_path(rel), encoding='utf-8'))
    except (OSError, ValueError):
        return None


def write_atomic(path, text):
    """Replace `path` with `text` so that a crash leaves the OLD file or the
    NEW one, never a broken one.

    An entry here holds the ORACLE's transcript, and storing an rnx row
    rewrote it in place. On 2026-10-03 the machine stopped uncleanly
    (Kernel-Power 41) moments after an interrupted pass had written six
    entries: each was its full length of ZERO bytes -- NTFS had committed
    the size and never the data -- so six oracle transcripts, the expensive
    half, were gone, and the next pass was partial for want of them. The new
    text is flushed to the disk first and then renamed over the old, and a
    rename is journalled."""
    tmp = path + '.tmp'
    with io.open(tmp, 'w', encoding='utf-8') as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def cache_write(rel, obj):
    os.makedirs(CACHE, exist_ok=True)
    write_atomic(cache_path(rel), json.dumps(obj))


def enc(b):
    """Bytes through JSON without losing one -- latin-1 is the identity."""
    return b.decode('latin-1')


def dec(s):
    return s.encode('latin-1')


def shape(line):
    """The line with its digits blanked, so twenty tests failing the same
    assertion rank as ONE cause."""
    return DIGITS.sub('#', line.decode('utf-8', 'replace'))[:96]


def first_crash(stderr_text):
    for l in stderr_text.split('\n'):
        m = CRASH.search(l.strip())
        if m:
            return m.group(1).strip()[:90]
    return None


def dirs_of(rel):
    mod, fn = rel.rsplit('/', 1)
    if mod.startswith('@'):
        # the wide suite's max/ and core/ programs: from the library root
        sub = mod[1:].replace('/', os.sep)
    else:
        sub = os.path.join('base', 'test', mod.replace('/', os.sep))
    # the Linux oracle runs its own copy of the tree (clock34.make_oracle_copy_linux),
    # and on Windows the snapshot's (clock34.make_snapshot, F-96)
    oracle_root = (K.ORACLE_COPY_LINUX if PLATFORM[0] == 'linux' else
                   K.ORACLE_COPY_WIN if SNAPSHOT[0] else K.LIB)
    return os.path.join(oracle_root, sub), os.path.join(K.COPY, sub), fn


def classify(A, C, volatile, rnx_err, hung):
    """(cause, key, detail) for the FIRST line outside the noise floor."""
    if hung:
        return 'hangs', 'rnx still running at %d s' % RNX_TIMEOUT, ''
    n = min(len(A), len(C))
    at = None
    for i in range(n):
        if A[i] != C[i] and i not in volatile:
            at = i
            break
    if at is None:
        if len(A) == len(C):
            return None, None, ''
        at = n
    if at >= len(C):
        # rnx ran out of output first: it stopped, and the question is what
        # it said about that -- its own report line, or nothing at all.
        crash = first_crash(rnx_err)
        if crash:
            return 'crash', DIGITS.sub('#', crash), 'at %d of %d lines' % (at, len(A))
        code, detail, _ = S.classify(C)
        if code:
            return 'refused/raised', code, (detail or '')[:80]
        return 'stops quietly', 'no report at all', '%d of %d lines' % (at, len(A))
    if at >= len(A):
        return 'longer', 'kept printing after the oracle stopped', \
            '%d against %d lines' % (len(C), len(A))
    a, c = A[at], C[at]
    if a.endswith(b'[PASS]') and c.endswith(b'[FAIL]'):
        return 'assertion', shape(a), 'line %d' % (at + 1)
    return 'line differs', shape(a), 'rnx: ' + c.decode('utf-8', 'replace')[:70]


def restamp(names, tree, reason):
    """Re-stamp the cached transcripts WITHOUT re-measuring them.

    This is only ever right when the difference that invalidated them is
    known and known to be irrelevant, and IT MUST BE SAID OUT LOUD EACH
    TIME -- so the caller says it, in `--restamp=<reason>`, and it is
    printed and kept in every transcript it touches.

    IT USED TO ASSERT ONE: "the only thing that had moved was a generated
    file the stamp now excludes". That was TRUE THE FIRST TIME and became
    a fixed sentence the tool printed whatever had actually moved -- on
    2026-09-22 it said it about an edit to future/stzTextStream.ring,
    which is a different reason entirely (that file is outside the LOAD
    UNIT). A justification the instrument supplies for you is not a
    justification; it is a rubber stamp, and this one was about to be
    applied to an hour of oracle time.

    A RESTAMP NEVER REVALIDATES AN RNX ROW. It is a judgement about the
    ORACLE -- "what moved cannot change what Ring prints" -- and it is paid
    for because the oracle is the expensive side. rnx is the cheap side, so
    it is not asked to inherit the judgement: every transcript re-stamped
    here loses its rnx key and the next pass measures rnx again. When the
    TREE moved, the key would not have matched anyway, since it carries the
    tree stamp; when only the ORACLE binary moved, it would have -- and this
    line is what makes the rule hold then too.
    """
    n = 0
    for rel in names:
        a_dir, _, fn = dirs_of(rel)
        cached = cache_read(rel)
        if not cached:
            continue
        want = stamp_of(os.path.join(a_dir, fn), tree)
        if cached.get('stamp') != want:
            cached['stamp'] = want
            cached['restamped'] = time.strftime('%Y-%m-%d %H:%M')
            cached['restamp_reason'] = reason
            cached.pop('rnx_key', None)
            cache_write(rel, cached)
            n += 1
    print('re-stamped %d transcript(s) -- NOT re-measured. The reason given:'
          % n)
    print('    %s' % reason)
    if n:
        print('their rnx rows are dropped: the next pass runs rnx on those %d again'
              % n)
    return n


def run_one_per_folder(todo, jobs, folder_of, one, stopped):
    """Run `one(job)` for every job on `jobs` threads, never two jobs of
    the same folder at once.

    TESTS IN ONE FOLDER SHARE ITS FILES. The diagram and dotcode tests all
    write temp/temp.dot beside them, and three of them at once handed each
    other a file still open or half written: in ten of eleven the oracle's
    FIRST run raised "Error in parameter, NULL pointer!" in fwrite and its
    second did not, and dotcode/02's Graphviz read a half-written file --
    so why432 counted Ring as stopping early where Ring++, measured one test
    at a time, ran on (the wide fill of 2026-10-04, found 2026-10-05). The
    folder is the unit a test's relative paths are resolved in, so it is the
    unit kept apart. `stopped` is the budget flag `one` raises."""
    import threading
    cond = threading.Condition()
    busy = set()
    pending = list(todo)

    def worker():
        while True:
            with cond:
                while True:
                    if stopped[0] or not pending:
                        return
                    pick = next((k for k, j in enumerate(pending)
                                 if folder_of(j) not in busy), None)
                    if pick is not None:
                        job = pending.pop(pick)
                        busy.add(folder_of(job))
                        break
                    cond.wait()
            try:
                one(job)
            finally:
                with cond:
                    busy.discard(folder_of(job))
                    cond.notify_all()

    threads = [threading.Thread(target=worker) for _ in range(jobs)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()


def fill(names, tree, budget, jobs=1):
    """Phase one: the ORACLE, twice per test, onto disk. Nothing else.

    `--jobs=N` runs N tests' oracle pairs at once (item 8's 5,112 programs
    are ~23 hours serially). Each test's two runs stay back to back on one
    worker, so a test's noise floor is taken under one load; what N costs is
    that every timing line is taken on a busier machine than a serial fill's,
    which the floor then sets aside more often. The 432 keep jobs=1."""
    import threading
    t0 = time.time()
    todo, have = [], 0
    for i, rel in enumerate(names):
        a_dir, c_dir, fn = dirs_of(rel)
        if not os.path.exists(os.path.join(a_dir, fn)):
            continue
        want = stamp_of(os.path.join(a_dir, fn), tree)
        cached = cache_read(rel)
        if cached and cached.get('stamp') == want:
            have += 1
            continue
        todo.append((rel, a_dir, fn, want))
    lock = threading.Lock()
    took = [0]
    stopped = [False]

    def one(job):
        rel, a_dir, fn, want = job
        if budget is not None and time.time() - t0 > budget:
            stopped[0] = True
            return
        o1, e1 = run_oracle(fn, a_dir)
        o2, e2 = run_oracle(fn, a_dir)
        cache_write(rel, {'stamp': want,
                          'a1': enc(o1 + e1), 'a2': enc(o2 + e2),
                          'oracle_timeout': b'<TIMEOUT>' in e1 or b'<TIMEOUT>' in e2,
                          'when': time.strftime('%Y-%m-%d %H:%M'),
                          'jobs': jobs})
        with lock:
            took[0] += 1
            print('  %4d/%d  %-56s %5.1f s' % (have + took[0], len(names), rel[:56],
                                               time.time() - t0), flush=True)

    if jobs <= 1:
        for job in todo:
            one(job)
            if stopped[0]:
                break
    else:
        run_one_per_folder(todo, jobs, lambda job: job[1], one, stopped)
    if stopped[0]:
        print('budget spent after %.1f minutes: %d taken, %d already had one, '
              '%d still to take' % ((time.time() - t0) / 60, took[0], have, len(todo) - took[0]))
    else:
        print('fill complete: %d taken this run, %d already had one, %.1f minutes'
              % (took[0], have, (time.time() - t0) / 60))
    # A TEST CAN MOVE THE TREE WHILE THE FILL RUNS. gg_color_c5 rewrites a
    # TRACKED file, base/test/graphics/theme_pro.ring, on every run, and the
    # first run after the library's theme changed moved the stamp in the
    # middle of the 2026-09-29 fill -- seen only at the NEXT command, which
    # found every transcript stale and began taking all 5,112 again, and
    # whose own report of what moved went unread. Stamped once more here,
    # against the list written at this fill's start, stamp_tree() names what
    # moved while it is still this fill's news.
    if stamp_tree() != tree:
        print('THE TREE MOVED DURING THIS FILL. Its transcripts are keyed on the '
              'stamp from its start, %s: decide from the list above between '
              '--restamp=<reason> and a refill.' % tree)
    else:
        print('the tree did not move during the fill (stamp %s at both ends)' % tree)
    return took[0]


def rnxc_stamp():
    st = os.stat(K.RNXC)
    return '%d-%d' % (st.st_size, st.st_mtime_ns)


FRAME_LINE = re.compile(rb'^(Called from line |Line )(\d+)( .*)$')
SOURCE_LINES = {}


def source_line(rest, n, rel):
    """Line n of the file a trace line names (`... in file F`), read from
    the clock copy -- the same sources as the oracle's snapshot -- or None."""
    i = rest.rfind(b' in file ')
    if i < 0:
        return None
    name = rest[i + len(b' in file '):].strip().decode('utf-8', 'replace')
    if name.startswith('<stzlib>'):
        path = K.COPY + name[len('<stzlib>'):]
    elif os.path.isabs(name):
        path = name
    else:
        path = os.path.join(dirs_of(rel)[1], name)
    path = os.path.normpath(path.replace('/', os.sep).replace(chr(92), os.sep))
    if path not in SOURCE_LINES:
        try:
            SOURCE_LINES[path] = io.open(path, encoding='utf-8', errors='replace').read().split('\n')
        except OSError:
            SOURCE_LINES[path] = None
    src = SOURCE_LINES[path]
    return src[n - 1] if src and 0 < n <= len(src) else None


def decided_line(a, c, rel):
    """'C-26' or 'C-27' when a differing pair of lines is a divergence
    docs/CORRECTIONS.md DECIDED, else None (2026-10-13, at Mansour's word).

      C-26  a trace frame that differs in its FILE alone: Ring names the
            caller's current file once a call site has run before (F-112)
      C-27  the same frame or error line, Ring's line number an `if`, `but`
            or `elseif` whose condition holds an `or`, Ring++'s a later line
            (F-113: a true left side jumps past the body's line marker)

    Narrow on purpose: anything else that differs keeps the row where it
    was, so a decided label can never hide a defect of another shape."""
    # both sides must END in a file name: on Linux the oracle prints glibc's
    # `corrupted size vs. prev_size ...` after its last frame (F-86), which a
    # test on the header alone read as a file that differed
    ia, ic = a.rfind(b' in file '), c.rfind(b' in file ')
    if ia >= 0 and ic >= 0 and a[:ia] == c[:ic] and a[ia:] != c[ic:] and \
            a.rstrip().lower().endswith(b'.ring') and c.rstrip().lower().endswith(b'.ring'):
        return 'C-26'
    ma, mc = FRAME_LINE.match(a), FRAME_LINE.match(c)
    if ma and mc and ma.group(1) == mc.group(1) and ma.group(3) == mc.group(3):
        ra, rc = int(ma.group(2)), int(mc.group(2))
        if rc > ra:
            src = source_line(ma.group(3), ra, rel)
            if src is not None:
                t = ' ' + src.strip().lower() + ' '
                words = t.split()
                if words and words[0] in ('if', 'but', 'elseif') and (' or ' in t or '||' in t):
                    return 'C-27'
    return None


def decided(A, C, volatile, rel):
    """The corrections that account for EVERY line of a row outside the
    noise floor, or None when any line is something else."""
    if len(A) != len(C):
        return None
    tags = set()
    for i, (x, z) in enumerate(zip(A, C)):
        if x != z and i not in volatile:
            d = decided_line(x, z, rel)
            if d is None:
                return None
            tags.add(d)
    return tags or None


def recut(rel, cached, A, C, volatile, stale):
    """The row, built from what was kept. Called both after a run of rnx
    and, later, instead of one."""
    if cached.get('oracle_timeout'):
        cause, key, detail = 'oracle timed out', 'measures nothing, counted apart', ''
    else:
        cause, key, detail = classify(A, C, volatile,
                                      dec(cached.get('e', '')).decode('utf-8', 'replace'),
                                      cached.get('hung', False))
        # A row whose every differing line is a decided divergence is not
        # open work: it is counted apart, never as agreeing.
        if cause == 'line differs':
            tags = decided(A, C, volatile, rel)
            if tags:
                cause, key = 'decided', ', '.join(sorted(tags))
                detail = 'every differing line is ' + key + ' (docs/CORRECTIONS.md)'
    # How many lines differ, not only the first. `Executed in N second(s)`
    # is the whole difference in sixteen tests and the first-divergence view
    # cannot say so; a test that differs on ONE measurement line is a
    # different fact from one that differs on eighty.
    ndiff = sum(1 for i, (x, z) in enumerate(zip(A, C)) if x != z and i not in volatile)
    ndiff += abs(len(A) - len(C))
    return {'rel': rel, 'cause': cause or 'same', 'key': key or '', 'detail': detail,
            'ring_lines': len(A), 'rnx_lines': len(C), 'volatile': len(volatile),
            'ndiff': ndiff, 'stale': stale}


# How many times this process actually ran rnx -- the readout that says
# whether a pass re-cut or re-measured. It used to be inferred from how long
# a row took (> 0.05 s), which a re-cut of a large transcript can exceed.
RNX_RAN = [0]


# THE ENGINE'S "not found" WARNINGS ARE DROPPED ON BOTH SIDES (2026-09-28).
# They were dropped on rnx's side only, from the days the Ring++ engine
# lacked domains the oracle had; no Windows oracle transcript carries one
# (475 checked), so that asymmetry never showed -- until Linux, where the
# loaders print the same two warnings on BOTH runtimes (the curl domains)
# and the rows slid out of alignment by two lines.
def measure(rel, tree, stale_ok, allow_rnx=True, run=None):
    """One row, from the cached oracle and one run of rnx.

    rnx's two streams are cached beside the oracle's, so that the ranking
    can be re-cut, re-grouped and re-read without running anything -- a
    change to the CLASSIFIER then costs seconds -- and so a pass can be
    taken in chunks like the fill.

    THE RE-CUT NEVER RAN, from the day it was written until 2026-09-23. It
    asked for `cached['row']`, and nothing ever wrote that key, so every
    pass re-measured rnx on every test. That was the SAFE side of the
    defect, and the reason it is not fixed by writing the key: the row was
    keyed on the rnxc binary ALONE, so a re-cut would have re-used rnx
    output taken on an OLD library after Mansour edited his tree -- which
    happened that same day, with stzNetCalibrate.ring, and only the dead
    branch kept the pass honest.

    So the streams are kept under rnx_key(): the rnxc binary, Mansour's
    tree stamp, the COPY rnx actually ran on (by content, engine DLLs
    included -- stamp_copy()), the timeout, and the test's own bytes. Any
    one of them moving means rnx runs again. `run` is that key without the
    test; a caller that passes none never re-cuts.
    """
    a_dir, c_dir, fn = dirs_of(rel)
    blank = {'rel': rel, 'key': '', 'detail': '', 'ring_lines': 0, 'rnx_lines': 0,
             'volatile': 0, 'stale': False}
    if not os.path.exists(os.path.join(c_dir, fn)):
        return dict(blank, cause='not in the copy')
    cached = cache_read(rel)
    if not cached:
        return None
    stale = cached.get('stamp') != stamp_of(os.path.join(a_dir, fn), tree)
    if stale and not stale_ok:
        return None
    key = rnx_key(run, os.path.join(c_dir, fn)) if run else None
    if key and not RERUN[0] and cached.get('rnx_key') == key and 'c' in cached and 'e' in cached:
        # Re-cut from what was kept, so a change to the CLASSIFIER costs
        # nothing: this is how Stack Overflow stopped being filed as silence.
        A, B = K.lines(dec(cached['a1']), drop_warnings=True), K.lines(dec(cached['a2']), drop_warnings=True)
        vol = {i for i, (x, y) in enumerate(zip(A, B)) if x != y}
        if len(A) != len(B):
            vol |= set(range(min(len(A), len(B)), max(len(A), len(B))))
        C = K.lines(dec(cached['c']), drop_warnings=True)
        return recut(rel, cached, A, C, vol, stale)
    if cached.get('oracle_timeout'):
        # The oracle did not finish, so there is nothing to be compared
        # against and running rnx would only spend the clock.
        return dict(blank, cause='oracle timed out', stale=stale,
                    key='measures nothing, counted apart')
    if not allow_rnx:
        return None

    A, B = K.lines(dec(cached['a1']), drop_warnings=True), K.lines(dec(cached['a2']), drop_warnings=True)
    volatile = {i for i, (x, y) in enumerate(zip(A, B)) if x != y}
    if len(A) != len(B):
        volatile |= set(range(min(len(A), len(B)), max(len(A), len(B))))

    # 432 images at 40 MB each is 17 GB. clockall drops them as it goes and
    # so does this; an ad-hoc scan of mine that did not left 16 GB behind.
    W.drop_images()
    RNX_RAN[0] += 1
    out, err, hung = run_rnx(fn, c_dir)
    C = K.lines(out, drop_warnings=True)

    # BOTH streams are kept: rnx's own voice is on stderr, and the census
    # can only be re-cut without re-running if what it read is still here.
    cached['c'] = enc(out)
    cached['e'] = enc(err)
    cached['hung'] = hung
    row = recut(rel, cached, A, C, volatile, stale)
    cached.pop('row_rnxc', None)     # the old key, rnxc alone -- never enough
    if key:
        cached['rnx_key'] = key
    else:
        cached.pop('rnx_key', None)
    cache_write(rel, cached)
    return row


PREV = os.path.join(K.ROOT, 'runtime', 'why432-prev.json')
MOVED = os.path.join(K.ROOT, 'runtime', 'why432-moved.json')


def diff_against_previous(rows, keep=True):
    """What moved since the last pass, per test, both ways.

    `keep=False` is a PARTIAL pass -- a name filter, or a budget that
    stopped rnx -- and it compares without writing. Written, a partial
    table would become the before-table of the next full pass, which would
    then report the missing rows as "new to the list" and could attribute
    none of their moves. That was harmless while every pass re-ran all of
    rnx anyway; with the re-cut working, a pass taken in chunks is the
    normal case.

    THE PASS USED TO OVERWRITE ITS OWN BEFORE-TABLE, so every report could
    say how many tests agreed and none could say WHICH -- twice in two days
    a fix was reported with "+2, and the row-by-row comparison is not
    available". The previous table is kept now and the delta is printed
    here, which is the only form in which a move can be attributed at all.

    AND IT IS WRITTEN TO A FILE, not only to stdout, because printing it
    is not keeping it: a pass whose output was read from the tail lost
    three of five row names, and by then both tables were the new one and
    the comparison could not be taken again (2026-09-22). The delta is
    the perishable half of this instrument -- the tables are rewritten
    every pass -- so it goes on disk first and is echoed second.

    A 432-row measurement moves by a few rows between runs of the SAME
    build, so this is evidence and not a verdict: read it with that.
    """
    old = {}
    if os.path.exists(PREV):
        try:
            for r in json.loads(io.open(PREV, encoding='utf-8').read()):
                old[r['rel']] = r
        except Exception as e:
            print('note: the previous table could not be read (%s)' % e)
    now = {r['rel']: r for r in rows}
    if not old:
        print('no previous table to compare against; this pass becomes one')
    else:
        moves = [(rel, old[rel]['cause'], now[rel]['cause'])
                 for rel in sorted(now)
                 if rel in old and old[rel]['cause'] != now[rel]['cause']]
        print()
        if not moves:
            print('=== NOTHING MOVED since the last pass (%d test(s) compared) ==='
                  % len(old))
        else:
            print('=== WHAT MOVED since the last pass, %d of %d test(s) ==='
                  % (len(moves), len(old)))
            gained = [m for m in moves if m[2] == 'same']
            lost = [m for m in moves if m[1] == 'same']
            for rel, a, b in moves:
                mark = '  ->' if b == 'same' else ('  <-' if a == 'same' else '    ')
                print('%s %-46s %s -> %s' % (mark, rel.replace('_narrated.ring', ''), a, b))
            print('    %d newly AGREE, %d stopped agreeing' % (len(gained), len(lost)))
        only_now = [r for r in now if r not in old]
        only_old = [r for r in old if r not in now]
        if only_now or only_old:
            print('    (%d test(s) new to the list, %d gone from it)'
                  % (len(only_now), len(only_old)))
        # ON DISK BEFORE IT IS ON THE SCREEN. With each side's LINE, not only
        # its cause: the previous table becomes this one the moment the pass
        # ends, so a row that moved could be named but not explained, and two
        # passes in a row (2026-10-09/10) were attributed by re-running the
        # movers on the build before. The line that differed is the evidence.
        if keep:
            try:
                write_atomic(MOVED, json.dumps(
                    [dict(test=rel, was=a, now=b,
                          was_detail=old[rel].get('detail', ''), now_detail=now[rel].get('detail', ''))
                     for rel, a, b in moves],
                    indent=1))
            except Exception as e:
                print('note: could not keep the delta (%s)' % e)
    if not keep:
        print('a PARTIAL pass: the previous table, the delta and the report '
              'are NOT rewritten')
        return False
    # The table just measured becomes the one the NEXT pass compares to.
    try:
        write_atomic(PREV, json.dumps(rows, indent=1))
    except Exception as e:
        print('note: could not keep this table for next time (%s)' % e)
    return True


def report(rows, no_transcript):
    done = [r for r in rows if r['cause'] != 'same']
    print()
    print('%d measured, %d agree on every line the oracle reproduces'
          % (len(rows), len(rows) - len(done)))
    nd = sum(1 for r in done if r['cause'] == 'decided')
    if nd:
        print('%d more differ ONLY by a divergence docs/CORRECTIONS.md decided (C-26, C-27) '
              '-- counted apart, not as agreeing' % nd)
    if no_transcript:
        print('%d have NO usable transcript -- `python bench/why432.py --fill`'
              % no_transcript)
    stale = [r for r in done if r.get('stale')]
    if stale:
        print('%d row(s) USED A STALE TRANSCRIPT (--stale-ok): the tree moved under them'
              % len(stale))
    print()
    print('=== what holds them, by cause ===')
    for cause, n in collections.Counter(r['cause'] for r in done).most_common():
        print('  %4d  %s' % (n, cause))
    one = [r for r in done if r.get('ndiff') == 1]
    if one:
        print()
        print('  of those, %d differ on exactly ONE line -- the smallest gap there '
              'is' % len(one))

    groups = collections.defaultdict(list)
    for r in done:
        groups[(r['cause'], r['key'])].append(r)
    ranked = sorted(groups.items(), key=lambda kv: -len(kv[1]))
    print()
    print('=== and by the LINE, digits blanked, so one cause reads as one ===')
    shown = 0
    for (cause, key), items in ranked:
        if len(items) < 2 or shown >= 30:
            continue
        shown += 1
        print('  %4d  %-15s %s' % (len(items), cause, key[:72]))
        for r in items[:3]:
            print('              %s' % r['rel'])
        if len(items) > 3:
            print('              ... and %d more' % (len(items) - 3))
    print()
    print('%d cause(s) are held by exactly ONE test. The full table is %s'
          % (sum(1 for kv in ranked if len(kv[1]) == 1), os.path.relpath(REPORT, K.ROOT)))


def main():
    # A ROW IS PRINTED IN THE CONSOLE'S CODE PAGE when stdout is redirected,
    # and a test line holding a character outside it (U+10481, an Osmanya
    # letter, on 2026-10-01) raised UnicodeEncodeError and ended a wide pass
    # a minute in. Printing a measurement must never stop one.
    for st in (sys.stdout, sys.stderr):
        try:
            st.reconfigure(errors='backslashreplace')
        except (AttributeError, ValueError):
            pass
    flags = [a for a in sys.argv[1:] if a.startswith('--')]
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    stale_ok = '--stale-ok' in flags
    RERUN[0] = '--rerun' in flags
    budget = None
    jobs = 1
    wide = False
    for f in flags:
        if f.startswith('--budget='):
            budget = float(f.split('=', 1)[1])
        if f.startswith('--jobs='):
            jobs = max(1, int(f.split('=', 1)[1]))
        if f == '--suite=wide':
            wide = True
    if '--platform=linux' in flags:
        use_linux()
        if '--his-tree' not in flags and linux_copy_is_snapshot():
            use_snapshot()
            print('the Linux oracle runs the SNAPSHOT at %s (clock34 --linux-snapshot; '
                  '--his-tree for a copy of his tree)'
                  % os.path.relpath(K.ORACLE_COPY_LINUX, K.ROOT))
        elif '--his-tree' not in flags:
            print('NOTE: the Linux oracle\'s copy was not taken from the snapshot -- '
                  '`python bench/clock34.py --linux-snapshot` takes it')
    if (PLATFORM[0] == 'windows' and '--his-tree' not in flags
            and os.path.isdir(K.LP + K.ORACLE_COPY_WIN)):
        use_snapshot()
        print('the oracle runs the SNAPSHOT at %s, its engine built from that copy '
              '(F-96; --his-tree for his tree and his zig-out)'
              % os.path.relpath(K.ORACLE_COPY_WIN, K.ROOT))
    if wide:
        # the wide suite keeps its OWN tables, so the 432's before-table is
        # never overwritten by a pass over a different set of tests
        global REPORT, PREV, MOVED
        tag = 'linux-wide' if PLATFORM[0] == 'linux' else 'wide'
        REPORT = os.path.join(K.ROOT, 'runtime', 'why-%s.json' % tag)
        PREV = os.path.join(K.ROOT, 'runtime', 'why-%s-prev.json' % tag)
        MOVED = os.path.join(K.ROOT, 'runtime', 'why-%s-moved.json' % tag)

    if not os.path.isdir(K.LIB):
        print('SKIP why432: no Softanza tree at ' + K.LIB)
        return 0
    if not os.path.isdir(K.ENGINE_DLLS):
        print('SKIP why432: no Ring++ engine DLLs -- run `python bench/engine_copy.py`')
        return 0
    the_list = W.LIST_WIDE if wide else W.LIST
    if not os.path.exists(the_list):
        print('no list yet -- run `python bench/clockall.py --discover%s` first'
              % (' --wide' if wide else ''))
        return 1
    names = [l.strip() for l in io.open(the_list, encoding='utf-8') if l.strip()]
    names = [n for n in names if not args or any(a in n for a in args)]

    t = time.time()
    tree = stamp_tree()
    print('%d test(s); tree stamp %s, taken in %.2f s' % (len(names), tree, time.time() - t))
    if MIRROR_MAP:
        # what the ORACLE reads, on WSL's own disk
        sync_mirror([('runtime/oracle-copy-linux', tree + '/' + rule_mtime(K.ORACLE_COPY_LINUX)),
                     ('runtime/linux-x64', listing_stamp('runtime/linux-x64')),
                     ('runtime/libraries', listing_stamp('runtime/libraries')),
                     ('runtime/extensions', listing_stamp('runtime/extensions')),
                     ('runtime/softanza', listing_stamp('runtime/softanza'))])

    if any(f == '--restamp' or f.startswith('--restamp=') for f in flags):
        why = ''
        for f in flags:
            if f.startswith('--restamp='):
                why = f.split('=', 1)[1].strip()
        if not why:
            print('--restamp needs a REASON: --restamp="why these '
                  'transcripts are still valid". Nothing was re-stamped.')
            return 1
        restamp(names, tree, why)
        return 0

    if '--fill' in flags:
        print('filling the oracle cache: TWO runs per test at ~8 s, and nothing '
              'else runs.')
        fill(names, tree, budget, jobs)
        return 0

    if not os.path.isdir(K.LP + K.COPY):
        if SNAPSHOT[0]:
            print('the snapshot has no clock copy -- re-take BOTH: '
                  '`python bench/clock34.py --snapshot`')
            return 1
        K.make_copy()
    copy = None
    if MIRROR_MAP:
        # what RNX reads, on WSL's own disk; the stamp is taken here so the
        # mirror is synced before the prefix is built from it
        t = time.time()
        copy = stamp_copy()
        copy_took = time.time() - t
        sync_mirror([('runtime/clock-copy', copy + '/' + rule_mtime(K.COPY)),
                     ('zig-out-linux', listing_stamp('zig-out-linux')),
                     ('runtime/linux-mirror-tools', listing_stamp('runtime/linux-mirror-tools'))])
        subprocess.run(['wsl.exe', '-d', WSL_DISTRO, '--exec', 'mkdir', '-p', to_wsl(W.CACHE)])
    # The prefix is what makes the rnx side ~0.5 s. Build it only when it is
    # absent, older than rnxc, or BUILT FROM A DIFFERENT TREE.
    #
    # THAT LAST TEST WAS MISSING and it cost an hour. The prefix is the
    # LIBRARY compiled; when the library changes it is stale, and nothing
    # looked at the library. Five files were edited in Mansour's tree on
    # 2026-09-22, the check saw an rnxc no newer than the prefix, reused
    # it -- and every one of the 432 tests then missed its compiled image
    # and cold-compiled 613 files. rnx took 66.5 minutes instead of 8.
    #
    # The SCORE is what makes it worth a guard rather than a note: a cold
    # process samples timing differently, which this project already
    # knows (frame_profiler and seams PASS warm and FAIL cold), so 17
    # rows moved backwards and 18 forwards and the headline read the
    # same. A pass that is merely slow is a nuisance; one that churns a
    # third of its rows for a reason outside the change is a wrong
    # measurement, and it looks exactly like a real one.
    #
    # The tree stamp already exists -- it is what keys the oracle
    # transcripts -- so this is the same fact asked a second time.
    #
    # AND THE COPY'S, since 2026-10-15. The prefix is compiled from the CLOCK
    # COPY, and on the snapshot the tree stamp is the snapshot's: three lines
    # edited in the copy alone (the viewer switch) left the stamp where it was,
    # the old prefix was reused, rnxc's own manifest refused it, and every test
    # cold-compiled -- 32 dotcode tests in 5.9 minutes. Named on 2026-09-23 as
    # "slow, never wrong"; on a wide pass slow is twelve hours.
    t = time.time()
    if copy is None:
        copy = stamp_copy()
        copy_took = time.time() - t
    prefix_key = tree + ' copy ' + copy
    pref = [f for f in os.listdir(W.CACHE) if f.endswith('.rnxp')] \
        if os.path.isdir(W.CACHE) else []
    newest = max([os.path.getmtime(os.path.join(W.CACHE, f)) for f in pref], default=0)
    built_from = ''
    try:
        built_from = io.open(PREFIX_TREE, encoding='utf-8').read().strip()
    except OSError:
        pass
    # On the mirror the prefix sits on WSL's disk, out of this listing's
    # sight, so it is built once per invocation -- seconds, natively.
    if MIRROR_MAP or not pref or os.path.getmtime(K.RNXC) > newest or built_from != prefix_key:
        ok, note = W.build_prefix()
        if not ok:
            print('SKIP why432: could not build the library prefix (%s)' % note)
            return 0
        print(note)
        try:
            write_atomic(PREFIX_TREE, prefix_key)
        except OSError as ex:
            print('note: could not record the prefix tree stamp (%s)' % ex)
    else:
        print('prefix: reused (%s), same rnxc, same tree and same copy (%s)'
              % (pref[0], prefix_key))

    # What every rnx row is keyed on, taken ONCE (above, for the prefix): the
    # copy is ~6,000 sources and 80 DLLs by content, about a second.
    run = rnx_run_stamp(tree, copy)
    print('rnx rows keyed on: rnxc %s, tree %s, copy %s (%.1f s) -> %s'
          % (rnxc_stamp(), tree, copy, copy_took, run))
    if SNAPSHOT[0]:
        apart = snapshot_disagreement()
        if apart:
            # Not a refusal: the tests WRITE .ring files into the copy they
            # run on (theme_pro.ring, every gg_color_c5 run), so the two can
            # part legitimately. Named, so a re-sync of one copy alone shows.
            print('NOTE: the two copies hold %d source(s) that differ, e.g. %s -- '
                  'if that is not a file the tests write, re-take the snapshot '
                  '(`python bench/clock34.py --snapshot`)' % (len(apart), ', '.join(apart[:3])))

    rows, no_transcript, no_row = [], 0, 0
    t0 = time.time()
    for rel in names:
        allow = budget is None or time.time() - t0 < budget
        row = measure(rel, tree, stale_ok, allow_rnx=allow, run=run)
        if row is None:
            if allow:
                no_transcript += 1
            else:
                no_row += 1
            continue
        rows.append(row)
        if row['cause'] != 'same':
            print('%-52s %-15s %s' % (row['rel'][:52], row['cause'], row['key'][:46]),
                  flush=True)
    # A table missing rows must not become anyone's before-table.
    partial = [why for why, n in (('a name filter', len(args)),
                                  ('the budget stopped rnx', no_row),
                                  ('tests without a usable transcript', no_transcript))
               if n]
    if diff_against_previous(rows, keep=not partial):
        write_atomic(REPORT, json.dumps(rows, indent=1))
    else:
        print('    (partial because of %s)' % ', '.join(partial))
    print()
    dt = time.time() - t0
    ran = RNX_RAN[0]
    print('rnx ran %d test(s) in %s; %d row(s) came back from the cache' % (
        ran, '%.1f minutes' % (dt / 60) if dt > 90 else '%.1f seconds' % dt,
        len(rows) - ran))
    if no_row:
        print('%d test(s) NOT RUN -- the budget stopped it; run again to continue'
              % no_row)
    report(rows, no_transcript)
    return 0


if __name__ == '__main__':
    sys.exit(main())
