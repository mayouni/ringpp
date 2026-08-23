# Google Group post — an answer to Youssef

**Status: DRAFTED, NOT SENT.** For the Ring Google Group, posted by
Mansour. The GitHub reply it links to **is** already posted:
[issue #2, comment 5384766820](https://github.com/ysdragon/tree-sitter-ring/issues/2#issuecomment-5384766820).

An answer to Youssef, in public, so the group gets the useful part: what
tree-sitter buys a Ring programmer and why this project depends on it.
~240 words; the numbers stay in the link.

---

**Subject:** Re: tree-sitter-ring — v1.1.1 fixes it, and why I depend on this grammar

Youssef,

v1.1.1 fixes it. Re-measured over **10,233 Ring files** — a full Ring 1.27
install plus my Softanza library tree — the files your grammar wrongly
rejects went **18 → 11**. Reproducers and numbers:

https://github.com/ysdragon/tree-sitter-ring/issues/2#issuecomment-5384766820

For the group, since this may look obscure:

**What tree-sitter gives Ring.** A real syntax tree with exact positions,
which keeps parsing after a mistake instead of stopping at the first one.
That is what lets a tool say *"line 13, column 45"* instead of *"something
is wrong"*. Ring's compiler is built to **run** programs, not to answer
questions about them — so every editor, highlighter, formatter or analyser
would otherwise reimplement Ring's syntax and slowly drift from it.
Youssef's grammar means we write that once.

**Why I use it.** I am building static type checking for large Ring
projects — the thing a serious team asks about before adopting a language
at scale. It reads a whole project across `load` boundaries and catches, for
instance, a function called with the wrong number of arguments, before the
program runs. On Ring's own standard library it found two functions that
have never worked.

**The rule I would pass on:** the grammar is a *lens, never a judge*. When
it and Ring disagree, **Ring is right** and the grammar has a bug. That is
how this one was found — the grammar rejected

```ring
? Wrap(3Copies("x"))
```

which Ring accepts. A digit-leading name was fine alone, and fine as a
call, but not as an argument *to another call*.

One correction: the *0.16%* I published with the original report should not
be quoted — my measuring script was silently broken. The finding was
hand-verified and stands; the percentage never deserved printing.

Thank you, Youssef. A narrowed reproducer went in, a fix came back.

Mansour
