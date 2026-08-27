# Case study: N-Queens, analysed and made 16× faster

A real Ring program, taken as received, measured, and improved in three
steps. Every number below is a minimum over three runs, and no speed
figure is printed until the variants agree on the answer.

```
powershell -File bench\queens\run.ps1 -N 11 -Reps 3
```

**The program.** `Queens-N-Timing.ring` — a backtracking N-Queens solver
with a timing harness around it. Its own header credits the algorithm to
VIKASH VIK VIKASHVVERMA (programminggeek.in); the timing wrapper is a
later adaptation. Nothing about it is unusual, which is the point: it is
ordinary Ring, written the way the algorithm is normally written.

---

## The result first

Boards 1 through 11, all variants producing **3905 solutions** — the
published constant, so a variant that is faster and wrong cannot pass.

| variant | time | vs original |
|---|---:|---:|
| **V0** the original | 5 016 ms | 1.00× |
| **V1** one `fabs()` removed | 4 705 ms | 1.07× |
| *X1* + `RppIndexed` — **rejected** | 4 853 ms | 1.03× |
| *X2* board as a parameter — **rejected** | 5 899 ms | **0.85×** |
| **V2** occupancy flags | 1 342 ms | 3.74× |
| **V3** bitmask, no board at all | **304 ms** | **16.50×** |

Two of the six made it slower or did nothing. They are in the repository
with the others, because a study that reports only its wins is not a
measurement.

---

## Step 0 — what the analyser said: nothing

```
$ ringpp check bench/queens/v0-original.ring --advise
  0 error, 0 warn, 0 perf, 0 note   in 1 files
```

This is worth stating plainly rather than hiding. **Ring++'s checker had
no comment on this program**, and it was right not to invent one. Its
rules cover string copying, pointer misuse, loop headers that re-measure
strings, and shapes where a measured Ring++ idiom is faster. This program
touches none of that: it is integer arithmetic and recursion over an
11-element list.

The gap is real and worth naming. A checker built from findings about
*data-heavy* code has nothing to say about *compute-heavy* code, and no
amount of wishing makes a rule appear. What follows was found by
measuring, which is where the rules come from in the first place.

---

## Step 1 — measure before touching anything

The first question is not "what looks slow" but "what runs most".

```
Place() calls   : 2,247,737
inner iterations: 9,015,683
fabs() calls    : 18,031,366
```

The inner test of `Place()` runs nine million times, and each pass calls
`fabs()` twice:

```ring
for j = 1 to k-1
    if( x[j] = i   OR
        fabs(x[j]-i) = fabs(j-k) )
```

Eighteen million calls into a C builtin. That is the whole program.

---

## Step 2 — the obvious rewrite, which was wrong

`fabs(j-k)` is computing a sign the loop header already fixed: `j` runs to
`k-1`, so `j-k` is **always negative** and `fabs(j-k)` is just `k-j`. And
`fabs(a) = b` is `a = b or a = -b`, needing no call at all.

So the obvious move is to remove both calls, hoist `x[j]` into a local
since it is read twice, and carry `k-j` in a counter instead of
recomputing it. Three changes, all of them textbook.

**All three made it slower.**

| change | time |
|---|---:|
| original | 4 707 ms |
| both `fabs` replaced by comparisons | 5 097 ms |
| `x[j]` hoisted into a local | 5 484 ms |
| `k-j` carried in a counter | 5 253 ms |
| **`fabs(j-k)` → `k-j`, nothing else** | **4 307 ms** |

Measuring Ring's per-operation costs explains it ([F-44](FINDINGS.md)):

```
  y = 1                 20 ns    assignment
  if k - j = 5          32 ns    arithmetic in a test
  if fabs(-5) = 5       53 ns    builtin call in a test
```

**An assignment costs about the same as the `fabs` call it was meant to
avoid.** Hoisting a repeated call into a local is a trade at par, not a
saving — and replacing one call with two comparisons is a loss outright.

The one change that helped deleted a call and put *nothing* in its place.
That is V1, and it is worth 7%.

**Why there is no checker rule for this.** "Hoist this out of the loop" is
wrong about as often as it is right in Ring, and a rule that is wrong half
the time is worse than no rule. This stays a finding.

---

## Step 3 — where Ring++ itself does not help

Two library-informed attempts, both kept as counter-examples.

**X1 — `RppIndexed` on the board.** The idiom exists because Ring reaches
a list element by walking from a cursor, making jumping access O(distance)
— worth 5× on an 8,000-item list ([F-42](FINDINGS.md)). Here the board is
**11 items**. There is no distance to save, and no gain arrives: 4 853 ms
against V1's 4 705, inside the noise. The size rule the library already
states holds: the indexed idiom is for big lists read out of order.

**X2 — passing the board as a parameter.** Ring passes a list by
reference, so threading it through every call should cost nothing and
might save the global lookups. It costs **15%**. `Place()` is called
2,247,737 times, and each call now pushes one more argument; the per-call
price of the extra parameter exceeds the per-read saving inside.

> Passing a list by reference means no **copy**. It does not mean free.

---

## Step 4 — stop asking the question

V0 and V1 both ask "does this square conflict?" nine million times, and
answer by walking every queen already placed. The standard fix is to make
the question O(1): a queen at `(k,i)` conflicts only on a column, a
diagonal (`k+i`), or an anti-diagonal (`k-i`) — three numbers, three
flags.

**V2** keeps one flag list per set: 1 342 ms, **3.74×**. The inner loop is
gone; the price is six list writes per node for marking and unmarking.

**V3** notices those three sets are each at most `n` bits wide, and `n` is
12, so all three fit in ordinary Ring numbers. Marking becomes `OR`,
testing `AND`, and unmarking becomes **free** — shifting the diagonal
masks one position per row means the caller's own copy is never modified,
so returning undoes it.

```ring
nFree = nAll & ~(nCol | nD1 | nD2)
while nFree != 0
    nBit = nFree & -nFree              # lowest set bit
    nFree -= nBit
    Solve(nCol | nBit, ((nD1 | nBit) << 1) & nAll, (nD2 | nBit) >> 1, nAll)
end
```

**304 ms — 16.5×**, and the board list disappears entirely.

---

## What the study teaches

**The order mattered more than the cleverness.** Counting the inner
iterations took one minute and pointed at the only line worth touching.
Every optimisation attempted before measuring — and three were — made the
program slower.

**Ring's cost model is not C's.** A builtin call is cheap; an assignment
is not free. Optimisations that move work around lose. Only deleting work
wins.

**The biggest win was not a micro-optimisation at all.** V1's careful
7% is worth less than a twentieth of what V3 got by asking a different
question. Micro-tuning a linear scan is effort spent making the wrong
algorithm faster.

**And Ring++ was not the answer here.** Its library targets copying, and
this program copies nothing; its checker targets data-heavy shapes, and
this program is compute-heavy. Both said so honestly rather than
manufacturing a win. The gains came from Ring itself — measured, and
reproducible with one command.
