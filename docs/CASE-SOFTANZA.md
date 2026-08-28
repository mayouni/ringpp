# Case study: a string-heavy Softanza path, measured

`stzString.ReplaceByMany` — walk a text, replace every occurrence of a
substring, cycling through a list of replacements. Real code, in the
library Ring++ was built alongside, on the kind of workload Ring++ exists
for.

Three results came out, and only one of them is about speed.

```
cd D:\GitHub\stzlib\libraries\stzlib
ring D:/GitHub/ringpp/bench/12_softanza_replace.ring
```

---

## Result 1 — Ring++ would not load beside Softanza at all

Before a single measurement, this:

```
D:/GitHub/ringpp/rpp/probe.ring Line (138)
Error (C22) : Function redefinition, function is already defined!
```

Ring++ defined a global helper called **`iff`**. So does Softanza
(`stzExtinCode.ring:72`). Ring allows one definition of a name per program,
so `load "ringpp.ring"` next to Softanza failed outright — before either
library ran a line.

`iff` was the **only** unprefixed global in Ring++; every other name is
`Rpp…` or `_Rpp…`. It is now `_RppIff`. A dependency-free library that
cannot be loaded alongside the library it was built for is not
dependency-free, and nothing but putting the two in one program was ever
going to find it.

---

## Result 2 — the shipping path is 10× slower than plain Ring

Same input, same output, byte-identical on every row, minima of three runs:

| bytes | occurrences | **V0** as it ships | **V1** engine handle hoisted | **V2** Ring++ | **V3** plain Ring |
|---:|---:|---:|---:|---:|---:|
| 19 500 | 300 | 5 ms | 2 ms | 70 ms | **0 ms** |
| 39 000 | 600 | 18 ms | 6 ms | 142 ms | **1 ms** |
| 78 000 | 1 200 | 57 ms | 26 ms | 280 ms | **6 ms** |
| 156 000 | 2 400 | 202 ms | 101 ms | 570 ms | **21 ms** |

V0 is quadratic: every doubling of the text roughly quadruples the time.

### Why

`ReplaceByMany` finds and slices through two helpers, and each one does
this:

```ring
def _FindFrom(pcHay, pcNeedle, _nFrom_)
    _pH_ = StzEngineString(pcHay)          # the WHOLE haystack, per call
    _nRes_ = StzEngineStringFindFirstFromCS(_pH_, pcNeedle, _nFrom_, 1)
    StzEngineStringFree(_pH_)
```

`_EngineSlice` is the same shape. So one find plus one slice per occurrence
means **two full rebuilds of the text across the Ring↔Zig bridge per
occurrence** — O(n·k) of copying to do O(n) of work.

The Zig engine is not the problem. It is fast, and it is doing the search
correctly. **The bridge is being crossed with the whole text in hand, k
times.**

### The fix Softanza should make

**V1** changes one thing: build the engine string **once**, search and slice
against that handle, free it at the end. Same algorithm, same engine, same
codepoint semantics, no Ring++ anywhere — and **2× faster**.

That is the change worth making, because it keeps the engine's
codepoint-correct behaviour. V3 below is faster still but is byte-oriented,
which is not the same guarantee.

### The number that reframes it

**V3 is twelve lines of plain Ring** — `substr(hay, needle)` to find, `+=`
to build — and it is **10× faster than the shipping path** and 5× faster
than the fixed one. `substr` is a native C search, and Ring's string append
already doubles its capacity.

For this operation, on ASCII, crossing into the engine costs more than the
engine saves.

---

## Result 3 — Ring++ is the wrong tool here, and the number says so

**V2 is the slowest of the four**, by 3–27×.

It is a fair implementation of the obvious idea: hold the text in an
`RppBuffer`, scan with `Byte()`, confirm with `Peek()`, never copy the
haystack. Every read is genuinely cheap — and there are 156,000 positions,
each costing two method calls at roughly a microsecond of interpreter
apiece. **No per-read saving survives that.**

> `RppBuffer` is for holding one large value still and taking a **few large
> slices** of it. Used per byte, in a loop, it loses to everything —
> including plain `substr`.

This is the same boundary the library already documents from the other
direction: building 1.6 MB from 8-byte chunks is 28× *slower* through
`memcpy` than through `cOut += chunk` (F-5). The rule generalises — **Ring++
wins on the size of each operation, never on their number.**

### What the checker did find

Across Softanza's 46-file string library:

```
$ ringpp check .../base/string --advise
  3 error, 3 warn, 66 perf, 1 note   in 46 files
  39 advice item(s)

  36  rpp/substr-in-loop
  30  rpp/len-in-loop-header
  39  rpp/advise-forin
   4  rpp/method-shadows-builtin
   3  rpp/type-arity
```

Those 30 `len-in-loop-header` hits are the quadratic loop-header trap
([F-41](FINDINGS.md)) — including in number validators like
`RepresentsSignedRealNumber`, which use the worse `while i <= len(s)` form.
Each is a one-line fix. **The checker earned its place here; the library
did not.**

---

## What this case study is worth

**It corrected the library.** The `iff` collision was a real defect that
made Ring++ unloadable beside Softanza, and only this exercise could
surface it.

**It found a 10× regression in real code**, with a mechanism (the bridge
crossed with the whole text, per call), a conservative fix (V1, 2×,
semantics preserved), and an aggressive one (V3, 10×, byte-oriented).

**It drew Ring++'s boundary in numbers rather than prose.** The library is
worth reaching for when one operation moves a lot of data. It is the wrong
answer when many operations each move a little — and it says so here in
its own case study, at 27× against.

**And one methodological note.** A first pass through this measurement
nearly reported a bug in `ReplaceByMany`, because a sibling method's
comment describes different semantics — extras left untouched — while the
method that actually runs deliberately cycles. Reading the code that runs,
rather than the code that looks like it runs, is the difference between a
finding and an embarrassment.
