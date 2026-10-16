r"""The clock: how many of Softanza's assertion-bearing tests does Ring++
answer exactly as Ring does?

    python bench/clock34.py              all of them
    python bench/clock34.py perf         only tests whose name matches

WHY THIS IS NOT A PLAIN DIFF. Nine of these tests print measurements --
`rss = 136.53 MB`, `ElapsedMs() = 7.42`, `measured rate = 235808.02
events/s`, `checkout: total 60.17 ms`. Two runs of RING AGAINST ITSELF
disagree on those lines, so comparing them to Ring++ measures the clock,
not the compiler. F-57 taught this project the lesson the expensive way:
30 of 37 "divergences" were the oracle disagreeing with itself.

So the noise floor comes first, per test:

    the oracle runs TWICE       -> lines that differ between those two runs
                                   are VOLATILE, and named in the report
    rnx runs once               -> compared to the oracle's first run,
                                   ignoring exactly those line positions

A test whose stable content matches is IDENTICAL ON STABLE CONTENT; the
count of those, and the count that match on EVERY line, are both reported,
because they answer different questions and only one of them is the
compatibility claim.

WHAT IT NEEDS, and it says so rather than skipping quietly:
  * Mansour's tree (the tests, and his engine build) -- the oracle runs
    there, since Ring cannot load a DLL built for Ring++;
  * a sources copy of that tree with the Ring++ engine DLLs in place --
    `python bench/engine_copy.py` builds the DLLs, `--copy` here lays the
    sources out beside them. rnx runs there.
Both paths are normalised to <stzlib> before comparing: the same file
under two roots is the same file.
"""
import io, os, re, shutil, stat, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
LIB = r'D:\GitHub\stzlib\libraries\stzlib'
COPY = os.path.join(ROOT, 'runtime', 'clock-copy', 'libraries', 'stzlib')
ENGINE_DLLS = os.path.join(ROOT, 'runtime', 'engine-copy', 'zig-out', 'bin')
RING = os.environ.get('RING') or os.path.join(ROOT, 'runtime', 'win64', 'ring.exe')
# RNXC=<path> measures another build, as RING= does for the oracle: an rnxc
# installed under its own prefix (`zig build -p zig-out-bis`) carries the
# same load/ layout, so it compiles the same unit -- which a bare COPY of
# the binary does not. Used when zig-out/bin is another session's instrument.
RNXC = os.environ.get('RNXC') or os.path.join(ROOT, 'zig-out', 'bin', 'rnxc.exe')
TESTS = 'base/test'

# NO VIEWER (2026-10-15, at Mansour's word). The diagram, dotcode, orgchart, graph and graphics tests call View() and Show(),
# and every one opened its generated SVG in his browser -- a tab a test, dozens in a pass, while he worked. Softanza honours
# STZ_NO_VIEW since then (stzSystemCall.OpenFile, stzCanvas.Show, stzScene.Show: the file is written, not opened), and every
# process this harness starts inherits it from here. It changes no output: the guard prints nothing, on all three runtimes.
os.environ['STZ_NO_VIEW'] = '1'

# What a test generates beside itself, named by the clock so that every run ADDS one: 4,538 files (29 MB) had piled up in
# 24 folders by 2026-10-15. Cleared before each run, so a folder keeps the last run's sample only.
GENERATED = re.compile(r'^(diagram_[0-9.]+|stzcanvas_show|stzscene_show)\.\w+$', re.I)


def clear_generated(test_dir):
    """Remove what earlier runs generated in a test's folder and its output/. Only inside this harness's own copies under
    runtime/ -- his tree is never cleaned from here (524 of its files are tracked). Safe beside the parallel fill because
    run_one_per_folder never lets a folder be busy twice, and no test reads its output folder (grepped)."""
    if not os.path.abspath(test_dir).lower().startswith(os.path.join(ROOT, 'runtime').lower() + os.sep):
        return
    for d in (test_dir, os.path.join(test_dir, 'output')):
        try:
            names = os.listdir(d)
        except OSError:
            continue
        for f in names:
            if GENERATED.match(f):
                try:
                    os.remove(os.path.join(d, f))
                except OSError:
                    pass

# The assertion-bearing files: those whose output carries a verdict marker.
# Recorded here rather than rediscovered, so the clock always means the
# same 34 files (2026-09-09; `--discover` re-derives it).
THE_34 = """_smoke/test_load_base.ring
app/02_stzapp_body_narrated.ring app/04_stzapp_pursue_narrated.ring
app/05_stzapp_live_narrated.ring app/06_stzsuperapp_narrated.ring
common/hostile_globals_narrated.ring common/log_narrated.ring
common/slice_primitives_narrated.ring extincode/51_extincode_narrated.ring
list/02_haspath.ring perf/driven_load_narrated.ring
perf/engine_senses_narrated.ring perf/frame_profiler_narrated.ring
perf/governed_loop_narrated.ring perf/judgment_narrated.ring
perf/labels_narrated.ring perf/log_trace_narrated.ring
perf/metrics_monitor_narrated.ring perf/profile_narrated.ring
perf/seams_narrated.ring perf/stopwatch_narrated.ring
perf/tracing_tail_narrated.ring reactive/52_reactive_polling_narrated.ring
reactive/53_engine_time_narrated.ring reactive/54_cancel_narrated.ring
reactive/55_reactor_narrated.ring reactive/56_reactor_core_narrated.ring
reactive/57_reactor_async_tcp_narrated.ring reactive/58_reactor_pool_narrated.ring
reactive/59_reactor_server_narrated.ring reactive/60_reaxis_on_reactor_narrated.ring
reactive/61_reactor_spawn_narrated.ring reactive/62_reactive_timer_surface_narrated.ring
reactive/62_reactor_https_narrated.ring""".split()

SKIP_DIRS = {'zig-out', '.git', '.zig-cache', 'node_modules', '__pycache__', 'vendor'}
LP = chr(92) * 2 + '?' + chr(92)


def _force_rm(func, path, _exc):
    """rmtree cannot unlink a READ-ONLY file on Windows, and the tests
    write some: system/_deploy_scratch/bare.git is a real git object
    store and every object in it is read-only by design. The re-sync
    then died with PermissionError and copied nothing -- found
    2026-09-22, the first time the tree had to be re-copied after being
    EDITED. Clear the bit and retry; anything still unremovable is left
    behind, and the copy over the top is what the next run reads."""
    try:
        os.chmod(path, stat.S_IWRITE)
        func(path)
    except OSError:
        pass


# rule 3, 2026-09-26: 256 MB. The neural tests read .gguf models from
# models/, and stzNeuralModel takes "the first *.gguf found" there -- so the
# 138 MB smollm2 model the 64 MB cap left out made rnx read a different
# directory from the oracle. Nothing in the tree is larger.
#
# rule 4, 2026-09-27: ...and the engine build's artifacts that are NOT Ring
# extensions. zig-out is skipped (the Ring-bound DLLs are replaced by the
# Ring++ builds below), and with it went stz.wasm -- the WASM edge, no Ring
# API in it -- which system/wasm checks for on disk. Its own `zig build
# wasm` fails on BOTH runtimes; the oracle then finds the artifact of
# 2026-09-15 in Mansour's zig-out and rnx found none, so the one line that
# differed was the harness's. The .exe tools ride along for the same reason.
COPY_RULE = 'rule 4: every file under 256 MB, and the engine build\'s non-Ring artifacts (.wasm, .exe)'
MAX_COPY = 256 * 1024 * 1024
NON_RING_ARTIFACTS = ('.wasm', '.exe')


def make_copy():
    """A copy of the tree with the Ring++ engine DLLs in place.

    EVERY FILE, not a list of extensions. The first rule copied .ring, .rh
    and nine data extensions under 512 KB, and the tests read fixtures of
    FORTY other kinds -- agentic/agentfile's three .pia agents, the .stz*
    data formats, .pem certificates, .db, .wav, .ttf, and the 6.6 MB
    _data/bigtext.txt the size cap dropped. The oracle runs Mansour's tree
    and sees them all, so every such test compared two different INPUTS:
    `the folder admitted the valid files` failed on rnx because the folder
    held one file where the oracle's held four. 64 MB leaves out the model
    weights under models/ and nothing a test reads; what it leaves out is
    printed. The rule is written into the copy, so stamp_copy() moves when
    it changes and no rnx row taken under the old rule is re-used."""
    if os.path.exists(LP + COPY):
        shutil.rmtree(LP + COPY, onexc=_force_rm)
    n = 0
    nbytes = 0
    left = []
    for dirpath, dirs, names in os.walk(LP + LIB):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        rel = os.path.relpath(dirpath, LP + LIB)
        out = os.path.join(LP + COPY, rel) if rel != '.' else LP + COPY
        os.makedirs(out, exist_ok=True)
        for f in names:
            src = os.path.join(dirpath, f)
            try:
                size = os.path.getsize(src)
                if size > MAX_COPY:
                    left.append((os.path.join(rel, f), size))
                    continue
                shutil.copyfile(src, os.path.join(out, f))
                n += 1
                nbytes += size
            except OSError:
                pass
    for p, size in left:
        print('copy: left out %s (%.0f MB, over the %d MB cap)'
              % (p, size / 1e6, MAX_COPY // (1024 * 1024)))
    io.open(os.path.join(LP + COPY, '_copy_rule.txt'), 'w', encoding='utf-8',
            newline='\n').write('%s\n%d files, %d bytes, %d left out\n'
                                % (COPY_RULE, n, nbytes, len(left)))
    dst = os.path.join(LP + COPY, 'engine', 'zig-out', 'bin')
    os.makedirs(dst, exist_ok=True)
    m = 0
    if os.path.isdir(ENGINE_DLLS):
        for f in os.listdir(ENGINE_DLLS):
            if f.endswith('.dll'):
                shutil.copyfile(os.path.join(ENGINE_DLLS, f), os.path.join(dst, f))
                m += 1
    copy_linux_libs()
    k = 0
    his_bin = os.path.join(LP + LIB, 'engine', 'zig-out', 'bin')
    if os.path.isdir(his_bin):
        for f in os.listdir(his_bin):
            if f.lower().endswith(NON_RING_ARTIFACTS):
                shutil.copyfile(os.path.join(his_bin, f), os.path.join(dst, f))
                k += 1
    print('copy: %d source files, %d Ring++ engine DLLs, %d non-Ring engine artifacts' % (n, m, k))
    mirror_sibling_fixtures()
    return m


def copy_linux_libs():
    """The Ring++ engine for LINUX (item 8) into the clock copy:
    zig-out/lib/lib*.so, where every loader opens it under isLinux().
    Windows runs never read this folder, so refreshing it alone leaves every
    Windows row where it was -- stamp_root() hashes these on Linux only."""
    linux_libs = os.path.join(ROOT, 'runtime', 'engine-copy', 'zig-out-linux', 'lib')
    m = 0
    if os.path.isdir(linux_libs):
        ldst = os.path.join(LP + COPY, 'engine', 'zig-out', 'lib')
        os.makedirs(ldst, exist_ok=True)
        for f in os.listdir(linux_libs):
            if f.endswith('.so'):
                shutil.copyfile(os.path.join(linux_libs, f), os.path.join(ldst, f))
                m += 1
    return m


ORACLE_COPY_LINUX = os.path.join(ROOT, 'runtime', 'oracle-copy-linux', 'libraries', 'stzlib')
# The first line of the Linux oracle copy's _copy_rule.txt says where its
# sources came from; why432 measures it as a snapshot only when it says this.
FROM_SNAPSHOT = 'sources from the snapshot (oracle-copy-win)'


def make_oracle_copy_linux(from_snapshot=False):
    """The tree the LINUX ORACLE runs (item 8): Mansour's tree has no Linux
    build of the engine, and build output is not written into his tree, so
    the oracle gets a copy of it -- the same rule as the clock copy -- with
    the ORACLE-flavour engine (bench/engine_copy.py --oracle: his real
    ring_api, Ring's C API) in engine/zig-out/lib.

    `from_snapshot` (2026-10-08): the sources are the Windows SNAPSHOT's,
    oracle-copy-win, not his live tree -- so the Linux pass reads the same
    6,069 sources as the Windows one and as the clock copy, and his tree is
    free to move. The non-Ring engine artifacts (.wasm, .exe; copy rule 4)
    come with them, as they do for the clock copy rnx runs on Linux."""
    src_libs = os.path.join(ROOT, 'runtime', 'engine-oracle', 'zig-out-linux', 'lib')
    if not os.path.isdir(src_libs):
        print('no oracle-flavour Linux engine at ' + src_libs + ' -- run `python bench/engine_copy.py --oracle` and build it')
        return 0
    src_root = ORACLE_COPY_WIN if from_snapshot else LIB
    if not os.path.isdir(LP + src_root):
        print('no tree to copy at ' + src_root)
        return 0
    dst = LP + ORACLE_COPY_LINUX
    if os.path.exists(dst):
        shutil.rmtree(dst, onexc=_force_rm)
    n = 0
    for dirpath, dirs, names in os.walk(LP + src_root):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        rel = os.path.relpath(dirpath, LP + src_root)
        out = os.path.join(dst, rel) if rel != '.' else dst
        os.makedirs(out, exist_ok=True)
        for f in names:
            if rel == '.' and f == '_copy_rule.txt':
                continue
            src = os.path.join(dirpath, f)
            try:
                if os.path.getsize(src) > MAX_COPY:
                    continue
                shutil.copyfile(src, os.path.join(out, f))
                n += 1
            except OSError:
                pass
    ldst = os.path.join(dst, 'engine', 'zig-out', 'lib')
    os.makedirs(ldst, exist_ok=True)
    m = 0
    for f in os.listdir(src_libs):
        if f.endswith('.so'):
            shutil.copyfile(os.path.join(src_libs, f), os.path.join(ldst, f))
            m += 1
    k = 0
    if from_snapshot:
        sbin = os.path.join(LP + src_root, 'engine', 'zig-out', 'bin')
        bdst = os.path.join(dst, 'engine', 'zig-out', 'bin')
        os.makedirs(bdst, exist_ok=True)
        for f in (os.listdir(sbin) if os.path.isdir(sbin) else []):
            if f.lower().endswith(NON_RING_ARTIFACTS):
                shutil.copyfile(os.path.join(sbin, f), os.path.join(bdst, f))
                k += 1
    io.open(os.path.join(dst, '_copy_rule.txt'), 'w', encoding='utf-8', newline='\n').write(
        '%s -- the Linux oracle\'s copy, oracle-flavour engine%s\n%d files, %d libraries\n'
        % (COPY_RULE, ('; ' + FROM_SNAPSHOT) if from_snapshot else '', n, m))
    print('oracle copy (Linux): %d source files%s, %d oracle-flavour engine libraries, '
          '%d non-Ring artifacts' % (n, ' from the snapshot' if from_snapshot else '', m, k))
    return m


def make_linux_snapshot():
    """The Linux side of the snapshot: the Linux oracle's copy taken from
    oracle-copy-win, and the clock copy's Linux engine refreshed. The clock
    copy's sources are NOT re-taken -- they are the snapshot's already, and
    re-taking them would discard the Windows pass's rnx state with them.
    Their sources are compared and every difference named: the tests write
    .ring files into the copy they run on, so a few may part."""
    import hashlib
    if not os.path.isdir(LP + ORACLE_COPY_WIN) or not os.path.isdir(LP + COPY):
        print('no snapshot to take the Linux side of -- `python bench/clock34.py --snapshot` first')
        return False
    m = copy_linux_libs()
    print('clock copy: %d Ring++ engine libraries for Linux refreshed' % m)
    if not make_oracle_copy_linux(from_snapshot=True):
        return False

    def sources(root):
        out = {}
        for dp, dn, fn in os.walk(LP + root):
            dn[:] = [d for d in dn if d not in SKIP_DIRS and not d.startswith('.')]
            for f in fn:
                if (f.endswith('.ring') or f.endswith('.rh')) and not f.startswith('.'):
                    p = os.path.join(dp, f)
                    rel = os.path.relpath(p, LP + root).replace(os.sep, '/')
                    out[rel] = hashlib.sha256(io.open(p, 'rb').read()).hexdigest()
        return out

    a, b = sources(COPY), sources(ORACLE_COPY_LINUX)
    differ = sorted(p for p in set(a) | set(b) if a.get(p) != b.get(p))
    print('Linux snapshot: the clock copy and the Linux oracle copy hold %d and %d sources, '
          '%d differ%s' % (len(a), len(b), len(differ), (' -- ' + ', '.join(differ[:6])) if differ else ''))
    return True


# COPY RULE 5 (2026-10-04): what a test reads OUTSIDE his tree, by a path
# relative to itself. agentic/roster loads its agents from
# "../../../../../../softanza/roster/" -- six levels above base/test/agentic
# is D:\GitHub for his tree, and runtime\ for every copy (each sits at
# runtime\<copy>\libraries\stzlib). So both sides FAILED to find them on the
# snapshot and agreed -- a false agreement. The folder is mirrored to the
# same place relative to the copies. Tests that name his tree by ABSOLUTE
# path (meta/codegraph, two systemcall programs) read his live tree on both
# sides alike, and are named in CLAUDE.md rather than rewritten.
SIBLING_FIXTURES = ('softanza/roster',)


def mirror_sibling_fixtures():
    """Lay each SIBLING_FIXTURES folder out under runtime/ as it lies beside
    his repository, so a copy reaches it by the same relative path."""
    his_parent = os.path.dirname(os.path.dirname(os.path.dirname(LIB)))   # D:\GitHub
    n = 0
    for rel in SIBLING_FIXTURES:
        src = os.path.join(his_parent, rel.replace('/', os.sep))
        dst = os.path.join(ROOT, 'runtime', rel.replace('/', os.sep))
        if not os.path.isdir(src):
            print('copy rule 5: no %s beside his tree -- the test reading it will fail on both sides' % src)
            continue
        if os.path.exists(dst):
            shutil.rmtree(dst, onexc=_force_rm)
        shutil.copytree(src, dst)
        n += sum(len(f) for _, _, f in os.walk(dst))
    return n


ORACLE_COPY_WIN = os.path.join(ROOT, 'runtime', 'oracle-copy-win', 'libraries', 'stzlib')
ORACLE_ENGINE_WIN = os.path.join(ROOT, 'runtime', 'engine-oracle', 'zig-out', 'bin')


def make_oracle_copy_win():
    """The tree the WINDOWS ORACLE runs since 2026-10-03 (F-96): a copy of
    Mansour's tree with the engine built from its own source against the
    ORACLE (bench/engine_copy.py --oracle: his ring_api, the oracle's
    import library), in place of the DLLs in his zig-out.

    Those import Ring's API from ring.dll, and the oracle is one ring.exe,
    so hosting them it mapped D:\\Ring127\\bin\\ring.dll off the PATH -- every
    engine call the estate made on the oracle ran the official installation,
    and without it on the PATH the oracle could not load the engine at all.
    His DLLs were also not his current source (built 2026-06-23 to
    2026-09-12) while the Ring++ engine was, so the two sides could run two
    different engines. Here both are built from one copy of one source,
    in his own default mode, ReleaseSafe."""
    if not os.path.isdir(ORACLE_ENGINE_WIN):
        print('no oracle-flavour Windows engine at ' + ORACLE_ENGINE_WIN +
              ' -- run `python bench/engine_copy.py --oracle` and build it')
        return 0
    dst = LP + ORACLE_COPY_WIN
    if os.path.exists(dst):
        shutil.rmtree(dst, onexc=_force_rm)
    n = 0
    for dirpath, dirs, names in os.walk(LP + LIB):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        rel = os.path.relpath(dirpath, LP + LIB)
        out = os.path.join(dst, rel) if rel != '.' else dst
        os.makedirs(out, exist_ok=True)
        for f in names:
            src = os.path.join(dirpath, f)
            try:
                if os.path.getsize(src) > MAX_COPY:
                    continue
                shutil.copyfile(src, os.path.join(out, f))
                n += 1
            except OSError:
                pass
    bdst = os.path.join(dst, 'engine', 'zig-out', 'bin')
    os.makedirs(bdst, exist_ok=True)
    m = 0
    for f in os.listdir(ORACLE_ENGINE_WIN):
        if f.endswith('.dll'):
            shutil.copyfile(os.path.join(ORACLE_ENGINE_WIN, f), os.path.join(bdst, f))
            m += 1
    k = 0
    his_bin = os.path.join(LP + LIB, 'engine', 'zig-out', 'bin')
    if os.path.isdir(his_bin):
        for f in os.listdir(his_bin):
            if f.lower().endswith(NON_RING_ARTIFACTS):
                shutil.copyfile(os.path.join(his_bin, f), os.path.join(bdst, f))
                k += 1
    io.open(os.path.join(dst, '_copy_rule.txt'), 'w', encoding='utf-8', newline='\n').write(
        '%s -- the Windows oracle\'s copy, oracle-flavour engine\n%d files, %d libraries\n' % (COPY_RULE, n, m))
    print('oracle copy (Windows): %d source files, %d oracle-flavour engine DLLs, %d non-Ring artifacts'
          % (n, m, k))
    return m


def make_snapshot():
    """ONE SNAPSHOT for both sides: the clock copy rnx runs and the copy the
    oracle runs, taken back to back from his tree, and refused unless their
    sources agree byte for byte. Measured on a snapshot, his own tree never
    has to freeze -- it is the snapshot that holds still for the hours a
    refill takes, and both sides read the same one."""
    import hashlib

    def sources(root):
        out = {}
        for dp, dn, fn in os.walk(LP + root):
            dn[:] = [d for d in dn if d not in SKIP_DIRS and not d.startswith('.')]
            for f in fn:
                if (f.endswith('.ring') or f.endswith('.rh')) and not f.startswith('.'):
                    p = os.path.join(dp, f)
                    rel = os.path.relpath(p, LP + root).replace(os.sep, '/')
                    out[rel] = hashlib.sha256(io.open(p, 'rb').read()).hexdigest()
        return out

    for attempt in range(3):
        make_copy()
        make_oracle_copy_win()
        print('copy rule 5: %d file(s) the tests read beside his tree, mirrored under runtime/'
              % mirror_sibling_fixtures())
        a, b = sources(COPY), sources(ORACLE_COPY_WIN)
        differ = sorted(p for p in set(a) | set(b) if a.get(p) != b.get(p))
        if not differ:
            print('snapshot: both copies hold the same %d sources' % len(a))
            return True
        print('snapshot: the tree moved between the two copies (%d file(s), e.g. %s) -- again'
              % (len(differ), differ[0]))
    print('snapshot: REFUSED -- the tree kept moving; nothing is measured on two trees')
    return False


ROOTS = None
# Roots a caller adds before the first unroot(): why432's Linux MIRROR, the
# same copies laid out on WSL's own disk (2026-10-08), whose paths a Linux
# program prints where it would print /mnt/d/...
EXTRA_ROOTS = []


def unroot(b):
    global ROOTS
    if ROOTS is None:
        ROOTS = []
        # ...and each root as a LINUX process under WSL sees it, /mnt/d/...,
        # with the Linux oracle's own copy beside them (item 8)
        for p in (LIB, COPY, ORACLE_COPY_LINUX, ORACLE_COPY_WIN):
            ROOTS.append(p.encode())
            ROOTS.append(p.replace(chr(92), '/').encode())
            fwd = p.replace(chr(92), '/')
            ROOTS.append(('/mnt/' + fwd[0].lower() + fwd[2:]).encode())
        for p in EXTRA_ROOTS:
            ROOTS.append(p.encode())
    for r in ROOTS:
        b = b.replace(r, b'<stzlib>')
    return b


def lines(b, drop_warnings=False):
    # BLANK LINES ARE OUTPUT (2026-10-11). Every instrument compared lines with
    # the blank ones dropped, so `? aList`'s closing blank line -- Ring prints
    # it, Ring++ left it out -- was invisible to all of them: 108 rows of the
    # wide suite differed in nothing else and were counted as agreeing (F-106).
    # Only the line ending and the trailing newlines are not compared.
    out = []
    for l in unroot(b).split(b'\n'):
        l = l.rstrip(b'\r')
        if drop_warnings and l.startswith(b'WARNING: '):
            continue
        out.append(l)
    while out and not out[-1].strip():
        out.pop()
    return out


def without_ring_install():
    """This process's environment with every PATH entry of a Ring
    INSTALLATION removed. The oracle runs under it on the snapshot, so a
    library that still reaches for the official ring.dll fails to load,
    loudly (R38), instead of finding it on the PATH as it did until F-96."""
    env = dict(os.environ)
    env['PATH'] = os.pathsep.join(p for p in env.get('PATH', '').split(os.pathsep)
                                  if 'ring127' not in p.lower())
    return env


def run(exe_args, cwd, timeout=300, env=None):
    clear_generated(cwd)
    try:
        r = subprocess.run(exe_args, cwd=cwd, capture_output=True, timeout=timeout, env=env)
        return r.stdout, r.stderr
    except subprocess.TimeoutExpired as e:
        return (e.stdout or b''), (e.stderr or b'') + b'\n<TIMEOUT>'


def main():
    only = [a for a in sys.argv[1:] if not a.startswith('-')]
    if not os.path.isdir(LIB):
        print('SKIP clock: no Softanza tree at ' + LIB)
        return 0
    if not os.path.isdir(ENGINE_DLLS):
        print('SKIP clock: no Ring++ engine DLLs -- run `python bench/engine_copy.py`')
        return 0
    if '--snapshot' in sys.argv:
        # both copies, one tree -- why432.py measures on it from then on
        return 0 if make_snapshot() else 1
    if '--linux-snapshot' in sys.argv:
        # the Linux oracle's copy from that snapshot, for why432 --platform=linux
        return 0 if make_linux_snapshot() else 1
    if '--copy' in sys.argv or not os.path.isdir(LP + COPY):
        make_copy()

    names = [t for t in THE_34 if not only or any(o in t for o in only)]
    stable_same = exact_same = 0
    volatile_total = 0
    rows = []
    for rel in names:
        mod, fn = rel.split('/')
        t0 = time.time()
        # the noise floor: the ORACLE against itself, in Mansour's tree
        # (Ring cannot load a DLL built for Ring++, so it runs on his)
        a1o, a1e = run([RING, fn], os.path.join(LIB, TESTS.replace('/', os.sep), mod))
        a2o, a2e = run([RING, fn], os.path.join(LIB, TESTS.replace('/', os.sep), mod))
        A, B = lines(a1o + a1e), lines(a2o + a2e)
        volatile = {i for i, (x, y) in enumerate(zip(A, B)) if x != y}
        if len(A) != len(B):
            volatile |= set(range(min(len(A), len(B)), max(len(A), len(B))))
        # rnx, in the copy
        # stdout: a program's output, as Ring writes it (the streams were
        # swapped until 2026-09-12). stderr carries rnxc's status and the
        # engine-DLL warnings, and is not compared.
        co, ce = run([RNXC, fn], os.path.join(COPY, TESTS.replace('/', os.sep), mod))
        C = lines(co, drop_warnings=True)
        exact = (A == C)
        stable = True
        first = ''
        if len(A) != len(C):
            stable = False
            first = 'length %d vs %d' % (len(A), len(C))
        else:
            for i, (x, z) in enumerate(zip(A, C)):
                if x != z and i not in volatile:
                    stable = False
                    first = 'line %d: ring %r | rnx %r' % (i + 1, x[:46].decode('utf-8', 'replace'), z[:46].decode('utf-8', 'replace'))
                    break
        exact_same += exact
        stable_same += stable
        volatile_total += len(volatile)
        tag = 'SAME ' if exact else ('STABLE' if stable else 'DIFF  ')
        rows.append((tag, rel, len(A), len(volatile), first, time.time() - t0))
        print('%s %-46s %3d lines %2d volatile  %s' % (tag, rel, len(A), len(volatile), first[:60]), flush=True)
    print()
    print('EXACT   %d of %d -- every line, measurements included' % (exact_same, len(names)))
    print('STABLE  %d of %d -- every line the oracle reproduces from itself' % (stable_same, len(names)))
    print('        %d lines set aside across the suite as the oracle\'s own noise' % volatile_total)
    return 0


if __name__ == '__main__':
    sys.exit(main())
