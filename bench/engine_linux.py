"""Build the LINUX engine libraries of runtime/engine-copy through the Ring++ backend, one batch a call.

    python bench/engine_copy.py                refresh the copy from Mansour's live engine first (Windows names the domains)
    python bench/engine_linux.py               list the five batches
    python bench/engine_linux.py <1..5>        build one batch: ONLY=<its domains> zig build -j2 -Dtarget=x86_64-linux-gnu --prefix zig-out-linux
    python bench/package.py --platform=linux   then lay the package

The domains are the Windows build's DLL names (runtime/engine-copy/zig-out/bin) less the two vendored runtimes (accesskit, wgpu_native) and the two that
do not build for Linux -- stz_gui (stz_rmlui.cpp uses __declspec) and stz_window (the system's X11): 87, the count of the Linux package. The heavy domains
(ggml, mbedTLS, sqlite, tree-sitter, libuv) are split over the first two batches. His default ReleaseSafe, -j2, FOREGROUND: a batch is 18-40 minutes on a
machine at full speed's order of magnitude (2026-10-23, throttled to a fifth: 2376, 1311, 1386, 1277 and 1106 s), and a command left running longer than
the tool's limit goes on in the background by itself -- read its output file rather than starting a second build beside it.

The libraries land in runtime/engine-copy/zig-out-linux/lib. Check them under WSL before the package is laid: all 87 load and answer rpp_abi_version
(ctypes.CDLL(f).rpp_abi_version() == native.VERSION, 3 on 2026-10-23)."""
import glob, os, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
EC = os.path.join(ROOT, 'runtime', 'engine-copy')
N_BATCHES = 5
HEAVY = ('stz_reactor', 'stz_http', 'stz_crypto', 'stz_db', 'stz_polyglot', 'stz_neural', 'stz_matrix', 'stz_gpu', 'stz_unidata',
         'stz_sound', 'stz_voice', 'stz_audiodev', 'stz_a11y')
NOT_LINUX = ('accesskit', 'wgpu_native', 'stz_gui', 'stz_window')


def batches():
    names = sorted(os.path.basename(f)[:-4] for f in glob.glob(os.path.join(EC, 'zig-out', 'bin', '*.dll')))
    names = [n for n in names if n not in NOT_LINUX]
    out = [[] for _ in range(N_BATCHES)]
    heavy = [n for n in names if n in HEAVY]
    light = [n for n in names if n not in HEAVY]
    for i, n in enumerate(heavy):
        out[i % 2].append(n)
    for i, n in enumerate(light):
        out[i % N_BATCHES].append(n)
    return names, out


def main():
    names, bs = batches()
    if not names:
        print('SKIP: no Windows build in %s -- run bench/engine_copy.py and build it first (the domain names come from its DLLs)' % EC)
        return 0
    if len(sys.argv) < 2:
        print('%d domains' % len(names))
        for i, b in enumerate(bs):
            print(i + 1, len(b), ','.join(b)[:110])
        return 0
    k = int(sys.argv[1]) - 1
    env = dict(os.environ, ONLY=','.join(bs[k]))
    t = time.time()
    r = subprocess.run(['zig', 'build', '-j2', '-Dtarget=x86_64-linux-gnu', '--prefix', 'zig-out-linux'], cwd=EC, env=env)
    print('batch %d: %d domains, exit %d, %.0f s' % (k + 1, len(bs[k]), r.returncode, time.time() - t))
    return r.returncode


if __name__ == '__main__':
    sys.exit(main())
