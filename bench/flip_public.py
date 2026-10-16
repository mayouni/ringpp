"""THE FLIP: the library era goes to an archive repository and Ring++ 2 takes mayouni/ringpp's main -- run only at Mansour's word.

    python bench/flip_public.py          print every step and check what can be checked; changes NOTHING
    python bench/flip_public.py --go     do it

Decided by Mansour, 2026-10-15: the library era is archived in a SEPARATE repository, mayouni/ringpp-old (read-only);
mayouni/ringpp's main then holds only Ring++ (bench/public_tree.py's tree, one fresh commit: Haro, the AI brief and the private
history stay private); and nothing public changes until he says go. The steps, in order:

  1. check: the public tree lays out clean, origin/main is still the library era, both packages exist and each carries
     the rnxc built last (byte for byte: a package is a COPY, and it has gone stale before)
  2. create github.com/mayouni/ringpp-old and push the library era's main to it, tags included
  3. archive mayouni/ringpp-old (read-only)
  4. replace mayouni/ringpp's main with ONE commit holding the public tree (a force push: the old history lives on in
     ringpp-old, and step 2 must have succeeded first)
  5. the repository's About says what Ring++ is now: its description, the site as its website, its topics
  6. publish the release: the two packages, packed afresh (Windows a zip, Linux a tar.gz), as assets of v2.0.0
DONE 2026-10-16 (6f6eaaa on mayouni/ringpp main, v2.0.0 released). Run again, step 1 refuses: origin/main is no longer the
library era. And the one thing it got wrong: pages.yml runs on a push touching site/**, and the force push that replaced the
history did NOT trigger it, so the site was redeployed by its workflow_dispatch -- which step 4 now runs after the push."""
import os, shutil, subprocess, sys, tarfile, tempfile, time, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PUB = os.path.join(ROOT, 'runtime', 'public', 'ringpp')
PKG = os.path.join(ROOT, 'runtime', 'package')
OLD_REPO = 'mayouni/ringpp-old'
NEW_REPO = 'mayouni/ringpp'
LIBRARY_ERA_MAIN = 'a4a29e6'   # origin/main at the decision, 2026-10-15
TAG = 'v2.0.0'
GO = '--go' in sys.argv
SITE = 'https://mayouni.github.io/ringpp/'
# The About box of mayouni/ringpp: until the flip it still describes the library era ("a dependency-free library and CLI").
ABOUT = ('Ring++: a register VM and a compiler for Ring programs, in one binary. It runs the Ring code that exists, Softanza '
         'first, without Ring: faster, and refusing what it cannot run correctly. The bridge to Haro. No C compiler, ever.')
TOPICS = ['ring', 'ring-programming-language', 'programming-language', 'compiler', 'virtual-machine', 'bytecode-vm', 'zig',
          'static-analysis', 'softanza']
# which built rnxc each package must carry
BUILT = {'ringpp-win64': ('zig-out', 'rnxc.exe'), 'ringpp-linux-x64': ('zig-out-linux', 'rnxc')}

NOTES = """Ring++ 2: a register VM and a compiler for Ring, in one binary.

It runs the Ring code that exists -- Softanza's 300,000 lines first -- with no Ring underneath. Every assertion that passes on
Ring passes on Ring++: 8,540 of 8,540 on Windows, 7,873 of 7,873 on Linux. Why it left Ring, and every issue of Ring it
solves, measured: https://mayouni.github.io/ringpp/

The packages hold rnxc, Ring's standard library, Softanza and its engine built for Ring++. Unpack anywhere -- the
Windows zip, or on Linux `tar -xzf ringpp-linux-x64.tar.gz` -- and run `bin/rnxc program.ring`.

The library era (August 2026) is archived at https://github.com/mayouni/ringpp-old."""


def sh(cmd, cwd=ROOT, check=True):
    print('    $ ' + ' '.join(cmd))
    if not GO:
        return ''
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise SystemExit('FAILED (%d): %s\n%s' % (r.returncode, ' '.join(cmd), (r.stderr or r.stdout)[-800:]))
    return r.stdout


def step(n, what):
    print('\n%d. %s' % (n, what))


def archive_name(p):
    # Windows gets a zip; Linux a tar.gz -- a stock Ubuntu may have no unzip (this machine's WSL has none), and tar keeps
    # the Unix modes a zip written on Windows does not, so rnxc unpacks executable.
    return p + ('.tar.gz' if p == 'ringpp-linux-x64' else '.zip')


def write_archive(p, out, sub=''):
    """Pack runtime/package/<p> (or only its <sub> folder) into out, as <p>/... inside."""
    base = os.path.join(PKG, p)
    files = []
    for dp, dn, fn in os.walk(os.path.join(base, sub)):
        dn.sort()
        for f in sorted(fn):
            # the Haro session's scratch binaries are not part of an install
            if f.startswith('rnxc_') and f.endswith('.exe'):
                continue
            full = os.path.join(dp, f)
            files.append((full, (p + '/' + os.path.relpath(full, base)).replace(os.sep, '/')))
    if out.endswith('.zip'):
        with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as zf:
            for full, rel in files:
                zf.write(full, rel)
        return
    def mode(ti):
        ti.mode = 0o755 if (ti.isdir() or ti.name.endswith('bin/rnxc')) else 0o644
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = 'root'
        return ti
    with tarfile.open(out, 'w:gz') as tf:
        for full, rel in files:
            tf.add(full, rel, recursive=False, filter=mode)


def main():
    print('THE FLIP -- %s' % ('DOING IT' if GO else 'dry run: nothing changes; --go does it'))

    step(1, 'check')
    r = subprocess.run([sys.executable, os.path.join(HERE, 'public_tree.py')], cwd=ROOT, capture_output=True, text=True)
    print('    ' + r.stdout.strip().split('\n')[-1])
    if r.returncode != 0:
        raise SystemExit('the public tree is refused; nothing done')
    head = subprocess.run(['git', '-C', ROOT, 'rev-parse', '--short', 'origin/main'], capture_output=True, text=True).stdout.strip()
    print('    origin/main is %s (the library era: %s)' % (head, LIBRARY_ERA_MAIN))
    if not head.startswith(LIBRARY_ERA_MAIN):
        raise SystemExit('origin/main moved since the decision; look before flipping')
    for p, (prefix, exe) in BUILT.items():
        if not os.path.isdir(os.path.join(PKG, p)):
            raise SystemExit('no package %s; run bench/package.py' % p)
        built = os.path.join(ROOT, prefix, 'bin', exe)
        packed = os.path.join(PKG, p, 'bin', exe)
        with open(built, 'rb') as a, open(packed, 'rb') as b:
            if a.read() != b.read():
                raise SystemExit('package %s does not carry the rnxc in %s/bin -- re-lay it (bench/package.py)' % (p, prefix))
        print('    %s present, its rnxc the one in %s/bin (%s)' %
              (p, prefix, time.strftime('%Y-%m-%d %H:%M', time.localtime(os.path.getmtime(built)))))

    step(2, 'create %s and push the library era to it' % OLD_REPO)
    sh(['gh', 'repo', 'create', OLD_REPO, '--public', '--description',
        'Ring++, the library era (August 2026): archived. Ring++ today: https://github.com/mayouni/ringpp'])
    sh(['git', 'push', 'https://github.com/%s.git' % OLD_REPO, '%s:refs/heads/main' % LIBRARY_ERA_MAIN])
    sh(['git', 'push', 'https://github.com/%s.git' % OLD_REPO, '--tags'], check=False)

    step(3, 'archive %s (read-only)' % OLD_REPO)
    sh(['gh', 'repo', 'archive', OLD_REPO, '--yes'])

    step(4, "replace %s's main with one commit holding the public tree" % NEW_REPO)
    work = tempfile.mkdtemp(prefix='ringpp_public_')
    print('    (a fresh repository in %s, the public tree copied in)' % work)
    if GO:
        shutil.copytree(PUB, work, dirs_exist_ok=True)
    sh(['git', 'init', '-q', '-b', 'main'], cwd=work)
    sh(['git', 'add', '-A'], cwd=work)
    sh(['git', 'commit', '-q', '-m', 'Ring++ 2: the register VM and the compiler for Ring, in one binary'], cwd=work)
    sh(['git', 'push', '--force', 'https://github.com/%s.git' % NEW_REPO, 'main:main'], cwd=work)
    # a push that replaces the history does not trigger pages.yml's path filter: start the deploy by hand
    sh(['gh', 'workflow', 'run', 'pages.yml', '--repo', NEW_REPO, '--ref', 'main'])

    step(5, "%s's About: what Ring++ is now" % NEW_REPO)
    print('    description: ' + ABOUT)
    sh(['gh', 'repo', 'edit', NEW_REPO, '--description', ABOUT, '--homepage', SITE] +
       [a for t in TOPICS for a in ('--add-topic', t)])

    step(6, 'publish %s with the two packages, archived' % TAG)
    zips = []
    for p in BUILT:
        z = os.path.join(PKG, archive_name(p))
        zips.append(z)
        print('    pack %s -> %s (afresh: an archive left by an earlier package must never be uploaded)' % (p, z))
        if GO:
            if os.path.exists(z):
                os.remove(z)
            write_archive(p, z)
    sh(['gh', 'release', 'create', TAG, '--repo', NEW_REPO, '--title', 'Ring++ 2', '--notes', NOTES] + zips)

    print('\n%s' % ('DONE: https://github.com/%s and https://mayouni.github.io/ringpp/ (Pages redeploys in a minute or two)' % NEW_REPO
                    if GO else 'dry run complete: nothing changed'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
