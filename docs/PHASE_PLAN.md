# Ring++ — phases and gates

*A plan is not done until its gate runs.*

House rules, taken from `ringscript/docs/REPAIR_PLAN.md`:

- Every phase ends in something **runnable**, and the gate is a command
  with an expected output, not an opinion.
- One commit per phase, phase number in the message.
- **Losses are reported next to wins.** Every performance claim comes
  with the pattern it hurts, measured on the same build.
- All measurement on `D:\ring127\bin\ring.exe` (1.27.0). Never the 1.26
  install.
- Status markers in this file are updated as phases land. Nothing is
  marked done until its gate has actually been run and its output
  pasted under it.

> **This rule was broken from the first commit until 2026-08-23**, and
> the audit that found it went looking for something smaller. Four
> defects, in rising order of embarrassment:
>
> 1. the file went 13 commits without an update while the type checker
>    gained cross-file resolution, class-body resolution and two new
>    rules — so it stated the **opposite of the truth** (*"no checking
>    inside class bodies"*);
> 2. it kept routing unbuilt work to **T4**, a phase descoped further
>    down the same file;
> 3. **P3 read "not started"** while six of its seven idioms and 22 of
>    its assertions were green;
> 4. **P1 read "not started" in the very commit that shipped it** —
>    `rpp/probe.ring` and `tests/probe_smoke.ring` are both in `65b185e`.
>    The marker was never right, not once.
>
> And P1's gate *command* was `ring rpp\probe.ring`, which **prints
> nothing and exits 0**, because that file is a library. A gate that
> passes by doing nothing sat in this plan from the beginning, looking
> runnable.
>
> The failure mode is worth naming, because nothing here catches it: the
> gates run the *code*, and **no gate reads this file**. A plan cannot be
> gated by a test, only by the habit of editing it in the commit that
> invalidates it — and the direction of the errors is the tell. Three of
> the four **understated** what was built, which is the direction nobody
> checks, because a project that undersells itself never trips an alarm.
> Where a claim below has been overtaken it is corrected in place and the
> correction says so, rather than rewritten into looking prescient.

---

## The premise — settled, not a gate

Ring++ exists to remove Ring's weakness in **performant and
data-intensive work**: banking, government, consumer platforms — high
data volumes, complex processing, optimisation, ML and AI. Those are the
domains this project serves, and that settles *whether* to build it.
Nothing below waits on a workload census.

What the domains do change is **ordering**. Data-intensive and ML/AI
work is dominated by dense numeric arrays, large record streams, and
tight inner loops — which puts `RppBuffer`/`RppView` (P2) and
`RppIndexed` (P3) ahead of everything else.

**Amended 2026-08-23.** This paragraph used to put "the compiled numeric
kernels (T4)" in that same first rank, and to place `RppArray`
deliberately *after the compiler*. T4 is descoped (see *The toolchain
half* below), so there is no compiler to be after. `RppArray` is
therefore **not scheduled at all**, and the reason is the measurement
that always governed it: a packed numeric buffer is 2.2× **slower** than
a Ring list until the loop around it is native ([F-15](FINDINGS.md)).
Without a native loop it is a pessimisation with a nice name. If the
compiled half ever returns as its own proposal, `RppArray` returns with
it; until then, shipping it would be the project contradicting its own
number.

## P0 — Baselines *(one afternoon, not a permission gate)*

Pick the shapes to optimise and record what they cost today, so every
later phase has something to be measured against.

Three shapes, chosen from the target domains rather than from a code
audit — each already has a measured stand-in in `bench/`:

| shape | stand-in | today |
|---|---|---|
| a large record stream sliced field by field | F-6, `bench/08` | 12.5 µs per slice of a 500 KB payload |
| a dense numeric kernel (scoring, optimisation, ML inner loop) | K2, `bench/headroom` | 92 ms per 1 M-element dot product |
| a wide table read out of order (reporting, reconciliation) | F-9, `bench/03` | 1562 ms per 80 K permuted reads |

**Gate.** `docs/BASELINES.md` exists and records, for each of the three,
a representative size from real usage and the current time on Ring 1.27.
Where a production size is not to hand, use a stated estimate and mark
it as such — an estimate that is written down can be corrected; an
unstated one cannot.

That is the whole of P0. **P1 and T1 may start immediately, in
parallel** — neither depends on it.

*Status: not started.*

---

## P1 — The probe suite

`rpp/probe.ring`, standalone, no dependencies. One row per name in the
declared compatibility surface ([DESIGN.md §5](DESIGN.md#5-surviving-ring-128-and-135)),
each asserting a *behaviour*, not a presence:

- write through `varptr` + `memcpy`, read the bytes back;
- the address from `varptr` is stable across a read of the variable;
- `ringvm_genarray` speeds up a permuted read, and one `+` slows it
  again;
- every packing pair round-trips; endianness recorded;
- a sub-state runs, returns a lower-cased variable, and deletes;
- a Ring error inside a sub-state does not kill the host.

Each row carries its degradation policy (HARD / SOFT / INFO).

**Gate.**

```bash
cd tests && D:\ring127\bin\ring.exe probe_smoke.ring
```

prints one line per row, ends with `PROBE OK — n rows on this Ring`, and
exits 0. Then deliberately break one row (rename a probe's target to a
name that does not exist) and confirm it exits non-zero and names the
row.

*Status (corrected 2026-08-23 — it read **"not started"**): **built and
green.** 9 rows, exit 0, 0.10 s. Run as `P1 probe` in the suite.*

**Two corrections to the gate as written**, both found by running it:

- the command was `ring rpp\probe.ring`, which **prints nothing and
  exits 0**. `rpp/probe.ring` is a library — it defines the rows, it does
  not run them. A gate that passes by producing no output is the worst
  kind, and this one had been sitting in the plan looking runnable. The
  runner is `tests/probe_smoke.ring`, and it must run **from `tests/`**
  because it loads `../ringpp.ring`;
- the expected string was `PROBE: n/n OK on Ring 1.27.0`; the probe
  actually prints `PROBE OK — n rows on this Ring`. The suite matches on
  `PROBE OK`, so the gate was real — only its description here was
  wrong.

---

## P2 — `RppBuffer` and `RppView`

The core, and only the core: `RppBuffer(n)`, `Poke`, `Peek`, `View`,
`Str`, `Grow`, `Len`, `Capacity`, plus `RppView` with `Peek`, `Byte`,
`Sub`. Every entry point bounds-checked in Ring before the primitive.
The `…Unchecked` variants exist and are named.

The invariant to hold, and to test: **the backing string is created once
and never reassigned**; `Grow` allocates a new one, copies, and re-caches
the address.

**Gate — three parts, all required.**

1. *Correctness.* `tests/buffer.ring` — round-trip every `Poke`/`Peek`
   pair, at offset 0, at the last legal offset, across a `Grow`, and
   through a `View` of a `View`. Byte-compare against the equivalent
   pure-Ring construction. Prints `n passed, 0 failed`.

2. *Safety fuzz.* `tests/fuzz_bounds.ring` — 100,000 random
   `(offset, length)` pairs, most of them illegal, against buffers of
   random sizes. **Expected: 0 crashes, every illegal pair raising a
   catchable `Rpp:` error with the three numbers in it.** The process
   must exit 0. This is the gate that R3 lives or dies on.

3. *Performance, both directions.* — **DONE, with the gate corrected.**

**Measured** ([`tests/bench_buffer.ring`](../tests/bench_buffer.ring)),
50,000 eight-byte patches at scattered offsets in 500 KB:

| | ms |
|---|---:|
| pure Ring rebuild | 7981 |
| **`RppBuffer.Poke`** | **78** — *102× faster* |
| raw `memcpy` through a cached pointer | 13 |

**The "within 2× of raw memcpy" gate was unachievable as written, and
the reason is worth more than the gate.** I measured the API shape
itself before blaming the implementation:

| | ns/call |
|---|---:|
| empty loop iteration | 20 |
| plain function call | 140 |
| **method call, doing nothing** | **340** |
| method + 3 attribute reads | 400 |
| raw `setptr` + `memcpy` | 280 |

**A Ring method call costs more than the entire raw operation it would
wrap.** Any object-based buffer API therefore starts at ~1.4× before
executing a single useful instruction, and `Poke`'s own work — `len`,
`setptr`, a leading-byte test, `memcpy` — lands it at **6×**.

Optimisation went as far as it usefully could: the source is handed to
`memcpy` directly unless it is one of the two shapes that trigger F-14
(saving a `varptr` at 790 ns and a `nullptr` at 520 ns per call), the
range guard is inlined so `CheckRange` is entered only to raise,
`isstring` is off the hot path, and the `RPP_NUL_BYTE` global is cached
as an attribute. That took 6.07× to 6.0× — i.e. nothing. The floor is
the method call.

**Corrected gate, and the guidance that follows from it:** `Poke` must
stay within **8×** of raw `memcpy` *and* beat pure Ring by **≥50×** on
the patch case. Both hold (6×, 102×). A hot inner loop that genuinely
needs the raw 280 ns has `AddressUnchecked()` — which is precisely why
that escape hatch exists, and it is now documented as the answer rather
than an embarrassment.

4. *The append loss, reported.* Building 1 MB, `RppBuffer.Poke` versus
   `+=`: concat wins at every chunk size up to 4 KB and only loses at
   64 KB. **`RPP_APPEND_CROSSOVER = 512` is the crossover for *raw*
   `memcpy` (F-8), not for the checked API** — through `Poke` the
   crossover is roughly two orders of magnitude higher. The benchmark
   prints `CONCAT WINS - use +=` on every row where it does, and the
   constant needs renaming to say which of the two it describes.

*Status: done — see `tests/buffer.ring` (30/30), `tests/fuzz_bounds.ring`
(0 crashes, 0 silent holes), `tests/bench_buffer.ring`.*

---

## P3 — The idioms, and the first real workload

`RppIndexed` (with the break-even refusal and the staleness warning),
`RppRows`, `RppSandbox`, `RppSyntaxOk`, `RppTokens`, `RppAdvise`,
`RppReport`.

Then take **workload #1 from P0** and rewrite its hot path in Ring++,
in place, in the real application.

**Gate.**

1. `RppIndexed` on a 40-item list refuses and says why. `RppIndexed` on
   an 80,000-item list reproduces the ~95× from
   [`bench/03_lists.ring`](../bench/03_lists.ring). A list mutated
   between `RppIndexed` and `Release` produces a warning naming the
   list's size change — and the documentation states plainly that
   `sort()` and `reverse()` are **not** detected (verified: they
   invalidate the array without changing `len()`).
2. `RppSandbox` runs `? 1/0` without killing the host, and
   `RppSyntaxOk("x = 'unterminated")` returns false.
3. The real workload: **before and after timings from the production
   data size**, in `docs/WORKLOADS.md`, plus a byte-identical output
   check against the old path. If the speedup is under 2×, say so and
   keep the old code.

*Status (corrected 2026-08-23 — it read **"not started"**, which was
wrong in the direction people do not check for): **gate parts 1 and 2 are
built and green**, gate part 3 is not started.*

All seven idioms exist — six in [`rpp/idioms.ring`](../rpp/idioms.ring),
with `RppReport` in [`rpp/probe.ring`](../rpp/probe.ring) because it
reports the probe's own rows — and are gated by 22 assertions in
[`tests/idioms.ring`](../tests/idioms.ring), run as `P3 idioms` in the
suite. **Three deviations from the gate as
written above**, recorded because a gate quietly run differently is a
gate not run:

- the break-even case uses a **60,000**-item list, not 80,000;
- it asserts **≥20×** on the permuted read rather than reproducing the
  ~95× — a floor is stable across machines in a way a point figure is
  not, and this gate has to pass on a laptop that is also compiling;
- staleness surfaces as **`Release` returning FALSE plus advice**, not
  as a warning naming the size change. The `sort()`/`reverse()` caveat
  the plan demands *is* asserted by name.

**What is left is part 3, and it is the honest gap.** No hot path in a
real application has been rewritten in Ring++ and measured at production
size. [`bench/workload/`](../bench/workload/README.md) records the
attempt: it got as far as finding that the target module could not be
driven through its own API — three defects, listed there — and step (c)
says plainly that it has not been started. Until part 3 lands, every
performance claim this project makes is a **benchmark** claim, not a
production one. That distinction is the reason this status was worth
correcting rather than rounding up.

---

## P4 — The upgrade matrix

`build.zig` compiles the Ring VM from source, one binary per version
under test (1.26, 1.27, and whatever is current), Zig the only
dependency. `zig build conformance` runs `probe.ring` and the whole of
`bench/` against each.

This is also where the provisional constants get settled: the 512-byte
crossover and the ~20-reads break-even are one machine's numbers (R6).
Re-measure on Linux and on RingScript's WASM build; if they move, they
become probe-derived at load time instead of hard-coded.

**The matrix has two axes, not one.** A Ring axis (1.26, 1.27, current)
and a **Zig axis** (0.15.2, 0.16, current), because upstream is moving:
Zig 0.16 already defaults Debug builds to the self-hosted x86_64
backend, and there is a live proposal to move `zig cc` out of the `zig`
binary entirely along with LLVM
([DESIGN_TOOLCHAIN §7](DESIGN_TOOLCHAIN.md#what-zig-016-changes--and-what-it-does-not)).
Ring++ must find out from a matrix cell, not from a user.

**Gate.**

```bash
zig build conformance
```

prints a matrix — one row per Ring version, one column per probe row —
green on 1.27 and on at least one other version, with any red cell
naming the row and its degradation policy. The `bench/` numbers for each
version are written to `docs/MATRIX.md`, including the ones that got
worse. `bench/toolchain/` is re-run per Zig version, and the
`-O0`/`-O1`/`-O2` table is refreshed — the tier boundaries in
DESIGN_TOOLCHAIN §7 are derived from it and must not go stale.

*Status: **built and green**, [`docs/MATRIX.md`](MATRIX.md), one axis
short of the plan.*

What was built: `src/conformance.zig` + a `conformance` step. It
discovers each tree's `.c` files **at run time** (a hardcoded list would
go stale between Ring versions, which is the exact failure this step
exists to catch), builds a `ring` per row with `zig cc -O2`, runs the
gates against each, writes the matrix, and exits non-zero on a red cell.
A failed build now prints the compiler's own first diagnostic instead of
a bare `BUILD FAILED` — verified by removing a required source and
watching it name `undefined symbol: rs_objcache_new`.

Current rows: **1.27.0 stock** and **1.27.0 + RingScript's 8 vendor
patches**, 5/5 each. The second is not a free row — its `rlist.c` patch
calls into RingScript's own bridge, so the tree cannot link a CLI
without `rs_oop.c`. That coupling is worth knowing and is recorded in
the row's note.

**It paid for itself on the first two-row run** by failing `idioms` on
the *patched* VM: RingScript's `rlist.c` already generates the items
array on random access, so `RppIndexed` had nothing to buy (467 ms
baseline stock, 4 ms there). The gate asserted a mechanism where it
should have asserted an outcome, and only a second VM could say so.
FINDINGS **F-23**.

Still owed against the plan above, none of it blocking:

- a **second Ring version** — both rows are 1.27.0, so the Ring axis is
  a patch axis today, not a version axis;
- the **Zig axis** — one toolchain (0.15.2); 0.16 is no longer on this
  machine and re-downloading it is a deliberate call, not a default;
- **re-deriving the provisional constants** (512-byte crossover,
  ~20-read break-even) per row, and refreshing the `bench/toolchain/`
  `-O0`/`-O1`/`-O2` table that DESIGN_TOOLCHAIN §7's tier boundaries
  rest on.

---

## P5 *(conditional)* — the optional accelerator

**Only if a P3 or P4 measurement identifies a specific loop the pure-Ring
implementation cannot reach.** Not before. `build.zig` cross-compiles one
small extension exporting a handful of `RING_API` functions; Ring++
`loadlib`s it when present and falls back to the pure path when absent.

**Gate.** Every `tests/` and `bench/` result identical with the
extension present and absent — only faster. If any output differs, the
extension is wrong, not the pure path. Plus: the exact loop that
justified it, with the pure-Ring number and the extension number side by
side.

*Status: conditional, not started.*

---

## P6 *(conditional)* — Softanza adoption

Reimplement `stkBuffer.Write` and `stkPointer` on `RppBuffer`.

**Gate.** Softanza's own memory-framework tests pass unchanged, and the
`stkBuffer.Write` benchmark drops from the 803 ms shape (F-7) to the
in-place shape. Also: `stkPointer.InitializeLowLevelAccess` either works
or is deleted — it must not go on silently returning `NULL`.

*Status: conditional, not started.*

---

---

## The toolchain half

> **Reframed by Mansour, 2026-08-23.** The product is the library plus
> **one shipped binary** — type safety and static analysis, no compilation
> story, no C compiler ever suggested to a user. **T3–T7 are descoped to a
> research annex**: the designs and headroom measurements stay
> (`DESIGN_TOOLCHAIN.md`, `bench/headroom/`), and if a compiled half ever
> returns it returns as its own proposal with its own gates. T1 and T2 —
> which carried most of the value and are **built** — are the whole
> toolchain promise now, delivered as `bin/<platform>/ringpp`.

Phases **T1–T7** live in
[DESIGN_TOOLCHAIN.md §10](DESIGN_TOOLCHAIN.md#10-phases-and-gates--the-toolchain-half).

| | | status |
|---|---|---|
| **T1** | `ringpp check` — the FINDINGS rules as lint | **built, gated, shipped** |
| **T2** | type checking and `ringpp why` — level 1, then **across the load graph and inside class bodies** | **built, gated, shipped** |
| **T3–T7** | vendored VM, compiled kernels, cross-builds, cache | *research annex — descoped 2026-08-23* |

The shipped artefact is five prebuilt binaries — Windows, Linux x64 and
arm64, macOS x64 and arm64 ([`bin/README.md`](../bin/README.md), which
records how far each one is verified) — carrying `tree-sitter-ring`
**v1.1.1**, whose one open defect against this project was fixed
upstream and re-measured ([`upstream/`](../upstream/README.md)).

### T2 — `ringpp why`: *status*

**The diagnostic half is built and gated** ([`src/why.zig`](../src/why.zig),
`ringpp why`, gate `T2 why gate` in `tests/run-all.ps1`).

A catalog of **21 entries** — the **16 rules** `check` can emit (9 lint +
7 type), plus 5 traps a linter cannot see (F-18, F-20, F-21, F-22, F-23)
— each with a symptom,
a cause, a fix, the bench program that produces its numbers, the pattern
the fix makes worse, and its upstream state. Reachable three ways: by
rule, by finding id, and **by the Ring error code the user actually
saw** (`R4`, `R6`, `R20`, `C27`). That last route is the one that earns
the command; a code names no cause, and each of those cost a day here.

Two compile-time tests are what make the catalog trustworthy rather than
decorative, and both were verified by breaking them on purpose:

- every `rpp/…` rule string in `check.zig` must have an entry — the ids
  are scanned out of the source at comptime, so a new rule with no
  explanation fails the build;
- every `F-n` cited must exist as a heading in `FINDINGS.md` —
  `docs/FINDINGS.md` is handed to the module in `build.zig` for this.

### T2 — level 1 type checking: *built, then deepened*

[`src/types.zig`](../src/types.zig) + [`src/project.zig`](../src/project.zig),
**seven rules**, gated by `T2 type gate` and `T2 xfile gate`.

Measuring Ring before writing it corrected the design. **A Ring type
annotation is two mechanisms sharing one syntax** ([FINDINGS
F-24](FINDINGS.md)): the parameter types are a parser feature that costs
nothing and needs nothing, while `int func Sum(...)` is an ordinary
expression reading a global that only `typehints.ring` defines —
`Error (R24)` without it, and `load "stdlib.ring"` does not supply it.

| rule | severity | why it is sound |
|---|---|---|
| `rpp/type-hints-missing` | error | R24 is certain; a note instead when another file in the run loads the library |
| `rpp/type-arity` | error | Ring enforces arity exactly — R19 too few, R20 too many, no defaults, no overloads |
| `rpp/type-arg-mismatch` | warn | a *literal* contradicting the annotation; Ring runs it and concatenates |
| `rpp/type-return-mismatch` | warn | a returned *literal* contradicting the return annotation |
| `rpp/type-not-a-hint` | note | a fixed near-miss list only (`bool` → `boolean`) |
| `rpp/type-duplicate-func` | error | two definitions of one name in a load graph is `C22` **at load**; the program never starts ([F-26](FINDINGS.md)) |
| `rpp/type-declared-conflict` | note | the same name defined differently in files that never meet — a refusal, not a finding |

**What it found on its first real run.** 99 arity call sites in 46
distinct functions across Softanza's 5,949 files, plus one in Ring's own
1,959 — all dormant R19/R20 crashes, the dominant shape being an alias
that forgot to forward its parameter. One was confirmed by running it:
`@IsContinuous()` raises R19 at `stzListFunc.ring:7574`, exactly as
predicted.

**And one false positive, which shaped the design.** Ring's one-line
class form puts an attribute where a return annotation goes —
`Class Point x y z func print` — so the first version reported R24 on
correct code in Ring's own samples. Two structural guards fixed it, at
the cost of no longer seeing a class name used as a return type. After
them, Ring's corpus yields exactly one type finding and it is real.

### T2 — deepened: across files, and inside classes

*Three commits after the section above was written, and it invalidated
two of its sentences. Both are corrected here rather than quietly edited
away.*

**Across files** ([`src/project.zig`](../src/project.zig), commit
`3275e27`). A call in one file is now checked against a definition in
another, through the **load graph**. It is sound rather than heuristic
because Ring makes it so: a duplicate function name is `C22` at *load*
time and the program never starts ([F-26](FINDINGS.md)), so within one
graph a resolving name has exactly **one** live definition. Where that
certainty is unavailable the checker refuses and says so — an unknown
parent class, a name with two definitions, a file that did not parse.

**Inside class bodies** (commit `e1ed273`). The sentence above — *"no
checking inside class bodies"* — **is no longer true.** Calls in a class
body are now resolved in Ring's own measured order: own method →
inherited → global → builtin, with arity enforced at every step
([F-27](FINDINGS.md)). What made it safe was measuring the order first;
what makes it honest is that resolution stops and reports nothing when a
parent class is not visible.

**What the deepened checker found** *(a different run from the level-1
one above, and a different rule set — the two counts are not in
conflict)*. Ring's own 1,959 files → **3 errors, all real, zero
false positives** — including `encrypt_ex`/`decrypt_ex` in the shipped
standard library, which have never worked. Softanza's 6,012 → 99 arity
findings, of which **97 are in dead archives**; saying that mattered more
than the count. Two live shadowing bugs were found and fixed. The whole
run is written up in [CASE-TYPE-SAFETY.md](CASE-TYPE-SAFETY.md), *with
the three false positives it produced and what they cost*.

**The three false positives are the reason this section exists.** Each
was a Ring scoping rule the checker did not know, and **not one would
have been caught by a test written from imagination** — all three came
from running real corpora: brace blocks run in object scope; a call
invented by error-recovery inside a file that did not parse; and Ring's
`call` keyword invoking a function held in a variable. The second was a
*broken promise* — `rpp/unparsed` says no rules were applied, while the
cross-file layer was applying them anyway (fixed in `0277f10`, at the
knowing cost of discarding 12 genuine duplicates in a file that cannot
run).

The rules still give up coverage on purpose in two places, each recorded
at the site: no functions registered after the first class (they are
methods, [F-21](FINDINGS.md)), and only literals judged for type —
anything computed is genuinely unknown in a dynamic language.

**Still open under T2:** nothing.

> **Two items are currently unowned, and that is a decision, not an
> oversight to fix silently.** Level 2 type checking (*compilable*) and
> the `ringpp why <function>` form in [CLI.md](CLI.md) were both routed
> to **T4**, which was descoped on 2026-08-23. They therefore have no
> phase. Level 2 arguably belongs with the compiled half if it ever
> returns; `ringpp why <function>` does not depend on a compiler at all
> and could be a small T2 follow-up. **Which is which is the author's
> call** — this file names them rather than reassigning them, because
> the last time it went stale it was by quietly keeping a phase that no
> longer existed. Asking for either today prints that it is not built,
> rather than reporting a typo.

---

## The build half *(proposed 2026-08-23 — B0 only is scheduled)*

> **Shipping a Ring program on any platform, with no compiler.** Design
> and measured feasibility in [DESIGN_BUILD.md](DESIGN_BUILD.md);
> the mechanism is [F-28](FINDINGS.md).

Ring already emits bytecode that runs with no C compiler
(`ring app.ring -go` → `ring app.ringo`), `load` is resolved at compile
time so the object file **carries its whole Ring-source dependency
tree**, and the runtime that executes it is `ring.exe` + `ring.dll` =
**1.3 MB**, verified in an empty directory. Ring's own `ring2exe`
meanwhile writes a `.c` file and shells out to Visual C++, GCC or Clang.
Same shape as the other two halves: **the mechanism is already in Ring
and nobody can reach it.**

### B0 — is bytecode portable across architectures?

**The one blocking unknown, and the only phase scheduled.** Every figure
in F-28 is Windows x64. If a `.ringo` written on Windows does not load on
Linux, then "build for any platform from any platform" is not a product
and the whole half shrinks to something smaller — worth knowing before
designing, not after.

**Gate.**

```bash
powershell -File tests\b0_bytecode.ps1
```

Compiles two fixtures on the host, cross-compiles a Linux x86_64-musl
Ring runtime with `zig cc` if one is not supplied (43 files, ~25 s),
runs the **same bytes** under WSL, and compares output byte for byte.
Prints `SKIP` with a named reason when no Linux runtime can be obtained.
Verified non-vacuous in both directions: it **fails** when handed a Linux
binary that is not Ring, and **skips** when the VM sources are absent.

*Status: **done, 2026-08-23** — `PASS b0 bytecode`,
[F-29](FINDINGS.md).*

**The answer is split, and the second half is the useful one.**

| | result |
|---|---|
| pure-Ring bytecode, Windows x64 → Linux x64 | **byte-identical** — ints, floats (`1/3` → `0.33` both), string case, `ascii`/`char`, loops, list indexing |
| the same plus `load "stdlib.ring"` | **fails on Linux**, `R38` on `libring_odbc.so`, while succeeding on Windows |

The failure is neither the bytecode nor stdlib: **a `loadlib` that fails
is silent on Windows and fatal on Linux.** An empty directory holding
only `ring.exe` + `ring.dll` runs the stdlib program and exits 0, so
Windows does not need the extension either — it simply does not mind its
absence.

So the constraint on any build half is now known and is sharper than
"portable or not": **the bytecode travelling is necessary and not
sufficient.** Packaging must resolve `loadlib` at build time or carry the
target's extensions, or an executable tested on Windows fails on Linux
for a library it never calls — in the user's hands, not at build time.

Also learned: the object file is **text** and says `# OBJECT 1.25` while
Ring reports 1.27.0. **The object format is versioned separately from the
language**, and it is what would silently invalidate already-packaged
programs.

**Still unmeasured: arm64.** Everything is x64→x64; the honest claim is
*"portable between x64 platforms"* and nothing wider. That is the first
thing B1 would have to close.

### B1 — `ringpp deps`: what must ship beside the program

**Scheduled and built because it is needed under every branch of the
decisions below**, and because B0 left a concrete hole: the bytecode
travels, the native libraries do not, and the failure surfaces at run
time on the user's machine rather than at build time.

It is answerable statically because of Ring's own idiom:

```ring
if iswindows()   LoadLib("ring_odbc.dll")
but ismacosx()   LoadLib("libring_odbc.dylib")
but islinux()    LoadLib("libring_odbc.so")
ok
```

**The platform branch is decided at run time; the file names are
literals.** So the complete set of native libraries a program can reach,
on every platform, is visible in the source. `ringpp deps` walks the load
closure — following into Ring's own tree when given `--ring` — collects
every `LoadLib` and `loadlibfile` literal, and collapses the three
spellings onto one row per library.

**Gate.**

```bash
powershell -File tests\run-all.ps1     # gate `b1 deps`
```

Three assertions, and the third is the one that matters:

1. a program reaching `stdlib.ring` must name **`libring_odbc.so`** — the
   exact library that killed B0's fixture on Linux;
2. a program with no `load` must be reported **PURE RING**;
3. **with no `--ring`, the loads cannot be followed, so the answer must be
   a refusal and a non-zero exit — never "pure".**

That third one is gated harder than the happy path on purpose. A
dependency report that answers *"nothing to worry about"* when it could
not look is the same defect `tests/fidelity.ps1` carried from its first
commit, and it would be worse here: it would be believed at exactly the
moment someone ships. Verified non-vacuous — removing the `load` from the
fixture fires all three.

*Status: **done, 2026-08-24**. It predicts, without running anything, the
failure B0 needed a Linux runtime to discover:*

```
    windows            macos                  linux                  declared in
    ring_odbc.dll      libring_odbc.dylib     libring_odbc.so        odbclib.ring:2
    ring_mysql.dll     libring_mysql.dylib    libring_mysql.so       mysqllib.ring:2
    ring_sqlite.dll    libring_sqlite.dylib   libring_sqlite.so      sqlitelib.ring:2
    ring_internet.dll  libring_internet.dylib libring_internet.so    internetlib.ring:2
    ring_openssl.dll   libring_openssl.dylib  libring_openssl.so     openssllib.ring:2
    ring_pgsql.dll     libring_pgsql.dylib    libring_pgsql.so       postgresqllib.ring:2
```

**Six extensions, to call `upper()`.** That is what `load "stdlib.ring"`
costs a program that wants one string function, and it is the strongest
argument yet for a `deps` command existing at all — no one would guess it.

Two limits, both recorded at the site: a `loadlib` whose argument is
computed is reported as **unresolved rather than guessed at**, and a
library whose real name begins with `lib` lands in two rows instead of
one (`src/deps.zig`, the test named `KNOWN GAP`). Neither bites on Ring
today; both are stated rather than discovered later.

### B2–Bn — not scheduled, and deliberately so

Three decisions are the author's and are not derivable from any
measurement ([DESIGN_BUILD.md §6](DESIGN_BUILD.md)):

1. **Bare-metal microcontrollers are out.** A 1.2 MB VM with a GC and
   dynamic `loadlib` does not fit an ESP32. *Linux-class* embedded — a
   Raspberry Pi, a gateway — is in, and is the same work as Linux arm64.
   If the brief keeps bare metal, this half begins with a promise it
   cannot keep; MicroRing is that conversation.
2. **Cross-platform means Ring++ distributes Ring runtimes**, which is a
   commitment and arguably a governance question for Mahmoud rather than
   only a technical one.
3. **This may belong upstream.** Ring owns `ring2exe`. A compiler-free
   build path is arguably a *finding* — and the standing rule here is
   that a finding travels better than a patch.

Nothing below B0 is designed until those are answered.

---

## Standing gate: every phase re-runs `bench/`

`bench/` is the regression suite for the *assumptions*, not the code.
Any phase that changes a number in [FINDINGS.md](FINDINGS.md) must
update that file in the same commit, with the new measurement and the
build it came from.
