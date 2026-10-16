# -*- coding: utf-8 -*-
"""Contract 5.1's socket, driven for real.

Starts the binary serving examples/09's tree, GETs the page, POSTs the
form a browser would post, and checks the model it leaves is the one the
terminal renderers leave. Unlike the console probe this opens no window,
so it runs in the gate rather than behind a flag -- a socket can be
spoken to, and what can be spoken to can be checked.
"""
import os, subprocess, sys, time, urllib.request, urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RNXC = os.path.join(ROOT, 'zig-out', 'bin', 'rnxc.exe')
EX = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'examples', '09-a-window-in-the-terminal')
PORT = 8771
WANT = 'model:name=amina|events:change,name,amina|click,OK,|submit,,|'


def get(url, data=None, timeout=5):
    req = urllib.request.Request(url, data=data)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode('utf-8', 'replace')


def main():
    live = os.path.join(EX, 'web_live.ring')
    if not os.path.exists(RNXC) or not os.path.exists(live):
        print('SKIP: no binary or no web_live.ring')
        return 0
    src = open(live, encoding='utf-8').read().replace('8770', str(PORT))
    tmp = os.path.join(EX, '_web_probe.ring')
    open(tmp, 'w', encoding='utf-8', newline='').write(src)
    p = subprocess.Popen([RNXC, 'exec', '_web_probe.ring'], cwd=EX,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    out = ''
    try:
        page = None
        for _ in range(40):                       # up to ~4s for the listener
            try:
                page = get('http://127.0.0.1:%d/' % PORT)
                break
            except Exception:
                time.sleep(0.1)
        if page is None:
            print('no page served on %d' % PORT)
            return 1
        if '<input name="name"' not in page or 'value="OK"' not in page:
            print('page is not the tree: ' + page[:80].replace('\n', ' '))
            return 1
        # the POST is answered with a 303 and urllib follows it; after the
        # final screen the farewell page is what answers, and if the timing
        # goes the other way the socket is simply gone. Either is a
        # delivered POST, which is what this checks.
        try:
            get('http://127.0.0.1:%d/' % PORT, data=b'name=amina&press=OK')
        except Exception:
            pass
        p.wait(timeout=10)
        out = p.stdout.read().decode('utf-8', 'replace')
    except Exception as e:
        print('probe failed: %s' % e)
        return 1
    finally:
        if p.poll() is None:
            p.kill()
        try:
            os.remove(tmp)
        except OSError:
            pass
    got = [l.strip()[8:].strip() for l in out.split('\n') if l.strip().startswith('serial:')]
    if not got:
        print('no serial line; last output: ' + ' | '.join(
            [l for l in out.split('\n') if l.strip()][-2:]))
        return 1
    if got[0] != WANT:
        print('model differs from the terminal renderers')
        print('  got  ' + got[0])
        print('  want ' + WANT)
        return 1
    print('served the tree, took the form, same model as the terminal')
    return 0


if __name__ == '__main__':
    sys.exit(main())
