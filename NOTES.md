# rnx-spike -- the first measurements of the VM, 2026-08-29 to 2026-09-04

A register VM in Zig: 16-byte tagged values, contiguous vectors, immutable
by-reference strings, threaded dispatch (labeled switch), Lua-style register
windows for calls. The six F-39 algorithms hand-compiled to its bytecode at
the op granularity Lua's own compiler emits. ~700 lines, one file, no stdlib,
no parser — deliberately. It exists to price an architecture, not to run code.

Build: `zig build-exe src/main.zig -OReleaseFast -femit-bin=rnx.exe` (Zig 0.15.2).

## Results — 2026-08-29, desktop (Windows 11, same machine for all three)

All six CHECK values byte-identical across Ring 1.27, Lua 5.1 and the spike;
sortedness of the mergesort result asserted host-side. Minima over
repetitions; Lua timed with inner-repeat windows ≥300 ms because its
`os.clock` ticks at 15.6 ms on Windows.

| bench      | Ring 1.27 | Lua 5.1 | rnx-spike | spike vs Ring | spike vs Lua 5.1 |
|------------|----------:|--------:|----------:|--------------:|-----------------:|
| sieve      |  82.00 ms |   20.30 |      6.42 |         12.8× |             3.2× |
| matmul     |  62.00    |   14.42 |      4.33 |         14.3× |             3.3× |
| fib        |  23.00    |    5.13 |      1.57 |         14.6× |             3.3× |
| mergesort  | 112.00    |   22.20 |      2.45 |         45.7× |             9.1× |
| binsearch  | 167.00    |    5.25 |      1.07 |          156× |             4.9× |
| bytescan   |  13.00    |    4.00 |      0.61 |          21×  |             6.6× |

**Provisional gate verdict (Lua 5.1): PASS, with margin.** The spike is
*faster* than Lua 5.1 on every row, by 3.2–9.1×.

## Definitive gate — Lua 5.4.7, built native on this machine, 2026-08-29

`zig cc -O2` from lua.org source, `os.clock` inner-repeat harness (same
15.6 ms Windows tick problem, same fix: repeat until the window clears
300+ ms, minimum of 3 windows, report per-call). CHECKs identical.

| bench | Lua 5.4.7 | rnx-spike | Lua/spike |
|------------|----------:|----------:|----------:|
| sieve      |  10.967 ms |  6.42 ms | 1.71× |
| matmul     |   5.635    |  4.33    | 1.30× |
| fib        |   3.070    |  1.57    | 1.96× |
| mergesort  |  10.467    |  2.45    | 4.27× |
| binsearch  |   1.727    |  1.07    | 1.61× |
| bytescan   |   2.520    |  0.61    | 4.13× |

**Gate verdict: PASS, unconditionally.** The kill criterion was "any compute
row worse than 3× Lua [as a multiplier of Lua's time, i.e. the spike allowed
to be up to 3× *slower*]". The spike is instead *faster than Lua 5.4* on
every single row, by 1.3–4.3×, with no asterisk needed this time — 5.4 is
the real peer, built on the real machine, same day. The 9–16× Ring-to-Lua
gap from F-39 is fully closed by this redesign, with room left over.

## A third peer — Luau, interpreter-only, no JIT

Luau (Roblox's typed, gradually-checked Lua descendant) is already vendored
in the sibling `stz` repo at `vendor/luau` — no download needed. Built here
native with `zig c++` from that source: VM + Compiler + Ast + Config +
CodeGen + the CLI's Repl/Coverage/Profiler/Require, plus the bundled
`extern/isocline` line editor (`isocline.c` compiled as C, everything else
as C++17), 93 translation units, one capped invocation, no CMake. **The
stock CLI defaults `codegen = false`**, flipped only by an explicit
`--codegen` flag (`CLI/Repl.cpp`) — CodeGen's object files link in (the code
path exists) but nothing here ever asked it to run, so this stays a fair
no-JIT peer, same kind as Lua, not ART's kind.

It earns its place in the table on its own terms: it is the same lineage as
the fair peer, already on disk, and it previews the exact interpreter
engineering the redesign proposes (fast calling convention, hardened table
implementation) — so it prices "how much of this gap does more engineering
on Lua's *own* architecture close, without changing the architecture."

| bench | Ring 1.27 | Lua 5.1 | Lua 5.4.7 | Luau | rnx-spike | spike vs Luau |
|------------|----------:|--------:|----------:|--------:|----------:|--------------:|
| sieve      |  82.00 ms | 20.300  |   10.967  |  10.778 |  6.42 ms | 1.68× |
| matmul     |  62.00    | 14.415  |    5.635  |   5.464 |  4.33    | 1.26× |
| fib        |  23.00    |  5.127  |    3.070  |   2.621 |  1.57    | 1.67× |
| mergesort  | 112.00    | 22.200  |   10.467  |   6.356 |  2.45    | 2.59× |
| binsearch  | 167.00    |  5.247  |    1.727  |   2.227 |  1.07    | 2.08× |
| bytescan   |  13.00    |  4.000  |    2.520  |   0.840 |  0.61    | 1.38× |

**The spike beats Luau too, on every row**, by 1.26–2.59× — smaller margins
than against stock 5.4 (Luau closes roughly half that gap through
engineering alone) but never closed. Two things reported exactly as
measured, not explained: **Luau beats Lua 5.4 by 3× on bytescan** (its
hardened string/table path earning its keep) but **loses to Lua 5.4 on
binsearch** (2.227 vs 1.727 ms) — table-indexing implementations differ
between the two and this file does not claim to know the mechanism, per the
F-39 precedent of naming an outlier instead of inventing a story for it.

**Reading the four-peer picture together**: Ring → Lua 5.1 → Lua 5.4 → Luau
is a monotonic climb through thirty years of the *same* register-VM-plus-
tables architecture getting better engineered, and it still lands
1.26–2.59× behind a from-scratch redesign that changes what a variable and
a list physically are. That is the study's Section 3 thesis restated as a
measurement: the gap Ring-Next targets is not "Ring needs Lua's polish," it
is one level deeper than polish reaches.

## The phone — ARM64, same device as F-39/F-40, 2026-08-29

> ### ⚠ THE TABLE IN THIS SECTION IS RETRACTED — read §"The retraction" below
>
> It was published this morning showing the spike losing to Luau on ARM.
> The simpleperf profile commissioned to explain that loss found instead
> that **it does not reproduce**: the run was executing on little cores
> while its peer ran on big ones. The corrected table is in §3 below, and
> no row is lost. The original is kept, unedited, because a retraction
> that deletes its own evidence is not a retraction.

`rnx.exe` and the Luau CLI cross-compiled with `zig build-exe -target
aarch64-linux-musl` / `zig c++ -target aarch64-linux-musl -static` — one
extra flag each, no other change. Lua 5.4.7 arm64 reused from the cached
F-39 build (`zig cc -target aarch64-linux-musl -static`). Pushed via `adb`,
run on-device, no rooting, no NDK — the same seccomp-avoiding path F-36
established. All CHECKs matched the desktop run exactly.

| bench | spike | Lua 5.4.7 | Luau | spike vs Lua5.4 | spike vs Luau |
|------------|------:|----------:|------:|----------------:|---------------:|
| sieve      | 59.03 |  66.64    | 43.26 |  1.13× faster   | **0.73× — LOSES** |
| matmul     | 45.38 |  51.12    | 22.29 |  1.13× faster   | **0.49× — LOSES** |
| fib        | 12.44 |  30.72    | 14.80 |  2.47× faster   |  1.19× faster |
| mergesort  | 26.00 |  49.16    | 33.55 |  1.89× faster   |  1.29× faster |
| binsearch  |  6.82 |   6.23    |  7.18 |  **0.91× — LOSES** |  1.05× faster |
| bytescan   |  4.15 |  12.06    |  2.52 |  2.91× faster   | **0.61× — LOSES** |

> ### ⚠ RETRACTED THE SAME DAY — the table above is a scheduler artifact
>
> The conclusion first drawn from it ("the redesign loses to Luau on ARM;
> what dominates on x64 does not automatically dominate on mobile") **is
> withdrawn.** The profile commissioned to explain it found instead that
> it does not reproduce. The corrected measurement is below; the table is
> kept, struck, because a retraction that deletes its own evidence is not
> a retraction.

## The retraction — what the simpleperf run actually found

### 1. The result does not reproduce

Identical binary, identical command (`./rnx`, no arguments, the exact
six-benchmark configuration of the morning run), same device, hours later:

| bench | morning | re-run ×3 | discrepancy |
|---|---:|---:|---:|
| sieve | 59.03 ms | 34.77 / 35.11 / 34.78 | **1.70×** |
| matmul | 45.38 | 22.69 / 22.64 / 22.66 | **2.00×** |
| bytescan | 4.15 | 2.24 | **1.85×** |

The re-runs agree with each other to under 1%. The morning figures are the
outlier — and pinning says where they came from.

### 2. The mechanism: core placement, and it is measurable

MT6768 (Helio G85) is **6× Cortex-A55 @1.8 GHz (cpu0–5) + 2× Cortex-A75
@2.0 GHz (cpu6–7)**. Pinning the same binary with `taskset`:

| bench | spike on A55 (cpu0) | spike on A75 (cpu7) | morning (unpinned) |
|---|---:|---:|---:|
| sieve | 64.18 | 34.86 | 59.03 ← little-core territory |
| matmul | 55.98 | 22.57 | 45.38 ← little-core territory |

The morning numbers sit in the little-core band. **The morning run was
executing on A55s while it was being compared against a peer on A75s.**

Why only the spike was hit: Luau's figures are *identical* across both
sessions (sieve 43.26 → 44.34, matmul 22.29 → 21.96, bytescan 2.52 → 2.50).
Its binary is 16.8 MB against the spike's 2.2 MB, and loading it does
enough page-fault work at startup to raise the task's utilisation signal —
so Android's energy-aware scheduler has already promoted it to a big core
before its first timed repetition. The spike starts in about a millisecond
and gets measured wherever it happened to land. Stock Lua 5.4 (2.7 MB) was
hit on matmul too (51.12 → 25.41), which fits the same explanation.

**The lesson, and it is the most portable thing this profile produced:**
three repetitions of a 20–60 ms workload on an unpinned big.LITTLE phone
is not a measurement of the workload, it is a measurement of the scheduler.
The house rule already says *report minima over repetitions, never a single
run*. The ARM corollary: **name the core, or the experiment is not
controlled.** Minima do not save you here — every repetition can land on
the wrong cluster.

### 3. The corrected ARM table — all three runtimes pinned to cpu7 (A75)

| bench | spike | Lua 5.4.7 | Luau | spike vs Lua 5.4 | spike vs Luau |
|------------|------:|----------:|------:|-----------------:|--------------:|
| sieve      | 34.86 |  73.11    | 44.46 | 2.10× faster | **1.28× faster** |
| matmul     | 22.57 |  24.49    | 21.98 | 1.09× faster | 0.97× — **dead heat** |
| bytescan   |  2.24 |  12.03    |  2.50 | 5.37× faster | **1.12× faster** |

On equal hardware the spike leads Luau on sieve and bytescan and ties on
matmul. It beats stock Lua 5.4 on all three. **No row is lost.**

### 4. The counters — the branch-misprediction hypothesis is refuted

`simpleperf stat`, pinned to cpu7. This is what the profile was commissioned
to find, and it kills the leading guess:

| bench | runtime | instructions | cycles | CPI | branch-miss rate |
|---|---|---:|---:|---:|---:|
| sieve | spike | 666.5 M | 537.0 M | 0.806 | 0.85% |
| sieve | Luau | 947.4 M | 743.7 M | 0.785 | 0.70% |
| matmul | spike | 697.0 M | 380.1 M | 0.545 | 1.11% |
| matmul | Luau | 728.2 M | 381.2 M | 0.524 | 1.02% |
| bytescan | spike | 400.0 M | 196.6 M | 0.492 | 0.56% |
| bytescan | Luau | 512.0 M | 220.8 M | 0.431 | 0.38% |

- **Branch misses are 0.4–1.1% for both, and comparable.** The hypothesis
  that ARM mispredicts the spike's labeled-switch dispatch — the leading
  candidate written into this file this morning — **is dead.** A75s predict
  this dispatch loop about as well as they predict Luau's.
- **The spike executes fewer instructions on every row** (1.04× on matmul,
  1.28× on bytescan, 1.42× on sieve). The register/vector redesign does
  reduce work per iteration on ARM exactly as it does on x64.
- **Luau retires instructions slightly more efficiently** — better CPI on
  matmul (0.524 vs 0.545) and bytescan (0.431 vs 0.492). That is real and
  is Luau's ARM tuning showing up where it should. On matmul the two
  effects cancel almost exactly: 380.1 M vs 381.2 M cycles, which is why
  that row is a genuine tie rather than a win for either.
- Luau issues 30.5 M branches on bytescan against the spike's 17.4 M —
  its `string.byte` stdlib call versus the spike's byte-index opcode,
  visible in the counter, as caveat 2 predicts.

### 5. The published Ring numbers were checked and are NOT affected

The obvious worry: `tests/android_campaign.ps1` runs Ring **first** and Lua
**last**, unpinned — precisely the order that would penalise Ring. Checked
directly, same device, same session:

| bench | Ring unpinned | Ring pinned cpu7 | delta |
|---|---:|---:|---:|
| sieve | 582.63 ms | 576.45 | 1.1% |
| matmul | 432.05 | 428.97 | 0.7% |
| bytescan | 76.84 | 76.83 | 0.0% |

**F-39, F-38 and F-40 stand.** Ring's benchmarks run 400–600 ms each, so the
task is promoted to a big core long before the measurement ends and the
artifact cannot bite. The artifact scales inversely with workload duration —
it only reaches workloads short enough to finish during placement, which is
exactly the range the spike lives in and Ring does not.

**What survives from the morning's reading**: nothing of its conclusion, and
all of its data. fib and mergesort still favour the spike (those rows were
never in dispute), and now sieve, matmul and bytescan do too, once the two
runtimes are made to run on the same silicon.

### Methodology now in force for every ARM measurement here

1. **Pin with `taskset`** and say which core in the report. cpu6/cpu7 are
   the A75s on this device; cpu0–5 are A55s.
2. **Re-run in a later session before publishing.** Both morning tables
   would have survived any amount of within-session repetition; only a
   cross-session re-run exposed them.
3. **Report the counters, not just the clock** — `simpleperf stat -e
   instructions,cpu-cycles,branch-instructions,branch-misses`. Instructions
   and CPI separate "does less work" from "runs the same work faster", and
   a wall-clock number alone cannot tell those apart.
4. Single-benchmark mode (`rnx <bench> [reps]`) exists for this; it keeps
   a profile from being polluted by the other five.

## The memory model, priced — 2026-08-29, and it changes the study

Caveat 3 below said the spike "has no GC" and predicted the mergesort row
would shrink once it had one. That prediction was **wrong in scope**: the
cost is not confined to mergesort, and on ARM it is large enough to erase
the redesign's advantage entirely. This section is the measurement.

### The three builds

`build.zig` produces variants differing in exactly one thing at a time, so
the cost decomposes instead of arriving as one lump:

| build | allocation | reclamation |
|---|---|---|
| `rnx-arena` | bump arena | none (wholesale at rep end) |
| `rnx-mi` | mimalloc | none — leaks on purpose |
| `rnx-mi-rc` | mimalloc | refcounts, real frees |

`arena → mi` prices the allocator. `mi → mi-rc` prices the refcount traffic.
The `rc` field is present in `Vec`/`Str` in **all** builds so object layout
is identical and the A/B measures counting, not cache footprint. mimalloc is
the copy already vendored in ringpp for F-40 (v2.17, MIT, sha recorded).

### It is correct, and it does reclaim

Every CHECK value is byte-identical across all three builds on both
architectures — no use-after-free, no wrong answer. And peak RSS on the
phone is the functional proof that the refcounts actually work:

| build | peak RSS (ARM, full suite) |
|---|---:|
| `rnx-arena` | 25 264 kB |
| `rnx-mi` (never frees) | 66 912 kB |
| `rnx-mi-rc` | **14 760 kB** |

**4.5× less memory than the leaking build and 1.7× less than the arena.**
That is what the timing below buys.

### Desktop x64 — minima of 3 runs

| bench | arena | mi | mi-rc | allocator cost | **RC cost** |
|------------|------:|------:|------:|---------------:|------------:|
| sieve      |  6.27 |  5.42 |  6.58 | −14% (mi wins) | **+21%** |
| matmul     |  4.56 |  4.34 |  7.30 | −5% | **+68%** |
| fib        |  1.60 |  1.60 |  2.75 | 0% | **+72%** |
| mergesort  |  2.57 |  3.38 |  3.93 | **+32%** | +16% |
| binsearch  |  1.10 |  1.08 |  1.31 | −2% | **+21%** |
| bytescan   |  0.68 |  0.68 |  0.97 | 0% | **+43%** |

### ARM64 — pinned to cpu7 (A75), per the methodology above

| bench | arena | mi | mi-rc | **RC cost** |
|------------|------:|------:|------:|------------:|
| sieve      | 33.43 | 30.74 | 62.11 | **+102%** |
| matmul     | 23.57 | 25.34 | 57.86 | **+128%** |
| fib        |  7.71 |  7.76 | 19.67 | **+154%** |
| mergesort  | 15.18 | 15.65 | 22.66 | +45% |
| binsearch  |  3.75 |  3.72 |  6.15 | +65% |
| bytescan   |  2.34 |  2.29 |  4.87 | **+113%** |

**The allocator is nearly free; the refcounting is not.** Swapping the bump
arena for mimalloc costs nothing outside mergesort (+32%, the only
allocation-heavy row) and is sometimes faster. Refcounting costs 16–72% on
x64 and **45–154% on ARM** — roughly double, because an A75 has less
out-of-order machinery to hide the extra loads, stores and branches.

**And it is emphatically not an allocation cost.** `fib` allocates *nothing
whatsoever* and pays +154% on ARM; `bytescan` allocates nothing and pays
+113%. The cost is (a) `setReg`'s retain/release tag check on **every**
register write, and (b) the frame-teardown sweep that releases every
register of a callee window on **every** return. fib makes 242 785 calls;
each now sweeps 4 registers it did not previously touch.

### What this does to the standing comparison

Against the peers, on the same pinned ARM core, with honest memory
management on both sides:

| bench | mi-rc | Lua 5.4 | Luau | vs Lua 5.4 | vs Luau |
|------------|------:|--------:|------:|-----------:|--------:|
| sieve      | 62.11 |  72.95  | 44.92 | 1.17× faster | **0.72× LOSES** |
| matmul     | 57.86 |  25.38  | 22.34 | **0.44× LOSES** | **0.39× LOSES** |
| fib        | 19.67 |  13.31  | 14.78 | **0.68× LOSES** | **0.75× LOSES** |
| mergesort  | 22.66 |  49.10  | 33.72 | 2.17× faster | 1.49× faster |
| binsearch  |  6.15 |   6.22  |  7.16 | 1.01× tie | 1.16× faster |
| bytescan   |  4.87 |  12.03  |  2.51 | 2.47× faster | **0.52× LOSES** |

**The spike loses four of six rows to Luau and three to Lua 5.4 once it
manages its own memory.** The earlier "beats every peer on every row" claim
does not survive this section and is withdrawn for the RC configuration.

**The Stage-1 gate still passes** — it was "any compute row worse than 3×
Lua", and the worst row (matmul, 57.86 vs 25.38) is 2.28× slower, inside
the bar. But it passes with a fraction of the margin the arena build showed,
and nobody should quote the arena numbers as the language's.

### Why this is a finding about the design, not just a slow implementation

This is **naive** reference counting, and the two standard remedies are
both large and both already in the study:

1. **Deferred / coalesced counting** (Deutsch–Bobrow): do not count
   register-to-register traffic at all; treat registers as roots and
   reconcile at safe points. Nearly all of fib's and matmul's cost is
   exactly that traffic.
2. **Type information — and this is the important one.** Every register in
   fib, and every register in matmul's inner loop, provably holds an `int`.
   A compiler that knows this emits a plain store with *zero* refcount
   traffic. The tax measured above is largest precisely where static types
   would erase it completely.

So the pass does not say "RC was the wrong choice". It says something more
useful for Stage 3: **the memory model and the type system are the same
lever.** Study §4.6 chose COW to keep Ring's copy semantics, §4.7 chose RC
for deterministic release, and §4.9 made types real — and this measurement
shows §4.9 is what pays for §4.6 and §4.7. An untyped Ring-Next with RC is
slower than Lua on compute; a typed one need not be. That is now a
measured constraint on the design rather than an aesthetic preference, and
it is the single most decision-relevant thing Stage 1 has produced.

**The honest open question**: Lua and Luau pay a *tracing* GC and these
workloads suit it — lots of short-lived garbage, few live objects, exactly
what generational collection is cheapest on. Whether RC-plus-types beats
tracing-GC-without-types on realistic Softanza-shaped work is **not**
answered by six algorithms, and this file does not claim it is.

## Typed registers and deferred counting — the tax, repaid

The previous section ended with a prediction: that the RC tax is largest
exactly where static types would erase it, so **the memory model and the
type system are the same lever**. Both remedies are now implemented and
measured, and the prediction holds.

Two more builds, still one variable at a time:

| build | what changed |
|---|---|
| `rnx-mi-rc-typed` | the compiler marks which registers and which writes can carry a reference; everything else is a plain store, and a frame's teardown sweeps only its boxed registers (fib's mask is **empty**) |
| `rnx-defer` | Deutsch–Bobrow deferred counting on top: register writes adjust **no** counts at all, only heap-to-heap edges are counted, and a zero-count table plus a root scan decides what is really garbage |

The masks are declared by hand here — that is precisely the output a typed
front end produces, and study §4.9's `typehints` channel is where Ring-Next
gets them. One codegen change came with them: matmul's `b[k]` now lands in
its own register instead of reusing an int register, which is exactly the
register allocation type information enables. All builds run that same
bytecode, so the comparison stays honest.

### Correct in every configuration

All six CHECK values byte-identical across **five builds × two
architectures**. Nothing is freed early, nothing is answered wrong.

### ARM64, pinned to cpu7 — the full ladder

| bench | arena | mi (no RC) | mi-rc | **typed** | **defer** |
|------------|------:|-----------:|------:|----------:|----------:|
| sieve      | 32.45 | 31.18 | 66.47 | 36.63 | **35.13** |
| matmul     | 23.43 | 25.00 | 58.65 | 32.36 | **25.88** |
| fib        |  8.08 |  8.06 | 19.29 |  8.00 | **7.43** |
| mergesort  | 14.85 | 15.50 | 22.71 | **16.31** | 16.72 |
| binsearch  |  3.74 |  3.78 |  6.15 |  3.89 | **3.81** |
| bytescan   |  2.32 |  2.33 |  4.87 |  2.38 | **2.35** |
| **peak RSS** | 25 292 kB | 66 916 kB | 14 760 kB | **14 672 kB** | 24 596 kB |

**Typed registers repay most of the tax on their own.** fib goes
19.29 → 8.00 against a no-RC baseline of 8.06 — a *complete* recovery, because
fib's boxed mask is empty and its returns stop sweeping anything. bytescan,
binsearch and mergesort likewise land within a few percent of the build that
does no memory management at all. What survives is the code that genuinely
moves references: sieve +17% and matmul +29% over no-RC.

**Deferred counting closes almost all of the remainder**, and the counters
show it is real work removed rather than a lucky layout:

| matmul, ARM | instructions | vs no-RC |
|---|---:|---:|
| `mi` (no RC at all) | 720 368 350 | — |
| `mi-rc` (naive) | 1 328 292 611 | **+84%** |
| `typed` | 925 889 436 | +29% |
| `defer` | **720 258 302** | **−0.02%** |

Deferred counting executes *the same instruction count as the build that
never frees* while actually managing memory. The refcount traffic in
matmul's inner loop is gone, not hidden.

### What it costs: memory, exactly as the theory says

Peak RSS is where deferred counting pays: **14 672 kB eager (typed) versus
24 596 kB deferred**, a 68% increase, because garbage now waits for a root
scan instead of dying at the instant its last reference drops. That is the
classic deferred-RC trade — latency for footprint — and it is a real design
choice rather than a free win. For the banking domain that motivated §4.7's
deterministic release, **eager typed RC is probably the right default**, with
deferred counting as an opt-in for compute-heavy code.

### The standing comparison, restored

Against the peers on the same pinned core, with the spike now doing honest
memory management (and freeing — 24.6 MB against the leaking build's 66.9):

| bench | defer | Lua 5.4 | Luau | vs Lua 5.4 | vs Luau |
|------------|------:|--------:|------:|-----------:|--------:|
| sieve      | 35.13 |  72.95  | 44.92 | 2.08× | 1.28× |
| matmul     | 25.88 |  25.38  | 22.34 | 0.98× tie | **0.86× LOSES** |
| fib        |  7.43 |  13.31  | 14.78 | 1.79× | 1.99× |
| mergesort  | 16.72 |  49.10  | 33.72 | 2.94× | 2.02× |
| binsearch  |  3.81 |   6.22  |  7.16 | 1.63× | 1.88× |
| bytescan   |  2.35 |  12.03  |  2.51 | 5.12× | 1.07× |

**Five of six rows won against both peers; matmul is a tie with Lua 5.4 and
the one loss to Luau.** The four-row loss reported in the previous section
was the cost of *untyped* refcounting, and it is repaid.

### One anomaly, resolved by counters rather than argued about

On the desktop, `defer` ran fib in 1.90 ms against `typed`'s 1.24 ms — the
build doing *less* work appearing 53% slower, reproducibly. The ARM counters
say typed retires 258.6 M instructions on fib and defer 223.7 M: deferred
really does less work, and on ARM it is correspondingly faster (7.43 vs
8.00). The desktop inversion is a code-layout effect in the `ret` dispatch
arm, not a cost. Recorded, not theorised — and it is the third time today
that a wall-clock number alone would have produced a wrong conclusion.

### What this settles for the study

§4.9 was written as the *type-safety* pillar — the answer to the bank's
governance question. It turns out to be load-bearing for performance too:
without types, RC costs 45–154% on ARM and loses four rows to Luau; with
them, the tax is 0–29% and the rows come back. **Gradual typing is not a
feature Ring-Next adds on top of its memory model — it is what makes that
memory model affordable.** That is now measured, on two architectures, with
instruction counts behind it.

Still not claimed: that any of this survives contact with Softanza-shaped
code. Six algorithms with hand-declared masks are not a type inferencer, and
Stage 2 is where that gets tested.

## The string workload — the founding thesis, measured at last

Every benchmark up to here was compute-heavy and allocation-light. None of
them passed a large string across a call boundary — which is the one thing
the whole project is *about*: "a Ring string is copied every time it crosses
a call boundary. A list is not." (F-1, F-5). The redesign's answer is
immutable by-reference strings, and until now that answer had never been run.

Two kernels, in all four runtimes, same work, CHECK values identical
(`bench/strings.ring`, `bench/strings.lua`, and two programs in the spike):

- **strpass** — call a one-line `flen(s)` 2000 times with a 1 MB string.
  Almost all the work is the call boundary itself.
- **strfind** — naive substring search over the same 1 MB, byte by byte.

| kernel | Ring 1.27 | Lua 5.4.7 | Luau | spike |
|---|---:|---:|---:|---:|
| strpass (desktop) | **730.00 ms** | 0.0260 | 0.0206 | **0.02** |
| strfind (desktop) | 557.00 | 65.00 | 29.41 | **9.10** |
| strpass (ARM, pinned) | — | 0.116 | 0.096 | 0.12 |
| strfind (ARM, pinned) | — | 337.01 | 96.44 | **52.92** |

**Ring pays 365 µs per call to hand a 1 MB string to a one-line function**
(730 ms / 2000), which is F-5's mechanism measured end to end, on a kernel
rather than a microbenchmark. The redesign pays nothing measurable:
**~28 000× faster on strpass.**

**And the honest half, which matters more than the ratio:** on strpass the
spike does *not* beat Lua or Luau — 0.02 against 0.026 and 0.021 is a tie.
It could not be otherwise: Lua has had immutable by-reference strings since
1993. So the founding thesis justifies **leaving Ring's substrate**; it does
not differentiate the redesign from the peer. Where the spike does lead is
strfind — 3.2× over Luau and 7.1× over Lua 5.4 on the desktop, 1.8× and 6.4×
on ARM — and that is the register/dispatch work, not the string design.

## Ring's assignment semantics — decided, and one decision was forced

Three questions were left open for ratification. All three are now settled by
measurement rather than preference, and the third one reversed a result from
earlier the same day.

### The test that settled them

Six instructions: `a = [1,2,3]; b = a; b[1] = 99; return a[1]`. **Ring
answers 1** — assignment copies a list. Reference semantics answer 99.

| build | answer | |
|---|---:|---|
| typed, no COW | **99** | reference semantics — Lua's, not Ring's |
| typed + COW (eager counts) | **1** | ✓ Ring |
| COW + **deferred** counting | **99** | ✗ silently wrong |

### Decision 4 — copy-on-write: YES, and it is not optional

The spike had **reference semantics all along**, which nobody had noticed
because no benchmark aliased a list. That means it was Lua wearing Ring's
syntax, and every claim resting on "746 K lines of Softanza keep meaning what
they mean" was unfounded until now. COW makes assignment observably copy
while sharing until the first write.

**It costs nothing measurable** — every row within noise of the non-COW
build, because at each mutation site the vector is unshared (`rc == 1`) and
the clone never fires. Ring's copy-on-assignment semantics, which look
expensive, are free when implemented this way. That is the single most
useful thing this section produces for the migration story.

**Amended 2026-09-11 (CORRECTIONS C-7).** The clone-on-write above was
wrong for the one sharing Ring does by reference: a parameter. `f(a)`
with `l[1] = 99` inside left the caller's `a` untouched, and a callee's
`add(l, x)` grew a clone that was thrown away -- unseen because no row
here writes through a parameter. Ring's copy is made at the ASSIGNMENT
now, eagerly (`copyv`), objects included, and a write never clones. The
rows above are unchanged (no list is assigned in them); the price where
lists ARE assigned is in `docs/CORRECTIONS.md`, C-7: +20% on a merge sort
that returns a list at every level, and 3.5 ns per element on a whole-list
assignment -- 21-31x under what Ring pays for the same copy.

### Decision 2 — eager counting, and it was never a preference

Deferred counting was reported an hour earlier as the winner on speed
(matmul at the no-RC instruction count) at a cost of 68% more memory. That
framing was wrong. **Deferred counting cannot implement Ring's semantics at
all**: COW's shared test is `rc > 1`, and deferred counting deliberately
leaves register references uncounted, so a shared list looks unshared and the
write lands in the original. The row above is that bug, reproduced on demand.

So the choice is not "speed versus footprint" — it is **correct versus
incorrect**. Eager typed reference counting is the default because deferred
counting answers 99 where Ring answers 1. Its speed was real and was bought
with a semantics violation nobody had tested for.

Deferred counting is not dead, but it is now confined: it would need a
separate conservative "possibly shared" flag maintained on every register
write, which is most of the cost it was introduced to avoid. Parked, with
the reason recorded.

### Decision 1 — reference counting over a tracing GC

Follows from decision 4 rather than from the banking argument I originally
gave. **COW's shared test *is* the refcount.** A tracing collector has no
cheap "is anyone else holding this?" query, so implementing Ring's assignment
semantics on top of one needs write barriers and a separate sharing flag —
paying for the count anyway, without getting deterministic release with it.
RC gives the semantics for free and the determinism as a bonus.

Still unbuilt, and stated so it is not forgotten: **the cycle collector**.
These kernels create no cycles; Ring objects can reference each other, so a
real implementation needs one. How much Softanza actually relies on cyclic
object graphs is an empirical question for Stage 2.

## Stage 2, milestone 1 — Ring source compiles and gives the same answers

The milestone was deliberately narrow: **the front end compiles the six
algorithms from Ring source and reproduces the CHECK values Ring itself
produces**, proving the pipe end to end before any Softanza module is
touched. It passes.

```
$ ring kernels_run.ring | grep CHECK   >  ring.out
$ rnxc run kernels.ring  | grep CHECK  >  rnx.out
$ diff ring.out rnx.out
IDENTICAL
```

sieve 25997, matmul 197883280, fib 75025, mergesort 895077970,
binsearch 470 — from the *same source file*, run by Ring 1.27 and by
tree-sitter → `compile.zig` → the spike's bytecode.

`rnxc` reuses ringpp's vendored tree-sitter and its grammar, and `ts.zig`
is copied verbatim from the checker. What is new is the trust placed in it:
in the checker a wrong guess about a node's shape produces a false
positive; here it produces a wrong program.

### The inference works, and you can read it

`rnxc dis` prints what the front end concluded. For MatMul it separates the
five list registers from the six integer ones with no annotations at all:

```
MatMul  frame=20 mask=0xff936 ret=int
    ; r0 = nN (int)      ; r1 = aA (ref)     ; r2 = aB (ref)
    ; r3 = i  (int)      ; r4 = aRowA (ref)  ; r5 = aRowB (ref)
    ; r6 = j  (int)      ; r7 = nAcc (int)   ; r8 = aRow (ref)
    ; r9 = nS (int)      ; r10 = k (int)
```

Those masks are the same ones Stage 1 measured at 45–154% on ARM, now
derived from source instead of hand-written.

### Four findings, all of them things a compiler learns and a checker does not

**1. The grammar does not reliably nest a function's statements inside the
function node.** In an eight-function file, *every function except the last
one kept only its first statement*; the rest appeared as siblings at file
level. Ring has no `end func`, so "one statement, then top-level code" is a
legal parse of the same text and tree-sitter is free to prefer it. The fix
is F-21's own rule — a function owns everything up to the next `func` — so
bodies are reconstructed **by position**, never by nesting. The checker
learned exactly this about classes and answers it the same way.

**2. Copy-on-write makes "load into a temporary, then mutate" silently
wrong.** `add(aL, x)` first compiled to *copy aL into a temp, then push*.
That makes `rc == 2`, so COW correctly decides the list is shared, clones
it, and the append lands in the clone, which is discarded. The list never
grows and nothing reports an error. Under COW a compiler needs a notion of
a mutable **place**, not merely of an expression. `a[i][j] = v` is the same
problem one level down and is still refused rather than miscompiled.

**3. A numeric `for` keeps its bound in a register that is live across the
whole body.** The body's temporaries were being allocated from the same
floor and overwrote it, so loops ran a wrong number of times. Found by
disassembling rather than by reasoning — `forloop a=3 b=4` next to
`dget a=4` is unmistakable, and no amount of staring at the source was
going to produce it.

**4. Inference is only as good as the call sites it can see.** `Fib`'s
parameter is proven `int` because Fib calls itself; `Sum32`'s could not be,
because nothing in the unit calls it, and assuming `int` would have dropped
the retain on a real list. Entry points are therefore conservative — and
that pessimism is exactly what **Ring's own type-hint channel removes**.
`func Sum32(list aL)` states what inference here has to assume. Study §4.9
stops being only a safety feature at this point and becomes the thing that
makes the generated code tight, which is the same conclusion the RC
measurements reached from the other side.

### Step 1 done: specialisation, and the speed gap closed and measured

The milestone deliberately left speed unmeasured, because compiled code used
dynamic `dget`/`dlen` where the hand-written bytecode used specialised
opcodes. That gap is now closed, and closing it produced the sharpest
finding of the whole front end.

**Inference learned to distinguish lists from strings.** The class lattice
went from `{int, ref}` to `{unknown, int, list, str, ref}` with a proper
join, plus a second level — what a list's *elements* are — because
`aRow = aA[i]` then `aRow[k]` needs it. Two bugs were in the way and both
were the same mistake: a local starting at `int` rather than at the lattice
bottom, so the first `join(int, list)` collapsed straight to `ref` and
nothing in the file specialised; and return types tested for exactly `ref`
instead of joining, so `BuildData` — which returns a list — was typed `int`
and its caller then read a vector as an integer.

Result: **20 of 25 container operations specialise** (13 `vget`, 7 `vlen`),
up from none. The five that remain are in `Sum32` and `BinSearchAll`, the
two entry points whose parameters inference cannot prove — which is
precisely the case type hints exist for.

**Then the pathology.** With specialisation in, compiled sieve ran **161 ms
against hand-written bytecode's 6.5 — 25× slower**, while every other row
sat at 2–3×. The cause is copy-on-write meeting naive codegen: reading
`aFlag[i]` copied the list into a temporary, which made `rc == 2`, so the
next `aFlag[j] = 1` found the list shared and **cloned 300,000 elements on
every single write**. The answers stayed correct the whole time.

> **Under COW a gratuitous register copy is not merely slow — it is
> semantically expensive.** Every read-into-a-temporary turns the next write
> into a full clone. A read has to be a *borrow*: when the base is a plain
> variable, its own register is handed to the opcode and no count moves.

That one change took sieve from 161.64 to 12.54 ms. Adding operand
borrowing (a bare variable can *be* the operand register) and immediate
forms (`x % 1000000007` is one instruction, as Lua's `MODK` is) removed a
further 70 instructions of the 346, and took sieve to 9.76.

### The same Ring source, both runtimes

`bench/kernels_bench.ring` times the file under Ring 1.27; `rnxc bench`
times what the front end makes of it. Minima over three repetitions, same
machine, identical CHECK values throughout:

| kernel | Ring 1.27 | Ring-Next | **speedup** | hand-written | compiled/hand |
|------------|----------:|----------:|------------:|-------------:|--------------:|
| sieve      |  83.00 ms |  9.76 ms  |  **8.5×**   | 6.50 | 1.50× |
| matmul     |  59.00    |  7.87     |  **7.5×**   | 5.36 | 1.47× |
| fib        |  22.00    |  2.54     |  **8.7×**   | 1.27 | 2.00× |
| mergesort  | 111.00    |  4.75     | **23.4×**   | 3.22 | 1.48× |
| binsearch  | 183.00    |  1.58     | **116×**    | 1.08 | 1.46× |

**Seven and a half to a hundred and sixteen times faster than Ring on the
same source, with the same answers.** binsearch is the extreme because it
is F-42's cursor walk — Ring's list indexing is O(distance) and the
redesign's is O(1) — so that row is a data-structure result, not a
compiler one.

The last column is the honest ceiling: hand-written bytecode is still
1.46–2.0× faster than what the front end emits. fib is the worst of them at
2.0× and has no containers at all, so that gap is pure call-sequence and
register-allocation naivety — known work, not a mystery.

### Step 2 done: Ring's own type hints, and what they are actually worth

F-24 settles which channel to use, and it is not the obvious one. Ring has
**two** annotation mechanisms wearing one syntax:

- `func Sum32(list aL)` — a **parser** feature (`stmt.c:1217`), free, no
  library, stock Ring runs it. Verified again here: `func Sq(int x)` returns
  49 on Ring 1.27 with nothing loaded.
- `int func Sum32(...)` — an ordinary expression statement reading a global
  named `int`. Without `typehints.ring` loaded the file **aborts with R24**,
  which is exactly what happened when I tried it. (It is also parsed as a
  stray top-level statement, which the body reconstruction would have
  absorbed into the previous function.)

So the front end reads **parameter annotations only**. `bench/kernels_typed.ring`
is `kernels.ring` with signatures annotated and nothing else changed; stock
Ring 1.27 runs it and prints the same five CHECK values.

| | un-annotated | annotated |
|---|---:|---:|
| dynamic `dget`/`dlen` remaining | 5 | **0** |
| `BinSearchAll` mask | 0xe03 | **0xe01** (`nQueries` proven int) |
| `Sum32`'s `aL` | `ref` | **`list`** |

| kernel | un-annotated | annotated | gain |
|------------|-------------:|----------:|-----:|
| sieve      |  9.96 ms | 9.47 | 5% |
| matmul     |  8.01    | 7.83 | 2% |
| fib        |  2.57    | 2.54 | 1% |
| mergesort  |  4.83    | 4.34 | 10% |
| binsearch  |  1.58    | 1.49 | 6% |

**The honest reading: 1–10%, not a transformation.** The annotations do
exactly what they should — every remaining dynamic dispatch disappears and
the masks tighten — but on *this* code inference had already proven 80% of
it unaided, so what was left to win was small and none of it sat in the
hottest loop. The mechanism is demonstrated; the magnitude here is modest.

Where the magnitude should be larger is code inference cannot see through:
entry-heavy libraries, deep call graphs, anything whose parameters arrive
from outside the compilation unit. That describes Softanza far better than
it describes eight self-contained kernels — which makes it a question for
the port, not something to claim from this table.

What this does settle is the *direction* of the §4.9 argument. The
type-safety pillar and the performance pillar are the same annotation, read
by the same pass, and neither costs the programmer anything they were not
already willing to write.

### Step 3 done: nested path assignment, and Ring's copy semantics go deep

`a[i][j] = v` was refused rather than miscompiled, because under COW the
write would land in a private clone and vanish. It now compiles, via one new
opcode.

**`vgetw` — get for write.** It makes the path private on the way *down*:
the container first (COW it if shared, rebinding the variable's register),
then the element (clone it if shared, storing the clone back into the
now-private container). The compiler chains one per level and finishes with
an ordinary `vset`, so `a[i][j][k] = v` works to arbitrary depth.

**The subtle part is that it hands back a borrow.** If `vgetw` retained the
element, `rc` would be 2 and the following `vset` would decide it was shared
and clone it *again* — the write lost, exactly the bug from step 1 one level
deeper. So the register points at the element without counting it, and the
compiler emits a single `loadi t, 0` afterwards to clear it, because a frame
teardown must never release a reference that was never taken. That clearing
instruction is the price of the borrow, and it is one instruction per nested
assignment.

**Checked against Ring, not against my expectations.** Ring's answer for
`aB = aA; aB[1][2] = 99; return aA[1][2]` is **0** — its
copy-on-assignment reaches *nested* lists, not just the outer one. The COW
implementation reproduces that exactly, because cloning the outer list
leaves the inner one shared, and the second level's clone then makes it
private too. `MatMul` rewritten in natural Ring style (`aA[i][j] = ...`,
the way `algorithms.ring` writes it) gives 197883280, matching Ring.

**It costs nothing.** Nested formulation 8.08–8.47 ms against the flat
build-a-row-then-add formulation at 8.05–8.33. Natural Ring style is not
penalised, which matters because it is the style Softanza is written in.

Two general tools came with it, replacing the hardcoded six-kernel driver:
`rnxc call <file> <Func> [args]` and `rnxc time <file> <Func> <arg> [reps]`.

### Step 4, first pass: the module is picked, and the object model is the gate

**The module: `stzStringWalker`** (`stzlib/libraries/stzlib/base/string/`),
210 lines, 21 methods, one class. Chosen deliberately over easier options:
it is in the string domain (the founding thesis), it has 22 control-flow
constructs of its own rather than being pure delegation, and *walking a
string with a cursor* is the exact shape F-42 showed Ring handles worst.

**It compiles to zero functions.** That is the expected answer, and the
useful output of this pass is not a friction number but a sized
prerequisite.

| construct in the module | count | in the subset? |
|---|---:|---|
| `for` / `while` / `if` | 22 | **yes** |
| subscripts, incl. nested | 20 | **yes** |
| `len()` | 5 | **yes** |
| class + inheritance (`from`) | 1 | no |
| `def` methods | 21 | no |
| `@attribute` declarations | 8 | no |
| `obj.method()` calls | 21 | no |
| `This` / `self` | 7 | no |
| `new stzX(...)` | 4 | no |
| string literals | 4 | no |
| `aList + item` (append operator) | 6 | no |
| `def` nested inside a `def` | 3 | no |
| `isString` / `isObject` | 2 | no |
| `StzRaise` | 4 | no |

**And it is representative.** Census of `base/`, 527 files, excluding tests
and archives — **267,791 non-blank non-comment lines**:

| | lines | share |
|---|---:|---:|
| classes | 571 | — |
| `def` methods | 34,112 | — |
| lines using `obj.method` | 36,633 | 13% |
| lines using `This`/`self` | 39,720 | 14% |
| lines with an `@attribute` | 29,479 | 11% |
| lines with a string literal | 44,610 | 16% |

**A note on the line count, because it corrects this file's own arithmetic.**
Mansour flagged that Softanza is ~300K lines of Ring plus ~180K of Zig, not
the 746K this study had been quoting. The mechanism is now identified: the
`archive/` directories hold **monolithic** predecessors —
`stzString_monolithic.ring` alone is 104,671 lines, 202,205 across all of
them. Counting those roughly tripled the estate. Excluding them gives
267,791 in `base/`, consistent with his figure. Everything the study priced
against 746K — migration cost, "keeps the estate" — was pessimistic by that
factor, which moves the numbers in the redesign's favour.

**A new grammar finding, reproducible in three lines.** Inside a class
method, `return obj.Method()` **splits**: the tree gets a bare
`return_statement` and an orphaned sibling `expression_statement` holding
the call. In a plain `func` the identical expression parses correctly.

```
func Get(oS)      -> return_statement > member_expression      correct
class C / def Get -> return_statement (bare) + expression_statement   split
```

It is not the `@` prefix — an unprefixed attribute splits the same way. A
compiler consuming this grammar for class methods would silently emit a
method that returns nothing, so the object-model work has to handle it from
the first line. It is also worth checking against `ringpp check`, where a
method whose return is invisible could skew a real rule.

**Verdict against the kill criterion.** The criterion was: *if the friction
says the checked subset is a different language in disguise, stop.* It does
not. Nothing on the missing list is a semantic mismatch — the value model,
copy-on-write semantics and control flow already agree with Ring exactly,
which the nested-alias test proved by reproducing Ring's deep-copy answer
of 0. What is missing is the **object model**, and every item is a bounded,
conventional feature.

But it is not a small piece of work either, and the honest framing is that
**friction per KLOC is not yet measurable**: the port is blocked on a layer
that does not exist, not on semantic surprises. What this pass converted is
the question — from "port a module and count the friction" to "build the
object model, then count it", with the prerequisite sized: class definition
with attribute slots, single inheritance, method dispatch, `This`, `new` +
`init`, member-expression codegen, string literals with their builtins, and
the `+` append operator.

### Step 4: the object model is built, and 65% of real Softanza compiles

The gate said the port was blocked on a layer that did not exist. It exists
now, and the friction is measured rather than estimated.

**What was built.** Objects are a class id plus a flat slot array. `@oString`
resolves to a slot INDEX at compile time — Ring stores an object as a list of
attribute lists and looks the name up at runtime, which is the same wound as
D1 one level up. Methods are ordinary functions whose register 0 is the
receiver. Dispatch is a dense `(class x name)` table, one indexed load, with
inheritance resolved once at compile time rather than walked at every call.
`new` allocates and runs `init` — including an **inherited** `init`, which a
subclass that adds no constructor still needs or every attribute stays nil.
Plus string constants, list literals with elements, `isString`/`isObject`,
`StzRaise`, and Ring's `+` list-append operator.

**Verified against Ring, not against expectations.** A class with attributes,
methods, `This`, `new`, inheritance and an override:

```
                     Ring 1.27   Ring-Next
  UseCounter            155         155
  UseSeen                10          10
  UseInherit            210         210     <- override reached
  UseInheritSeen         10          10     <- inherited init ran
```

**Two more grammar traps, both the same shape as before.** A second `class`
nests INSIDE the first, exactly as a second `func` does — Ring has no `end
class` either, so classes are collected by walking, and members stop at the
next class. And a method's statements leak out to class level after the
first one, so method bodies are reconstructed by position too. Inside a
method `return <expr>` splits into a bare `return` plus an orphaned
expression statement; those are rejoined, or every method silently returns
nothing.

**A self-inflicted bug worth recording.** A line-numbered patch rewrote
`return Error.Unsupported;` *inside the error reporter itself*, so `nope()`
called `nope()` forever and every refusal became a stack overflow with no
message. The text matched; the location did not. Mechanical edits need to
check where they land, not only what they replace.

#### The friction, measured

`rnxc census <file>` compiles for measurement: it records every refusal and
tries the next statement anyway, so one pass produces the whole catalogue.
Twelve real modules from `stzlib/base`:

| module | statements | compiled |
|---|---:|---:|
| stzStringSections | 46 | **89%** |
| stzStringWalker | 49 | **87%** |
| stzComplex | 62 | 75% |
| stzStringTrimmer | 83 | 74% |
| stzCounter | 38 | 71% |
| stzWordStream | 44 | 70% |
| stzStateMachine | 52 | 67% |
| stzStringCaseChanger | 58 | 55% |
| stzStringDuplicates | 67 | 55% |
| stzBytes | 50 | 52% |
| stzCache | 67 | 43% |
| stzValidator | 31 | 41% |
| **total** | **647** | **423 (65%)** |

**And what the 224 refusals are:**

| kind | count | what it actually is |
|---|---:|---|
| `call_expression` | 167 | `StzUpper`, `StzEngineStringTrim`, `TransformListToString`, `classname` — **functions in other files**, plus Ring builtins |
| `identifier` | 22 | mostly undeclared `@attributes` |
| `qualified_identifier` | 16 | `new stzString(...)` — **classes in other files** |
| `binary_expression` | 8 | operators not yet handled |
| `switch_statement` | 4 | a real missing statement form |
| other | 7 | unary, symbol, assignment shapes |

**Three quarters of the friction is unresolved names, not language
semantics.** 167 calls plus 16 classes is 183 of 224 — and they are almost
all *cross-file*: Softanza is a library, so every module calls its siblings.
The 65% is the single-file, no-linker number. Ring's `load` graph is
precisely what `ringpp`'s own `project.zig` already models, closures and all,
so this is a known piece of work rather than an unknown one.

The genuinely language-level gaps left are small and nameable: `switch`, a
few operator forms, and the interesting one below.

#### The one thing that is not a missing feature

`stzStringWalker` assigns `@char` and `@position` — **attributes its class
never declares** — immediately before calling `eval(_cCode_)` on a caller's
code string. That is a dynamic extension point: the attributes exist so the
evaluated snippet can see them. A static slot model cannot express it, and
neither can any amount of added syntax.

It is also exactly the construct `ringpp check` already treats as a
universe-breaker: a file using `eval` silences the absence rules for the
whole set. The checker and the compiler reach the same conclusion from
opposite directions, which is reassuring about both.

#### Verdict

The kill criterion — *is the checked subset a different language in
disguise?* — still answers no, and now with a number behind it: **65% of
real library code compiles unmodified**, the remaining friction is
dominated by linking rather than by semantics, and every module that was
tested produced correct answers for the parts that compiled.

What this does NOT establish: that the compiled 65% is FAST (only
correctness was checked here), that the cross-file work is cheap merely
because it is known, or that `eval`-shaped dynamism is rare. The last one
matters most for Stage 3 and is a straightforward next measurement — count
`eval` across the library rather than guessing from one module.

### Step (b): the object model measured — and the order had to flip

**The speed measurement on shipping modules is blocked by the linking work.**
Softanza classes are not independently constructible: `stzCounter`'s `init`
calls `IsHashList`, `stzStringWalker`'s calls `new stzString`, `stzComplex`
needs doubles. Every candidate that compiles well enough to time needs a
sibling to *construct*. So (b) on real modules requires (a), and the order
recommended in the last memo was wrong. Said here rather than quietly
reordered.

What can be measured now is the object model itself, on a class exercising
attributes, method dispatch, `This`, `new`, inheritance and an override —
200,000 iterations, ~400,000 method calls, identical answers in both
runtimes:

| | Ring 1.27 | Ring-Next | speedup |
|---|---:|---:|---:|
| UseCounter (attributes + dispatch) | 144 ms | 12.22 | **11.8×** |
| UseInherit (override + inherited init) | 151 ms | 11.58 | **13.0×** |

That is the slot model against Ring's attribute-list lookup, and dense
`(class × name)` dispatch against Ring's runtime method search.

#### The measurement that was wrong, and how it was caught

The first run of this benchmark reported **19.7×** for `UseInherit` — and it
was false. `Doubler.Bump` was consistently 1.75× faster than `Counter.Bump`
despite doing strictly more arithmetic, which is not a thing that happens.
The disassembly said why: `frame=12, mask=0xfff` against `frame=5,
mask=0x1f`, and `ret=unknown`. **Doubler's `return This.Value()` had never
been compiled.** It was faster because it was doing less, and the answer
stayed correct only because that return value is discarded at the call site.

The cause was the grammar again, in a shape neither earlier fix covered: for
the last method of a **nested** class, the orphaned statements land back in
the *enclosing* class, after the nested class node. Three ad-hoc sibling
scans had each missed a different arrangement.

**The fix is the general one, and it should have been first.** Headers
(`func`, `def`, `class`) and loose statements are now gathered into a single
list ordered by source byte, and each statement is given to the header that
most recently preceded it. That is Ring's own rule — F-21 states it — and it
is the only rule this grammar respects. It replaced all three scans, every
gate still passes, and both `Bump` methods now compile to identical shapes
and identical times.

The census is unchanged by it: **635 statements, 411 compiled (64%)**,
against 65% before, so the positional collector costs no coverage.

**The lesson is the one this file keeps re-learning**: a number that is too
good gets checked, and the check is the disassembly, not the reasoning. Four
times now — core placement, code layout, semantics, and a missing return —
a plausible result has been wrong for a reason no amount of repetition
would have exposed.

### Step (a): the load graph — and 88% of the whole base layer compiles

The single-file census said 64%, and said the missing 36% was mostly
cross-file names. That prediction is now tested rather than argued.

**What was built.** `rnxc` follows Ring's `load` graph: a relative load
resolves against the directory of the file that *contains* it, and `load` is
treated as the compile-time directive it is — every load encountered is
pulled in, whatever branch it sits in. One deliberate difference from Ring,
stated rather than hidden: Ring keys its already-loaded set on the literal
path *text*, so the same file reached by two spellings is loaded twice and
dies with C22; here the key is the resolved path, which cannot double-load.
That is stricter than Ring, and no library should depend on the difference.

**The result, on `base/stzBase.ring` — the aggregator with 471 loads:**

```
files loaded          587
classes               575
methods + functions  43,139
statements         16,894:  15,014 compiled (88%), 1,880 refused   <- WITHDRAWN
                                             in 4.2 seconds
```

**WITHDRAWN — see the correction below: the traversal was truncated and the real figure is 81% over 95,067 statements.** 64% → 88% once the library is linked, which is what the earlier census
predicted and the reason the order had to flip. Only 5 `qualified_identifier`
refusals remain across 587 files, against 16 in twelve unlinked files: class
references resolve now.

A note on the metric, because it is easy to over-read. A "statement" here is
an *outermost* statement of a function; a failure anywhere inside a nested
`if` or loop fails the whole enclosing statement. The count is therefore
conservative — 88% means 88% of top-level statements compiled *with
everything nested inside them*, not 88% of lines.

**What the remaining 1,880 refusals are:**

| kind | count | what it is |
|---|---:|---|
| `call_expression` | 711 | Ring builtins and the `StzEngine*` Zig bridge |
| `binary_expression` | 435 | `and`/`or` used as *values*, not conditions |
| `identifier` | 389 | undeclared names — globals and dynamic attributes |
| `symbol` | 249 | Ring's `:Symbol` literals |
| `switch_statement` | 31 | a real missing statement form |
| `assignment_expression` | 23 | assignment shapes not handled |
| `hash_pair` | 18 | `[:Units = x]` hash literals |
| `qualified_identifier` | 5 | classes still unresolved |

That is now a **language feature list, not an architecture problem**:
symbols, hash literals, `switch`, boolean expressions as values, and a
builtin library. Every one is conventional work of known shape. The two
files that could not be read are noted in the output rather than swallowed.

**What this does not show.** That the compiled 88% *runs* — the census
compiles for measurement and skips what it cannot take, so a function with a
refused statement is counted as refused but its neighbours are not proven
executable. Running real modules needs a lenient compile that marks such
functions unusable rather than silently emitting a wrong body, which is the
honest next step and is deliberately not claimed here.

### The lenient compile — and a correction to the 88%

**First, the correction.** The previous section reported "16,894 statements,
88% compiled". That number was measured on a **truncated traversal**: a
float literal raised `BadNumber`, which was not an `Unsupported` refusal and
so aborted the whole compile part-way through the library. Everything after
the abort was never counted. With unrepresentable literals turned into
ordinary refusals, the full traversal says:

```
files loaded          587
classes               575
methods + functions  43,139
statements         95,067:  77,435 compiled (81%), 17,632 refused
```

**81%, not 88%**, over 5.6× more statements. The earlier figure is
withdrawn. That is the fifth time in this study a pleasing number turned out
to be measuring less than it claimed, and the fifth time the check was
mechanical rather than intuitive.

**What was built.** A lenient compile: a statement that cannot be compiled
marks its function **poisoned** and the rest of the library still compiles.
A poisoned function is *refused at call time* rather than run, because its
body is incomplete and running it would produce a wrong answer silently —
the one outcome worse than a missing feature. Poison spreads to callers,
since a wrong answer one frame up is still a wrong answer:

```
Good   -> runs
Bad    -> UNUSABLE: part of its body did not compile
Caller -> UNUSABLE (it calls Bad)
```

**The usability number, which is the honest one for "can you run it":**

| | count | share |
|---|---:|---:|
| functions + methods | 43,139 | |
| **usable** (own body compiles, calls nothing broken) | **7,231** | **16%** |
| unusable — own body failed | 11,021 | 26% |
| unusable — poisoned by an edge | 24,887 | 58% |
| *…of which, from the conservative dispatch rule* | *17,463* | |

**74% of functions compile their own body. Only 16% are callable.** The gap
is dominated by poison propagation, and half of that propagation comes from
one deliberately pessimistic rule: a method call's receiver class is a
runtime fact, so if *any* method of that name is poisoned anywhere in 43,139
functions, every caller of `.Name()` is poisoned too. In a library where
`Content()`, `Copy()` and `Size()` are defined on dozens of classes, that
spreads very far.

That rule is pessimistic on purpose — a refusal costs less than a wrong
answer — but it means **16% is a floor, not a ceiling**. Receiver-class
inference would recover most of the 17,463, and receiver-class inference is
the same §4.9 lever that paid for the memory model and the specialisation.

**And the honest consequence: the speed number on shipping code still
cannot be taken.** Not because compilation fails, but because the callable
set is dominated by trivial functions — `SetTempNumber`, `SetCheckParamTo`
— since anything substantial calls something that does not yet compile.
Measuring those would say nothing about Softanza's speed. The claim
"Ring-Next runs real library code N× faster" is **not** available from this
work, and no arrangement of these numbers produces it.

**What the remaining 17,632 refusals are** (full traversal):

| kind | count | what it is |
|---|---:|---|
| `call_expression` | 6,480 | Ring builtins and the `StzEngine*` bridge |
| `symbol` | 3,732 | Ring's `:Symbol` literals |
| `binary_expression` | 2,428 | `and`/`or` as values |
| `identifier` | 2,323 | undeclared names |
| `hash_pair` | 550 | `[:Units = x]` |
| `see_statement` | 349 | `? expr` output |
| `assignment_expression` | 273 | assignment shapes |
| `loop_statement` | 247 | `loop` (continue) |

Still a feature list, still conventional — but it is a longer list than the
truncated census suggested, and `symbol` alone is 3,732 sites.

### What the milestone does NOT show

The subset is real and the restrictions are named in `bench/kernels.ring`:
integers only, `add()` rather than the `+` append operator, no nested path
assignment, no classes, no strings beyond `len`/`ascii(s[i])`, no printing
(the driver calls the functions and prints). ~~Speed was not measured.~~
Measured above, after step 1.

## What flatters the spike — read before quoting any number

1. **Lua 5.1 was a provisional stand-in; superseded above by the definitive
   5.4 and Luau gates.** Kept in the table for the record, not as evidence.
2. **bytescan is a designed advantage, not a discovery**: the spike indexes
   bytes with an opcode because Ring's `s[i]` is an operator; Lua's
   `string.byte` is a stdlib *call* resolved and invoked per iteration. That
   row measures a language-design difference on purpose, as F-39 discussed.
3. ~~**The spike has no GC.**~~ **PRICED, then REPAID, 2026-08-29.** Naive
   refcounting cost 21–72% on x64 and 102–154% on ARM even on rows that
   allocate nothing; typed registers and deferred counting bring that to
   0–29%, with peak RSS of 14.7 MB (eager) or 24.6 MB (deferred) against
   66.9 MB for the build that never frees. See the two sections above.
   Every number in the tables below is still from the **arena** build —
   quote `rnx-defer` or `rnx-mi-rc-typed` as the language's, not these.
4. **The spike's VM carries nothing else**: no metatables, no coroutines, no
   debug hooks, no error unwinding in the hot path. Lua's dispatch carries
   all of these. A full runtime typically gives back 20–50% of a spike's
   margin; the margin here survives that haircut on every row.
5. **Hand register allocation.** A real single-pass compiler lands close to
   this but not exactly on it.

## What the numbers already establish

- The 9–16× Ring-to-Lua interpreter gap (F-39) is **architecture, not
  effort**: same machine, same algorithms, same dynamic typing with runtime
  tag checks, and the register/value/vector redesign clears the whole gap
  with room to spare.
- The binsearch row is the cleanest indictment: Ring 167 ms → spike 1.07 ms
  (156×) — F-42's cursor-walk mechanism, priced end to end.
- fib exercises real CALL/RET frames (recursion depth 25, two calls per
  level), so the 14.6× over Ring covers the call convention too, not just
  loops. Ring's per-call scope List allocation is the difference.

## Next (Stage 1 completion, then Stage 2 per the study)

1. ~~Build Lua 5.4 from source and re-run the gate.~~ **Done 2026-08-29** —
   definitive gate PASS, and Luau added as a third peer, also PASS.
2. ~~Re-run on the phone.~~ **Done 2026-08-29**, then ~~reversed~~ —
   **retracted and corrected the same day.** Pinned, the spike leads Luau
   on sieve and bytescan and ties on matmul; no row is lost.
3. ~~`simpleperf` profile of the losing rows.~~ **Done 2026-08-29** — it
   found the loss was a scheduler artifact and refuted the
   branch-misprediction hypothesis. Counters in §4 above.
4. **The remaining honest gap**: Luau's CPI beats the spike's on matmul
   (0.524 vs 0.545) and bytescan (0.431 vs 0.492) — its ARM tuning is real
   even though the spike still executes less work. Worth a `simpleperf
   record` at instruction level on matmul if that row ever needs to be
   won rather than tied; it is the only place a peer is genuinely ahead
   per-instruction on either architecture.
5. ~~Add RC + mimalloc and re-measure.~~ **Done 2026-08-29** — and it cost
   far more than caveat 3 predicted: 16–72% on x64, 45–154% on ARM, on rows
   that allocate nothing. Four of six ARM rows now lose to Luau. The gate
   still passes; the sweeping claim does not.
   ~~**Next on this thread**: implement deferred counting and/or typed
   registers.~~ **Done 2026-08-29** — both. The prediction held: fib
   recovers completely from typed registers alone, matmul needs deferred
   counting and then matches the no-RC instruction count exactly. Five of
   six rows won back against both peers. See the section above.
6. Re-run the three phone-row measurements once more in a *later session*
   before any of this is quoted outside this file, per methodology rule 2.
7. binsearch's Luau-vs-Lua5.4 inversion (desktop) is unexplained — same
   status as F-39's outliers: recorded, not theorized. Note it was measured
   on a hybrid-core CPU (Core 5 210H, 8C/12T) unpinned; rule 1 has not been
   applied to the desktop table, and should be before that row is trusted.
