# Google Group post — tree-sitter-ring v1.1.1

**Status: DRAFTED, NOT SENT.** For the Ring Google Group, posted by
Mansour. The GitHub reply it links to **is** already posted:
[issue #2, comment 5384766820](https://github.com/ysdragon/tree-sitter-ring/issues/2#issuecomment-5384766820).

Kept short on purpose — the group gets the headline and the link, not the
tables. Everything quantitative lives in the linked comment.

---

**Subject:** tree-sitter-ring v1.1.1 — two parsing fixes, measured over 10,233 Ring files

Youssef Saeed's tree-sitter grammar for Ring
(https://github.com/ysdragon/tree-sitter-ring) is at v1.1.1, and it fixes
two constructs that Ring accepts but the grammar was rejecting:

1. a **digit-leading identifier whose call is an argument to another
   call** — `? Wrap(3Copies("x"))`. Ring accepts it; the grammar did not.
   Statement-level `? 3Copies("x")` always worked, which is what made it
   hard to spot.

2. a bare **`exit` or `loop` as a function's last statement**, followed by
   another `func`. The old rule reached past the end of the function and
   tried to take the next `func` declaration as the operand of `exit`:

```ring
func A
    exit

func B
    ? 1
```

I re-measured after the fix, over **10,233 files** — a full Ring 1.27
install (4,221) and the Softanza library tree (6,012) — with Ring itself
as the judge: every disagreement is settled by `ring <file> -norun`, never
by the grammar's opinion.

**Files the grammar wrongly rejects: 18 → 11. Seven fixed, no
regressions.**

Of the 11 that remain, 8 are Ring's own **changeable-syntax** material
(`language/tests/scripts/natural/`, `samples/Language/ChangeSyntax/`,
`samples/UsingNaturalLib/`), where a program redefines Ring's keywords at
run time. I do not think a static grammar can follow that, and I am not
sure it should try — worth saying out loud rather than filing as defects.

This matters beyond one grammar: editor support, syntax highlighting and
static analysis for Ring all end up standing on it, so a false rejection
there becomes a false error in someone's editor.

Full numbers, the reproducers, and the provenance of what was measured:

https://github.com/ysdragon/tree-sitter-ring/issues/2#issuecomment-5384766820

That comment also retracts a figure I published in my original report — a
"0.16% disagreement rate" that came from a measurement harness whose
forward direction, it turns out, had never matched anything. The finding
itself was hand-bisected and stands; the percentage should not be quoted.
Better said plainly than left in circulation.

Thanks to Youssef for the turnaround — a narrowed reproducer went in and a
fix came back.
