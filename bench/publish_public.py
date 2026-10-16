"""PUBLISH AGAIN: a new commit of the public tree on top of mayouni/ringpp's main -- after the flip, the only way the public
repository and the site move. Run only at Mansour's word.

    python bench/publish_public.py "message"          print what would change; changes NOTHING
    python bench/publish_public.py "message" --go     do it

The flip (bench/flip_public.py, 2026-10-16) put ONE commit of bench/public_tree.py's tree on main. Every later publish is the
same tree laid out again from HEAD and committed ON TOP of main -- never a force push, never a push of `next`. The commit
message is the argument; the public history reads as a list of what changed and when, nothing more. GitHub Pages redeploys
when the push touches site/**; the script checks that a run started and dispatches one when it did not (a lesson of the
flip)."""
import os, shutil, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PUB = os.path.join(ROOT, 'runtime', 'public', 'ringpp')
REPO = 'mayouni/ringpp'
URL = 'https://github.com/%s.git' % REPO
GO = '--go' in sys.argv
MSG = next((a for a in sys.argv[1:] if not a.startswith('--')), None)


def run(cmd, cwd=ROOT, check=True, quiet=False):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, encoding='utf-8', errors='replace')
    if check and r.returncode != 0:
        raise SystemExit('FAILED (%d): %s\n%s' % (r.returncode, ' '.join(cmd), (r.stderr or r.stdout)[-1200:]))
    return r.stdout


def main():
    if not MSG:
        raise SystemExit('usage: python bench/publish_public.py "what changed" [--go]')
    print('PUBLISH -- %s' % ('DOING IT' if GO else 'dry run: nothing changes; --go does it'))

    print('\n1. the public tree, from HEAD')
    r = subprocess.run([sys.executable, os.path.join(HERE, 'public_tree.py')], cwd=ROOT, capture_output=True, text=True)
    print('    ' + r.stdout.strip().split('\n')[-1])
    if r.returncode != 0:
        raise SystemExit('the public tree is refused; nothing done')

    print('\n2. a clone of %s main, the tree replaced, one commit on top' % REPO)
    work = tempfile.mkdtemp(prefix='ringpp_publish_')
    run(['git', 'clone', '-q', '--depth', '1', '--branch', 'main', URL, work])
    base = run(['git', 'rev-parse', '--short', 'HEAD'], cwd=work).strip()
    print('    main is %s' % base)
    for name in os.listdir(work):
        if name == '.git':
            continue
        p = os.path.join(work, name)
        shutil.rmtree(p) if os.path.isdir(p) else os.remove(p)
    shutil.copytree(PUB, work, dirs_exist_ok=True)
    run(['git', 'add', '-A'], cwd=work)
    stat = run(['git', 'diff', '--cached', '--stat'], cwd=work).strip()
    if not stat:
        print('    nothing differs from main; nothing to publish')
        return 0
    print('    ' + stat.replace('\n', '\n    '))
    touches_site = any(l.strip().startswith('site/') for l in stat.split('\n'))
    print('    commit: ' + MSG)
    if not GO:
        print('\ndry run complete: nothing changed')
        return 0
    run(['git', 'commit', '-q', '-m', MSG], cwd=work)
    run(['git', 'push', 'https://github.com/%s.git' % REPO, 'main:main'], cwd=work)
    new = run(['git', 'rev-parse', '--short', 'HEAD'], cwd=work).strip()
    print('    pushed %s -> %s' % (base, new))

    print('\n3. the site')
    if not touches_site:
        print('    site/ unchanged; Pages has nothing to do')
        return 0
    time.sleep(15)
    runs = run(['gh', 'run', 'list', '--repo', REPO, '--workflow', 'pages.yml', '--limit', '1',
                '--json', 'headSha,status,databaseId'], check=False)
    if new[:7] in runs:
        print('    Pages run started on the push: ' + runs.strip())
    else:
        print('    no Pages run on the push; dispatching one')
        run(['gh', 'workflow', 'run', 'pages.yml', '--repo', REPO, '--ref', 'main'])
    print('\nDONE: https://github.com/%s -- the site follows in a minute or two' % REPO)
    return 0


if __name__ == '__main__':
    sys.exit(main())
