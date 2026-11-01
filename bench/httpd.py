"""rnxc's server natives (src/httpd.zig, rpp_http_*), driven over HTTP: a program that holds its own request loop
(bench/httpd/serve.ring, run by `rnxc exec`) and a client here that checks every byte it answers.

    python bench/httpd.py            RNXC=<path> picks the compiler (default zig-out/bin/rnxc.exe)

What it asks, of ONE server process:
  before     a reply with no request pending answers 0, and a request's parts read "" -- printed before listening
  parts      method, path, query, a header asked in another case than it was sent, a header not sent (""), and the
             body byte for byte: all 256 byte values, NUL among them; a body sent in pieces after its head; a 1 MB body
  reply      the status line, Content-Type, Content-Length and Connection: close, for 200, 404 and 503; a status
             outside 100-999 answered 500
  unanswered a request the program leaves unanswered is answered 500 by the next rpp_http_next, and the loop goes on
  broken     a connection that closes before its request is whole is passed over, and the loop goes on
  waiting    rpp_http_next(nWaitMs) answers -1 while nothing comes, so the loop runs between requests
  stop       the loop ends on request, the program prints its last line, exits 0, and wrote nothing to stderr

Not asked here, and why: a client that connects and sends nothing holds the loop 10 s (RECV_TIMEOUT_MS) before it is
given up -- too slow for the gate; a request over 64 MB, answered 413."""
import os, socket, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RNXC = os.environ.get('RNXC') or os.path.join(ROOT, 'zig-out', 'bin', 'rnxc.exe')
SERVE = os.path.join(HERE, 'httpd', 'serve.ring')
fails, passed = [], []


def say(ok, what):
    print(('ok    ' if ok else 'FAIL  ') + what, flush=True)
    (passed if ok else fails).append(what)


def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    p = s.getsockname()[1]
    s.close()
    return p


PORT = free_port()


def raw(data, pieces=(), pause=0.0):
    """Send `data` (and then each of `pieces`, `pause` seconds apart) on a connection of its own; read to the close.
    Returns (status, headers {lower name: value}, body bytes). A blocking socket: one with a timeout waits through
    select(), a Windows timer tick a request."""
    s = socket.create_connection(('127.0.0.1', PORT))
    s.sendall(data)
    for p in pieces:
        time.sleep(pause)
        s.sendall(p)
    got = b''
    while True:
        b = s.recv(65536)
        if not b:
            break
        got += b
    s.close()
    head, _, body = got.partition(b'\r\n\r\n')
    lines = head.decode('latin-1').split('\r\n')
    status = int(lines[0].split(' ')[1]) if lines[0].startswith('HTTP/1.1 ') else 0
    hdrs = {}
    for l in lines[1:]:
        k, _, v = l.partition(':')
        hdrs[k.strip().lower()] = v.strip()
    return status, hdrs, body, lines[0]


def req(method, target, body=b'', headers=()):
    h = ''.join('%s: %s\r\n' % kv for kv in headers)
    return raw(('%s %s HTTP/1.1\r\nHost: 127.0.0.1\r\n%sContent-Length: %d\r\nConnection: close\r\n\r\n'
                % (method, target, h, len(body))).encode('ascii') + body)


def echo_of(method, path, query, probe, body):
    return b'|'.join([method.encode(), path.encode(), query.encode(), probe.encode(), b'', str(len(body)).encode(), body])


def parts():
    st, h, b, line = req('GET', '/a/b?x=1&y=two', headers=[('X-PROBE', 'abc def')])
    say(st == 200 and b == echo_of('GET', '/a/b', 'x=1&y=two', 'abc def', b''),
        'parts: method, path, query, a header asked in another case, a header not sent -- %r' % b[:60])
    say(line == 'HTTP/1.1 200 OK' and h.get('content-type') == 'application/x-echo' and h.get('content-length') == str(len(b))
        and h.get('connection') == 'close', 'reply: status line, Content-Type, Content-Length, Connection: close')


def bodies():
    every = bytes(range(256))
    st, h, b, _ = req('POST', '/bytes', every)
    say(st == 200 and b == echo_of('POST', '/bytes', '', '', every), 'body: all 256 byte values, NUL among them, byte for byte')
    body = b'first half|second half'
    head = ('PUT /pieces HTTP/1.1\r\nContent-Length: %d\r\n\r\n' % len(body)).encode()
    st, h, b, _ = raw(head, [body[:10], body[10:]], pause=0.15)
    say(st == 200 and b == echo_of('PUT', '/pieces', '', '', body), 'body sent in two pieces after its head, 150 ms apart')


def big_body():
    big = bytes((i * 7 + 3) % 251 for i in range(1 << 20))
    st, h, b, _ = req('POST', '/big', big)
    say(st == 200 and b == echo_of('POST', '/big', '', '', big), 'a 1 MB body echoed byte for byte')


def statuses():
    for n, word in ((404, 'Not Found'), (503, 'Service Unavailable'), (42, 'Internal Server Error')):
        st, h, b, line = req('GET', '/status?%d' % n)
        want = 500 if n == 42 else n
        say(st == want and line == 'HTTP/1.1 %d %s' % (want, word) and h.get('content-type') == 'text/x-probe' and b == b'status %d' % n,
            'status %d answered as %r' % (n, line))


def unanswered():
    # a socket timeout here: a defect that leaves the request hanging must fail this case, not hang the check
    s = socket.create_connection(('127.0.0.1', PORT))
    s.settimeout(5)
    s.sendall(b'GET /noreply HTTP/1.1\r\nContent-Length: 0\r\n\r\n')
    try:
        got = b''
        while True:
            b = s.recv(65536)
            if not b:
                break
            got += b
    except socket.timeout:
        got = b'(nothing after 5 s)'
    s.close()
    say(got.startswith(b'HTTP/1.1 500 '), 'a request the program leaves unanswered: answered 500 for it -- %r' % got[:40])
    st, _, b, _ = req('GET', '/after')
    say(st == 200 and b.startswith(b'GET|/after|'), 'the loop goes on after it')


def broken():
    s = socket.create_connection(('127.0.0.1', PORT))
    s.sendall(b'GET /half HT')
    s.close()
    st, _, b, _ = req('GET', '/after-half')
    say(st == 200 and b.startswith(b'GET|/after-half|'), 'a connection closed before its request was whole is passed over')


def waiting():
    req('GET', '/idle')
    time.sleep(0.4)
    st, _, b, _ = req('GET', '/idle')
    say(st == 200 and b.isdigit() and int(b) >= 3, 'rpp_http_next(50) answered -1 while nothing came: %s times in 0.4 s' % b.decode())


def stop():
    st, _, b, _ = req('POST', '/stop')
    say(st == 200 and b == b'stopping', 'stop answered')


CASES = [('parts', parts), ('bodies', bodies), ('1 MB', big_body), ('statuses', statuses), ('unanswered', unanswered),
         ('broken', broken), ('waiting', waiting), ('stop', stop)]


def main():
    if not os.path.isfile(RNXC):
        print('no rnxc at ' + RNXC)
        return 1
    env = dict(os.environ, RPP_HTTPD_PORT=str(PORT))
    proc = subprocess.Popen([RNXC, 'exec', SERVE], cwd=HERE, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    t0 = time.time()
    while True:
        try:
            socket.create_connection(('127.0.0.1', PORT)).close()
            break
        except OSError:
            if proc.poll() is not None or time.time() - t0 > 30:
                out, err = proc.communicate(timeout=10) if proc.poll() is not None else (b'', b'')
                print('FAIL  the server did not listen on %d: %s %s' % (PORT, out[-300:], err[-300:]))
                return 1
            time.sleep(0.05)
    print('serving on 127.0.0.1:%d in %.0f ms (%s)' % (PORT, (time.time() - t0) * 1000, RNXC))
    # (the readiness probe above connected and closed at once: no request, passed over -- the `broken` case below)
    for name, case in CASES:
        try:
            case()
        except Exception as e:  # noqa: BLE001 -- a case that breaks is a FAIL line, and the cases after it still run
            say(False, '%s: the client failed: %r' % (name, e))
    try:
        out, err = proc.communicate(timeout=20)
    except subprocess.TimeoutExpired:
        proc.kill()
        out, err = proc.communicate(timeout=20)
        say(False, 'the server did not stop when asked')
    lines = out.decode('utf-8', 'replace').replace('\r', '').strip().split('\n')
    say(lines[:3] == ['reply with nothing pending: 0', 'method with nothing pending: []', 'listening'],
        'before a request: reply answers 0, the parts read "" -- %r' % lines[:2])
    say(proc.returncode == 0 and lines[-1] == 'done', 'the loop ended and the program ran on: exit %d, last line %r' % (proc.returncode, lines[-1]))
    say(err.strip() == b'', 'nothing on stderr' + ('' if not err.strip() else ': %r' % err[:200]))
    print()
    if fails:
        print('HTTPD FAILED -- %d of %d checks: %s' % (len(fails), len(fails) + len(passed), '; '.join(f[:50] for f in fails)))
        return 1
    print('HTTPD OK -- %d checks' % len(passed))
    return 0


sys.exit(main())
