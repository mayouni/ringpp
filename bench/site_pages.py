"""The Ring++ site (site/), its hand-written pages, and the one menu every page shares.

    python bench/site_pages.py      writes site/index.html, why.html, how.html, start.html
    python bench/site_issues.py     writes site/issues.html (it imports head() and FOOT from here)

The pages are Python strings so the menu, the head and the footer cannot drift between them. Every number on them is one the
project measured; the date beside it says when. The library era's pages (performance, checker, build, reference, the blog) live
in the archive repository, github.com/mayouni/ringpp-old, with the code they described."""
import io, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SITE = os.path.join(ROOT, 'site')
GH = 'https://github.com/mayouni/ringpp'
OLD = 'https://github.com/mayouni/ringpp-old'
REL = GH + '/releases/latest'
CSSV = '2.0.1'

MENU = [('why.html', 'Why we left Ring'), ('issues.html', 'Ring\'s issues, solved'), ('how.html', 'How it works'),
        ('start.html', 'Start here')]

GITHUB_SVG = ('<svg viewBox="0 0 16 16" width="22" height="22" fill="currentColor" aria-hidden="true"><path d="M8 0C3.58 0 0 3.58 0 8c0 '
              '3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13'
              '-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 '
              '0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27s1.36.09 2 .27c1.53-1.04 2.2-.82 '
              '2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 '
              '2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8z"/></svg>')


def head(title, desc, page):
    nav = ''.join('<a href="%s"%s>%s</a>' % (h, ' class="active"' if h == page else '', t) for h, t in MENU)
    full = 'Ring++' if page == 'index.html' else 'Ring++ -- ' + title
    return '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>%s</title>
<meta name="description" content="%s">
<meta name="author" content="Mansour Ayouni">
<meta property="og:type" content="website">
<meta property="og:url" content="https://mayouni.github.io/ringpp/%s">
<meta property="og:title" content="%s">
<meta property="og:description" content="%s">
<meta property="og:image" content="https://mayouni.github.io/ringpp/ringpp-logo.jpg">
<link rel="icon" href="favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="style.css?v=%s">
</head>
<body>

<nav>
  <div class="wrap">
    <a class="brand" href="index.html"><img src="favicon.svg" alt="">Ring<span>++</span></a>
    %s
    <a class="repo" href="%s" target="_blank" rel="noopener" aria-label="Ring++ on GitHub">%s</a>
    <a class="cta" href="%s" target="_blank" rel="noopener">Get it <span class="newtab" aria-hidden="true">&#8599;</span></a>
  </div>
</nav>
''' % (full, desc, '' if page == 'index.html' else page, full, desc, CSSV, nav, GH, GITHUB_SVG, REL)


FOOT = '''
<footer>
  <div class="wrap">
    <span>Ring++ &copy; 2026 Mansour Ayouni &middot; MIT</span>
    <span>A <a href="https://mayouni.github.io/stzsite/" target="_blank" rel="noopener">Softanza</a> project, towards Haro</span>
    <span>Ring is the work of Mahmoud Fayed (MIT); its 1.27 VM is vendored here, unchanged, as the oracle Ring++ is measured against</span>
    <a href="%s" target="_blank" rel="noopener">The library era, archived</a>
    <a class="sp" href="%s" target="_blank" rel="noopener">GitHub</a>
  </div>
</footer>

</body>
</html>''' % (OLD, GH)


INDEX = '''
<header class="hero wrap">
  <img class="logo" src="ringpp-logo.jpg" alt="Ring++">
  <h1>Your Ring programs, on a runtime <em>you control</em>.</h1>
  <p class="sub">Ring++ runs programs written in the Ring language, without Ring. It is one program of 5&nbsp;MB, for Windows
  and Linux, that compiles Ring code and runs it &mdash; faster than Ring, and refusing what it cannot run correctly instead of
  giving a wrong answer. It is built for the code that already exists: <a href="https://github.com/mayouni/stzlib"
  target="_blank" rel="noopener">Softanza</a>, its 300,000 lines, and the applications built on them.</p>
  <div class="actions">
    <a class="btn primary" href="start.html">Start here: one folder, one program</a>
    <a class="btn ghost" href="why.html">Why Ring++ left Ring</a>
  </div>
</header>

<section class="wrap narrow">
  <h2>What changed</h2>
  <p>Until August 2026, Ring++ was a library that ran inside Ring, and a contribution to it. It is now the runtime itself. On
  14 October 2026 I retired Ring from all my projects: Softanza, and the customers who depend on it, run on Ring++, and the
  work goes on towards Haro, the language that comes next.</p>
  <p><a href="why.html">Why, technically and in how Ring is governed</a>, is a page of its own. <a href="issues.html">The
  issues of Ring that Ring++ solves</a> are another, each shown by a program run on both. The library era is
  <a href="''' + OLD + '''" target="_blank" rel="noopener">archived, read-only</a>.</p>
</section>

<section class="wrap">
  <h2>What it is</h2>
  <div class="grid">
    <div class="card">
      <h3>It runs Ring as it is</h3>
      <p>Every answer is compared with Ring 1.27 itself, built from its own source. Where Ring++ answers differently, it is a
      decision on record, never an accident.</p>
    </div>
    <div class="card">
      <h3>It is fast by design</h3>
      <p>Lists that are arrays, strings passed without copying, methods found once instead of at every call: the places where
      Ring's design costs it most, replaced.</p>
    </div>
    <div class="card">
      <h3>It refuses what it cannot run correctly</h3>
      <p>The compiler is also the checker. A line it cannot run correctly is refused with its reason, instead of failing in
      production on the day that line is reached.</p>
    </div>
    <div class="card">
      <h3>It stands on its own ground</h3>
      <p>One program, no C compiler, nothing downloaded at run time. Nothing it depends on can be withdrawn by anyone else,
      which is why it exists.</p>
    </div>
  </div>
</section>

<section class="wrap narrow">
  <h2>Measured, not promised</h2>
  <table class="perf">
    <thead><tr><th>what is measured, before every release</th><th>the result</th></tr></thead>
    <tbody>
      <tr><td>Softanza's own tests: the checks that pass on Ring, passing on Ring++</td><td data-label="the result">12,863 of 13,008 on Windows (98.9%), 12,170 of 12,255 on Linux (99.3%) &mdash; <a href="how.html#parity">the rest, named</a></td></tr>
      <tr><td>Ring programs compared with Ring, line by line</td><td data-label="the result">5,112</td></tr>
      <tr><td>Speed against Ring 1.27, on the same programs</td><td data-label="the result"><a href="issues.html#speed">4 to 2,000 times faster</a></td></tr>
      <tr><td>What has to be installed beside it</td><td data-label="the result">nothing</td></tr>
    </tbody>
  </table>
</section>

<section class="wrap narrow">
  <h2>The road</h2>
  <ol class="steps">
    <li><b>Ring++, now.</b> The bridge: existing Ring code keeps running, Softanza first, on a runtime whose every decision
    sits in one open repository.</li>
    <li><b>Haro, next.</b> A new language on this VM. It keeps what makes Ring worth writing in &mdash; its simple syntax, its
    many paradigms, the declarative brace block first among them &mdash; and leaves the rest behind. It will be announced on
    its own.</li>
  </ol>
</section>
'''

WHY = '''
<header class="page wrap narrow">
  <h1>Why Ring++ left <em>Ring</em></h1>
  <p class="lead">Ring++ began as a contribution to Ring. It is now the runtime that carries Ring's programs off Ring. This
  page says why: on the technical side, and on the side of how the language is governed. The issues that Ring++ solves are
  on <a href="issues.html">a page of their own</a>, each shown by a program run on both runtimes.</p>
</header>

<section class="wrap narrow">
  <h2>What Ring gets right</h2>
  <p>Ring is Mahmoud Fayed's work, and a remarkable one. A syntax simple enough to read aloud. Real multiparadigm
  expressiveness, including the declarative brace block that Softanza's whole style is built on. A small VM that can be
  read in a sitting, and that runs on a stock Android phone. A GUI story, an Android story, a package manager and a decade
  of continuity, from one person.</p>
  <p>Narrow defects get fixed fast and with credit. Seven of my ten pull requests landed, in some form, and over the eight
  years I took part in the project, hundreds of my questions and reports were fixed or taken into account.</p>
  <p>Nobody writes a 300,000-line library on a language they do not love. What follows is the bill for learning, at
  production scale and with paying customers, which parts of a beautiful language were load-bearing.</p>
</section>

<section class="wrap narrow">
  <h2>The technical case</h2>
  <p>Softanza grew past 300,000 lines and met Ring's limits one by one. Each one here was measured.</p>
  <ul class="plain">
    <li><b>Speed is paid for by the design.</b> A string is copied every time it is passed to a function: passing a
    1&nbsp;MB string 2,000 times takes Ring 1.27 1,348&nbsp;ms, and Ring++ less than one. A list is linked, so reaching its
    middle walks to it, and a binary search becomes linear: 188 seconds in Ring 1.27, against 93 milliseconds in Ring++. A
    method is looked up by its name at every call. On identical programs, Ring measured 9 to 16 times behind Lua.</li>
    <li><b>Safety cannot be switched on.</b> <code>TRUE</code> can be reassigned. Reading a missing key of a hash list adds
    it. A program can rename the language's keywords. A method silently writes the program's variables. An error is a
    string in a global. And none of it can be fenced off: there is no strict mode.</li>
    <li><b>Text is bytes, and letters need a GUI toolkit.</b></li>
  </ul>
  <pre class="code"><span class="c"># An Arabic word of four letters: salaam</span>
cWord = <span class="s">"<span class="ar" lang="ar">&#1587;&#1604;&#1575;&#1605;</span>"</span>

<span class="k">?</span> len(cWord)
<span class="res">#--> 8, the bytes, not the letters</span>

<span class="k">?</span> cWord[<span class="n">1</span>]
<span class="res">#--> a broken character: half of the first letter</span></pre>
  <p>To get four letters, and the first of them, a Ring program has to load the whole Qt toolkit and go through its
  <code>QString</code>, whether or not it has a window to show. Regular expressions come from Qt too. Ring++ keeps Ring's
  byte answers, so that existing programs keep their meaning, and Softanza's own engine gives the letters with no GUI
  toolkit at all: <code>StzStringQ(cWord).NumberOfChars()</code> is 4.</p>
  <ul class="plain">
    <li><b>Simple on paper, complex in production.</b> Ring's data types and syntax are simple. A real application is not:
    the build steps, the C and C++ extensions, the libraries each needs and the versions they must match are where the time
    goes, and the questions asked in Ring's own group show it, week after week.</li>
    <li><b>No one way to build an interface.</b> About ten GUI and graphics libraries ship with Ring 1.27 &mdash; Qt, libui,
    NAppGUI, RayLib, Allegro, SDL, FreeGLUT, OpenGL, Tilengine, the Windows API &mdash; each with its own mental model.</li>
    <li><b>Three worlds, not one.</b> Desktop, mobile and web are three different worlds in Ring, each with its own build and
    its own way of writing the application. No single programming model spans them.</li>
    <li><b>Mistakes are found late.</b> A function that does not exist, or a variable read before it is set, is found when
    its line runs, in production, never before.</li>
  </ul>
</section>

<section class="wrap narrow">
  <h2>The governance case</h2>
  <p>The technical limits alone would have been work. What made them a reason to leave is that there is no way to change
  them.</p>
  <ul class="plain">
    <li><b>One person decides.</b> Ring is designed and developed by its author alone. That is a legitimate way to run a
    language, and it served Ring for a decade. The customers Softanza serves &mdash; banks, governments, platforms &mdash;
    raised it as a risk they could not carry: a dependency whose every decision sits with one person, through no process a
    user can take part in, and whose behaviour cannot be fenced by a strict mode.</li>
    <li><b>A design question has no place to become a decision.</b> Ring's repository has its issue tracker, its discussions
    and its pull requests switched off; the Google Group is the only channel, and it holds conversations, not decisions.
    Defects are fixed, often within days. Design questions are answered, and stay where they were.</li>
    <li><b>We diverged on the project's governance.</b> Over the years I argued for a different way of running it &mdash;
    production use as a goal, a strict mode, a foundation around the language &mdash; and the project did not take that
    direction. That is the author's right, and it is a fact a production user has to act on.</li>
  </ul>
  <p>A project built for customers cannot depend on a direction it has no way to influence. So on 14 October 2026 I retired
  Ring from all my projects.</p>
</section>

<section class="wrap narrow">
  <h2>What Ring++ does instead</h2>
  <ul class="plain">
    <li><b>It keeps the code that exists running.</b> Softanza runs on Ring++: of the checks in its tests that pass on Ring,
    Ring++ passes 12,863 of 13,008 on Windows and 12,170 of 12,255 on Linux, and every one it does not pass has a named
    cause (<a href="how.html#parity">how it is counted</a>).</li>
    <li><b>It answers like Ring, unless it says otherwise.</b> Each of Ring's defects was looked at on its own and given one
    of four answers: keep it, so existing programs mean the same; fix it, where no correct program could tell the
    difference; refuse it, with a rule the compiler checks; or drop a feature Softanza never uses, and say so. Each answer is
    written down with what it costs. They are <a href="issues.html#decisions">explained on the issues page</a>.</li>
    <li><b>It measures instead of asserting.</b> Ring 1.27, built from its own source, is the reference: 5,112 programs are
    compared with it line by line, and a gate runs before every change.</li>
    <li><b>It owns its ground.</b> One program, no C compiler, every file it carries from elsewhere checked against its
    hash.</li>
  </ul>
  <p>RingServ, RingScript and MicroRing are no longer maintained on Ring. They are test projects for Ring++ now, and the
  starting points for Haro's own server, browser and embedded runtimes.</p>
</section>

<section class="wrap narrow">
  <h2>Towards Haro</h2>
  <p>Ring++ is a bridge, not the destination. Haro is a new language built on this VM. It keeps Ring's simple syntax and its
  expressiveness, the brace block first, and adds what Ring never had: a <code>?</code> that shows a list as a list. Ring
  prints a list one item per line, its structure lost, which is why Softanza has <code>@@()</code>. Its design is being
  written and measured now, and it will be announced on its own.</p>
  <p>Ring++ stays open source under the MIT licence, as Ring is. Its findings document Ring's VM in detail; they are there for
  anyone to learn from, the Ring team included.</p>
</section>
'''

HOW = '''
<header class="page wrap narrow">
  <h1>How <em>Ring++</em> works &mdash; and how it is measured</h1>
  <p class="lead">One binary, <code>rnxc</code>, holds the whole runtime: a parser, a compiler and a register VM. Next to it
  sits a second runtime that is never shipped: Ring 1.27 itself, built from its own source, so that "compatible" is a
  measurement.</p>
</header>

<section class="wrap narrow">
  <h2>The pieces</h2>
  <ul class="plain">
    <li><b>The parser.</b> Youssef Saeed's tree-sitter grammar for Ring, vendored. It gives every node its exact span, which
    is what lets the compiler point at the statement it refuses.</li>
    <li><b>The compiler.</b> Ring source to bytecode: name resolution done once, at compile time; type inference over the
    whole program; methods resolved to slots where the receiver is known; and a refusal, with its reason, for anything it
    cannot compile correctly. <code>rnxc check</code> is the same compiler reporting instead of running.</li>
    <li><b>The VM.</b> 16-byte tagged values, contiguous lists, strings passed by reference, lists and objects copied at
    assignment as Ring's semantics require; register windows for calls; threaded dispatch; mimalloc underneath.</li>
    <li><b>The native interface.</b> A small ABI in Zig. Softanza's engine &mdash; 89 domains: strings, Unicode, regular
    expressions, graphs, neural models, GPU, sound and more &mdash; is built for Ring++ from its own unchanged source, with one
    file swapped. Zip is built in.</li>
    <li><b>The compiled image.</b> A program is compiled once; later runs start from the image: Softanza's 614 files in
    0.1&nbsp;s instead of 10.</li>
  </ul>
</section>

<section class="wrap narrow">
  <h2>The oracle</h2>
  <p>Ring 1.27's VM source is vendored verbatim, under its MIT licence, and built with the same Zig toolchain on five
  platforms. That build &mdash; not an installation anyone else controls &mdash; is what every comparison is made against.
  It is never shipped and never the product; it exists so that every claim of compatibility can be checked.</p>
</section>

<section class="wrap narrow">
  <h2>What is measured, before every release</h2>
  <ul class="plain">
    <li><b>The probes.</b> 156 programs, each pinning one rule of Ring, byte for byte against the oracle: on Windows in the
    optimised and the safety-checked builds, and on Linux.</li>
    <li><b>The census.</b> Softanza's base library compiled whole: 118,640 statements, 118,506 compiled; the 134 refused are
    one 3,909-line function that exceeds the register window.</li>
    <li><b>The wide clock.</b> 5,112 Ring programs &mdash; Softanza's tests and examples &mdash; run on both runtimes. The oracle
    runs each twice first, so a line it does not reproduce from itself (a time, a random draw) is never counted against
    Ring++. 3,567 agree on every remaining line on Windows, 3,753 on Linux; most of the rest differ only on the line that
    reports how long the program took.</li>
    <li id="parity"><b>Assertion parity.</b> Every check that passes on Ring must pass on Ring++. Counting every check
    Softanza's tests print, <code>[PASS]</code> and <code>[OK]</code> alike, Ring++ passes 12,863 of Ring's 13,008 on
    Windows and 12,170 of 12,255 on Linux. The rest is named: 81 sit in two test files that read a global without its
    <code>$</code> inside a function, which Ring++ refuses to compile; 61 sit behind one function too large for the register
    window (Windows); a handful measure time or memory; and on Linux one is a cluster test that does not finish under
    Ring++. Until 17 October 2026 this count read <code>[PASS]</code> lines
    only, and said 8,540 of 8,540: true of those checks, and silent about the 4,468 written as <code>[OK]</code>.</li>
  </ul>
  <p>And four rules for every number: no claim without a measurement; minima over repetitions, never one run; the same
  answer before any speed is quoted; and every speed-up stated with the pattern it makes slower. The first measurements of
  the VM, and what flatters them, are in <a href="''' + GH + '''/blob/main/NOTES.md">NOTES.md</a>.</p>
</section>

<section class="wrap narrow">
  <h2>The commands</h2>
  <pre class="code">rnxc program.ring            run it (the first run compiles; later runs start from the image)
rnxc check program.ring      report what Ring would only find when the line runs
rnxc census program.ring     what compiles, what is refused, and why
rnxc fmt program.ring        the canonical text of a Ring file
rnxc graph program.ring      the resolved call graph, as the compiler bound it
rnxc dump --json file.ring   the lossless parse tree</pre>
</section>
'''

START = '''
<header class="page wrap narrow">
  <h1>Start <em>here</em></h1>
  <p class="lead">One folder holds everything: <code>rnxc</code>, Ring's standard library, Softanza and its engine built for
  Ring++. Unpack it anywhere; nothing else is installed, and no C compiler is ever needed.</p>
</header>

<section class="wrap narrow">
  <h2>1. Get the package</h2>
  <p>From <a href="''' + REL + '''" target="_blank" rel="noopener">the latest release</a>:</p>
  <ul class="plain">
    <li><b>Windows (x64)</b> &mdash; <code>ringpp-win64.zip</code>, 412&nbsp;MB unpacked: unzip it anywhere</li>
    <li><b>Linux (x64, glibc)</b> &mdash; <code>ringpp-linux-x64.tar.gz</code>, 674&nbsp;MB unpacked:
    <code>tar -xzf ringpp-linux-x64.tar.gz</code></li>
  </ul>
  <p>Most of that is Softanza and its engine. <code>rnxc</code> itself is one 5&nbsp;MB file.</p>
</section>

<section class="wrap narrow">
  <h2>2. Run a program</h2>
  <pre class="code"><span class="k">load</span> <span class="s">"stzlib.ring"</span>

<span class="k">?</span> <span class="s">"sort:      "</span> + @@( Q([ <span class="n">3</span>, <span class="n">1</span>, <span class="n">2</span> ]).Sorted() )
<span class="k">?</span> <span class="s">"upper:     "</span> + StzStringQ(<span class="s">"ring++ runs softanza"</span>).Uppercased()
<span class="k">?</span> <span class="s">"words:     "</span> + StzStringQ(<span class="s">"one two three"</span>).NumberOfWords()</pre>
  <pre class="code">ringpp-win64\\bin\\rnxc.exe prog.ring

sort:      [ 1, 2, 3 ]
upper:     RING++ RUNS SOFTANZA
words:     3</pre>
  <p><code>load "stzlib.ring"</code> works from any folder. The first run compiles Softanza's 614 files (about ten seconds);
  every later run starts from the compiled image, in a tenth of a second.</p>
</section>

<section class="wrap narrow">
  <h2>3. Check a program before it runs</h2>
  <pre class="code">rnxc check prog.ring

prog.ring
  2:1  error  rpp/undefined-function
          Nope() is not defined anywhere this file can reach -- Error (R3) the moment this line runs</pre>
</section>

<section class="wrap narrow">
  <h2>4. Build it yourself</h2>
  <p>With Zig 0.15.2 and nothing else:</p>
  <pre class="code">zig build -Doptimize=ReleaseFast -j2 -Dmi=true -Drc=true -Dtyped=true -Dcow=true</pre>
  <p>The gate that every change passes is <code>python bench/gate.py</code>.</p>
</section>
'''

PAGES = [
    ('index.html', 'Ring programs, on ground you control', 'Ring++ is a register VM and a compiler for Ring, in one binary: '
     'it runs the Ring code that exists, Softanza first, with no Ring underneath, and it is the bridge to Haro.', INDEX),
    ('why.html', 'Why Ring++ left Ring', 'The technical and the governance reasons Ring++ became its own runtime, and Ring was '
     'retired from every project built on it -- with the record behind each statement.', WHY),
    ('how.html', 'How it works', 'The parser, the compiler, the register VM, the oracle built from Ring\'s own source, and what '
     'is measured before every release.', HOW),
    ('start.html', 'Start here', 'One folder, one binary: get the Ring++ package, run a Ring program, check it before it runs.',
     START),
]


def main():
    for name, title, desc, body in PAGES:
        with io.open(os.path.join(SITE, name), 'w', encoding='utf-8', newline='\n') as f:
            f.write(head(title, desc, name) + body + FOOT + '\n')
        print('wrote site/' + name)
    return 0


if __name__ == '__main__':
    sys.exit(main())
