"""ONE PACKAGE (item 8): Ring++ and Softanza with its engine, in one folder
that runs a Softanza program from anywhere, on Windows or Linux.

    python bench/package.py                     Windows, from zig-out
    python bench/package.py --platform=linux    Linux, from zig-out-linux
    python bench/package.py --with-tests        ...and the three test folders
    python bench/package.py --stz=<tree>\\libraries\\stzlib --engine=runtime\\engine-main
                                                Softanza from another tree (a worktree of stzlib MAIN) and
                                                the engine copy built from that tree's engine (2026-10-29)

A tree from a clean checkout carries no models (models/*.gguf are git-ignored): they are taken from
--models=<dir> (default: Mansour's tree), each under the file cap and, where models/SHA256SUMS of the
Softanza tree names it, only if its hash matches. bin/../PACKAGE.txt records the commits that went in.

    runtime/package/ringpp-<platform>/
      bin/rnxc[.exe]                 the one binary (commitment 5)
      bin/load/                      Ring's shims, and two of ours:
        stzlib.ring, stzmax.ring     `load "stzlib.ring"` from anywhere
      libraries/stdlib/              Ring's library, with rpp/stdlib's two files
      extensions/ringzip/            rpp/ringzip's shim (zip is built in)
      libraries/stzlib/              Softanza: core, base, max and the engine's
        engine/*.ring                  loaders, WITHOUT the engine's sources;
        engine/zig-out/bin|lib/        the engine built for Ring++ (rpp_init)

THE LAYOUT IS SOFTANZA'S OWN RULE, not a choice made here: its engine
discovery searches upward from the current directory and then falls back to
exefolder() + "/../libraries/stzlib/engine" (core/common/stkRingLibs.ring),
which is exactly bin/ -> libraries/stzlib/engine above. And Ring resolves a
bare `load "x.ring"` through <exefolder>/load/, where the two shims sit.

Built from what is already built -- rnxc and its layout by `zig build`, the
engine by bench/engine_copy.py -- so this copies and never compiles. The
Softanza sources come from Mansour's tree, read-only; archive/ and future/
are not loaded by anything and stay out, and the test folders only with
--with-tests. Nothing is published: runtime/ is gitignored."""
import hashlib, os, re, shutil, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
STZ_DEFAULT = r'D:\GitHub\stzlib\libraries\stzlib'
STZ = next((a[6:] for a in sys.argv[1:] if a.startswith('--stz=')), STZ_DEFAULT)
MODELS = next((a[9:] for a in sys.argv[1:] if a.startswith('--models=')), os.path.join(STZ_DEFAULT, 'models'))
ENGINE = next((a[9:] for a in sys.argv[1:] if a.startswith('--engine=')), os.path.join(ROOT, 'runtime', 'engine-copy'))
OUT = os.path.join(ROOT, 'runtime', 'package')
MAX_FILE = 256 * 1024 * 1024
SKIP_DIRS = {'.git', '.zig-cache', 'zig-out', 'zig-out-linux', 'node_modules', '__pycache__', 'archive', 'future'}
# the engine's SOURCES are not part of an install: only its loaders (*.ring)
ENGINE_SOURCE_DIRS = {'src', 'vendor', 'tools', 'tests', 'bench', 'docs', '_ring_headers'}
TEST_DIRS = ('base/test', 'max/test', 'core/test')

SHIMS = {
    'stzlib.ring': 'load "/../../libraries/stzlib/stzLib.ring"\n',
    'stzmax.ring': 'load "/../../libraries/stzlib/max/stzMax.ring"\n',
}


def copytree(src, dst, skip=lambda rel, d: False, keep=lambda rel, f: True):
    n = size = 0
    for dp, dn, fn in os.walk(src):
        rel = os.path.relpath(dp, src).replace(os.sep, '/')
        rel = '' if rel == '.' else rel
        dn[:] = [d for d in dn if d not in SKIP_DIRS and not skip(rel, d)]
        out = os.path.join(dst, rel) if rel else dst
        os.makedirs(out, exist_ok=True)
        for f in fn:
            p = os.path.join(dp, f)
            try:
                s = os.path.getsize(p)
            except OSError:
                continue
            if s > MAX_FILE or not keep(rel, f):
                continue
            shutil.copyfile(p, os.path.join(out, f))
            n += 1
            size += s
    return n, size


def main():
    linux = '--platform=linux' in sys.argv
    tests = '--with-tests' in sys.argv
    plat = 'linux-x64' if linux else 'win64'
    zo = os.path.join(ROOT, 'zig-out-linux' if linux else 'zig-out')
    exe = os.path.join(zo, 'bin', 'rnxc' if linux else 'rnxc.exe')
    eng = os.path.join(ENGINE, 'zig-out-linux' if linux else 'zig-out', 'lib' if linux else 'bin')
    for what, p in (('rnxc', exe), ('the Ring++ engine', eng), ('Softanza', STZ)):
        if not os.path.exists(p):
            print('SKIP package: no %s at %s' % (what, p))
            return 0
    pkg = os.path.join(OUT, 'ringpp-' + plat)
    t0 = time.time()
    if os.path.exists(pkg):
        shutil.rmtree(pkg)
    # 1. Ring++: the binary and the layout zig build installs beside it
    os.makedirs(os.path.join(pkg, 'bin'))
    shutil.copy2(exe, os.path.join(pkg, 'bin', os.path.basename(exe)))
    copytree(os.path.join(zo, 'bin', 'load'), os.path.join(pkg, 'bin', 'load'))
    for d in ('libraries', 'extensions'):
        copytree(os.path.join(zo, d), os.path.join(pkg, d))
    for name, text in SHIMS.items():
        with open(os.path.join(pkg, 'bin', 'load', name), 'w', encoding='utf-8', newline='\n') as f:
            f.write(text)
    # 2. Softanza, without the engine's sources and (by default) the tests
    def skip(rel, d):
        if rel == 'engine' and d in ENGINE_SOURCE_DIRS:
            return True
        full = (rel + '/' + d) if rel else d
        return (not tests) and full in TEST_DIRS
    def keep(rel, f):
        # the engine folder carries its *.ring loaders; its build files stay out
        return not (rel == 'engine' and not f.endswith(('.ring', '.rh')))
    n, size = copytree(STZ, os.path.join(pkg, 'libraries', 'stzlib'), skip, keep)
    # ...but a file a loader of the library NAMES is the library's, wherever it sits: max/stzMax.ring loads
    # test/stzTestoor.ring (Softanza's test framework), and without it every program that loads the max layer
    # was refused at load, E9 then C27 (C-25) -- in the v2.0.5 packages too, found 2026-10-30
    if not tests:
        lib = os.path.join(pkg, 'libraries', 'stzlib')
        todo = [os.path.join(dp, f) for dp, _, fs in os.walk(lib) for f in fs if f.endswith(('.ring', '.rh'))]
        pulled = 0
        while todo:
            src = todo.pop()
            try:
                text = open(src, encoding='utf-8', errors='replace').read()
            except OSError:
                continue
            for lit in re.findall(r'(?im)^[ 	]*load[ 	]+"([^"]+)"', text):
                rel = os.path.relpath(os.path.normpath(os.path.join(os.path.dirname(src), lit)), lib)
                if rel.startswith('..') or not any((rel.replace(os.sep, '/') + '/').startswith(d + '/') for d in TEST_DIRS):
                    continue
                dst, org = os.path.join(lib, rel), os.path.join(STZ, rel)
                if os.path.exists(dst) or not os.path.isfile(org):
                    continue
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copyfile(org, dst)
                pulled += 1
                n += 1
                size += os.path.getsize(dst)
                todo.append(dst)
        if pulled:
            print('  %d file(s) of a test folder kept: a loader of the library names them' % pulled)
    # 3. the engine, built for Ring++, where the loaders open it
    edst = os.path.join(pkg, 'libraries', 'stzlib', 'engine', 'zig-out', 'lib' if linux else 'bin')
    os.makedirs(edst, exist_ok=True)
    m = esize = 0
    for f in os.listdir(eng):
        if f.endswith('.so' if linux else '.dll'):
            shutil.copy2(os.path.join(eng, f), os.path.join(edst, f))   # its build time kept: a proof line reads it
            m += 1
            esize += os.path.getsize(os.path.join(eng, f))
    # 4. the models, when the Softanza tree is a clean checkout (they are git-ignored), checked against its SHA256SUMS
    mdst = os.path.join(pkg, 'libraries', 'stzlib', 'models')
    os.makedirs(mdst, exist_ok=True)
    have = [f for f in os.listdir(mdst) if f.endswith('.gguf')]
    sums = {}
    sp = os.path.join(STZ, 'models', 'SHA256SUMS')
    if os.path.exists(sp):
        for line in open(sp, encoding='utf-8', errors='replace'):
            parts = line.split()
            if len(parts) >= 2:
                sums[parts[-1].lstrip('*')] = parts[0].lower()
    models = []
    if not have and os.path.isdir(MODELS):
        for f in sorted(os.listdir(MODELS)):
            p = os.path.join(MODELS, f)
            if not f.endswith('.gguf') or os.path.getsize(p) > MAX_FILE:
                continue
            if f in sums:
                h = hashlib.sha256()
                with open(p, 'rb') as fh:
                    for chunk in iter(lambda: fh.read(1 << 22), b''):
                        h.update(chunk)
                if h.hexdigest() != sums[f]:
                    print('  model %s does NOT match SHA256SUMS -- left out' % f)
                    continue
            shutil.copyfile(p, os.path.join(mdst, f))
            models.append(f)
    # 5. what went in, by commit
    def head(d):
        r = subprocess.run(['git', '-C', d, 'log', '-1', '--format=%h %cd %s', '--date=format:%Y-%m-%d'], capture_output=True, text=True)
        return r.stdout.strip()[:110] or '(not a git tree)'
    with open(os.path.join(pkg, 'PACKAGE.txt'), 'w', encoding='utf-8', newline='\n') as f:
        f.write('Ring++ package %s, laid %s\n' % (plat, time.strftime('%Y-%m-%d %H:%M')))
        f.write('  rnxc       ringpp %s\n' % head(ROOT))
        f.write('  Softanza   stzlib %s\n' % head(STZ))
        f.write('  engine     built for Ring++ by bench/engine_copy.py from %s (%d libraries)\n' % (ENGINE, m))
        f.write('  models     %s\n' % (', '.join(models or have) or 'none'))
    total = sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(pkg) for f in fs)
    print('package %s: rnxc + Ring\'s library + Softanza (%d files, %.0f MB) + %d engine libraries (%.0f MB) + %d model(s)'
          % (pkg, n, size / 1e6, m, esize / 1e6, len(models)))
    print('  %.0f MB in all, %.1f s%s' % (total / 1e6, time.time() - t0, '' if tests else '  (tests left out)'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
