# The corrections register

**Every place Ring++ deliberately behaves differently from Ring, with the
verdict, the measurement, and who decided.**

`docs/FINDINGS.md` records what Ring *does*. This file records what Ring++
does *instead*, and why that was chosen. A finding is an observation; a
correction is a decision, and decisions need an owner and a date.

The charter
(`softanza/memos/2026-08-30-ringpp-design-charter.md` §4) sets the
vocabulary, and compatibility is decided **per defect**, never as a blanket
promise:

| verdict | meaning |
|---|---|
| **keep** | Ring's behaviour reproduced exactly |
| **fix silently** | Ring's behaviour was a bug, and the corrected one cannot break correct code |
| **break, with a rule** | the behaviour is removed, and a checker rule finds every site that relied on it |
| **drop, with a constraint** | the feature does not exist in Ring++, and the estate is written not to use it |

A fifth shape exists and is named here because the first entry is one: a
**fix whose blast radius is not statically findable**. It cannot be
"silent", because it changes output that correct code produces; and it
cannot be "break, with a rule", because no rule can find the affected sites.
Those get a stated migration cost instead of a rule.

---

## C-1 · Exact ties round half-to-even, not half-away-from-zero

**Verdict: fix — IEEE correctness. Decided by Mansour, 2026-09-07.**
Finding: [F-57](FINDINGS.md). Blast radius: **not statically findable.**

```
                     Ring 1.27    Ring++
  decimals(2)
    0.125      ->      0.13        0.12
    1/8        ->      0.13        0.12
  decimals(0)
    0.5        ->      1           0
    2.5        ->      3           2
```

Ring's official build rounds a tie **away from zero**; Ring++ rounds it
**to even**, which is the IEEE 754 default and what glibc, musl and LLVM's
`printf` implement. Only *exact* ties differ — 0.135 and 0.145 are not
really ties in binary and both agree on them, which is why this reads as an
occasional disagreement rather than a rule.

**The arithmetic is identical.** Only the decimal *formatting* of a tie
differs.

**Why correctness won.** Half-to-even is the defined behaviour of the
floating-point standard the arithmetic already follows, it does not
accumulate bias across many roundings, and it is what every other
IEEE-conforming runtime a Softanza number will ever meet — a database, a
spreadsheet, another language's report — will do with the same value. Half
away from zero is an artefact of one C runtime, not a decision anyone made.

**What it costs, stated rather than minimised.** Any recorded output
containing a formatted exact tie changes. In the 90-file Softanza sweep that
found it, four files were affected — `hashlist/17_numberofklasses`,
`hashlist/26_content`, `hashlist/test_engine_hashlist`,
`stats/plot_engine_parity_narrated` — where class frequencies print
`0.13` on Ring and `0.12` on Ring++, from 1/8.

**No checker rule is possible for this**, and it is worth being exact about
why: whether a value is a tie is a property of the value at run time, not of
the source. A rule could flag every `decimals()` call or every numeric
format site, but that is thousands of places of which almost none are
affected — a rule that cries wolf is a rule people turn off. The migration
cost is therefore: **re-record the expected outputs that contain a
formatted tie**, found by running the suite on both and diffing, which is
how these four were found.

---

## A note on `ab-known.txt`

`docs/FINDINGS.md` refers three times to divergences "registered in
`bench/ab-known.txt`" — `map:M10` and `map:M11` at line 2151, `bi:BI_IDX` at
line 2438, and "29 of them" at line 2211. **That file is not in this
repository and never has been**: `bench/` exists and has 30 other entries,
but no commit in the full history of ringpp ever added, moved or deleted it,
and it is not in `softanza` or `stzlib` either.

The likely account is that it belonged to the **compiled-kernel A/B
harness** — the line at 2211 is about `rnxc` refusing functions — which was
**descoped on 2026-08-23**, along with the workspace it lived in. So those
three citations point at a registry that is gone rather than one that is
elsewhere.

Until someone says otherwise, **this file is the register**, and those three
divergences should be restated here as entries so there is one place rather
than three pointers to a file nobody can open. They are not restated
already because doing it from the prose alone would be guessing at verdicts
that were never recorded.
