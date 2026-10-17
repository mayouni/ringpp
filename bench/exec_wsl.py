"""The exec probes on LINUX, under WSL: every bench/exec/*.ring on the Linux
oracle (runtime/linux-x64/ring) and on the Linux rnxc (zig-out-linux), byte
for byte -- the same question bench/exec.py asks on Windows.

    zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseFast -j2 -Dmi=true \
        -Drc=true -Dtyped=true -Dcow=true --prefix zig-out-linux
    powershell -File tests/b2_runtimes.ps1 -Only linux-x64
    python bench/exec_wsl.py [probe.ring ...]

FIRST RUN, 2026-09-28: 94 of 100, and five of the six were not rnxc's. The
Linux oracle had been built STATIC MUSL, which cannot dlopen, so it never
loaded its own zip extension; and musl's strtod sets errno when nothing
converts, which Ring's stringtonum turns into R41 -- `0 = 'abc'` raised on
it where glibc and Windows Ring answer 0 (F-83). Rebuilt on glibc, as Ring's
own Linux build is, those five agreed. The sixth was ours: clock() is C's
clock(), CPU time on glibc (F-84). 100 of 100 since.

Relative name and cwd, as bench/exec.py runs them: Ring reports a file as it
was GIVEN, so an absolute path changed `prevfilename` and every error line.
The oracle gets its own folder on LD_LIBRARY_PATH, which is where a Ring
install puts libring_libzip.so and what dlopen searches.

SKIPs, named, when WSL, the Linux oracle or the Linux rnxc is absent."""
import os, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
EXEC = os.path.join(HERE, 'exec')


def wsl_path(p):
    p = os.path.abspath(p).replace('\\', '/')
    return '/mnt/' + p[0].lower() + p[2:]


ORACLE = os.path.join(ROOT, 'runtime', 'linux-x64', 'ring')
RNXC = os.path.join(ROOT, 'zig-out-linux', 'bin', 'rnxc')


# The DISTRIBUTION is named: this machine's default is docker-desktop, where
# none of these paths exist, and the first version of this file ran every
# probe there -- exit 127 on both sides, two empty outputs, "0 differing of
# 100". A guard that compares two runs that never happened passes forever;
# that is why a runner that did not run is now an error, not a match.
DISTRO = os.environ.get('RPP_WSL_DISTRO', 'Ubuntu')


def run(exe, probe):
    d = wsl_path(EXEC)
    lx = wsl_path(exe)
    cmd = ['wsl.exe', '-d', DISTRO, '--cd', d, '--', 'env',
           'LD_LIBRARY_PATH=' + lx.rsplit('/', 1)[0], lx, probe]
    p = subprocess.run(cmd, capture_output=True, timeout=600)
    if p.returncode in (126, 127):
        raise SystemExit('FAIL exec on Linux: %s did not run (exit %d) -- %s'
                         % (lx, p.returncode, p.stderr.decode('utf-8', 'replace').strip()[:200]))
    return p.returncode, p.stdout.replace(b'\r', b'')


def absolute_load():
    """F-127, Linux only: a load by ABSOLUTE path. Ring tries a rooted path as
    written first, so on Linux `/x/lib.ring` is that file; rnxc read every
    leading `/` as <exefolder>/load/ and refused the program -- which is how
    every node and worker script Softanza generates (they load the library by
    an absolute path) died at birth on Linux. A probe in bench/exec cannot
    carry it: no absolute path is spelt the same on both platforms. So the
    files are written here, the root naming the library by its /mnt path, a
    loaded file loading another the same way (the splice), and both runtimes
    must print the same bytes. The build before printed the refusal."""
    d = os.path.join(ROOT, 'runtime', 'f127')
    os.makedirs(d, exist_ok=True)
    lib, inner = wsl_path(os.path.join(d, 'lib.ring')), wsl_path(os.path.join(d, 'inner.ring'))
    files = {
        'inner.ring': '? "inner: its top level runs at its load"\nfunc Inner127 return "inner answered"\n',
        'lib.ring': '? "lib: before its own load"\nload "%s"\n? "lib: after it"\nfunc F127 return "absolute load resolved"\n' % inner,
        'root.ring': '? "root: before"\nload "%s"\n? F127()\n? Inner127()\n? "root: after"\n' % lib,
    }
    for name, text in files.items():
        with open(os.path.join(d, name), 'w', encoding='utf-8', newline='\n') as f:
            f.write(text)
    outs = []
    for exe in (ORACLE, RNXC):
        lx = wsl_path(exe)
        p = subprocess.run(['wsl.exe', '-d', DISTRO, '--cd', wsl_path(d), '--', 'env',
                            'LD_LIBRARY_PATH=' + lx.rsplit('/', 1)[0], lx, 'root.ring'],
                           capture_output=True, timeout=600)
        outs.append(p.stdout.replace(b'\r', b''))
    if outs[0] != outs[1] or b'absolute load resolved' not in outs[0]:
        print('DIFF %-28s\n     oracle: %s\n     rnxc  : %s' % ('F-127 absolute load', outs[0][:200], outs[1][:200]))
        return False
    return True


def main():
    for what, p in (('the Linux oracle', ORACLE), ('the Linux rnxc', RNXC)):
        if not os.path.exists(p):
            print('SKIP exec on Linux: no %s at %s' % (what, p))
            return 0
    try:
        subprocess.run(['wsl.exe', '-d', DISTRO, '--', 'true'], capture_output=True, timeout=120, check=True)
    except Exception as e:
        print('SKIP exec on Linux: WSL does not answer (%s)' % e)
        return 0
    probes = sys.argv[1:] or sorted(f for f in os.listdir(EXEC) if f.endswith('.ring'))
    bad = []
    if not sys.argv[1:]:
        if not absolute_load():
            bad.append('F-127 absolute load')
        probes = probes + ['(F-127 absolute load)']
    for pr in probes:
        if pr.startswith('('):
            continue
        a = run(ORACLE, pr)
        b = run(RNXC, pr)
        if a[1] != b[1]:
            bad.append(pr)
            al, bl = a[1].decode('utf-8', 'replace').split('\n'), b[1].decode('utf-8', 'replace').split('\n')
            for i in range(max(len(al), len(bl))):
                x = al[i] if i < len(al) else '<none>'
                y = bl[i] if i < len(bl) else '<none>'
                if x != y:
                    print('DIFF %-28s line %d\n     oracle: %s\n     rnxc  : %s' % (pr, i + 1, x[:110], y[:110]))
                    break
    if bad:
        print('EXEC PROBES ON LINUX DIFFER   %d of %d' % (len(bad), len(probes)))
        return 1
    print('EXEC PROBES ON LINUX AGREE WITH RING   0 differing of %d' % len(probes))
    return 0


if __name__ == '__main__':
    sys.exit(main())
