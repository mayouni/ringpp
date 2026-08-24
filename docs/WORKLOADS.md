# P3 part 3 — the real workload

*Closed 2026-08-25. This file is the gate artefact
[PHASE_PLAN.md](PHASE_PLAN.md#p3--the-idioms-and-the-first-real-workload)
requires — before/after timings at a stated size, plus a byte-identical
check against the old path. Read the note at the bottom before citing
this as "P3, done" without qualification: it does not literally rewrite
the hot path on `RppBuffer`, and the reason is itself the finding.*

## The workload

`stkBuffer.Write` in Softanza's own library
(`stzlib/libraries/stzlib/core/system/stkBuffer.ring`) — a byte buffer
overwritten repeatedly, the same shape as a record field updated in
place. Reached through `bench/workload/`, which lives in this repository;
the file it optimises is in `stzlib`, a sibling repository this project
does not edit (`CLAUDE.md`'s estate rule) — the numbers below were
re-run, not assumed, before this file was written.

**Before it could be measured it had to be reachable at all.** Eight real
defects blocked the module's own advertised API — full account in
[`bench/workload/README.md`](../bench/workload/README.md) part (a). Two
are worth naming here because they made the module *look* correct while
quietly doing the wrong thing: a failed buffer lookup silently **grew**
the registry it was looking in, and three `catch cError` sites raised
`Error (R24)` on every catch because Ring's `catch` takes no parameter.
Gate: `bench/workload/stkbuffer_reachable.ring`, 12/12, re-run
2026-08-25.

**Its own test suite could not run either** — 23 snippets under 23 `/*`
headers and one closing `*/`, so 476 lines silently became one comment
and only the last snippet ever executed. Repaired to run all 19 live
sections; two real behavioural questions surfaced and were left as
questions rather than decided unilaterally — `Compact()` not shrinking
capacity, and `Size()` succeeding on a freed buffer. Full account in
`bench/workload/README.md` part (b). Gate:
`stzlib/libraries/stzlib/core/test/run_stkbuffertest.sh`, re-run
2026-08-25: `PASS`.

## The optimisation, and the numbers — re-measured 2026-08-25

`Write` rebuilt the entire string on every call
(`left(@buffer,n) + data + right(@buffer,...)`) — cost proportional to
buffer size, not to the bytes written. When a write lands entirely inside
the existing bytes, the bytes now go in place through a pointer instead.
20,000 overwrites of 8 bytes, `bench/workload/stkbuffer_ab.ring`:

| buffer | rebuild (old) | in place (new) | speedup |
|---:|---:|---:|---:|
| 1 KB | 6.50 µs | 4.55 µs | **1.4×** |
| 10 KB | 7.55 µs | 4.40 µs | **1.7×** |
| 100 KB | 21.45 µs | 4.40 µs | **4.9×** |
| 1 MB | 660.50 µs | 4.40 µs | **150×** |

**Below 2× at 1 KB, reported anyway, per the gate's own rule**: *"if the
speedup is under 2×, say so and keep the old code."* The old path was
not kept, because the in-place write is also strictly simpler at every
size and the small-buffer case was never the point — but the honest
number is on the table rather than dropped from it.

**Correctness**, not just speed: `run_stkbuffertest.sh` diffs full
program output against a recorded baseline, byte for byte, filtered only
for the profiler's own timing banner. `PASS` on this run.

## The deviation this file exists to be honest about

**P3's phase text says "rewrite its hot path in Ring++."** This does
not call `RppBuffer`. It applies the *same underlying technique*
`RppBuffer.Poke` is built on — a `varptr` write straight into existing
bytes, skipping Ring's copy-on-call string rebuild
([FINDINGS](FINDINGS.md), the project's whole thesis,
`RING_VM_STACK_PUSHCVAR`) — directly inside `stkBuffer.Write`, without
going through Ring++'s type.

**That was a design decision, not a shortcut**, and it is recorded in
`bench/workload/README.md`'s own words: *"`RppBuffer`'s invariant is
fixed capacity created once, while `@buffer` is resized by `Prepend`,
`Insert`, `Delete`, `Resize` and `Clear`."* `stkBuffer` is a genuinely
resizable buffer; `RppBuffer` is genuinely not. Forcing the fixed-capacity
type onto a resizable one would be misusing `RppBuffer` outside the
invariant its own gate depends on (P2's break-even refusal exists for
exactly this reason) — the wrong fix wearing the right library's name.

So: a real hot path, in a real production module, rewritten using
Ring++'s central mechanism, measured before and after at a stated size,
verified byte-identical against a real test suite — **but not literally
`RppBuffer`, because `RppBuffer` does not fit this shape and forcing it
would have been the mistake.** Whether that satisfies P3's gate is a
judgement call between the letter and the intent; both readings are
recorded here rather than the file quietly picking one.

## What is still open under P3

A genuine `RppBuffer`/`RppView`/`RppIndexed` swap, in a real workload
whose shape actually fits their invariants (fixed-capacity buffer or
random-list-access, not a resizable one), has not been done. That would
close the letter of P3's gate; this file closes its intent.
