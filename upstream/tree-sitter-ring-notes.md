# Grammar findings for `ysdragon/tree-sitter-ring`

> **SENT** — [ysdragon/tree-sitter-ring#2](https://github.com/ysdragon/tree-sitter-ring/issues/2),
> August 12, 2026. Filed as an issue, not a PR: no grammar fix attached,
> and that project has issues enabled.
>
> **FIXED by Youssef Saeed** in
> [`287afffb`](https://github.com/ysdragon/tree-sitter-ring/commit/287afffb)
> — *"fix(grammar): resolve digit-leading identifiers in argument
> position (#2)"* — shipped in **v1.1.1**. He asked for the corpus number
> to be re-measured. It has been, on 2026-08-23; the results are in
> [§ The re-measurement](#the-re-measurement) below.
>
> **The reply is SENT** —
> [issue #2, comment 5384766820](https://github.com/ysdragon/tree-sitter-ring/issues/2#issuecomment-5384766820),
> 2026-08-23, posted by Mansour on his instruction. It reports 18 → 11
> wrongly-rejected files and **retracts the ~0.16% below**. The issue was
> left open for Youssef to close himself.
>
> **TWO FURTHER DEFECTS, narrowed 2026-08-24 and NOT reported.** The three
> Softanza files still wrongly rejected after v1.1.1 turned out to be two
> defects unrelated to #2, both present in the pre-fix grammar: **U+017F and
> U+212A** — the only two non-ASCII codepoints Unicode case-folds into ASCII —
> break a file from anywhere in it, *including a comment*; and a **statement
> terminated by a period** is rejected. Reproducers, mechanism and controls
> are in [§ What is still too strict](#what-is-still-too-strict--the-three-root-s-files-narrowed-2026-08-24)
> and gated by `tsring open`. **Nothing has been sent** — that is Mansour's
> to send, and #2 should not be reopened for them.

Found by running `ringpp check` (which vendors this grammar) over 5,566
Softanza files and Ring 1.27's own corpus, then asking `ring <file> -norun`
to adjudicate every disagreement.

**~~Measured disagreement rate: ~0.16%~~ — ~~9 files out of 5,566~~.**

> **RETRACTED 2026-08-23, and retracted publicly in the reply.** This
> number came from `tests/fidelity.ps1`, whose forward direction searched
> for a diagnostic name the checker has never emitted, and so matched
> nothing on any corpus. It is left visible rather than deleted: withdrawing
> a number you published is not the same as removing it. See
> [§ The harness had to be repaired first](#the-harness-had-to-be-repaired-first-and-the-old-016-does-not-survive-it).
> **The finding itself was hand-bisected and stands.** Only the percentage
> was harness-derived.

The grammar is a good one; the note below is the residue.

## The finding, as filed

A **digit-leading identifier is rejected when the call appears as an
argument to another call**. Ring accepts all four of these; the grammar
rejects only the last:

| | grammar |
|---|---|
| `? 3Copies("x")` — statement level | accepts |
| `? 3Copies(:of = "x")` — named-argument form | accepts |
| `? Wrap(Copies(:of = "x"))` — nested, no leading digit | accepts |
| **`? Wrap(3Copies("x"))` — nested, leading digit** | **rejects** |

## How the reproducer was narrowed — worth recording

My first draft of this report claimed the rule was simply *"identifiers may
begin with a digit"*, with `? 3Copies("x")` as the reproducer. **It does not
reproduce** — both Ring and the grammar accept it. Filing that would have
sent the maintainer chasing a case that works.

The real file that failed was
`stzlib/base/test/string/112_repeatedntimes.ring` at 13:45, inside
`Then("...", 3Copies(:of = "♥"), "♥♥♥")`. Bisecting that line across five
variants produced the table above: the trigger is *digit-leading identifier
+ call + argument position*, and the `:of =` form is not involved at all.

**Check that a minimal reproducer actually reproduces before sending it.**

---

# The re-measurement

*2026-08-23. Both grammars measured in one session over the same roots,
with the same harness, on the same machine.*

## What was measured, exactly

**The roots from the original run were never recorded.** "5,566 Softanza
files" cannot be reconstructed, so no attempt was made to. Instead both
grammars were run over the **same two named roots in one session**, which
is a like-for-like delta whatever the roots are — and is better evidence
than a number compared against a corpus nobody can reproduce.

| | root | .ring files |
|---|---|---|
| **S** | `D:\GitHub\stzlib\libraries` | 6,012 → 6,013 |
| **R** | `D:\ring127` | 4,221 |

Root **S** is the Softanza *library* tree. The Softanza repository root
also holds 5,368 generated `.ring` files under `.claude` which are tooling
scratch, not code anyone wrote; including them would have let 47% of the
corpus be machine-generated. Root S at 6,012 files is also strikingly close
to the original report's 5,566, which suggests — without proving — that it
is the same tree eleven days later.

*Root S gained one file between the two runs (6,012 → 6,013): it is a live
working tree, not a frozen corpus. One file in six thousand does not move
any conclusion here, but the counts are printed as measured rather than
reconciled.*

## What was fetched, and how it was checked

```
git clone --depth 1 --branch v1.1.1 https://github.com/ysdragon/tree-sitter-ring
```

| | |
|---|---|
| tag | `v1.1.1` (`git describe` → `v1.1.1`) |
| commit | `b44d254e571ecba248eee803bdc5d70d00ec677f` |
| the fix | `287afffb` confirmed **contained in** v1.1.1 — `compare/287afffb...v1.1.1` gives `behind_by: 0, ahead_by: 5` |
| `src/parser.c` | present, pre-generated, 21,848,802 bytes (vendored was 21,827,954) |
| `src/scanner.c` | present, **byte-identical** to the vendored one — the fix is entirely in the grammar |
| `grammar.js` | 27,846 bytes, sha `47be7c89…` — **differs** from vendored `becd45fb…` |

Fetched into a scratch directory outside `vendor/`, and the baseline was
measured **before** anything in `vendor/` was touched.

**v1.1.1 is 5 commits ahead of the fix**, so it carries more than the
defect reported here. That turns out to matter — see *A second defect*
below.

## The four cases from the report

Checked individually, one case per file, so a whole-file verdict cannot
hide which line was refused
(`tests/fixtures/tsring_issue2/`):

| case | old grammar | **v1.1.1** | Ring |
|---|---|---|---|
| `? 3Copies("x")` — statement level | accepts | accepts | accepts |
| `? 3Copies(:of = "x")` — named-argument | accepts | accepts | accepts |
| `? Wrap(Copies(:of = "x"))` — nested, no digit | accepts | accepts | accepts |
| **`? Wrap(3Copies("x"))` — nested, digit-leading** | **REJECTS** | **accepts** | accepts |

**The defect is fixed and the other three did not regress.** This is also
what confirms the rebuilt binary actually contains v1.1.1: `build.zig`
compiles `vendor/tree-sitter-ring/src/parser.c` directly, so a grammar.js
swapped without a regenerated parser.c would have changed nothing while
looking like a result.

## The numbers

Disagreement = a file where `ringpp check` and `ring <file> -norun`
disagree about whether it parses.

### Root S — `D:\GitHub\stzlib\libraries`

| | old grammar | **v1.1.1** |
|---|---|---|
| files scanned | 6,012 | 6,013 |
| flagged unparseable by the grammar | 67 | 62 |
| of those, Ring agrees | 59 | 59 |
| **too strict** (grammar rejects, Ring accepts) | **8** | **3** |
| too permissive (Ring rejects, grammar accepts) | 0 | 0 |
| **rate** | **0.133%** | **0.050%** |
| coverage | forward FULL (67/67), reverse **sampled 120** of 5,945 | forward FULL (62/62), reverse **sampled 120** of 5,951 |

### Root R — `D:\ring127`

| | old grammar | **v1.1.1** |
|---|---|---|
| files scanned | 4,221 | 4,221 |
| flagged unparseable by the grammar | 17 | 15 |
| of those, Ring agrees | 7 | 7 |
| **too strict** | **10** | **8** |
| too permissive | 53 | 52 |
| **rate** | **1.493%** | **1.421%** |
| coverage | forward FULL, reverse **FULL** (4,204/4,204) | forward FULL, reverse **FULL** (4,206/4,206) |

### Combined, the number to quote

> **Files the grammar wrongly rejects: 18 → 11 across 10,233 files.
> Seven fixed, zero regressions.**

**On the sampling, stated plainly:** the *too strict* direction — the one
this fix affects — is **fully measured on both roots**, every flagged file
adjudicated by Ring. The *too permissive* direction is fully measured on
root R and **sampled at 120 files on root S**, because every Softanza file
`load`s the whole library and one `ring -norun` there costs 2.15 s against
0.20 s on root R; a full reverse pass would have run 3.5 hours per grammar.
The root-S rates above are therefore **not full-corpus rates** and must be
quoted with their coverage.

## The seven files, and what actually fixed each

Every remaining too-strict file was already too-strict before. **No file
that the old grammar accepted is rejected by v1.1.1** — checked against the
complete lists, not samples.

**Fixed by the reported defect — digit-leading identifier in argument
position (5 files, all Softanza):**

| file | the construct |
|---|---|
| `base/test/string/112_repeatedntimes.ring` | `, 3Copies(` — line 13, the file the original report was narrowed from |
| `base/test/string/433_basmalah.ring` | `, 3Hearts(` and `, 5Stars(` |
| `base/data/stzRandomData.ring` | `( 100Words(` — 4 occurrences in argument position |
| `base/test/string/102_boxedround.ring` | `( 2Hearts(` |
| `base/test/listoflists/69_pr.ring` | 2 digit-leading calls |

### A second defect, which this project never reported

**The two Ring-corpus files that improved contain no digit-leading
identifier at all.** They were fixed by v1.1.1's *other* change — the
`exit`/`loop` rework from `prec.right(seq(kw, optional($._expression)))`
to a `choice` with `prec.dynamic`.

**The minimal reproducer, verified against both grammars:**

```ring
func A
	exit

func B
	? 1
```

| | verdict |
|---|---|
| grammar at `65b185e` (pre-fix) | **rejects**, at `4:1` — the `func B` line |
| grammar at **v1.1.1** | accepts |
| `ring -norun` | accepts |

A bare `exit` (or `loop`) as a function's last statement made the old
`optional($._expression)` reach past the end of the function and try to
consume the **next `func` declaration** as its operand. That is why
`tictactoe3d.ring` failed at `560:2` — the `func` *after* the `exit`, not
the `exit` itself.

**How this was nearly got wrong, since the lesson is the same one as
above.** The first reproducer written for this was
`exit \t\t\t# Exit from the Events Loop` inside a `while`, on the theory
that the trailing comment was the trigger. **It does not reproduce** — the
pre-fix grammar accepts it, and so does v1.1.1. The comment is not
involved at all, and neither is the loop: a plain `exit` with no comment
reproduces just as well, provided another `func` follows. It was caught by
rebuilding the old grammar and actually running the reproducer against it
rather than reasoning from the diff.

*Second time this file records the same mistake. **Check that a minimal
reproducer actually reproduces before sending it.***

This was never filed from here. It is reported now because the credit is
his either way, and because it means **v1.1.1 fixed two classes of false
rejection, not one**.

## What is still too strict — the three root-S files, narrowed 2026-08-24

They have now been narrowed, and they are **two defects, neither of them the
one filed as #2**. Both are present in the pre-fix grammar as well, so v1.1.1
neither caused nor fixed them. Fixtures for all of it are in
`tests/fixtures/tsring_open/`, gated by `tests\run-all.ps1` as
`tsring open`.

### Defect A — the two codepoints Unicode case-folds into ASCII

`? "ſ"` alone is rejected by the grammar. `ring -norun` accepts it, silently,
exit 0. The character is **U+017F LATIN SMALL LETTER LONG S**, and it breaks
the file from anywhere in it:

| where the character sits | grammar | Ring |
|---|---|---|
| in a double-quoted string | **rejects** | accepts |
| in a single-quoted string | **rejects** | accepts |
| **in a comment** | **rejects** | accepts |
| in an identifier | **rejects** | accepts |
| plain ASCII `s` (control) | accepts | accepts |

That a **comment** kills the parse is what shows this is lexer-level and not a
string rule.

**The class is complete, not a sample.** One file per codepoint over 2,688
codepoints — U+00A0–U+07FF, U+1E00–U+1FFF, U+2100–U+21FF, U+FB00–U+FB1F — was
scanned in a single `ringpp check`. Exactly two were rejected:

| | name | case-folds to |
|---|---|---|
| **U+017F** `ſ` | Latin small letter long s | `s` |
| **U+212A** `K` | Kelvin sign | `k` |

These are the only two non-ASCII codepoints in Unicode whose simple case
folding produces an ASCII letter. U+212B `Å` (angstrom sign) folds to `å`,
which is *not* ASCII — and it parses, which is the control that makes the rule
a rule.

**The mechanism, from the generated table.** `grammar.js` builds
case-insensitive keywords with the `ci()` helper, mapping each letter to an
explicit `[sS]` pair — the careful approach, and not itself the bug.
tree-sitter then closes those classes under Unicode simple case folding, so
the `s` class acquires U+017F and the `k` class acquires U+212A, and both are
**subtracted from the catch-all identifier transition**:

```c
if (lookahead != 0 &&
    (lookahead < '\t' || '\r' < lookahead) &&
    lookahead != 0x17f &&
    lookahead != 0x212a) ADVANCE(90);
```

That is the "any other character" edge, so once those two are cut out of it
they have no transition left anywhere and the lex fails outright. 38
occurrences in `src/parser.c`.

**Not a v1.1.1 regression.** `git show 65b185e:vendor/tree-sitter-ring/src/parser.c
| grep -c 0x17f` gives **38** as well — identical. It has been there since the
initial import.

Accounts for `base/data/stzCharData.ring` (the `ſ` on line 1321) and
`base/test/char/47_showshortxtnl.ring` (line 25).

### Defect B — a statement terminated by a period

| | grammar | Ring |
|---|---|---|
| `foo("x").` | **rejects** | accepts |
| `? "x".` | **rejects** | accepts |
| `x = "a".` | **rejects** | accepts |
| a bare `.` on its own line | **rejects** | accepts |
| `foo("x")` — the same line without the dot | accepts | accepts |

Narrowed from `base/common/stzFuncs.ring` line 2690,
`StzRaise("...").`. **The decisive test:** that function extracted verbatim is
555 bytes and is rejected; the identical function with that single period
removed is 554 bytes and is accepted. One byte is the whole difference.

**On impact, stated carefully so nobody misquotes it.** A line ending in `).`
occurs **3,709 times across 1,187 files** in root S — and exactly **one** of
those files is rejected. Almost every occurrence is inside a comment or a
string, where it is harmless. That grep count is *not* the impact of this
defect, and it is written down here precisely so it cannot be quoted as one.

### Where the reported position is not the defect — a third time

Both files reported a position nowhere near their trigger. `stzFuncs.ring` was
reported at **2681:3**; the period is at **2690**. `47_showshortxtnl.ring` was
reported at **14:1**, the opening quote of a string literal whose `ſ` is on
line **25**. The grammar reports where it gave up, not where the trouble
started.

This file has now recorded the same lesson three times — twice as *check that
a minimal reproducer actually reproduces*, once as this. It is the same lesson:
**the first plausible explanation of a parse failure is usually the victim.**

### Root R's eight — assessment unchanged

Dominated by Ring's **changeable-syntax** feature
(`language/tests/scripts/natural/*`,
`samples/Language/ChangeSyntax/EnglishDemo.ring`, `samples/UsingNaturalLib/`),
where a program redefines Ring's own keywords at run time. A fixed grammar
cannot follow that, and it is not obvious it should try — that is a fair thing
to say out loud rather than file as a defect. Not re-narrowed here.

## The harness had to be repaired first, and the old 0.16% does not survive it

`tests/fidelity.ps1` matched the rule name **`rpp/parse-error`**. That
string appears **nowhere in `src/`**. The CLI emits **`rpp/unparsed`** —
and `git show 65b185e:src/…` confirms it emitted `rpp/unparsed` at the very
first commit, while `rpp/parse-error` existed *only inside the harness*,
which has never been edited since.

So the forward direction of this harness has **always matched nothing**. It
reported a structural zero on every corpus for either grammar, which is
worse than a wrong number because it reads as a clean result. Measured
proof, before the repair: root S reported `parse error : 0` while
`ringpp check` on the same root reported 67 `rpp/unparsed`.

**Therefore the published 0.16% cannot have come from this harness's
forward direction**, and it is not usable as a comparator. Whatever
produced it is unrecorded. This is exactly why both grammars were measured
here in one session instead of against the old figure — and it is the
strongest argument for doing it that way.

The harness now resolves the rule name against the binary's own catalogue
(`ringpp why`) and **aborts** if no parse-failure rule is found, rather than
reporting a clean corpus. It also prints its own coverage, so a sampled rate
cannot be read as a full one.

## The other direction

Root R shows 53 → 52 files that Ring **rejects** and the grammar
**accepts**, on full coverage both times. These are overwhelmingly Ring's
deliberately-invalid test fixtures (`language/tests/scripts/errormsg/*`)
plus the `naturallib` programs — consistent with the counter-guarded
keyword superset the grammar's README already documents. Not a problem for
Ring++, which keeps Ring's own scanner as the authority on validity and
uses the grammar only for structure and source spans.

## The thank-you, since it is true

The `typed_parameter` rule — keeping the type even though Ring's parser
discards it — is what makes `ringpp check` able to read type annotations at
all. The comment in `grammar.js` saying the type is *"kept here so the
structure is visible"* reached the same conclusion this project did
independently, and it is the reason the grammar was adopted rather than a
hand-written parser.

And the turnaround on #2 deserves saying: a narrowed reproducer went in, a
fix came back, and the corpus now measures seven fewer false rejections
across ten thousand files.
