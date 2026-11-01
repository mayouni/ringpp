"""THE RESIDENT VM's guard: `rnxc resident <file.ring>...`, one program fed files one at a time (rnxc.zig, residentMain; co.compileAdmit).

    python bench/resident.py            RNXC=<path> to measure another build

Six questions, each answered by running, never by reading the code:

  1. THE PROBES (bench/resident/r01..r10). A first file with a class; a file that calls a function no file has defined yet (R3 when it runs); the
     file that defines it, after which that call reaches it; one file for each of the four refusals (a statement that does not compile, a function
     already defined, a class after the first file, a new global an admitted function reads as an unassigned local); a top level that stops on an
     error nothing catches while the program carries on; and a last file that asks what is left -- through eval, an admitted object, the globals.
     The whole transcript must equal bench/resident/expect.txt, admission times blanked. After every refusal the program's size is printed, and it
     must be the size before it: a refused file leaves the program exactly as it was.
  2. RING'S OWN ANSWER for the files that are admitted: each one's text eval'd in order on the ORACLE (oracle_admitted.ring), as RingServ's host
     runs its library into one Ring state. Every line the files print must be the oracle's; the one difference allowed is how the uncaught raise of
     r09 is shown (Ring's report here, the driver's catch there).
  3. RINGSERV'S LIBRARY, its fourteen ringlib files in its host's order (D:\\GitHub\\ringserv, read and never written; RINGSERV=<checkout>): as
     written, five are admitted and nine refused, each for top-level globals read bare in a function (Rule A); migrated into a copy under runtime/
     (bench/resident_migrate.py), all fourteen are admitted, RingServ's own load check finds every promised function, and a probe of its library at
     work (ringserv_behaviour.ring -- a call from serv.ring that reaches data.ring, admitted after it, among them) prints on rnxc what the oracle
     prints for the same copy, and what the oracle prints for the files as written.

  4. RUNG 2, ADMISSION FROM INSIDE: in_host.ring admits files and code while it runs (`admitfile`, `admitcode`) and at once calls what
     they define, compiled before it existed; a refusal is an error it catches, an admitted top level that raises reaches its try, and an
     admission may admit, run three frames deep, and be reached by eval. Its transcript is expect_inside.txt, and every line it means
     alike with Ring's eval(read()) (oracle_inside.ring) is Ring's.

  5. RUNG 3, A RUNNING FUNCTION REPLACED: rp_host.ring admits rp_lib.ring and replaces its functions while it runs
     (`replacecode`, `replacefile`): the library's own static calls, the host's late calls, a call by name and eval all reach
     the new body; a replacement answering another kind of value than its callers were compiled against; a function replaced
     while its frame runs, and in the middle of its own recursion (the old frames finish the old body, the next call runs the
     new); a file rewritten on disk and replaced by its path; and four refusals. The transcript is expect_replace.txt. The same
     from the driver (`--replace`), expect_replace_drv.txt. Ring has no answer to compare with -- it refuses a function defined
     twice (C22) -- so these transcripts are golden, and say so.
  6. RUNG 4, CLASSES AFTER THE FIRST FILE: cl_host.ring admits cl_shape.ring (classes) and cl_square.ring (a class from one
     admitted before it), then REPLACES Shape while its objects exist: they answer with the new methods, a static `This.Area()`
     in an old method included; the class inheriting from it too; new objects get the new initial values; a method replaced
     while it runs; and six refusals (layout, parent, a parameter count, an added init, code at `new`, C26). The transcript is
     expect_classes.txt; every line before the first replacement is Ring's (oracle_classes.ring, eval(read()) for
     admitfile), a `new` compiled before its class existed among them (rung 8 finds the class by name, as Ring does).

     And ac_host.ring: a getter the program already held, for an attribute a later class brings -- the class tables grow
     with each admission (rung 5), so the new name must still find it; every line is Ring's (oracle_accessor.ring). And
     am_host.ring: a method addmethod attached at run time survives the admissions after it, a class replacement included;
     every line before the replacement is Ring's (oracle_addmethod.ring).
  8. RUNG 6, RELEASE: rl_host.ring admits code, calls it and RELEASES it -- the function gone by every way of calling it,
     its name free for a new body, a constant and a list the host kept still alive; only the last admission, so a stack;
     not one that defined a class or a lambda or replaced anything, nor from inside its own code; a file by its path; 500
     rounds of admit, call, release leaving the program its size. The driver's `--release` too (expect_release_drv.txt).
     Golden -- Ring has no release. Under section 7's check every release must give back the program's bytes exactly.
  9. RUNG 7, OBJECTS MOVED TO A CLASS'S NEW LAYOUT: gl_host.ring admits a class, makes objects (one held only in a list),
     then REPLACES the class with attributes added -- the objects made before take them at the first access that needs
     them, each starting as declared, a list a list of its own; a second growth stacks on the first; refused: a reorder, a
     removal, a computed starting value, region code that uses a gained attribute, one declared twice, and a class with a
     subclass the program holds. Golden (Ring has no replacement), and the migrated object's lines are Ring's for an
     object made under the new class from the start with the same values (gl_oracle.ring).
 10. RUNG 8, THE LATE `new`: every `new` in ln_host.ring is compiled before ln_gadget.ring and ln_sub.ring are admitted --
     R11 naming the class until one is, then the class found by name: its initial values, init with its arguments (and
     the arguments not run, the object made, for a class with none -- C-33), the target holding the object before them
     (F-91), a brace, any case of the name, a class from a parent admitted before it, a class replaced since (its new
     initial values), and a site in code that was released. Golden, and every line before the replacement is Ring's
     (ln_oracle.ring) but two: C-33's, and a brace's name the class lacks -- a variable on Ring, R12 here, because the
     class was unknown when the brace was compiled.
  7. RUNG 5, THE LIVE COMPILER: every run above again, twice. Under RNXC_RESIDENT_CHECK=1 each refused admission must leave
     the program's saved bytes exactly as they were, and each admitted one the VM's tables a whole build of the program gives
     (rnxc stops if not); under RNXC_RESIDENT_BLOB=1 the program is saved to bytes and restored after every admission -- the
     path before rung 5. All three must print the same transcript.

ON LINUX: `python bench/resident.py --platform=linux` asks all of it of the Linux rnxc (zig-out-linux) and the Linux oracle
(runtime/linux-x64/ring) under WSL, as bench/exec_wsl.py does the exec probes; the transcripts are the same files.

A part that cannot run is named, never passed in silence."""
import os, re, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RES = os.path.join(HERE, 'resident')
LINUX = '--platform=linux' in sys.argv
RNXC = os.environ.get('RNXC') or os.path.join(ROOT, 'zig-out-linux' if LINUX else 'zig-out', 'bin', 'rnxc' if LINUX else 'rnxc.exe')
RING = os.environ.get('RING') or os.path.join(ROOT, 'runtime', 'linux-x64' if LINUX else 'win64', 'ring' if LINUX else 'ring.exe')
DISTRO = os.environ.get('RPP_WSL_DISTRO', 'Ubuntu')
RINGSERV = os.environ.get('RINGSERV') or r'D:\GitHub\ringserv'
PROBES = ['r01_base.ring', 'r02_forward.ring', 'r03_later.ring', 'r04_refused_stmt.ring', 'r05_after.ring', 'r06_redefine.ring',
          'r07_class.ring', 'r08_global.ring', 'r09_error.ring', 'r10_eval.ring']
LIB = ['json_c.ring', 'serv.ring', 'data.ring', 'generic.ring', 'contract.ring', 'topology.ring', 'sync.ring', 'jsserv.ring', 'actor.ring',
       'journal.ring', 'gesture.ring', 'family.ring', 'config.ring', 'testing.ring']
AS_WRITTEN_ADMITTED = {'json_c.ring', 'data.ring', 'generic.ring', 'sync.ring', 'family.ring'}
fails = []
passed = []


def say(ok, what):
    print(('ok    ' if ok else 'FAIL  ') + what)
    (passed if ok else fails).append(what)


def wsl_path(p):
    p = os.path.abspath(p).replace(chr(92), '/')
    return '/mnt/' + p[0].lower() + p[2:]


def run(cmd, cwd, env=None):
    if LINUX and cmd[0] in (RNXC, RING):
        # under WSL, named (its default here is docker-desktop): the folder, every Windows path given, and the RNXC_
        # variables the run asks for (WSL inherits none); the oracle finds its zip extension beside itself, as an install does
        lx = wsl_path(cmd[0])
        args = [wsl_path(a) if len(a) > 2 and a[1] == ':' else a for a in cmd[1:]]
        extra = ['%s=%s' % (k, v) for k, v in (env or os.environ).items() if k.startswith('RNXC_')]
        cmd = ['wsl.exe', '-d', DISTRO, '--cd', wsl_path(cwd), '--', 'env', 'LD_LIBRARY_PATH=' + lx.rsplit('/', 1)[0]] + extra + [lx] + args
        r = subprocess.run(cmd, capture_output=True, timeout=300)
        if r.returncode in (126, 127):
            raise SystemExit('FAIL resident on Linux: %s did not run (exit %d) -- %s' % (lx, r.returncode, r.stderr.decode('utf-8', 'replace').strip()[:200]))
    else:
        r = subprocess.run(cmd, cwd=cwd, capture_output=True, timeout=300, env=env)
    return r.returncode, r.stdout.decode('utf-8', 'replace').replace('\r', ''), r.stderr.decode('utf-8', 'replace').replace('\r', '')


def blank(text):
    # the admission's time, and the instruction count -- which any change to code generation moves; the refusals' "unchanged" is
    # checked against this run's own counts below
    return re.sub(r'\d+ instruction', '# instruction', re.sub(r', \d+ ms -- ', ', # ms -- ', text))


def program_lines(text):
    """The lines the files print: not the verdicts, not an error report."""
    out = []
    for l in text.split('\n'):
        if re.match(r'(admitted |refused  |resident: |         |Line \d+ |In raise\(\))', l) or l == '':
            continue
        out.append(l)
    return out


def main():
    if not os.path.exists(RNXC):
        print('no rnxc at ' + RNXC)
        return 1
    # ---- 1. the probes
    code, out, err = run([RNXC, 'resident'] + PROBES, RES)
    want = open(os.path.join(RES, 'expect.txt'), encoding='utf-8').read().replace('\r', '')
    same = blank(out) == want
    say(code == 0 and same, 'probes: the transcript is bench/resident/expect.txt (%d lines)' % len(want.split('\n')))
    if not same:
        a, b = blank(out).split('\n'), want.split('\n')
        for i in range(max(len(a), len(b))):
            x, y = a[i] if i < len(a) else '<none>', b[i] if i < len(b) else '<none>'
            if x != y:
                print('      line %d: got  %s\n               want %s' % (i + 1, x, y))
                break
    if err.strip():
        say(False, 'probes: rnxc wrote to stderr: ' + err.strip().split('\n')[0][:100])
    # every refusal leaves the size the last admission printed
    last, held = None, True
    for l in out.split('\n'):
        m = re.search(r'program: (.*)$', l)
        if l.startswith('admitted '):
            last = m.group(1)
        m2 = re.search(r'program unchanged: (.*)$', l)
        if m2 and m2.group(1) != last:
            held = False
    say(held and last is not None, 'probes: after each of the 4 refusals the program is the size it was')

    # ---- 2. the oracle
    if not os.path.exists(RING):
        print('SKIP  oracle: absent at %s -- NOT compared (tests/b2_runtimes.ps1 builds it)' % RING)
    else:
        code2, ora, _ = run([RING, 'oracle_admitted.ring'], RES)
        ours = program_lines(out)
        theirs = [l for l in ora.split('\n') if l and not l.startswith('error: r09')]
        say(ours == theirs, 'oracle: the admitted files print what Ring prints, %d lines' % len(theirs))
        if ours != theirs:
            for x, y in zip(ours + ['<none>'] * 5, theirs + ['<none>'] * 5):
                if x != y:
                    print('      rnxc   %s\n      oracle %s' % (x, y))
                    break

    # ---- 4 (rung 2). Admissions from INSIDE the running program: in_host.ring admits files and code while it runs and calls what
    # they define at once -- compiled before it existed -- through a refusal it catches, an admitted top level that raises, an
    # admission inside an admission, eval, the same file twice, a redefinition, and a call from three frames deep.
    code6, out6, err6 = run([RNXC, 'resident', 'in_host.ring'], RES)
    want6 = open(os.path.join(RES, 'expect_inside.txt'), encoding='utf-8').read().replace('\r', '')
    same6 = blank(out6) == want6
    say(code6 == 0 and same6 and not err6.strip(), 'inside: the transcript is bench/resident/expect_inside.txt (%d lines)' % len(want6.split('\n')))
    if not same6:
        a, b = blank(out6).split('\n'), want6.split('\n')
        for i in range(max(len(a), len(b))):
            x, y = a[i] if i < len(a) else '<none>', b[i] if i < len(b) else '<none>'
            if x != y:
                print('      line %d: got  %s\n               want %s' % (i + 1, x, y))
                break
    if os.path.exists(RING):
        # Ring's answer where it has one (eval(read()) for admitfile): every line both programs mean alike. Left out: the
        # refusals, which differ in kind or in words (Ring refuses the redefinitions too, C22 caught as R42, and accepts
        # in_bad.ring, which Rule A refuses here), and the host's last two lines, which Ring never prints -- it ends without
        # a word after the caught raise in an eval'd file (C-21's family).
        _, ora6, _ = run([RING, 'oracle_inside.ring'], RES)
        drop = ('refused:', 'after the refusal:', 'inside eval:', 'twice:', 'redefined:', 'its function stays:', 'host: end',
                'never printed', 'eval Line', 'eval errors count')
        ours6 = [l for l in program_lines(out6) if not l.startswith(drop)]
        theirs6 = [l for l in ora6.split('\n') if l and not l.startswith(drop)]
        say(ours6 == theirs6 and len(theirs6) >= 15, 'inside: every line both mean alike is Ring\'s, %d lines' % len(theirs6))
        if ours6 != theirs6:
            for x, y in zip(ours6 + ['<none>'] * 5, theirs6 + ['<none>'] * 5):
                if x != y:
                    print('      rnxc   %s\n      oracle %s' % (x, y))
                    break

    # ---- 5 (rung 3). Functions REPLACED in the running program, from inside it and from the driver. Golden: Ring has
    # no replacement (a function defined twice is C22), so the transcripts are ours, pinned.
    for args, want_file, what in ((['rp_host.ring'], 'expect_replace.txt', 'replace: from inside, the transcript is'),
                                  (['rp_drv_lib.ring', 'rp_drv_v2.ring', '--replace', 'rp_drv_v2.ring', '--replace', 'rp_drv_none.ring'],
                                   'expect_replace_drv.txt', 'replace: from the driver, the transcript is')):
        code7, out7, err7 = run([RNXC, 'resident'] + args, RES)
        want7 = open(os.path.join(RES, want_file), encoding='utf-8').read().replace('\r', '')
        same7 = blank(out7) == want7
        say(code7 == 0 and same7 and not err7.strip(), '%s bench/resident/%s (%d lines, golden)' % (what, want_file, len(want7.split('\n'))))
        if not same7:
            a, b = blank(out7).split('\n'), want7.split('\n')
            for i in range(max(len(a), len(b))):
                x, y = a[i] if i < len(a) else '<none>', b[i] if i < len(b) else '<none>'
                if x != y:
                    print('      line %d: got  %s\n               want %s' % (i + 1, x, y))
                    break
    if os.path.exists(os.path.join(RES, 'rp_mod.ring')):
        say(False, 'replace: rp_host.ring left rp_mod.ring behind')

    # ---- 6 (rung 4). Classes admitted after the first file, and a class replaced while its objects exist.
    code8, out8, err8 = run([RNXC, 'resident', 'cl_host.ring'], RES)
    want8 = open(os.path.join(RES, 'expect_classes.txt'), encoding='utf-8').read().replace('\r', '')
    same8 = blank(out8) == want8
    say(code8 == 0 and same8 and not err8.strip(), 'classes: the transcript is bench/resident/expect_classes.txt (%d lines)' % len(want8.split('\n')))
    if not same8:
        a, b = blank(out8).split('\n'), want8.split('\n')
        for i in range(max(len(a), len(b))):
            x, y = a[i] if i < len(a) else '<none>', b[i] if i < len(b) else '<none>'
            if x != y:
                print('      line %d: got  %s\n               want %s' % (i + 1, x, y))
                break
    if os.path.exists(RING):
        # Ring's answer up to the first replacement (Ring refuses a class defined twice, C26) -- the `new` compiled before
        # its class existed included: rung 8 finds the class by name, as Ring does
        _, ora8, _ = run([RING, 'oracle_classes.ring'], RES)
        def upto(lines):
            out = []
            for l in lines:
                if l.startswith('replace shape:') or l == '':
                    break
                out.append(l)
            return out
        ours8 = upto(program_lines(out8))
        theirs8 = upto(ora8.split('\n'))
        say(ours8 == theirs8 and len(theirs8) >= 8, 'classes: every line before the first replacement is Ring\'s, %d lines' % len(theirs8))
        if ours8 != theirs8:
            for x, y in zip(ours8 + ['<none>'] * 5, theirs8 + ['<none>'] * 5):
                if x != y:
                    print('      rnxc   %s\n      oracle %s' % (x, y))
                    break

    # ---- 6b (rung 5). A getter the program already held, for an attribute a later class brings: the class tables GROW with
    # each admission, so the new name must still find it. Ring answers every line (eval(read()) for admitfile).
    code9, out9, err9 = run([RNXC, 'resident', 'ac_host.ring'], RES)
    want9 = open(os.path.join(RES, 'expect_accessor.txt'), encoding='utf-8').read().replace('\r', '')
    same9 = blank(out9) == want9
    say(code9 == 0 and same9 and not err9.strip(), 'accessors: the transcript is bench/resident/expect_accessor.txt (%d lines)' % len(want9.split('\n')))
    if not same9:
        a, b = blank(out9).split('\n'), want9.split('\n')
        for i in range(max(len(a), len(b))):
            x, y = a[i] if i < len(a) else '<none>', b[i] if i < len(b) else '<none>'
            if x != y:
                print('      line %d: got  %s\n               want %s' % (i + 1, x, y))
                break
    if os.path.exists(RING):
        _, ora9, _ = run([RING, 'oracle_accessor.ring'], RES)
        ours9 = program_lines(out9)
        theirs9 = [l for l in ora9.split('\n') if l]
        say(ours9 == theirs9 and len(theirs9) >= 5, 'accessors: every line is Ring\'s, %d lines' % len(theirs9))
    # ...and a method addmethod attached at run time survives the admissions after it (the method table only grows)
    code10, out10, err10 = run([RNXC, 'resident', 'am_host.ring'], RES)
    want10 = open(os.path.join(RES, 'expect_addmethod.txt'), encoding='utf-8').read().replace('\r', '')
    say(code10 == 0 and blank(out10) == want10 and not err10.strip(), 'addmethod: the transcript is bench/resident/expect_addmethod.txt (%d lines)' % len(want10.split('\n')))
    if os.path.exists(RING):
        _, ora10, _ = run([RING, 'oracle_addmethod.ring'], RES)
        ours10 = [l for l in program_lines(out10) if not l.startswith('after Pet replaced')]
        theirs10 = []
        for l in ora10.split('\n'):
            if l == '' or l.startswith('eval Line'):
                break
            theirs10.append(l)
        say(ours10 == theirs10 and len(theirs10) >= 3, 'addmethod: every line before the replacement is Ring\'s, %d lines' % len(theirs10))

    # ---- 8 (rung 6). RELEASE: the program's last admission undone -- its functions, globals, constants and names gone, the
    # program as it was before it. Golden: Ring has no release. From inside the program, and from the driver (`--release`)
    for args, want_file, what in ((['rl_host.ring'], 'expect_release.txt', 'release: from inside, the transcript is'),
                                  (['rl_lib.ring', '--release', 'rl_lib.ring', 'rl_lib.ring', '--release', 'nosuch.ring'],
                                   'expect_release_drv.txt', 'release: from the driver, the transcript is')):
        code11, out11, err11 = run([RNXC, 'resident'] + args, RES)
        want11 = open(os.path.join(RES, want_file), encoding='utf-8').read().replace('\r', '')
        same11 = blank(out11) == want11
        say(code11 == 0 and same11 and not err11.strip(), '%s bench/resident/%s (%d lines, golden)' % (what, want_file, len(want11.split('\n'))))
        if not same11:
            a, b = blank(out11).split('\n'), want11.split('\n')
            for i in range(max(len(a), len(b))):
                x, y = a[i] if i < len(a) else '<none>', b[i] if i < len(b) else '<none>'
                if x != y:
                    print('      line %d: got  %s\n               want %s' % (i + 1, x, y))
                    break

    # ---- 9 (rung 7). A class replaced with attributes ADDED while its objects exist: they take them, starting as declared
    code12, out12, err12 = run([RNXC, 'resident', 'gl_host.ring'], RES)
    want12 = open(os.path.join(RES, 'expect_layout.txt'), encoding='utf-8').read().replace('\r', '')
    same12 = blank(out12) == want12
    say(code12 == 0 and same12 and not err12.strip(), 'layout: the transcript is bench/resident/expect_layout.txt (%d lines, golden)' % len(want12.split('\n')))
    if not same12:
        a, b = blank(out12).split('\n'), want12.split('\n')
        for i in range(max(len(a), len(b))):
            x, y = a[i] if i < len(a) else '<none>', b[i] if i < len(b) else '<none>'
            if x != y:
                print('      line %d: got  %s\n               want %s' % (i + 1, x, y))
                break
    if os.path.exists(RING):
        _, ora12, _ = run([RING, 'gl_oracle.ring'], RES)
        theirs12 = ora12.rstrip('\n').split('\n')
        ours12 = out12.split('\n')
        at12 = ours12.index(theirs12[0]) if theirs12 and theirs12[0] in ours12 else -1
        say(at12 >= 0 and ours12[at12:at12 + len(theirs12)] == theirs12 and len(theirs12) >= 8,
            'layout: a migrated object prints what Ring prints for one made under the new class, %d lines' % len(theirs12))

    # ---- 10 (rung 8). The late `new`: a `new K` compiled before any admission defined K reaches K once one does
    code13, out13, err13 = run([RNXC, 'resident', 'ln_host.ring'], RES)
    want13 = open(os.path.join(RES, 'expect_late.txt'), encoding='utf-8').read().replace('\r', '')
    same13 = blank(out13) == want13
    say(code13 == 0 and same13 and not err13.strip(), 'late new: the transcript is bench/resident/expect_late.txt (%d lines, golden)' % len(want13.split('\n')))
    if not same13:
        a, b = blank(out13).split('\n'), want13.split('\n')
        for i in range(max(len(a), len(b))):
            x, y = a[i] if i < len(a) else '<none>', b[i] if i < len(b) else '<none>'
            if x != y:
                print('      line %d: got  %s\n               want %s' % (i + 1, x, y))
                break
    if os.path.exists(RING):
        # Ring's answer up to the replacement (C26 there), less C-33's row and a brace's name the class lacks
        _, ora13, _ = run([RING, 'ln_oracle.ring'], RES)
        def upto13(lines):
            out = []
            for l in lines:
                if l.startswith('replace gadget:') or l == '':
                    break
                if not l.startswith(('no init:', 'brace, a name the class lacks:')):
                    out.append(l)
            return out
        ours13 = upto13(program_lines(out13))
        theirs13 = upto13(ora13.split('\n'))
        say(ours13 == theirs13 and len(theirs13) >= 15, 'late new: every line before the replacement is Ring\'s but C-33\'s and the brace\'s, %d lines' % len(theirs13))
        if ours13 != theirs13:
            for x, y in zip(ours13 + ['<none>'] * 5, theirs13 + ['<none>'] * 5):
                if x != y:
                    print('      rnxc   %s\n      oracle %s' % (x, y))
                    break

    # ---- 3. RingServ's library
    lib = os.path.join(RINGSERV, 'src', 'ringlib')
    if not all(os.path.exists(os.path.join(lib, f)) for f in LIB):
        print('SKIP  ringserv: its library is not at %s -- NOT measured' % lib)
    else:
        probe = os.path.join(RES, 'ringserv_provides.ring')
        beh = os.path.join(RES, 'ringserv_behaviour.ring')
        code3, out3, _ = run([RNXC, 'resident'] + LIB + [probe], lib)
        adm = {l.split(':')[0][9:] for l in out3.split('\n') if l.startswith('admitted ')}
        ref = [l for l in out3.split('\n') if l.startswith('refused  ')]
        rule_a = all('statement(s) do not compile' in l for l in ref if 'ringserv_provides' not in l)
        bare = all(('Rule A' in l or 'identifier' in l) for l in out3.split('\n') if re.match(r'         \S+\.ring:\d+ ', l))
        say(adm & set(LIB) == AS_WRITTEN_ADMITTED and len([l for l in ref if 'ringserv_provides' not in l]) == 9 and rule_a and bare,
            'ringserv as written: 5 of 14 admitted, 9 refused, every refused statement a top-level name read bare')
        copy = os.path.join(ROOT, 'runtime', 'resident', 'ringlib')
        c4, o4, e4 = run([sys.executable, os.path.join(HERE, 'resident_migrate.py'), lib, copy], ROOT)
        if c4 != 0:
            say(False, 'ringserv migrated: the copy was not written: ' + (o4 + e4).strip().split('\n')[-1])
        else:
            code5, out5, err5 = run([RNXC, 'resident'] + LIB + [probe, beh], copy)
            n_adm = len([l for l in out5.split('\n') if l.startswith('admitted ')])
            say(n_adm == len(LIB) + 2 and 'provides: 14 of 14' in out5 and not err5.strip(),
                'ringserv migrated: 14 of 14 admitted, RingServ\'s load check finds 14 of 14 promised functions')
            beh_ours = [l for l in program_lines(out5) if not l.startswith('provides: ')]
            if os.path.exists(RING):
                _, ora_copy, _ = run([RING, os.path.join(RES, 'oracle_seq.ring')] + LIB + [beh], copy)
                _, ora_orig, _ = run([RING, os.path.join(RES, 'oracle_seq.ring')] + LIB + [beh], lib)
                oc = [l for l in ora_copy.split('\n') if l]
                oo = [l for l in ora_orig.split('\n') if l]
                beh_ours = [l for l in beh_ours if l]
                say(beh_ours == oc and len(oc) > 10, 'ringserv migrated: its library at work prints what Ring prints for the copy, %d lines' % len(oc))
                say(oc == oo, 'ringserv: on Ring the migrated copy prints what the files as written print')
    # ---- 7 (rung 5). The live compiler against its two proofs: each run above again under RNXC_RESIDENT_CHECK=1 (a refusal
    # leaves the saved program as it was; an admission leaves the VM the tables a whole build gives) and under
    # RNXC_RESIDENT_BLOB=1 (saved and restored after every admission, the path before rung 5) -- the same transcript all three ways.
    runs = [(PROBES, RES), (['in_host.ring'], RES), (['rp_host.ring'], RES),
            (['rp_drv_lib.ring', 'rp_drv_v2.ring', '--replace', 'rp_drv_v2.ring', '--replace', 'rp_drv_none.ring'], RES),
            (['cl_host.ring'], RES), (['ac_host.ring'], RES), (['am_host.ring'], RES),
            (['rl_host.ring'], RES), (['rl_lib.ring', '--release', 'rl_lib.ring', 'rl_lib.ring'], RES), (['gl_host.ring'], RES),
            (['ln_host.ring'], RES)]
    lib = os.path.join(RINGSERV, 'src', 'ringlib')
    if os.path.exists(os.path.join(lib, LIB[0])):
        # as written: nine refusals after the program has called natives -- what a refusal's undo must restore
        runs.append((LIB + [os.path.join(RES, 'ringserv_provides.ring')], lib))
    copy = os.path.join(ROOT, 'runtime', 'resident', 'ringlib')
    if os.path.exists(os.path.join(copy, LIB[0])):
        runs.append((LIB + [os.path.join(RES, 'ringserv_provides.ring'), os.path.join(RES, 'ringserv_behaviour.ring')], copy))
    else:
        print("SKIP  live compiler: RingServ's migrated copy is absent -- its run NOT repeated")
    bad = []
    for args, cwd in runs:
        c0, o0, _ = run([RNXC, 'resident'] + args, cwd)
        for var in ('RNXC_RESIDENT_CHECK', 'RNXC_RESIDENT_BLOB'):
            env = dict(os.environ)
            env[var] = '1'
            c1, o1, e1 = run([RNXC, 'resident'] + args, cwd, env)
            if c1 != c0 or blank(o1) != blank(o0) or e1.strip():
                bad.append('%s under %s: %s' % (args[0], var, e1.strip().split('\n')[0][:120] or 'the transcript differs'))
    say(not bad, 'live compiler: %d runs print the same under RNXC_RESIDENT_CHECK (refusals undone, tables whole) and RNXC_RESIDENT_BLOB' % len(runs))
    for b in bad[:3]:
        print('      ' + b)
    print()
    if fails:
        print('RESIDENT FAILED -- %d of %d: %s' % (len(fails), len(fails) + len(passed), fails[0]))
        return 1
    print('RESIDENT OK -- %d checks: the probes, the oracle, admissions from inside, replacements, classes, RingServ as written and migrated, the live compiler' % len(passed))
    return 0


if __name__ == '__main__':
    sys.exit(main())
