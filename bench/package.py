"""ONE PACKAGE (item 8): Ring++ and Softanza with its engine, in one folder
that runs a Softanza program from anywhere, on Windows or Linux.

    python bench/package.py                     Windows, from zig-out
    python bench/package.py --platform=linux    Linux, from zig-out-linux
    python bench/package.py --with-tests        ...and the three test folders

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
import os, shutil, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
STZ = r'D:\GitHub\stzlib\libraries\stzlib'
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
    eng = os.path.join(ROOT, 'runtime', 'engine-copy', 'zig-out-linux' if linux else 'zig-out',
                       'lib' if linux else 'bin')
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
    # 3. the engine, built for Ring++, where the loaders open it
    edst = os.path.join(pkg, 'libraries', 'stzlib', 'engine', 'zig-out', 'lib' if linux else 'bin')
    os.makedirs(edst, exist_ok=True)
    m = esize = 0
    for f in os.listdir(eng):
        if f.endswith('.so' if linux else '.dll'):
            shutil.copyfile(os.path.join(eng, f), os.path.join(edst, f))
            m += 1
            esize += os.path.getsize(os.path.join(eng, f))
    total = sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(pkg) for f in fs)
    print('package %s: rnxc + Ring\'s library + Softanza (%d files, %.0f MB) + %d engine libraries (%.0f MB)'
          % (pkg, n, size / 1e6, m, esize / 1e6))
    print('  %.0f MB in all, %.1f s%s' % (total / 1e6, time.time() - t0, '' if tests else '  (tests left out)'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
