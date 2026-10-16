"""THE PUBLIC TREE: what of `next` becomes the main of github.com/mayouni/ringpp (Mansour, 2026-10-15: "Ring++ only").

    python bench/public_tree.py              lay it out in runtime/public/ringpp and check it
    python bench/public_tree.py --list       print what goes in and what stays out, by top-level path
    python bench/public_tree.py --rev=<rev>  from another commit than HEAD

It takes the TRACKED files of a commit with `git archive` -- never the working tree, so nothing uncommitted can leak -- and leaves
out what stays private or belongs to the archive:

    haro/                 Haro's design and spike: private until Haro's own announcement
    CLAUDE.md, .claude/   the AI sessions' brief and their dev config
    upstream/             the draft pull requests to Ring: no longer a goal
    docs/<library era>    the documents of the library era, archived with it in github.com/mayouni/ringpp-old

NOTES.md's first line, which says PRIVATE, is rewritten. The result is then CHECKED: no excluded path may remain, and no file may
carry a marker that says it is private. Publishing it -- an orphan commit pushed to origin/main, after the old main is pushed to
mayouni/ringpp-old -- is a separate step, taken only at Mansour's word."""
import io, os, shutil, subprocess, sys, tarfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, 'runtime', 'public', 'ringpp')

EXCLUDE_PREFIXES = ('haro/', '.claude/', 'upstream/')
EXCLUDE_FILES = {'CLAUDE.md'}
# docs/ of the library era (2026-08): they describe the library, the CLI and the plans of that time
LIBRARY_ERA_DOCS = {'ANDROID.md', 'BASELINES.md', 'BUILD-OPTIONS.md', 'CASE-SOFTANZA.md', 'CASE-TYPE-SAFETY.md',
                    'CHECKER-FRONTIER.md', 'CLI.md', 'COUPLING.md', 'DESIGN.md', 'DESIGN_BUILD.md', 'DESIGN_TOOLCHAIN.md',
                    'MATRIX.md', 'P6-SOFTANZA-PROMPT.md', 'P6-SOFTANZA.md', 'PHASE_PLAN.md', 'SIBLINGS.md', 'UPSTREAM_NOTES.md',
                    'VM-CONTRACT.md', 'WORKLOADS.md'}
# a line that marks a file private, anywhere in the published text
PRIVATE_MARKERS = ('(PRIVATE)',)
NOTES_TITLE = '# rnx-spike -- the first measurements of the VM, 2026-08-29 to 2026-09-04'


def excluded(path):
    if path in EXCLUDE_FILES or path.startswith(EXCLUDE_PREFIXES):
        return True
    return path.startswith('docs/') and path[len('docs/'):] in LIBRARY_ERA_DOCS


def tracked(rev):
    out = subprocess.run(['git', '-C', ROOT, 'ls-tree', '-r', '-z', '--name-only', rev], capture_output=True, check=True).stdout
    return [p for p in out.decode('utf-8').split('\0') if p]


def main():
    rev = next((a.split('=', 1)[1] for a in sys.argv[1:] if a.startswith('--rev=')), 'HEAD')
    paths = tracked(rev)
    keep = [p for p in paths if not excluded(p)]
    if '--list' in sys.argv:
        tops = {}
        for p in paths:
            t = p.split('/')[0] if '/' in p else p
            k = 'out' if excluded(p) else 'in'
            tops.setdefault((t, k), 0)
            tops[(t, k)] += 1
        for (t, k), n in sorted(tops.items()):
            print('%-4s %5d  %s' % (k, n, t))
        print('%d of %d tracked files go public' % (len(keep), len(paths)))
        return 0
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    tar = subprocess.run(['git', '-C', ROOT, 'archive', '--format=tar', rev, '--'] + keep, capture_output=True, check=True).stdout
    with tarfile.open(fileobj=io.BytesIO(tar)) as t:
        t.extractall(OUT, filter='data')
    notes = os.path.join(OUT, 'NOTES.md')
    if os.path.exists(notes):
        s = io.open(notes, encoding='utf-8', newline='').read()
        nl = '\r\n' if '\r\n' in s else '\n'
        first, _, rest = s.partition(nl)
        io.open(notes, 'w', encoding='utf-8', newline='').write(NOTES_TITLE + nl + rest)
    # THE CHECK: nothing excluded, nothing marked private
    bad = []
    n = size = 0
    for dp, dn, fn in os.walk(OUT):
        for f in fn:
            p = os.path.join(dp, f)
            rel = os.path.relpath(p, OUT).replace(os.sep, '/')
            n += 1
            size += os.path.getsize(p)
            if excluded(rel):
                bad.append('excluded path present: ' + rel)
                continue
            if f.endswith(('.md', '.txt', '.html', '.ring', '.zig', '.py')) and rel != 'bench/public_tree.py':
                try:
                    text = io.open(p, encoding='utf-8', errors='replace').read()
                except OSError:
                    continue
                for m in PRIVATE_MARKERS:
                    if m in text:
                        bad.append('%s carries %r' % (rel, m))
    print('public tree %s: %d files, %.1f MB, from %s (%d tracked, %d left out)'
          % (OUT, n, size / 1e6, rev, len(paths), len(paths) - len(keep)))
    for b in bad:
        print('  REFUSED ' + b)
    print('PUBLIC TREE OK' if not bad else 'PUBLIC TREE REFUSED: %d problem(s)' % len(bad))
    return 0 if not bad else 1


if __name__ == '__main__':
    sys.exit(main())
