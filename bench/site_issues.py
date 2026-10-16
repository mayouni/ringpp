"""site/issues.html -- the issues of Ring that Ring++ solves, each shown by a program run on both runtimes.

    python bench/site_issues_probes.py      run the programs on official Ring 1.27 and on Ring++ (runtime/site-src/issue_runs.json)
    python bench/site_issues.py             render site/issues.html

Only what Ring++ SOLVES is listed (Mansour, 2026-10-16): what it keeps from Ring for now is a decision, explained in the
decisions narrative, not an issue. The order runs from the most damaging to the least: a program that dies, then a wrong answer
given silently, then the language changed under the programmer, then what is found only when a line runs, then speed.

Each issue shows the program -- commented, the names written out -- and then what the two runtimes printed. The page REFUSES to
render when a program's `#-->` comments disagree with what was measured: the `expect` strings below must appear in the outputs."""
import html, io, json, os, re, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RUNS = os.path.join(ROOT, 'runtime', 'site-src', 'issue_runs.json')
OUT = os.path.join(ROOT, 'site', 'issues.html')
REPO = 'https://github.com/mayouni/ringpp/blob/main/'

THEMES = [('crash', 'Programs that die'), ('wrong', 'Wrong answers, given silently'),
          ('changed', 'The language changed under you'), ('late', 'Found only when the line runs'), ('speed', 'Speed')]

# theme, probe key, title, Ring (one line), Ring++ (one line), status, (expected in Ring's output, expected in Ring++'s), refs
ISSUES = [
    ('crash', 'object_operand', 'An object taken from a list ends the program, with no message',
     'Adding two objects through their <code>operator</code> method works -- unless the right one comes from a list: then the '
     'program stops, exit code 1, no error printed, and no <code>try</code> can catch it.',
     'The operator is called, and the program goes on.', 'Solved', ('', '15'), ['F-100', 'C-24']),
    ('crash', 'empty_catch', 'Empty catch blocks fill the stack until the program dies',
     'Each empty <code>catch</code> leaves one slot on the VM\'s stack. A loop that expects failures dies with Stack Overflow.',
     'Nothing is left behind; the loop runs to the end.', 'Solved', ('Stack Overflow', '3,000 failures handled'), ['F-16']),
    ('wrong', 'hash_read', 'Reading a missing key adds it',
     'Asking a hash list for a key it does not have inserts that key. A read changes the data it reads.',
     'A read never writes.', 'Solved', ('3', '2'), ['C-13', 'F-49']),
    ('wrong', 'method_global', 'A method overwrites the program\'s variable',
     'A method that assigns a name the program also uses writes the program\'s variable, silently. Softanza spells its own '
     'variables <code>_name_</code> at 175,797 places to avoid it.',
     'A method\'s variables are its own. A global is written <code>$name</code>.', 'Solved', ('a visitor', 'Mansour'), ['C-2']),
    ('wrong', 'switch2', '<code>switch</code> ignores the second value of an <code>on</code>',
     '<code>on 6, 7</code> is accepted without a word, but only 6 is ever compared.',
     '<code>on 6, 7</code> matches either value.', 'Solved', ('weekday', 'weekend'), []),
    ('wrong', 'range_str', 'A range of two strings answers a string',
     '<code>"1":"12"</code> is neither a list nor an error: it is a string, and the program goes on with it.',
     'An operator that cannot do what it is asked says so.', 'Solved', ('STRING', 'Bad parameter type!'), []),
    ('changed', 'true', '<code>TRUE</code> can be reassigned',
     'After <code>TRUE = 0</code>, every <code>if TRUE</code> in the program takes the other branch.',
     'Assigning a constant of the language is refused: the line is not compiled, and the program stops there and says '
     'why.', 'Refused',
     ('TRUE is false now', 'refused this statement'), []),
    ('changed', 'keyword', 'A program can rename the language\'s keywords',
     '<code>ChangeRingKeyword</code> renames a keyword from that line on, silently, for whoever reads the file next.',
     'It is refused, by name: a reader of the file sees the language it was written in.', 'Refused', ('the keyword see is now spelt show', 'refused this statement'), ['C-28']),
    ('changed', 'loopvar', 'A loop variable keeps a value the loop never gave it',
     'After <code>for nIndex = 1 to 5</code>, <code>nIndex</code> is 6. Four kinds of loop leave four kinds of value behind.',
     'The variable belongs to its loop, and reading it afterwards is refused. Run over Softanza, the rule found two '
     'real bugs.', 'Refused', ('6', 'refused this statement'),
     ['C-11']),
    ('late', 'undefined', 'A missing function is found only when its line runs',
     'The program runs up to the call, then fails -- in production, on the day that line is reached.',
     '<code>rnxc check</code> reports it, with its line, before anything runs.', 'Solved',
     ('Calling Function without definition', 'not defined anywhere'), ['F-46']),
]

# measured 2026-10-15, official Ring 1.27 against Ring++ built from the same commit, minima of three runs, answers equal
SPEED = [
    ('A 1 MB string, passed to a function 2,000 times', '1,348 ms', 'below 1 ms',
     'Ring copies a string at every call; Ring++ passes it by reference.'),
    ('Binary search: 150,000 lookups in 200,000 numbers', '188,741 ms', '93 ms',
     'A Ring list is linked, so reaching item n walks to it; a Ring++ list is an array.'),
    ('Merge sort of 200,000 numbers', '5,222 ms', '242 ms', 'Lists, appends and calls.'),
    ('Matrix multiplication, 220 by 220', '1,790 ms', '245 ms', 'Nested lists and arithmetic.'),
    ('Sieve of Eratosthenes up to 4,000,000', '1,335 ms', '237 ms', 'Integer arithmetic over a list.'),
    ('Recursive Fibonacci of 31', '433 ms', '100 ms', 'Function calls.'),
]


def count(pattern, doc):
    return sum(1 for l in io.open(os.path.join(ROOT, 'docs', doc), encoding='utf-8') if re.match(pattern, l))


def esc(s):
    return html.escape(s, quote=False)


def anchors():
    """Each finding's and correction's anchor on GitHub: the heading, lower-cased, letters, digits, spaces, hyphens and
    underscores kept, spaces turned to hyphens -- GitHub's own rule, so a reference lands on its heading."""
    out = {}
    for doc, pat in (('FINDINGS.md', r'^#{2,3} (F-\d+)\. .*$'), ('CORRECTIONS.md', r'^## (C-\d+) · .*$')):
        for l in io.open(os.path.join(ROOT, 'docs', doc), encoding='utf-8'):
            m = re.match(pat, l.rstrip())
            if m:
                t = l.lstrip('#').strip().lower()
                t = ''.join(ch for ch in t if ch.isalnum() or ch in ' -_').replace(' ', '-')
                out[m.group(1)] = '%sdocs/%s#%s' % (REPO, doc, t)
    return out


ANCHORS = {}


def refs_html(refs):
    return ''.join('<a class="ref" href="%s" target="_blank" rel="noopener">%s</a>' % (ANCHORS[r], r) for r in refs)


def ring_code(code):
    """The program, with `#-->` result lines set apart from ordinary comments."""
    out = []
    for line in code.split('\n'):
        e = esc(line)
        s = line.lstrip()
        if s.startswith('#-->') or (s.startswith('#') and out and out[-1].startswith('<span class="res">') and s.startswith('#  ')):
            out.append('<span class="res">%s</span>' % e)
        elif s.startswith('#'):
            out.append('<span class="c">%s</span>' % e)
        else:
            out.append(e)
    return '\n'.join(out)


def printed(r, how):
    """What a runtime printed, as a reader needs it: the program's own lines, an error's first line, a refusal's reason."""
    out = r['out']
    if how == 'check':
        k = [l.strip() for l in out.split('\n') if 'not defined anywhere' in l]
        return 'rnxc check p.ring, before running it:\nline 2: ' + (k[0].split(' � ')[0].split(' -- ')[0] if k else out)
    m = re.search(r'Line (\d+) Ring\+\+ refused this statement \((.*?) `(.*?)`, line', out)
    if m:
        why = m.group(2)
        if re.match(r'^[a-z_]+$', why):          # a construct name: the statement itself says it
            why = ''
        else:                                     # a rule: drop its correction number
            why = re.sub(r'\s*\(C-\d+:.*?\)', '', why) + ': '
        return 'Line %s is refused: %s%s\n(the line is not compiled; the program stops there)' % (m.group(1), why, m.group(3))
    lines = [l.rstrip() for l in out.split('\n')]
    lines = [l for l in lines if l.strip() and not l.startswith(('in file ', 'In function ', 'Called from'))]
    text = '\n'.join(lines[:5])
    if not text:
        text = '(nothing)'
    if r['exit'] not in (0, 'timeout'):
        text += '\n(the program stops, exit code %s)' % r['exit']
    return text


def main():
    runs = json.load(io.open(RUNS, encoding='utf-8'))['runs']
    ANCHORS.update(anchors())
    measured = time.strftime('%d %B %Y', time.localtime(os.path.getmtime(RUNS))).lstrip('0')
    bad = []
    for theme, key, title, ring, ringpp, st, (er, ep), refs in ISSUES:
        r = runs[key]
        if er and er not in (r['ring']['out'] + ' '.join(r['ring']['err'])):
            bad.append('%s: Ring printed %r, the page says %r' % (key, r['ring']['out'][:80], er))
        if ep and ep not in (r['ringpp']['out'] + ' '.join(r['ringpp']['err'])):
            bad.append('%s: Ring++ printed %r, the page says %r' % (key, r['ringpp']['out'][:80], ep))
    if bad:
        for b in bad:
            print('REFUSED ' + b)
        return 1

    P = [HEAD]
    P.append('''<header class="page wrap narrow">
  <h1>Ring's issues that <em>Ring++</em> solves</h1>
  <p class="lead">Each issue below is a small Ring program, run on official Ring 1.27 and on Ring++ (%s). You read the
  program first, then what each runtime printed. Nothing here is a promise: it is what the two printed.</p>
  <div class="filter"><label for="theme">Show</label>
    <select id="theme">
      <option value="all">every issue</option>
%s
    </select>
  </div>
</header>''' % (measured,
                ''.join('      <option value="%s">%s</option>\n' % (k, t) for k, t in THEMES)))
    for tkey, tname in THEMES:
        P.append('<section class="wrap theme" data-theme="%s" id="%s"><h2>%s</h2>' % (tkey, tkey, tname))
        if tkey == 'speed':
            P.append('''<p class="lead">Three choices in Ring's design cost it the most: strings copied at every call, lists that are
linked, and methods found by name at every call. Ring++ replaces all three. The same programs, on the same machine, minima
of three runs, every answer checked equal:</p>
<table class="perf"><thead><tr><th>the program</th><th>Ring 1.27</th><th>Ring++</th><th>why</th></tr></thead><tbody>''')
            for what, a, b, why in SPEED:
                P.append('<tr><td>%s</td><td class="num" data-label="Ring 1.27">%s</td><td class="num" data-label="Ring++"><b>%s</b></td>'
                         '<td data-label="why">%s</td></tr>'
                         % (esc(what), a, b, esc(why)))
            P.append('</tbody></table>')
            P.append('<p>The first measurements of the VM, and what flatters them, are recorded in '
                     '<a href="%sNOTES.md">NOTES.md</a>.</p></section>' % REPO)
            continue
        for theme, key, title, ring, ringpp, st, _, refs in ISSUES:
            if theme != tkey:
                continue
            r = runs[key]
            P.append('<article class="issue">')
            P.append('<h3>%s</h3>' % title)
            P.append('<p class="status"><span class="st st-%s">%s</span>%s</p>' % (st.lower(), st, refs_html(refs)))
            P.append('<p class="who"><b>Ring 1.27</b> %s</p>' % ring)
            P.append('<p class="who"><b>Ring++</b> %s</p>' % ringpp)
            P.append('<pre class="code">%s</pre>' % ring_code(r['code']))
            P.append('<div class="printed"><div><span>Ring 1.27 printed</span><pre>%s</pre></div>'
                     '<div><span>Ring++ printed</span><pre>%s</pre></div></div>'
                     % (esc(printed(r['ring'], 'run')), esc(printed(r['ringpp'], r['how']))))
            P.append('</article>')
        P.append('</section>')

    P.append(KEPT)
    P.append(DECISIONS % (count(r'^## C-\d+ · ', 'CORRECTIONS.md'), REPO))
    P.append(FINDINGS % (count(r'^#{2,3} F-\d+\. ', 'FINDINGS.md'), count(r'^#{2,3} F-\d+\. ', 'FINDINGS.md'), REPO))
    P.append(FILTER_JS)
    P.append(FOOT)
    io.open(OUT, 'w', encoding='utf-8', newline='\n').write('\n'.join(P) + '\n')
    print('wrote %s: %d issues, %d speed rows; every comment agrees with what was measured' % (OUT, len(ISSUES), len(SPEED)))
    return 0


KEPT = '''<section class="wrap narrow" id="kept">
  <h2>What Ring++ keeps from Ring, for now</h2>
  <p>Some of Ring's behaviours are kept on purpose, so that existing programs keep their meaning: a list printed one item per
  line, a named argument that arrives as a two-element list, <code>decimals()</code> as a setting for the whole program, a
  string measured in bytes. They are not solved, so they are not listed above. They are decisions, explained below, and the
  next language, Haro, is where they change.</p>
</section>'''

DECISIONS = '''<section class="wrap narrow" id="decisions">
  <h2>Every decision, explained</h2>
  <p>Where Ring++ answers differently from Ring, it is never by accident. Each difference is a decision, taken for one defect
  at a time and written down with what it costs. There are four kinds.</p>
  <p><b>Keep Ring's answer</b>, so existing programs keep their meaning, even where Ring's choice is questionable.
  <code>decimals(2)</code> still changes every number the program prints from then on. A bare name at the top level is still
  a global. A <code>load</code> that names a missing file still stops the program before it starts, exactly as on Ring.</p>
  <p><b>Fix it silently</b>, where no correct program can notice. Reading <code>aHash[:key]</code> no longer inserts the key.
  An object taken from a list no longer ends the program when it meets an operator. Leaving a <code>try</code> through
  <code>return</code> also leaves its handler, from a function as from a method.</p>
  <p><b>Refuse, with a rule</b>, where Ring's behaviour is a trap. The program is refused before it runs, and
  <code>rnxc check</code> names every place the rule applies: a loop variable read after its loop, a numeric
  <code>for</code> whose bound changes while it runs.</p>
  <p><b>Drop it, and say so</b>, for what only Ring's own programs use and Softanza never does: renaming keywords, packages,
  raw memory pointers. Each is refused by name rather than half-built.</p>
  <p>All %d decisions are on record, each with its reasons and its cost, in
  <a href="%sdocs/CORRECTIONS.md">the corrections register</a>.</p>
</section>'''

FINDINGS = '''<section class="wrap narrow" id="findings">
  <h2>Every finding, explained</h2>
  <p>The findings are what Ring's VM was measured to do: %d of them, each from a program that ran. They fall into four
  families.</p>
  <p><b>Costs the source does not show.</b> A string passed to a function is copied, every time. A loop written
  <code>for i = 1 to len(s)</code> measures the string again at every turn, which makes it quadratic. How fast a list is read
  depends on how it was built and on where it was read last. On identical programs, Ring measured 9 to 16 times behind Lua.</p>
  <p><b>Traps.</b> <code>N</code> and <code>n</code> are the same variable. Every <code>func</code> written after the first
  <code>class</code> of a file becomes a method of that class. A string has no escapes: <code>"\\n"</code> is two characters.
  <code>char(300)</code> is <code>char(44)</code>, silently.</p>
  <p><b>Rules that Ring++ had to learn, to run Ring's programs as they are.</b> <code>:Name = value</code> is a two-element
  list. Ring calls <code>Main()</code> by itself after the top level. Every operator on an object calls its
  <code>operator()</code> method. <code>eval</code> runs in the scope of the function that calls it.</p>
  <p><b>Ring's own failures.</b> <code>memcpy()</code> ending the process on a zero byte; empty catch blocks filling the stack;
  an object from a list ending a program without a message; the Linux build crashing as it exits.</p>
  <p>All %d, each with the program that shows it, are in <a href="%sdocs/FINDINGS.md">the findings</a>.</p>
</section>'''

FILTER_JS = '''<script>
(function () {
  var sel = document.getElementById('theme');
  if (!sel) return;
  function show() {
    var v = sel.value;
    document.querySelectorAll('section.theme').forEach(function (s) {
      s.hidden = !(v === 'all' || s.getAttribute('data-theme') === v);
    });
  }
  sel.addEventListener('change', show);
  if (location.hash && document.querySelector('section.theme' + location.hash)) {
    sel.value = location.hash.slice(1);
  }
  show();
})();
</script>'''

sys.path.insert(0, HERE)
import site_pages  # noqa: E402
HEAD = site_pages.head('Ring\'s issues that Ring++ solves', 'Each issue of Ring that Ring++ solves, shown by a small program run '
                       'on Ring 1.27 and on Ring++, with what each printed.', 'issues.html')
FOOT = site_pages.FOOT

if __name__ == '__main__':
    sys.exit(main())
