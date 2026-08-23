# Google Group post — an answer to Youssef

**Status: DRAFTED, NOT SENT.** For the Ring Google Group, posted by
Mansour. The GitHub reply it links to **is** already posted:
[issue #2, comment 5384766820](https://github.com/ysdragon/tree-sitter-ring/issues/2#issuecomment-5384766820).

Written as an answer to Youssef, in public, so the rest of the group gets
the useful part: what tree-sitter buys a Ring programmer, and why this
project leans on it. Short on purpose — the numbers live in the link.

---

**Subject:** Re: tree-sitter-ring — v1.1.1 fixes it, and why I depend on this grammar

Youssef,

v1.1.1 fixes it. I re-measured over **10,233 Ring files** — a full Ring
1.27 install plus my Softanza library tree — and the files your grammar
wrongly rejects went **18 → 11**, seven fixed, nothing broken. Details and
reproducers are in the issue:

https://github.com/ysdragon/tree-sitter-ring/issues/2#issuecomment-5384766820

Since the group may wonder what this is about, the short version.

**What tree-sitter gives Ring.** It is a parser generator that produces a
real syntax tree with exact source positions, and keeps parsing after a
mistake instead of giving up at the first one. That is what lets a tool say
*"line 13, column 45"* rather than *"something is wrong somewhere"*. Ring's
own compiler is built to run programs, not to answer questions about them,
so anything that wants to **read** Ring — an editor, a highlighter, a
formatter, a static analyser — otherwise has to reimplement Ring's syntax
and slowly drift from it. Youssef's grammar means we write that once.

**Why I use it.** I am building static type checking for large Ring
projects, because that is the one thing a serious engineering team asks
about before committing to a language at scale. It reads a whole project
across `load` boundaries and reports things like a function called with the
wrong number of arguments — before the program runs, not at line 4,000 in
production. On Ring's own standard library it found two functions that have
never worked. That checker sees Ring through this grammar.

**One rule I would recommend to anyone doing the same:** the grammar is a
*lens, never a judge*. When it and Ring disagree about whether a file is
valid, **Ring is right, always** — the grammar has a bug. That is exactly
how this one was found: the grammar rejected

```ring
? Wrap(3Copies("x"))
```

which Ring accepts happily. A digit-leading identifier was fine on its own,
and fine as a call — but not as an argument *to another call*. Five real
files in my library hit it. v1.1.1 also fixed a second one I had never
reported: a bare `exit` at the end of a function would swallow the next
`func` declaration.

One correction while I am here: the *0.16%* figure I published with the
original report should not be quoted — it came from a measuring script of
mine that was silently broken. The finding was hand-verified and stands;
the percentage did not deserve to be printed.

Thank you for the turnaround, Youssef. A narrowed reproducer went in and a
fix came back, and Ring tooling is better for it.

Mansour
