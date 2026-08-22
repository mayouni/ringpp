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

---

## The premise — settled, not a gate

Ring++ exists to remove Ring's weakness in **performant and
data-intensive work**: banking, government, consumer platforms — high
data volumes, complex processing, optimisation, ML and AI. Those are the
domains this project serves, and that settles *whether* to build it.
Nothing below waits on a workload census.

What the domains do change is **ordering**. Data-intensive and ML/AI
work is dominated by dense numeric arrays, large record streams, and
tight inner loops — which puts `RppBuffer`/`RppView` (P2), `RppIndexed`
(P3), and the compiled numeric kernels (T4) ahead of everything else,
and puts `RppArray` deliberately *after* the compiler, because a packed
numeric buffer is 2.2× **slower** than a Ring list until the loop around
it is native (F-15).

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
D:\ring127\bin\ring.exe rpp\probe.ring
```

prints one line per row, ends with `PROBE: n/n OK on Ring 1.27.0`, and
exits 0. Then deliberately break one row (rename a probe's target to a
name that does not exist) and confirm it exits non-zero and names the
row. Runs in under one second.

*Status: not started.*

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

*Status: not started.*

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

Phases **T1–T7** live in
[DESIGN_TOOLCHAIN.md §10](DESIGN_TOOLCHAIN.md#10-phases-and-gates--the-toolchain-half).
They run after P0–P3 and are gated by the same P0 question. In short:

| | | needs toolchain? |
|---|---|---|
| **T1** | `ringpp check` — the FINDINGS rules as lint | no |
| **T2** | level 1 type checking and `ringpp why` — **built** | no |
| **T3** | vendored VM + CLI skeleton | yes |
| **T4** | one compiled kernel, end to end | yes |
| **T5** | `ringpp build`, five targets from one host | yes |
| **T6** | compile-and-cache (the "JIT") | yes |
| **T7** | *conditional* — anything more ambitious | yes |

T1 and T2 need nothing installed and carry most of the value. **Build
those first**, whatever happens to the rest.

### T2 — `ringpp why`: *status*

**The diagnostic half is built and gated** ([`src/why.zig`](../src/why.zig),
`ringpp why`, gate `T2 why gate` in `tests/run-all.ps1`).

A catalog of 14 entries — the 9 rules `check` can emit, plus 5 traps a
linter cannot see (F-18, F-20, F-21, F-22, F-23) — each with a symptom,
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

### T2 — level 1 type checking: *built*

[`src/types.zig`](../src/types.zig), five rules, gated by `T2 type gate`.

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

The rules give up coverage in three places on purpose, each recorded at
the site: no checking inside class bodies (an unqualified call finds a
method first, F-17), no functions registered after the first class (they
are methods, F-21), and only literals judged for type (anything computed
is genuinely unknown in a dynamic language).

**Still open under T2:** nothing. Level 2 — *compilable* — is T4's, and
so is the `ringpp why <function>` form in [CLI.md](CLI.md); asking for
it today says so rather than reporting a typo.

---

## Standing gate: every phase re-runs `bench/`

`bench/` is the regression suite for the *assumptions*, not the code.
Any phase that changes a number in [FINDINGS.md](FINDINGS.md) must
update that file in the same commit, with the new measurement and the
build it came from.
