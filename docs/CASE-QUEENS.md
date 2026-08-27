# Case study: a program Ring++ could not speed up

`Queens-N-Timing.ring`, a backtracking N-Queens solver, taken as received
and put through the whole Ring++ toolchain. **Neither half of the project
improved it.** The checker found nothing to report, and the two library
idioms that looked applicable each cost more than they saved.

That is the result. This document exists because it is a result — the
project's own rule is that a benchmark showing only its good case is
marketing, and a toolchain that has never published a case it does not fit
has not been tested, only advertised.

```
powershell -File bench/queens/run.ps1 -N 11 -Reps 3
```

**The program.** Its own header credits the algorithm to VIKASH VIK
VIKASHVVERMA (programminggeek.in); the timing wrapper is a later
adaptation. Nothing about it is unusual, which is the point: it is
ordinary Ring, written the way the algorithm is normally written.

---

## What Ring++ contributed: nothing measurable

| Ring++ facility | applied to | result |
|---|---|---|
| `ringpp check --advise` | the whole file | **0 findings**, correctly |
| `RppIndexed` (X1) | the board list | **1.03×** — inside the noise |
| list-by-reference (X2) | the board | **0.85×** — 15% *slower* |

**The checker.**

```
$ ringpp check bench/queens/v0-original.ring --advise
  0 error, 0 warn, 0 perf, 0 note   in 1 files
```

Its rules come from findings about data-heavy code — string copies,
pointer misuse, loop headers that re-measure strings, shapes where a
measured Ring++ idiom is faster. This program is integer recursion over an
11-element list and touches none of them. It was right not to invent a
comment, and the gap is worth naming rather than hiding: a checker built
from data-heavy findings has nothing to say about compute-heavy code.

**`RppIndexed` (X1).** The idiom exists because Ring reaches a list
element by walking from a cursor, so a jumping access costs O(distance)
([F-42](FINDINGS.md)) — worth 5× on an 8,000-item list. Here the board is
**11 items**. There is no distance to save, `ringvm_genarray`'s setup is
paid per board for a gain that never arrives, and the measurement lands
inside the noise of the variant it wraps.

**List-by-reference (X2).** A list crosses a Ring call boundary by
reference — the asymmetry with strings is the reason this project exists —
so threading the board through every call should have cost nothing and
might have saved the global lookups inside `Place()`. It cost **15%**.
`Place()` is called 2,247,737 times, and each call now pushes one more
argument; the per-call price of the extra parameter exceeds the per-read
saving inside.

> Passing a list by reference means no **copy**. It does not mean free.

> Ring++ targets the cost of **moving data**. This program moves almost
> none. The library was measured against it and declined, which is the
> outcome its own design predicts.

---

## What did make it faster: plain Ring, and a better algorithm

None of the gains below involve Ring++. They are recorded because the
*method* is transferable even when the library is not, and because one of
them produced a finding about the Ring VM worth more than the speed-up
([F-44](FINDINGS.md)).

Boards 1 through 11, minima of three runs, all variants producing **3905
solutions** — the published constant, so a variant that is faster and
wrong cannot pass.

| variant | what changed | time | vs original |
|---|---|---:|---:|
| **V0** the original | — | 5 016 ms | 1.00× |
| **V1** one `fabs()` removed | plain Ring | 4 705 ms | 1.07× |
| *X1* + `RppIndexed` | **Ring++** | 4 853 ms | 1.03× |
| *X2* board as a parameter | **Ring++ thesis** | 5 899 ms | **0.85×** |
| **V2** occupancy flags | different algorithm | 1 342 ms | 3.74× |
| **V3** bitmask, no board | different algorithm | **304 ms** | **16.50×** |

**The 16.5× is an algorithm change** — not a Ring++ result and not even a
Ring result. Replacing an O(k) conflict scan with O(1) bit tests pays off
in any language. It is the largest number on this page and the least
interesting one.

---

## How it was found

### 1. Measure before touching anything

The first question is not "what looks slow" but "what runs most".

```
Place() calls   : 2,247,737
inner iterations: 9,015,683
fabs() calls    : 18,031,366
```

The inner test of `Place()` runs nine million times and calls `fabs()`
twice per pass:

```ring
for j = 1 to k-1
    if( x[j] = i   OR
        fabs(x[j]-i) = fabs(j-k) )
```

Eighteen million calls into a C builtin. That is the whole program.

### 2. The obvious rewrite, which was wrong

`fabs(j-k)` computes a sign the loop header already fixed: `j` runs to
`k-1`, so `j-k` is **always negative** and `fabs(j-k)` is just `k-j`. And
`fabs(a) = b` is `a = b or a = -b`, needing no call at all.

So: remove both calls, hoist `x[j]` into a local since it is read twice,
carry `k-j` in a counter. Three changes, all textbook. **All three made it
slower.**

| change | time |
|---|---:|
| original | 4 707 ms |
| both `fabs` replaced by comparisons | 5 097 ms |
| `x[j]` hoisted into a local | 5 484 ms |
| `k-j` carried in a counter | 5 253 ms |
| **`fabs(j-k)` → `k-j`, nothing else** | **4 307 ms** |

Ring's per-operation costs explain it ([F-44](FINDINGS.md)):

```
  y = 1                 20 ns    assignment
  if k - j = 5          32 ns    arithmetic in a test
  if fabs(-5) = 5       53 ns    builtin call in a test
```

**An assignment costs about the same as the `fabs` call it was meant to
avoid.** Hoisting a repeated call into a local is a trade at par, not a
saving; replacing one call with two comparisons is a loss outright. The
one change that helped deleted a call and put *nothing* in its place.

*And there is deliberately no checker rule for this.* "Hoist this out of
the loop" is wrong about as often as it is right in Ring, and a rule wrong
half the time is worse than none.

### 3. Stop asking the question

V0 and V1 both ask "does this square conflict?" nine million times, and
answer by walking every queen already placed. Make the question O(1)
instead: a queen at `(k,i)` conflicts only on a column, a diagonal
(`k+i`), or an anti-diagonal (`k-i`) — three numbers, three flags.

**V2** keeps one flag list per set: 1 342 ms, **3.74×**. The inner loop is
gone; the price is six list writes per node to mark and unmark.

**V3** notices those three sets are each at most `n` bits wide, and `n` is
12, so all three fit in ordinary Ring numbers. Marking becomes `OR`,
testing `AND`, and unmarking becomes **free** — sliding the diagonal masks
one position per row means the caller's copy is never modified, so
returning undoes it.

```ring
nFree = nAll & ~(nCol | nD1 | nD2)
while nFree != 0
    nBit = nFree & -nFree              # lowest set bit
    nFree -= nBit
    Solve(nCol | nBit, ((nD1 | nBit) << 1) & nAll, (nD2 | nBit) >> 1, nAll)
end
```

**304 ms**, and the board list disappears entirely.

---

## What the study teaches

**Ring++ is not a general speed-up, and this is what that looks like.**
Its library targets copying and this program copies nothing; its checker
targets data-heavy shapes and this program is compute-heavy. Both said so
rather than manufacturing a win. A reader deciding whether Ring++ fits
*their* program is better served by this page than by another one where it
worked.

**The order mattered more than the cleverness.** Counting the inner
iterations took one minute and pointed at the only line worth touching.
Every optimisation attempted before measuring — three of them — made the
program slower.

**Ring's cost model is not C's.** A builtin call is cheap; an assignment
is not free. Optimisations that *move* work around lose. Only deleting
work wins.

**And the biggest number was the least interesting.** V1's careful 7% and
the whole discussion of `fabs` are worth less than a twentieth of what
came from asking a different question. Micro-tuning a linear scan is
effort spent making the wrong algorithm faster.
