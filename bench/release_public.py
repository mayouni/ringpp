"""RELEASE: a new release of mayouni/ringpp carrying both packages -- run only at Mansour's word.

    python bench/release_public.py v2.0.1 notes.md          check and print; changes NOTHING
    python bench/release_public.py v2.0.1 notes.md --go     create the release and upload both archives

After the flip (bench/flip_public.py made v2.0.0) this is how a release is made. The checks are the flip's, because each
was paid for: a package is a COPY and has gone stale before, so a package whose rnxc is not byte for byte the one built
last (zig-out, zig-out-linux) is refused; Windows ships a zip and Linux a tar.gz with Unix modes (flip_public.
write_archive), because a zip written on Windows unpacks rnxc unexecutable. An archive already in runtime/package is
reused only when it is NEWER than every file of its package -- so the archive that was unpacked and tested is the one
uploaded -- and packed afresh otherwise. The tag must not exist. GitHub makes the newest release `latest`, which every
page of the site links to, so the site needs no change."""
import json, os, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import flip_public as F  # noqa: E402  (its own --go is read only by its main(), never called here)

REPO = 'mayouni/ringpp'
GO = '--go' in sys.argv
ARGS = [a for a in sys.argv[1:] if not a.startswith('--')]


def newest(root):
    t = 0.0
    for dp, dn, fn in os.walk(root):
        for f in fn:
            t = max(t, os.path.getmtime(os.path.join(dp, f)))
    return t


def main():
    if len(ARGS) != 2:
        raise SystemExit('usage: python bench/release_public.py <tag> <notes.md> [--go]')
    tag, notes = ARGS
    if not os.path.exists(notes):
        raise SystemExit('no notes file at ' + notes)
    print('RELEASE %s -- %s' % (tag, 'DOING IT' if GO else 'dry run: nothing changes; --go does it'))

    print('\n1. the tag')
    r = subprocess.run(['gh', 'release', 'view', tag, '--repo', REPO], capture_output=True, text=True)
    if r.returncode == 0:
        raise SystemExit('    %s already exists on %s; nothing done' % (tag, REPO))
    print('    %s does not exist yet' % tag)

    print('\n2. the packages carry the rnxc built last')
    for p, (prefix, exe) in F.BUILT.items():
        built = os.path.join(F.ROOT, prefix, 'bin', exe)
        packed = os.path.join(F.PKG, p, 'bin', exe)
        with open(built, 'rb') as a, open(packed, 'rb') as b:
            if a.read() != b.read():
                raise SystemExit('    %s does not carry the rnxc in %s/bin -- re-lay it (bench/package.py)' % (p, prefix))
        print('    %s: its rnxc is %s/bin\'s (%s)' % (p, prefix, time.strftime('%Y-%m-%d %H:%M', time.localtime(os.path.getmtime(built)))))

    print('\n3. the archives')
    files = []
    for p in F.BUILT:
        out = os.path.join(F.PKG, F.archive_name(p))
        fresh = os.path.exists(out) and os.path.getmtime(out) > newest(os.path.join(F.PKG, p))
        if fresh:
            print('    %s: reused -- newer than every file of its package (%s bytes)' % (os.path.basename(out), format(os.path.getsize(out), ',')))
        else:
            print('    %s: packed afresh' % os.path.basename(out))
            if os.path.exists(out):
                os.remove(out)
            F.write_archive(p, out)
        files.append(out)

    print('\n4. the release')
    cmd = ['gh', 'release', 'create', tag, '--repo', REPO, '--title', 'Ring++ ' + tag.lstrip('v'), '--notes-file', notes] + files
    print('    $ ' + ' '.join(os.path.basename(c) if os.sep in c else c for c in cmd))
    if not GO:
        print('\ndry run complete: nothing changed')
        return 0
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit('FAILED: ' + (r.stderr or r.stdout)[-800:])
    got = json.loads(subprocess.run(['gh', 'release', 'view', tag, '--repo', REPO, '--json', 'assets,url'],
                                    capture_output=True, text=True).stdout)
    sizes = {a['name']: a['size'] for a in got['assets']}
    for f in files:
        n = os.path.basename(f)
        ok = sizes.get(n) == os.path.getsize(f)
        print('    %s %s (%s bytes)' % (n, 'uploaded' if ok else 'SIZE DIFFERS', format(sizes.get(n, 0), ',')))
    print('\nDONE: ' + got['url'])
    return 0


if __name__ == '__main__':
    sys.exit(main())
