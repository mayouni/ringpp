# 04 — Slicing a large string in a loop

**The task:** pull many small fields out of one big block of text. Fixed-width
records. A log scanner. A tokenizer. Anything that says *"give me 16 bytes
from offset N"*, thousands of times.

**The trap:** `substr()` copies **the whole string** before taking the slice.

Not the slice — the *string*. Asking for 16 bytes out of a megabyte copies a
megabyte. The cost scales with the size of the **source**, not the size of the
piece you asked for, which is the opposite of what the code looks like it does.

**The result** (1 MB source, 2,000 slices of 16 bytes):

| | |
|---|---:|
| raw Ring | **94 ms** |
| Ring++ | **4 ms** |
| | **23×** |
| bytes touched, raw | **1,907 MB** |
| bytes touched, Ring++ | **31 KB** |

---

## The whole difference

```ring
cField = substr(cData, nOff + 1, nWidth)     # copies 1 MB, returns 16 bytes
```

```ring
cField = oBuf.Peek(nOff, nWidth)             # reads 16 bytes
```

Same loop, same offsets. `Peek()` reads through a live pointer into bytes the
buffer owns, so the cost is the sixteen bytes you asked for.

## Where this loses — the honest half

**For a single character, don't reach for this.** Plain `s[i]` does not copy
and is already fast — Central measured `s[i]` at **0.07 µs** against
`substr(s, i, 1)` at **316 µs** on a 1.8 MB buffer, for the same character.
That difference costs nothing to take and needs no library.

**Ring++ is for a RANGE**, not a character. That distinction is worth more
than this example's speedup, and it is why the rule in
[CLAUDE.md](../../CLAUDE.md) says *use `s[i]`, or slice the row once and index
inside the slice*.

**And on a small source, `substr` is fine** — the copy it makes is small. The
cost is the size of what you are slicing *from*.

## A note on the check

`Peek()` is bounds-checked, and the check is what makes this safe by default.
`RppView.Sub()` over a region you have already validated skips the re-check,
for when you have measured and need it. Reaching for the unchecked form
before measuring is how you trade a 23× win for an information-disclosure bug
— `ptr2str` will happily return adjacent heap ([FINDINGS
F-5](../../docs/FINDINGS.md), safety).

## How the assertion is built

The fingerprint depends on **both ends and the length** of every slice:

```ring
return ascii(cField[1]) + ascii(cField[len(cField)]) * 3 + len(cField)
```

A wrong offset or a wrong width changes the total, so it shows up in the
correctness assertion instead of hiding behind a matching sum.

## Run it

```bash
ring examples/04-slice-a-large-string/example.ring
```
