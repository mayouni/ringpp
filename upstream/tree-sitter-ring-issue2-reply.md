# Reply to ysdragon/tree-sitter-ring#2 — the re-measured corpus number

**Status: NOT SENT.** Standing rule — this goes out over Mansour's name,
posted by him, after he has read it. Everything below the line is the
comment body, ready to paste into
[issue #2](https://github.com/ysdragon/tree-sitter-ring/issues/2).

Measured 2026-08-23. Working notes, with the full tables and the coverage
caveats, are in [`tree-sitter-ring-notes.md`](tree-sitter-ring-notes.md).

**Before sending, decide two things:**

1. **The 0.16% retraction.** The comment says plainly that the number in my
   original report cannot be reproduced and should not be relied on. That
   is true and I would rather say it than let him keep quoting it — but it
   is your call whether it goes in, since it is my error being published.
2. **Closing the issue.** The comment does not close it. If you want it
   closed, say so in the last line; GitHub lets him close it himself, and
   letting the maintainer close his own issue is the friendlier order.

---

Thank you — v1.1.1 fixes it. Here is the re-measured corpus number you
asked for, plus one thing your fix caught that I had never reported.

## The four cases from the report

| case | before | **v1.1.1** | Ring |
|---|---|---|---|
| `? 3Copies("x")` — statement level | accepts | accepts | accepts |
| `? 3Copies(:of = "x")` — named argument | accepts | accepts | accepts |
| `? Wrap(Copies(:of = "x"))` — nested, no digit | accepts | accepts | accepts |
| **`? Wrap(3Copies("x"))` — nested, digit-leading** | **rejects** | **accepts** | accepts |

The one that failed now parses, and the three that always worked did not
regress. I checked them one case per file, so a whole-file verdict could
not hide which line was refused.

## The corpus

**I could not reproduce my original corpus.** The roots behind "5,566
Softanza files" were never written down, so rather than guess at them I
measured **both grammars in one session over the same two roots**, which
gives a like-for-like delta whatever the roots are:

| root | `.ring` files |
|---|---|
| the Softanza library tree | 6,012 → 6,013 |
| a whole Ring 1.27 install, every `.ring` under it | 4,221 |

*(The Softanza count moved by one between the two runs — it is a live
working tree, not a frozen corpus. I am quoting the counts as measured
rather than reconciling them.)*

Method unchanged: run our checker (which statically links your grammar)
over the root, then adjudicate every disagreement with `ring <file> -norun`
— Ring's own scanner decides who is right, never the grammar.

### Files the grammar rejects that Ring accepts

| root | before | **v1.1.1** |
|---|---|---|
| Softanza library tree | 8 | **3** |
| Ring 1.27 tree | 10 | **8** |
| **total** | **18** | **11** |

> **18 → 11 across 10,233 files. Seven fixed, and no regressions** — every
> file still rejected was already rejected before. I compared complete
> lists, not samples, so that claim is exact.

As a rate: the Softanza tree went **0.133% → 0.050%**, and Ring's tree
**1.493% → 1.421%**.

**One honest caveat on those rates.** The *too strict* direction — the one
your fix changes — is fully measured on both roots, every flagged file
adjudicated. The opposite direction (Ring rejects, grammar accepts) is
fully measured on Ring's tree but **sampled at 120 files on the Softanza
tree**, because every file there `load`s the whole library and one
`ring -norun` costs 2.15 s against 0.20 s on Ring's tree; a full pass would
have taken 3.5 hours per grammar. So treat the Softanza percentages as
carrying a sampled component, and the 18 → 11 count as exact.

### The five files your fix repaired, and the construct in each

All five are the reported defect:

| file | construct |
|---|---|
| `base/test/string/112_repeatedntimes.ring` | `, 3Copies(` — line 13, the file the original report was narrowed from |
| `base/test/string/433_basmalah.ring` | `, 3Hearts(` and `, 5Stars(` |
| `base/data/stzRandomData.ring` | `( 100Words(`, 4 occurrences in argument position |
| `base/test/string/102_boxedround.ring` | `( 2Hearts(` |
| `base/test/listoflists/69_pr.ring` | 2 digit-leading calls |

## The thing I never reported, which you fixed anyway

The other two files that improved are in **Ring's own tree**, and they
contain **no digit-leading identifier at all** —
`applications/tictactoe3d/tictactoe3d.ring` and
`applications/eightpuzzle3d/EightPuzzleGame3D.ring`. They were fixed by
your `exit`/`loop` rework, the change from
`prec.right(seq(kw, optional($._expression)))` to a `choice` with
`prec.dynamic`.

Minimal reproducer, verified against both grammars:

```ring
func A
	exit

func B
	? 1
```

- grammar before the fix: **rejects**, at `4:1` — the `func B` line
- **v1.1.1: accepts**
- `ring -norun`: accepts

A bare `exit` (or `loop`) as a function's last statement made the old
`optional($._expression)` reach past the end of the function and try to
take the **next `func` declaration** as its operand. That is why
`tictactoe3d.ring` failed at `560:2` — the `func` after the `exit`, not the
`exit` itself.

So v1.1.1 fixed two classes of false rejection, not one. I only found the
second because I re-measured; it was never filed, and the credit is yours
either way.

## A correction I owe you: please do not rely on my 0.16%

The "~0.16%, 9 files out of 5,566" in my original report **cannot be
reproduced, and I no longer believe it measures what I said it did.**

The harness that produced my corpus numbers searched our checker's output
for a diagnostic named `rpp/parse-error`. Our checker has never emitted
that name — it emits `rpp/unparsed`, and it did so in the very first commit
of the repository, where `rpp/parse-error` existed only inside the harness
itself. So that half of the harness had always matched nothing and reported
a clean corpus regardless of the grammar. The proof is blunt: before I
repaired it, it reported **0** unparseable files on a tree where the
checker reported **67**.

The finding I sent you was real and reproducible — it came from a specific
file and was bisected by hand, and none of that depended on the harness.
But the *percentage* attached to it did, so it should not be quoted. The
numbers above come from a repaired harness that now resolves the
diagnostic name against the checker's own catalogue and refuses to run if
it cannot find it.

I would rather tell you this than have you cite 0.16% somewhere.

## What is still rejected (11 files), and my read on it

Eight are in Ring's tree and are dominated by Ring's **changeable-syntax**
feature — `language/tests/scripts/natural/*`,
`samples/Language/ChangeSyntax/EnglishDemo.ring`,
`samples/UsingNaturalLib/` — where a program redefines Ring's own keywords
at run time. I do not think a static grammar can follow that, and I am not
sure it should try. I mention them for completeness, not as defects.

The remaining three are in the Softanza tree
(`base/common/stzFuncs.ring`, `base/data/stzCharData.ring`,
`base/test/char/47_showshortxtnl.ring`). **I have not narrowed them to
reproducers**, so I am not filing them — the last time I sent a case I had
not verified, it did not reproduce and would have cost you an afternoon. If
I get them down to something minimal I will open a separate issue.

## Provenance, so you can check what I measured

```
git clone --depth 1 --branch v1.1.1 https://github.com/ysdragon/tree-sitter-ring
```

- tag `v1.1.1`, commit `b44d254e571ecba248eee803bdc5d70d00ec677f`
- `287afffb` confirmed contained in the tag (`compare` → `behind_by: 0`)
- `src/parser.c` sha256 begins `cb5bb1e7`, 21,848,802 bytes
- `src/scanner.c` is **byte-identical** to the pre-fix one — the fix is
  entirely in the grammar
- the pre-fix baseline was measured *before* anything was swapped, and the
  swap was confirmed to have reached the binary by case 4 flipping

Thanks again for the quick turnaround. The `typed_parameter` rule keeping
the type that Ring's parser discards is still the reason we build on your
grammar rather than a hand-written parser — the comment saying the type is
kept "so the structure is visible" reached the same conclusion we did,
independently.
